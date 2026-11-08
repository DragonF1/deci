// DeciTests/Music/LiveChecks/LiveWorld.swift
// The shared world of the live checks: the songs, the real analysis of each of them (MusicFileAnalyzer with beat_this,
// stored through the real MusicAnalysisCoordinator and MusicAnalysisStore), the synced lyrics, a fake backend that resolves
// each id to its local file, and the factory for a real MusicService on top of it.

import Foundation
@testable import Deci

/// A transport that is never asked: every song is a local file, so the coordinator analyses it with no fetch.
nonisolated struct LiveNoTransport: MusicDownloadTransport {
    func fetch(
        url: URL, range: ClosedRange<Int64>, headers: [String: String], received: @escaping @Sendable (Int) -> Void
    ) async throws -> MusicDownloadChunk {
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
final class LiveWorld {
    let songs: [LiveSong]
    let byId: [String: LiveSong]
    let store: MusicAnalysisStore
    let coordinator: MusicAnalysisCoordinator
    private(set) var rows: [String: MusicAnalysis] = [:]
    private(set) var lyricLines: [String: [LyricLine]] = [:]
    private(set) var lyricIntervals: [String: [ClosedRange<Double>]] = [:]
    private(set) var instrumentals: Set<String> = []
    private(set) var analysisSeconds = 0.0
    private(set) var analysedNow = 0

    private static var cached: LiveWorld?

    static func shared() async throws -> LiveWorld {
        if let cached { return cached }
        LiveDirs.make()
        let world = try LiveWorld()
        try await world.prepare()
        cached = world
        return world
    }

    private init() throws {
        songs = try LiveSongs.load()
        byId = Dictionary(uniqueKeysWithValues: songs.map { ($0.videoId, $0) })
        store = MusicAnalysisStore(url: LiveDirs.store.appendingPathComponent("Analysis.sqlite"))
        let cache = MusicTrackCache(
            root: LiveDirs.cache, transport: LiveNoTransport(), chunkSize: 5_000, sleep: { _ in },
            freeBytes: { _ in Int64.max / 2 }
        )
        let files = Dictionary(uniqueKeysWithValues: songs.map { ($0.videoId, $0) })
        coordinator = MusicAnalysisCoordinator(
            store: store, cache: cache,
            downloads: { id in files[id].map { MusicDownloadedFile(url: $0.url, durationSeconds: $0.duration) } },
            resolve: { id in
                guard let song = files[id] else { throw URLError(.fileDoesNotExist) }
                return song.stream
            }
        )
    }

    /// Real analysis of every song (kept in the store between runs), then the lyrics.
    private func prepare() async throws {
        let started = Date()
        let coordinator = coordinator
        let songs = songs
        var done = 0
        try await withThrowingTaskGroup(of: (String, MusicAnalysisCoordinator.Outcome).self) { group in
            var next = 0
            func launch() {
                guard next < songs.count else { return }
                let song = songs[next]
                next += 1
                group.addTask { (song.videoId, await coordinator.ensure(stream: song.stream, wantsFile: false)) }
            }
            for _ in 0..<2 { launch() }
            while let (id, outcome) = try await group.next() {
                done += 1
                if case .analysed = outcome { analysedNow += 1 }
                if outcome == .failed { print("LIVE analysis failed for \(id)") }
                launch()
            }
        }
        for song in songs {
            if let row = await coordinator.analysis(for: song.videoId) { rows[song.videoId] = row }
        }
        analysisSeconds = Date().timeIntervalSince(started)
        print("LIVE analysis: \(rows.count)/\(songs.count) rows, \(analysedNow) analysed this run, \(Int(analysisSeconds)) s")
        for song in songs {
            let entry = await LiveLyrics.fetch(song)
            if let lines = entry.lines {
                lyricLines[song.videoId] = lines
                lyricIntervals[song.videoId] = MusicVocalIntervals.from(lines: lines, duration: song.duration)
            } else if entry.instrumental {
                instrumentals.insert(song.videoId)
                lyricIntervals[song.videoId] = []
            }
        }
        print("LIVE lyrics: \(lyricIntervals.count)/\(songs.count) songs with synced lyrics or instrumental")
    }

    /// The planner's own gate for a grid.
    nonisolated static func gatePasses(_ g: MusicBeatGrid) -> Bool {
        MusicBeatGrid.periodRange.contains(g.periodSec) && g.beatConfidence >= MusicBeatPlanner.minConfidence
            && g.intervalSpread <= MusicBeatPlanner.maxIntervalSpread && abs(g.driftSec) <= MusicBeatPlanner.maxDriftSec
    }

    // MARK: - A real service

    func makeBackend() async -> FakeMusicBackend {
        let backend = FakeMusicBackend()
        for song in songs { await backend.setStream(song.stream) }
        return backend
    }

    func makeLookahead() -> MusicVocalLookahead {
        let answers = Dictionary(uniqueKeysWithValues: lyricIntervals.keys.map { id -> (String, LyricsAnswer) in
            if let lines = lyricLines[id] { return (id, LyricsAnswer(result: .synced(lines), credit: nil, lengthMatters: false)) }
            return (id, LyricsAnswer(result: .instrumental, credit: nil, lengthMatters: false))
        })
        return MusicVocalLookahead(
            readCache: { answers[$0] },
            youtube: { _ in throw URLError(.notConnectedToInternet) }
        )
    }

    /// The pieces of one real MusicService: real analysis, real planner, real queue; only the network is the fake backend.
    struct Rig {
        let service: MusicService
        let player: Deci.MusicPlayer
        let backend: FakeMusicBackend
        let saved: SavedPreferences
        let clock: MutableClock
    }

    func makeRig(
        engine: any PlaybackEngine, preferences: MusicPlaybackPreferences, backend: FakeMusicBackend, seed: UInt64 = 11,
        withLyrics: Bool = true
    ) -> Rig {
        let clock = MutableClock()
        let saved = SavedPreferences()
        let player = MusicPlayer(engine: engine)
        let surface = FakeNowPlayingSurface()
        let lookahead = withLyrics ? makeLookahead() : nil
        let service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: preferences,
            savePreferences: { saved.last = $0; saved.count += 1 },
            shuffleSeed: seed,
            queueRetryDelay: .seconds(60),
            connectivity: MusicConnectivity(isOnline: true),
            refreshOnCreate: false,
            analysis: coordinator,
            analysisReader: coordinator,
            vocalLookahead: lookahead
        )
        return Rig(service: service, player: player, backend: backend, saved: saved, clock: clock)
    }

    /// Waits for every task the service started to finish (the way the Mix harness does).
    func settle(_ service: MusicService) async {
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
}
