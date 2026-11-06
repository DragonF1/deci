// DeciTests/Music/MusicServiceTrackCacheTests.swift
// Tier 2a P3: the service's side of the track cache. The next song is resolved about 75 s before the end and handed to the
// analysis side; at the preload window the engine gets the cache file when it is ready (same exact duration and tracking
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
    private var outcomes: [String: MusicAnalysisCoordinator.Outcome] = [:]
    private var gates: [String: MusicTestGate] = [:]

    func setOutcome(_ id: String, _ outcome: MusicAnalysisCoordinator.Outcome) { outcomes[id] = outcome }
    func hold(_ id: String, _ gate: MusicTestGate) { gates[id] = gate }

    func ensure(stream: ResolvedStream, wantsFile: Bool) async -> MusicAnalysisCoordinator.Outcome {
        ensures.append((stream.videoId, wantsFile))
        origins[stream.videoId] = stream.origin
        if let gate = gates[stream.videoId] { await gate.wait() }
        return outcomes[stream.videoId] ?? .analysed(file: nil)
    }

    func release(videoId: String) { releases.append(videoId) }
    func discard(videoId: String) { discards.append(videoId) }
    func cancel(videoId: String) { cancels.append(videoId) }

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

    /// Ticks to `position`, then lets the prefetch (and the analysis task it starts) finish.
    func tick(_ position: TimeInterval) async {
        engine.tick(position, playing: true)
        await service.prefetchTask?.value
        await service.analysisTask?.value
        engine.tick(position + 0.5, playing: true)
    }
}

@MainActor
@Suite("MusicService track cache")
struct MusicServiceTrackCacheTests {
    @Test("nothing is resolved at 80 s left, the next song is resolved and handed over at 74 s left, once")
    func resolvesAtSeventyFive() async {
        let h = CacheHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c"])

        await h.tick(100)
        #expect(await h.analysis.ensuredIDs == ["a"], "only the song that plays")
        #expect(await h.backend.resolvedIDs == ["a"])

        await h.tick(126)
        await h.tick(130)
        #expect(await h.backend.resolvedIDs == ["a", "b"])
        #expect(await h.analysis.ensuredIDs == ["a", "b"])
        #expect(await h.analysis.ensures.last?.wantsFile == true)
        #expect(h.engine.preloads.isEmpty, "the preload still waits for its own window")
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

        h.engine.tick(126, playing: true)
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

    @Test("short songs and Loop song skip the early download")
    func shortAndLoopSkip() async {
        let short = CacheHarness()
        defer { short.cleanUp() }
        await short.startQueue(["a", "b"], duration: 100)
        await short.tick(30)
        await short.tick(85)
        #expect(await short.analysis.ensuredIDs == ["a"])

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
        h.engine.tick(126, playing: true)
        await h.service.prefetchTask?.value
        while await h.analysis.ensuredIDs.count < 2 { await Task.yield() }

        h.service.signOut()
        await gate.open()
        await h.service.analysisTask?.value
        await h.service.analysisCleanupTask?.value

        #expect(await h.analysis.cancels.contains("b"))
        #expect(await h.analysis.discards.contains("b"))
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
