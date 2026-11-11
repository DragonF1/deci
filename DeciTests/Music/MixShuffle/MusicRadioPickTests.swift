// DeciTests/Music/MixShuffle/MusicRadioPickTests.swift
// Radio pick: while songs blend (Crossfade or Mix) the first ten radio songs after the playing one are analysed one at a
// time and the one that mixes best out of it becomes the next song. Plain playback keeps the radio's order. The pick can
// change only until the next song is locked (the preload is offered, or its prefetch has started).

import Foundation
import Testing
@testable import Deci

/// A provider that stores the row a test scripted for a song when `ensure` runs (the real one stores what it analysed),
/// and counts how many analyses run at once.
actor RadioRowProvider: MusicAnalysisProviding {
    private let reader: FakeAnalysisReader
    private var rows: [String: MusicAnalysis] = [:]
    private var outcomes: [String: MusicAnalysisCoordinator.Outcome] = [:]
    private var gates: [String: MusicTestGate] = [:]
    private var stored: Set<String> = []
    private(set) var ensures: [String] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    init(reader: FakeAnalysisReader) { self.reader = reader }

    func script(_ row: MusicAnalysis) { rows[row.videoId] = row }
    func setOutcome(_ id: String, _ outcome: MusicAnalysisCoordinator.Outcome) { outcomes[id] = outcome }
    func hold(_ id: String, _ gate: MusicTestGate) { gates[id] = gate }

    func ensure(stream: ResolvedStream, wantsFile: Bool) async -> MusicAnalysisCoordinator.Outcome {
        let id = stream.videoId
        ensures.append(id)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if let gate = gates[id] { await gate.wait() }
        var outcome = outcomes[id] ?? .analysed(file: nil)
        if stored.contains(id) { outcome = .alreadyFresh }
        if case .analysed = outcome, let row = rows[id] {
            stored.insert(id)
            await reader.set(row)
        }
        inFlight -= 1
        return outcome
    }

    func release(videoId: String) {}
    func discard(videoId: String) {}
    func cancel(videoId: String) {}
}

@MainActor
private struct PickHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let connectivity = MusicConnectivity(isOnline: true)
    let reader = FakeAnalysisReader()
    let provider: RadioRowProvider
    let player: MusicPlayer
    let service: MusicService

    static let radio = (1...12).map { "r\($0)" }

    init(crossfade: Bool, seed: UInt64 = 11) {
        let engine = self.engine
        let clock = self.clock
        let player = MusicPlayer(engine: engine)
        self.player = player
        let provider = RadioRowProvider(reader: reader)
        self.provider = provider
        service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: MusicPlaybackPreferences(crossfade: crossfade, crossfadeSeconds: 6),
            shuffleSeed: seed,
            queueRetryDelay: .seconds(60),
            connectivity: connectivity,
            refreshOnCreate: false,
            analysis: provider,
            analysisReader: reader
        )
    }

    /// The playing song's own row: 128 BPM in 8A.
    func storeAnchor(_ id: String) async { await reader.set(MixRows.row(id, bpm: 128, tonic: 9, minor: true)) }

    /// Rows the analysis will store: `matching` mix well after the anchor, every other radio song is far from it.
    func script(matching: Set<String>, among ids: [String] = PickHarness.radio) async {
        for id in ids {
            let match = matching.contains(id)
            await provider.script(MixRows.row(id, bpm: match ? 128 : 70, tonic: match ? 9 : 3, minor: !match))
        }
    }

    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            let mix = service.mixTask
            let staged = service.stagedRadioTask
            await staged?.value
            await play?.value
            await radio?.value
            await mix?.value
            await service.currentAnalysisTask?.value
            await service.analysisCleanupTask?.value
            await service.transitionReadTask?.value
            if service.playTask == play, service.radioTask == radio, service.mixTask == mix { break }
        }
    }

    /// Settles, then waits for the radio scan (and whatever it started) to end.
    func settleScan() async {
        await settle()
        while true {
            let scan = service.radioScanTask
            await scan?.value
            await settle()
            if service.radioScanTask == scan { break }
        }
    }

    func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<3000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    /// A one-song page whose automix after it is the radio: the song is the last of its page, so the radio is next.
    func startPage(radio: [String] = PickHarness.radio) async {
        await storeAnchor("a")
        for id in ["a"] + radio { await backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
        await backend.setAutomix(afterVideoId: "a", tracks: MusicSamples.tracks("a") + radio.map { MusicSamples.track($0) })
        let page = MusicSamples.page("VLPL1", tracks: [MusicSamples.track("a", title: "Song a")], audioPlaylistId: nil)
        service.play(MusicSamples.track("a", title: "Song a"), in: page)
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// A tapped song whose radio joins the queue itself.
    func startRadio(radio: [String] = PickHarness.radio) async {
        await storeAnchor("s")
        for id in ["s"] + radio { await backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
        let tracks = ["s"].map { MusicSamples.track($0, title: "Song \($0)") } + radio.map { MusicSamples.track($0) }
        await backend.setRadio(seed: "s", tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// The radio songs the analysis was asked for (the playing song's own analysis is left out).
    func radioEnsures() async -> [String] { await provider.ensures.filter { $0.hasPrefix("r") } }

    var staged: [String] { service.queue.autoplay.map(\.videoId) }
    var order: [String] { service.queue.tracks.map(\.videoId) }
    var pickLines: [String] { service.transitionLines.filter { $0.hasPrefix("radio_pick ") } }
}

@MainActor
@Suite("MusicRadioPick")
struct MusicRadioPickTests {
    private func profile(_ id: String, bpm: Double, tonic: Int, minor: Bool) -> MusicMixProfile {
        MusicMixProfile(videoId: id, artist: "", analysis: MixRows.row(id, bpm: bpm, tonic: tonic, minor: minor))
    }

    private func unknown(_ id: String) -> MusicMixProfile { MusicMixProfile(videoId: id, artist: "", analysis: nil) }

    @Test("the best match wins and a tie goes to the earlier song")
    func bestOfKnown() {
        let anchor = profile("a", bpm: 128, tonic: 9, minor: true)
        let far = profile("far", bpm: 70, tonic: 3, minor: false)
        let near1 = profile("near1", bpm: 128, tonic: 9, minor: true)
        let near2 = profile("near2", bpm: 128, tonic: 9, minor: true)
        let choice = MusicRadioPick.best(of: [far, near1, near2], after: anchor)
        #expect(choice?.videoId == "near1")
    }

    @Test("songs without a row are not picked while another has one")
    func unknownNeverBeatsKnown() {
        let anchor = profile("a", bpm: 128, tonic: 9, minor: true)
        let far = profile("far", bpm: 70, tonic: 3, minor: false)
        #expect(MusicRadioPick.best(of: [unknown("u1"), far, unknown("u2")], after: anchor)?.videoId == "far")
    }

    @Test("nothing to score from means no pick: no row in the candidates, or none for the song it follows")
    func noBasis() {
        let anchor = profile("a", bpm: 128, tonic: 9, minor: true)
        #expect(MusicRadioPick.best(of: [unknown("u1"), unknown("u2")], after: anchor) == nil)
        #expect(MusicRadioPick.best(of: [profile("n", bpm: 128, tonic: 9, minor: true)], after: unknown("a")) == nil)
        #expect(MusicRadioPick.best(of: [], after: anchor) == nil)
    }

    @Test("Crossfade alone: the best of the first ten radio songs, analysed one at a time, becomes the next song")
    func crossfadeStagedPicksBest() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r7"])
        await h.startPage()
        await h.settleScan()
        #expect(h.staged == ["r7", "r1", "r2", "r3", "r4", "r5", "r6", "r8", "r9", "r10", "r11", "r12"])
        #expect(await h.radioEnsures() == ["r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10"])
        #expect(await h.provider.maxInFlight == 1)
    }

    @Test("the eleventh radio song is never analysed and never picked, however well it matches")
    func eleventhIgnored() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r11", "r12"])
        await h.startPage()
        await h.settleScan()
        let analysed = await h.radioEnsures()
        #expect(!analysed.contains("r11"))
        #expect(!analysed.contains("r12"))
        #expect(h.staged == PickHarness.radio)
    }

    @Test("Mix picks the best of the first ten by real analysis, whatever the seed")
    func mixPicksBest() async {
        for seed in [1, 2, 3, 4] as [UInt64] {
            let h = PickHarness(crossfade: false, seed: seed)
            await h.script(matching: ["r7"])
            await h.startPage()
            h.service.setShuffleMode(.mix)
            await h.settleScan()
            #expect(h.staged.first == "r7")
            #expect(Set(h.staged) == Set(PickHarness.radio))
            let analysed = await h.radioEnsures()
            #expect(!analysed.contains("r11"))
            #expect(!analysed.contains("r12"))
        }
    }

    @Test("a tapped song's radio in Crossfade: the best of the first ten moves to the first slot, the rest keep their order")
    func tappedRadioCrossfade() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r5"])
        await h.startRadio()
        await h.settleScan()
        #expect(h.order == ["s", "r5", "r1", "r2", "r3", "r4", "r6", "r7", "r8", "r9", "r10", "r11", "r12"])
        #expect(await h.radioEnsures() == ["r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10"])
    }

    @Test("a Play next song stays ahead of the radio; the pick is made once it plays")
    func playNextStaysAhead() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r7"])
        await h.reader.set(MixRows.row("q", bpm: 128, tonic: 9, minor: true))
        await h.backend.setStream(MusicSamples.stream(videoId: "q", duration: 240))
        await h.startRadio()
        h.service.playNext(MusicSamples.track("q", title: "Song q"))
        #expect(h.order.prefix(2) == ["s", "q"])
        await h.settleScan()
        #expect(h.order.prefix(2) == ["s", "q"])
        h.service.next()
        await h.settleScan()
        #expect(h.service.queue.current?.videoId == "q")
        #expect(h.service.queue.upcoming.first?.videoId == "r7")
        #expect(h.order.first == "s")
    }

    @Test("without Crossfade or Mix the radio keeps its order and nothing is analysed")
    func noBlendKeepsOrder() async {
        let h = PickHarness(crossfade: false)
        await h.script(matching: ["r7"])
        await h.startPage()
        await h.settleScan()
        #expect(h.staged == PickHarness.radio)
        #expect(await h.radioEnsures().isEmpty)
        let tapped = PickHarness(crossfade: false)
        await tapped.script(matching: ["r7"])
        await tapped.startRadio()
        await tapped.settleScan()
        #expect(tapped.order == ["s"] + PickHarness.radio)
        #expect(await tapped.radioEnsures().isEmpty)
    }

    @Test("plain Shuffle is no blend either: nothing is analysed")
    func shuffleKeepsOrder() async {
        let h = PickHarness(crossfade: false)
        await h.script(matching: ["r7"])
        await h.startPage()
        h.service.setShuffleMode(.shuffle)
        await h.settleScan()
        #expect(h.staged == PickHarness.radio)
        #expect(await h.radioEnsures().isEmpty)
    }

    @Test("with no row for any candidate the radio order stays, in Crossfade")
    func noRowsKeepsOrder() async {
        let h = PickHarness(crossfade: true)
        await h.startPage()
        await h.settleScan()
        #expect(h.staged == PickHarness.radio)
        #expect(h.pickLines.last?.contains("reason=order") == true)
    }

    @Test("a rate limit stops the scan and the best match so far is kept")
    func rateLimitedStops() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r2"])
        await h.provider.setOutcome("r3", .rateLimited)
        await h.startPage()
        await h.settleScan()
        #expect(await h.radioEnsures() == ["r1", "r2", "r3"])
        #expect(h.staged.first == "r2")
        #expect(Set(h.staged) == Set(PickHarness.radio))
    }

    @Test("a candidate that failed is not asked for again in the session")
    func failedNotRetried() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r7"])
        await h.provider.setOutcome("r2", .failed)
        await h.startPage()
        await h.settleScan()
        h.service.setCrossfade(false)
        h.service.setCrossfade(true)
        await h.settleScan()
        let asked = await h.radioEnsures()
        #expect(asked.filter { $0 == "r2" }.count == 1)
        #expect(asked.filter { $0 == "r1" }.count == 1)
        #expect(h.staged.first == "r7")
    }

    @Test("once the preload is offered a late row never moves the next song")
    func lockedNeverMoves() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r7"])
        let gate = MusicTestGate()
        await h.provider.hold("r7", gate)
        await h.startPage()
        let reached = await h.waitUntil { await h.radioEnsures().contains("r7") }
        #expect(reached)
        #expect(h.staged.first == "r1")
        h.service.offerPreloadForTesting("r1")
        await gate.open()
        await h.settleScan()
        #expect(h.staged.first == "r1")
        #expect(h.pickLines.last?.contains("reason=locked") == true)
    }

    @Test("the next song's own analysis waits for the scan's running analysis: never two at once")
    func neverTwoAtOnce() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r7"])
        let gate = MusicTestGate()
        await h.provider.hold("r2", gate)
        await h.startPage()
        let reached = await h.waitUntil { await h.radioEnsures().contains("r2") }
        #expect(reached)
        // Into the lead window: the prefetch of the next song starts and locks the pick.
        h.engine.tick(200, playing: true)
        await h.service.prefetchTask?.value
        await gate.open()
        await h.service.analysisTask?.value
        await h.settleScan()
        #expect(await h.provider.maxInFlight == 1)
        #expect(h.staged.first == "r1")
    }

    @Test("the early prefetch of the next song waits while the scan runs")
    func earlyPrefetchWaits() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r7"])
        let gate = MusicTestGate()
        await h.provider.hold("r2", gate)
        await h.startPage()
        let reached = await h.waitUntil { await h.radioEnsures().contains("r2") }
        #expect(reached)
        h.engine.tick(5, playing: true)
        h.clock.advance(by: MusicService.analysisSettle + 0.1)
        h.engine.tick(5.25, playing: true)
        #expect(h.service.prefetchTask == nil)
        await gate.open()
        await h.settleScan()
        #expect(h.staged.first == "r7")
        h.engine.tick(5.5, playing: true)
        h.clock.advance(by: MusicService.analysisSettle + 0.1)
        h.engine.tick(5.75, playing: true)
        #expect(h.service.prefetchTask != nil)
        await h.service.prefetchTask?.value
    }

    @Test("rolling: after the hand-over the next scan analyses only the songs not analysed before")
    func rollingAnalysesOnlyNewSongs() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r7"])
        await h.startPage()
        await h.settleScan()
        #expect(h.staged.first == "r7")
        h.service.next()
        await h.settleScan()
        #expect(h.service.queue.current?.videoId == "r7")
        let asked = await h.radioEnsures()
        #expect(asked.filter { $0 == "r1" }.count == 1)
        #expect(asked.filter { $0 == "r11" }.count == 1)
        #expect(!asked.contains("r12"))
        #expect(h.pickLines.count >= 2)
    }

    @Test("the log line names the candidates, what was analysed, the pick and why")
    func logLine() async {
        let h = PickHarness(crossfade: true)
        await h.script(matching: ["r7"])
        await h.startPage()
        await h.settleScan()
        let line = h.pickLines.last ?? ""
        #expect(line.contains("candidates=10"))
        #expect(line.contains("analysed=10"))
        #expect(line.contains("known=10"))
        #expect(line.contains("picked=r7"))
        #expect(line.contains("reason=best"))
    }
}
