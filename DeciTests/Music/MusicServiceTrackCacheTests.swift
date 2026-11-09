// DeciTests/Music/MusicServiceTrackCacheTests.swift
// Tier 2a P3: the service's side of the track cache. The next song is resolved as soon as it has settled as next (about
// 1 s) and handed to the analysis side; at the preload window the engine gets the cache file when it is ready (same exact duration and tracking
// URLs, origin trackCache) or the network stream when it is not, and never a second preload. A cache file is never
// mistaken for a download. A fake analysis provider stands in for the cache, the store and the network.

import Foundation
import Testing
@testable import Deci

actor FakeAnalysisProvider: MusicAnalysisProviding {
    private(set) var ensures: [(id: String, wantsFile: Bool)] = []
    private(set) var origins: [String: ResolvedStream.Origin] = [:]
    private(set) var releases: [String] = []
    private(set) var discards: [String] = []
    private(set) var cancels: [String] = []
    /// Songs whose `ensure` was stopped by its caller's task being cancelled (the only cancel the real coordinator honours
    /// while a caller that wants the file is waiting).
    private(set) var taskCancels: [String] = []
    /// Songs that have a row stored: a second `ensure` for one answers `.alreadyFresh` with no file, as the store would.
    private var stored: Set<String> = []
    /// Held songs whose waiting caller wants the file.
    private var waitingForFile: Set<String> = []
    private var outcomes: [String: MusicAnalysisCoordinator.Outcome] = [:]
    private var gates: [String: MusicTestGate] = [:]
    private var cancelGates: [String: MusicTestGate] = [:]
    /// Every provider call in the order it took effect: "ensure:x", "cancel:x" (when it returned), "discard:x".
    private(set) var events: [String] = []

    func holdCancel(_ id: String, _ gate: MusicTestGate) { cancelGates[id] = gate }

    func setOutcome(_ id: String, _ outcome: MusicAnalysisCoordinator.Outcome) { outcomes[id] = outcome }
    func hold(_ id: String, _ gate: MusicTestGate) { gates[id] = gate }

    func ensure(stream: ResolvedStream, wantsFile: Bool) async -> MusicAnalysisCoordinator.Outcome {
        ensures.append((stream.videoId, wantsFile))
        events.append("ensure:\(stream.videoId)")
        origins[stream.videoId] = stream.origin
        let id = stream.videoId
        if let gate = gates[id] {
            if wantsFile { waitingForFile.insert(id) }
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                Task { await self.stop(id, gate) }
            }
            waitingForFile.remove(id)
        }
        if taskCancels.contains(id), Task.isCancelled { return .failed }
        if stored.contains(id) { return .alreadyFresh }
        stored.insert(id)
        return outcomes[id] ?? .analysed(file: nil)
    }

    private func stop(_ id: String, _ gate: MusicTestGate) async {
        taskCancels.append(id)
        await gate.open()
    }

    func release(videoId: String) { releases.append(videoId) }
    func discard(videoId: String) {
        discards.append(videoId)
        events.append("discard:\(videoId)")
    }

    func cancel(videoId: String) async {
        cancels.append(videoId)
        // Like the coordinator: a plain cancel does nothing while a caller that wants the file is waiting.
        if waitingForFile.contains(videoId) { return }
        if let gate = cancelGates[videoId] { await gate.wait() }
        events.append("cancel:\(videoId)")
    }

    var ensuredIDs: [String] { ensures.map(\.id) }
}

@MainActor
private struct CacheHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let connectivity = MusicConnectivity(isOnline: true)
    let analysis = FakeAnalysisProvider()
    let player: MusicPlayer
    let service: MusicService
    let folder: URL

    init(crossfade: Bool = false, downloads: MusicDownloadService? = nil) {
        let engine = self.engine
        let clock = self.clock
        let player = MusicPlayer(engine: engine)
        self.player = player
        folder = URL(fileURLWithPath: "/Volumes/Storage/_test/deci-2a/service-cache", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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
            queueRetryDelay: .seconds(60),
            downloads: downloads,
            connectivity: connectivity,
            refreshOnCreate: false,
            analysis: analysis
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    /// A real file on disk, as the cache would have made.
    func makeFile(_ id: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(id).m4a")
        try Data("audio".utf8).write(to: url)
        return url
    }

    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            await play?.value
            await radio?.value
            await service.currentAnalysisTask?.value
            await service.analysisCleanupTask?.value
            if service.playTask == play, service.radioTask == radio { break }
        }
    }

    func startQueue(_ ids: [String], duration: Double = 200) async {
        for id in ids { await backend.setStream(MusicSamples.stream(videoId: id, duration: duration)) }
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)") }
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Ticks twice with the settle between them, without waiting for the work the second tick starts.
    func settledTick(_ position: TimeInterval) {
        engine.tick(position, playing: true)
        clock.advance(by: MusicService.analysisSettle + 0.1)
        engine.tick(position + 0.25, playing: true)
    }

    /// A page ending in `tap` with the automix after it staged, so the next song at the end is the radio's first.
    func startPageWithRadio(_ ids: [String], radio: [String]) async {
        for id in ids + radio { await backend.setStream(MusicSamples.stream(videoId: id, duration: 200)) }
        await backend.setAutomix(afterVideoId: ids.last!, tracks: MusicSamples.tracks(ids.last!) + radio.map { MusicSamples.track($0) })
        let page = MusicSamples.page("VLPL1", tracks: ids.map { MusicSamples.track($0, title: "Song \($0)") })
        service.play(MusicSamples.track(ids.last!, title: "Song \(ids.last!)"), in: page)
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Ticks to `position`, then lets the prefetch (and the analysis task it starts) finish.
    func tick(_ position: TimeInterval) async {
        settledTick(position)
        await service.prefetchTask?.value
        await service.analysisTask?.value
        engine.tick(position + 0.5, playing: true)
    }
}

@MainActor
@Suite("MusicService track cache")
struct MusicServiceTrackCacheTests {
    @Test("the next song is resolved and handed over right after play starts, once, with its file wanted")
    func resolvesRightAway() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c"])

        await h.tick(1)
        #expect(await h.backend.resolvedIDs == ["a", "b"])
        #expect(await h.analysis.ensuredIDs == ["a", "b"])
        #expect(await h.analysis.ensures.last?.wantsFile == true)

        await h.tick(30)
        await h.tick(130)
        #expect(await h.backend.resolvedIDs == ["a", "b"], "one resolve and one fetch per next song")
        #expect(await h.analysis.ensuredIDs == ["a", "b"])
        #expect(h.engine.preloads.isEmpty, "the preload still waits for its own window")
    }

    @Test("a short current song analyses its next song too")
    func shortCurrentSongAnalysesNext() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"], duration: 100)
        await h.tick(1)
        #expect(await h.analysis.ensuredIDs == ["a", "b"])
    }

    @Test("when the queue ends the radio's first song is the next one analysed")
    func radioFirstSong() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startPageWithRadio(["a", "b"], radio: ["r1", "r2"])
        #expect(h.service.queue.autoplay.first?.videoId == "r1")

        await h.tick(1)

        #expect(await h.analysis.ensuredIDs == ["b", "r1"])
        #expect(await h.analysis.ensures.last?.wantsFile == true)
    }

    @Test("a next song that is not settled yet is not fetched: rapid skips only fetch the song they land on")
    func rapidSkipsDoNotFetch() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c", "d", "e"])
        h.engine.tick(1, playing: true)
        for id in ["c", "d"] {
            h.service.playNext(MusicSamples.track(id, title: "Song \(id)"))
            h.clock.advance(by: 0.3)
            h.engine.tick(2, playing: true)
        }
        await h.service.prefetchTask?.value
        #expect(await h.backend.resolvedIDs == ["a"], "nothing next has held for a second yet")

        await h.tick(3)
        #expect(await h.analysis.ensuredIDs == ["a", "d"])
    }

    @Test("a next song that already has a row is handed to the coordinator, which fetches nothing for it")
    func analysedNextIsNotFetched() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"])
        await h.analysis.setOutcome("b", .alreadyFresh)
        await h.tick(1)
        await h.tick(30)
        #expect(await h.analysis.ensuredIDs == ["a", "b"], "asked once, the coordinator answers from the store")
    }

    @Test("when the next song changes mid-analysis the old job finishes and stores, its file is discarded, the new next waits behind it")
    func nextChangesMidAnalysis() async throws {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c"])
        let file = try h.makeFile("b")
        await h.analysis.setOutcome("b", .analysed(file: file))
        let gate = MusicTestGate()
        await h.analysis.hold("b", gate)
        h.settledTick(1)
        await h.service.prefetchTask?.value
        while await h.analysis.ensuredIDs.count < 2 { await Task.yield() }

        h.service.playNext(MusicSamples.track("c", title: "Song c"))
        h.settledTick(2)
        await h.service.prefetchTask?.value

        await gate.open()
        await h.service.analysisTask?.value
        await h.service.analysisCleanupTask?.value
        let events = await h.analysis.events
        #expect(events.filter { $0.hasPrefix("ensure:") } == ["ensure:a", "ensure:b", "ensure:c"], "\(events)")
        let ensureC = events.firstIndex(of: "ensure:c") ?? -1
        let discardB = events.firstIndex(of: "discard:b") ?? -1
        #expect(discardB >= 0, "b's file is released, nobody will play it")
        #expect(await h.analysis.ensures.first { $0.id == "b" }?.wantsFile == true)
        #expect(await h.analysis.cancels.isEmpty, "the running job is never cancelled")
        #expect(await h.analysis.taskCancels.isEmpty)
        _ = ensureC
    }

    @Test("nothing is analysed ahead signed out")
    func signedOutAnalysesNothing() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"])
        h.service.signOut()
        await h.tick(1)
        #expect(await h.analysis.ensuredIDs == ["a"])
    }

    @Test("a stream resolved early that is about to expire is replaced once, just before the offer, not at every tick")
    func expiringStreamIsResolvedAgain() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"])
        await h.backend.setStream(MusicSamples.stream(videoId: "b", expiresAt: Date(timeIntervalSinceNow: 30), duration: 200))
        await h.tick(1)
        await h.tick(60)
        #expect(await h.backend.resolvedIDs == ["a", "b"], "far from the window: not resolved again")
        await h.tick(186)
        await h.tick(187)
        await h.tick(188)
        #expect(await h.backend.resolvedIDs == ["a", "b", "b"], "replaced once even though the answer expires soon too")
        #expect(h.engine.preloads.count == 1)
    }

    @Test("with the file ready the engine is offered the file: same duration, same tracking URLs, origin trackCache")
    func preloadsTheFile() async throws {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"])
        let file = try h.makeFile("b")
        await h.analysis.setOutcome("b", .analysed(file: file))

        await h.tick(126)
        await h.tick(186)

        let offered = try #require(h.engine.preloads.last)
        #expect(h.engine.preloads.count == 1)
        #expect(offered.url == file)
        #expect(offered.origin == .trackCache)
        let network = MusicSamples.stream(videoId: "b", duration: 200)
        #expect(offered.durationSeconds == network.durationSeconds)
        #expect(offered.playbackTrackingURL == network.playbackTrackingURL)
        #expect(offered.watchtimeTrackingURL == network.watchtimeTrackingURL)
    }

    @Test("with the file not ready the network stream is preloaded, and a file that lands later offers no second preload")
    func fallbackThenNoSecondPreload() async throws {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"])
        let gate = MusicTestGate()
        await h.analysis.hold("b", gate)
        let file = try h.makeFile("b")
        await h.analysis.setOutcome("b", .analysed(file: file))

        h.settledTick(126)
        await h.service.prefetchTask?.value
        h.engine.tick(186, playing: true)
        #expect(h.engine.preloads.count == 1)
        #expect(h.engine.preloads.first?.origin == .network)

        await gate.open()
        await h.service.analysisTask?.value
        h.engine.tick(187, playing: true)
        h.engine.tick(188, playing: true)
        #expect(h.engine.preloads.count == 1, "the standby deck is never swapped mid-schedule")
    }

    @Test("a gapless advance releases the track that left exactly once, and a cache file is not a download")
    func gaplessReleasesAndIsNotADownload() async throws {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c"])
        let file = try h.makeFile("b")
        await h.analysis.setOutcome("b", .analysed(file: file))
        await h.tick(126)
        await h.tick(186)

        h.engine.advance()
        await h.settle()

        #expect(h.service.player.nowPlaying?.videoId == "b")
        #expect(await h.analysis.releases == ["a"])
        #expect(await h.analysis.discards.isEmpty)
        #expect(h.player.isPlayingLocalFile == false)
        #expect(h.engine.preloads.last?.origin == .trackCache)
        // No second resolve for ping URLs: the cache stream kept the first one's.
        #expect(await h.backend.resolvedIDs.filter { $0 == "b" }.count == 1)
    }

    @Test("a manual skip onto the preloaded song with Crossfade on releases the track that left once")
    func crossfadeSkipReleases() async throws {
        let h = CacheHarness(crossfade: true)
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c"])
        let file = try h.makeFile("b")
        await h.analysis.setOutcome("b", .analysed(file: file))
        await h.tick(126)
        await h.tick(180)

        h.service.next()
        await h.settle()

        #expect(await h.analysis.releases == ["a"])
        #expect(await h.analysis.discards.isEmpty)
    }

    @Test("a skip past the prefetched song releases the one that left and discards the one nobody played")
    func skipPastDiscardsSpeculative() async throws {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c", "d"])
        await h.tick(126)
        #expect(await h.analysis.ensuredIDs == ["a", "b"])

        h.service.play(MusicSamples.track("d", title: "Song d"))
        await h.settle()

        #expect(await h.analysis.releases == ["a"])
        #expect(await h.analysis.discards == ["b"])
    }

    @Test("X, then Y, then X again: the new fetch of X starts only after the old cleanup, so a late cancel or discard cannot hit it")
    func requeueWaitsForCleanup() async throws {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c", "d"])
        await h.tick(126)
        #expect(await h.analysis.ensuredIDs == ["a", "b"])

        let gate = MusicTestGate()
        await h.analysis.holdCancel("b", gate)
        h.service.playNext(MusicSamples.track("c", title: "Song c"))
        h.settledTick(127)
        await h.service.prefetchTask?.value
        h.service.playNext(MusicSamples.track("b", title: "Song b"))
        h.settledTick(128)
        await h.service.prefetchTask?.value
        for _ in 0..<50 { await Task.yield() }

        #expect(await h.analysis.ensuredIDs.filter { $0 == "b" }.count == 1, "no new fetch while b's old cleanup is pending")

        await gate.open()
        await h.service.analysisCleanupTask?.value
        await h.service.analysisTask?.value
        let events = await h.analysis.events
        let lastEnsure = try #require(events.lastIndex(of: "ensure:b"))
        #expect(events.filter { $0 == "ensure:b" }.count == 2)
        #expect(!events[lastEnsure...].contains("cancel:b"))
        #expect(!events[lastEnsure...].contains("discard:b"))
    }

    @Test("B, then C, then B again while B's job runs: the running job is taken back, so its file is kept and played")
    func nextAgainAdoptsRunningJob() async throws {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c", "d"])
        let file = try h.makeFile("b")
        await h.analysis.setOutcome("b", .analysed(file: file))
        let gate = MusicTestGate()
        await h.analysis.hold("b", gate)
        h.settledTick(126)
        await h.service.prefetchTask?.value
        while await h.analysis.ensuredIDs.count < 2 { await Task.yield() }

        h.service.playNext(MusicSamples.track("c", title: "Song c"))
        h.settledTick(127)
        await h.service.prefetchTask?.value
        h.service.playNext(MusicSamples.track("b", title: "Song b"))
        h.settledTick(128)
        await h.service.prefetchTask?.value
        await h.service.analysisCleanupTask?.value

        await gate.open()
        await h.service.analysisTask?.value
        await h.service.analysisCleanupTask?.value
        await h.tick(186)

        #expect(await h.analysis.ensuredIDs.filter { $0 == "b" }.count == 1, "no second job for b")
        #expect(await h.analysis.discards.filter { $0 == "b" }.isEmpty, "b's file is not discarded")
        #expect(await h.analysis.ensuredIDs.contains("c") == false, "c never started: it was dropped while it waited")
        let offered = try #require(h.engine.preloads.last)
        #expect(offered.url == file, "the preload plays from the file the taken-back job made")
        #expect(offered.origin == .trackCache)
    }

    @Test("the playing song is handed over once, without a file, and ticks never ask again")
    func currentTrackOnce() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"])
        #expect(await h.analysis.ensures.map(\.id) == ["a"])
        #expect(await h.analysis.ensures.first?.wantsFile == false)

        for position in stride(from: 1.0, through: 60, by: 0.5) { h.engine.tick(position, playing: true) }
        await h.service.currentAnalysisTask?.value
        #expect(await h.analysis.ensures.map(\.id) == ["a"], "one ask per track, never one per tick")
        #expect(h.engine.loads.count == 1, "playback is not touched")
    }

    @Test("each track that starts is handed over once, offline and signed out ask nothing")
    func currentTrackPerTrack() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"])
        h.service.next()
        await h.settle()
        #expect(await h.analysis.ensures.map(\.id) == ["a", "b"])

        let offline = CacheHarness()
        defer { offline.cleanUp() }
        offline.connectivity.update(isOnline: false)
        await offline.startQueue(["a", "b"])
        #expect(await offline.analysis.ensures.isEmpty)
    }

    @Test("a downloaded song is handed over as a file stream, so the coordinator reads its file and fetches nothing")
    func downloadedCurrentTrack() async {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        let id = DownloadSamples.idA
        rig.download(id)
        let done = await rig.settles(id, as: .downloaded)
        #expect(done)
        let h = CacheHarness(downloads: rig.service)
        defer { h.cleanUp() }

        await h.startQueue([id, "b"])

        #expect(await h.analysis.ensures.first?.id == id)
        #expect(await h.analysis.ensures.first?.wantsFile == false)
        #expect(await h.analysis.origins[id] == .download)
    }

    @Test("Loop song analyses nothing ahead")
    func loopSkips() async {
        let loop = CacheHarness()
        defer { loop.cleanUp() }
        await loop.startQueue(["a", "b"])
        loop.service.setLoopMode(.song)
        await loop.tick(126)
        await loop.tick(186)
        #expect(await loop.analysis.ensuredIDs == ["a"])
    }

    @Test("offline nothing is resolved or fetched")
    func offlineSkipsEverything() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"])
        h.connectivity.update(isOnline: false)

        await h.tick(126)

        #expect(await h.analysis.ensuredIDs == ["a"])
        #expect(await h.backend.resolvedIDs == ["a"])
    }

    @Test("signing out cancels the running job and discards the file it was fetching")
    func signOutCancels() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"])
        let gate = MusicTestGate()
        await h.analysis.hold("b", gate)
        h.settledTick(126)
        await h.service.prefetchTask?.value
        while await h.analysis.ensuredIDs.count < 2 { await Task.yield() }

        h.service.signOut()
        await gate.open()
        await h.service.analysisTask?.value
        await h.service.analysisCleanupTask?.value

        #expect(await h.analysis.cancels.contains("b"))
        #expect(await h.analysis.discards.contains("b"))
    }

    @Test("signing out also stops a job that stopped being next and is still running, by cancelling its task")
    func signOutStopsRetiredJob() async throws {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c"])
        let file = try h.makeFile("b")
        await h.analysis.setOutcome("b", .analysed(file: file))
        let gate = MusicTestGate()
        await h.analysis.hold("b", gate)
        h.settledTick(1)
        await h.service.prefetchTask?.value
        while await h.analysis.ensuredIDs.count < 2 { await Task.yield() }
        h.service.playNext(MusicSamples.track("c", title: "Song c"))
        h.settledTick(2)
        await h.service.prefetchTask?.value

        h.service.signOut()
        await h.service.analysisTask?.value
        await h.service.analysisCleanupTask?.value
        while await h.analysis.taskCancels.isEmpty { await Task.yield() }

        #expect(await h.analysis.taskCancels == ["b"], "the retired job is stopped through its task")
        #expect(await h.analysis.ensuredIDs == ["a", "b"], "the waiting job for c never starts")
    }

    @Test("a drop after a retire still queues the next job behind the running one: never two fetches at once")
    func dropKeepsChain() async throws {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c", "d"])
        let gate = MusicTestGate()
        await h.analysis.hold("b", gate)
        h.settledTick(1)
        await h.service.prefetchTask?.value
        while await h.analysis.ensuredIDs.count < 2 { await Task.yield() }
        // b is retired by c, then c is dropped by d: d must still wait behind b.
        h.service.playNext(MusicSamples.track("c", title: "Song c"))
        h.settledTick(2)
        await h.service.prefetchTask?.value
        h.service.playNext(MusicSamples.track("d", title: "Song d"))
        h.settledTick(3)
        await h.service.prefetchTask?.value
        await h.service.analysisCleanupTask?.value
        for _ in 0..<50 { await Task.yield() }
        #expect(await h.analysis.ensuredIDs == ["a", "b"], "d waits while b still runs")

        await gate.open()
        await h.service.analysisTask?.value
        #expect(await h.analysis.ensuredIDs == ["a", "b", "d"])
    }

    @Test("a failed early resolve is tried once more at the preload window, and an expiring stream is replaced once before the offer")
    func resolveRetry() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b"])
        await h.backend.setResolveError("b", URLError(.timedOut))
        await h.tick(1)
        #expect(await h.backend.resolvedIDs == ["a", "b"])
        await h.tick(60)
        #expect(await h.backend.resolvedIDs == ["a", "b"], "not retried before the window")
        await h.backend.clearResolveError("b")
        await h.tick(186)
        #expect(await h.backend.resolvedIDs == ["a", "b", "b"])
        #expect(h.engine.preloads.count == 1)
    }

    @Test("without an analysis provider nothing changes: the song is resolved only at the preload window")
    func noProviderIsTierOne() async {
        let backend = FakeMusicBackend()
        let engine = FakePlaybackEngine()
        let service = MusicService(
            backend: backend, player: MusicPlayer(engine: engine),
            presentSignIn: { _ in }, presentChannelPicker: { _, _ in }, closeSignInWindow: {}, raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            connectivity: MusicConnectivity(isOnline: true), refreshOnCreate: false
        )
        let tracks = ["a", "b"].map { MusicSamples.track($0, title: "Song \($0)") }
        await backend.setRadio(seed: "a", tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await service.playTask?.value
        engine.emit(.playingChanged(true))

        engine.tick(126, playing: true)
        await service.prefetchTask?.value
        #expect(await backend.resolvedIDs == ["a"])
        engine.tick(186, playing: true)
        await service.prefetchTask?.value
        #expect(await backend.resolvedIDs == ["a", "b"])
    }
}
