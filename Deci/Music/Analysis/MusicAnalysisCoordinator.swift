// Deci/Music/Analysis/MusicAnalysisCoordinator.swift
import Foundation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicAnalysis")

/// What the service (and, in P4, the background analyzer) needs from the analysis side. A protocol so the service's tests
/// use a fake that never touches a file or the network.
protocol MusicAnalysisProviding: Sendable {
    /// Makes sure `stream`'s song has a fresh analysis. With `wantsFile` a song that had to be fetched keeps its file,
    /// pinned, and the outcome names it so it can be played; without it the file is deleted at once.
    func ensure(stream: ResolvedStream, wantsFile: Bool) async -> MusicAnalysisCoordinator.Outcome
    /// The song was played or skipped: its cache file (if any) is deleted after the grace.
    func release(videoId: String) async
    /// Nobody will play the song's cache file after all (the queue changed): deleted now.
    func discard(videoId: String) async
    /// Cancels an `ensure` still running for the song.
    func cancel(videoId: String) async
}

/// Reads the stored analysis of a song (tier 2b): what the transition planner is built from. Separate from
/// `MusicAnalysisProviding` so the service's existing fakes stay as they are.
protocol MusicAnalysisReading: Sendable {
    func analysis(for videoId: String) async -> MusicAnalysis?
}

extension MusicAnalysisCoordinator: MusicAnalysisReading {}

/// A song in the Downloads store: its file and the exact duration it was downloaded with.
struct MusicDownloadedFile: Sendable, Equatable {
    var url: URL
    var durationSeconds: Double?
}

/// The policy that ties the track cache, the analyzer and the store together:
/// fresh entry, nothing to do; downloaded, analyse that file with no fetch; otherwise fetch into the cache, analyse,
/// store, and keep or delete the file. Duplicate requests for one song share one run.
actor MusicAnalysisCoordinator: MusicAnalysisProviding {
    enum Outcome: Equatable, Sendable {
        case alreadyFresh
        /// Analysed and stored. `file` is the cache file when one was made and kept (`wantsFile`).
        case analysed(file: URL?)
        case failed
        /// The fetch met a 429 or a 403 (an address that expired too often): the caller should back off.
        case rateLimited
    }

    typealias Analyze = @Sendable (URL, Double?) async throws -> MusicFileAnalyzer.Result

    private let store: MusicAnalysisStore
    private let cache: MusicTrackCache
    private let downloads: @Sendable (String) async -> MusicDownloadedFile?
    private let resolve: @Sendable (String) async throws -> ResolvedStream
    private let analyze: Analyze
    private let now: @Sendable () -> Date

    /// One shared run per song. `joiners` maps each waiting caller to whether it wants the file; the run is cancelled only
    /// when no joiner is left, and a joiner that wants the file keeps it for everyone.
    private struct Run {
        var task: Task<Outcome, Never>
        var token: UUID
        var joiners: [UUID: Bool]
        var cancelled = false
    }

    private var running: [String: Run] = [:]

    init(
        store: MusicAnalysisStore,
        cache: MusicTrackCache,
        downloads: @escaping @Sendable (String) async -> MusicDownloadedFile?,
        resolve: @escaping @Sendable (String) async throws -> ResolvedStream,
        analyze: @escaping Analyze = { try await MusicFileAnalyzer.analyze(file: $0, exactDuration: $1) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.cache = cache
        self.downloads = downloads
        self.resolve = resolve
        self.analyze = analyze
        self.now = now
    }

    func analysis(for videoId: String) async -> MusicAnalysis? {
        await store.entry(for: videoId)
    }

    /// Songs whose entry is of an older analysis version, oldest first (the idle queue's last stretch).
    func storeStaleVideoIds(limit: Int) async -> [String] {
        await store.staleVideoIds(limit: limit)
    }

    func ensure(stream: ResolvedStream, wantsFile: Bool) async -> Outcome {
        let id = stream.videoId
        // A run that was cancelled is let finish (it clears itself) before a new caller starts or joins one.
        while let run = running[id], run.cancelled { _ = await run.task.value }
        let me = UUID()
        let token: UUID
        let task: Task<Outcome, Never>
        if var run = running[id] {
            run.joiners[me] = wantsFile
            running[id] = run
            token = run.token
            task = run.task
        } else {
            token = UUID()
            task = Task { await self.run(stream, token: token) }
            running[id] = Run(task: task, token: token, joiners: [me: wantsFile])
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(id, token: token, joiner: me) }
        }
    }

    func release(videoId: String) async {
        await cache.unpin(videoId)
        await cache.release(videoId: videoId)
    }

    func discard(videoId: String) async {
        await cache.discard(videoId: videoId)
    }

    /// Drops the interest of every caller that does not want the file; the run stops unless one that does is waiting.
    func cancel(videoId: String) async {
        guard var run = running[videoId], !run.joiners.values.contains(true) else { return }
        run.cancelled = true
        running[videoId] = run
        run.task.cancel()
    }

    /// One caller stopped waiting: the run is cancelled when it was the last.
    private func leave(_ id: String, token: UUID, joiner: UUID) {
        guard var run = running[id], run.token == token, run.joiners.removeValue(forKey: joiner) != nil else { return }
        if run.joiners.isEmpty {
            run.cancelled = true
            run.task.cancel()
        }
        running[id] = run
    }

    /// Ends the run's entry (once; a later call finds a different token or none) and says whether a joiner wants the file.
    @discardableResult
    private func retire(_ id: String, token: UUID) -> Bool {
        guard let run = running[id], run.token == token else { return false }
        running[id] = nil
        return !run.cancelled && run.joiners.values.contains(true)
    }

    private func wantsFile(_ id: String, token: UUID) -> Bool {
        guard let run = running[id], run.token == token else { return false }
        return run.joiners.values.contains(true)
    }

    // MARK: - Run

    private func run(_ stream: ResolvedStream, token: UUID) async -> Outcome {
        let outcome = await work(stream, token: token)
        retire(stream.videoId, token: token)
        return outcome
    }

    private func work(_ stream: ResolvedStream, token: UUID) async -> Outcome {
        let id = stream.videoId
        let expected = MusicAnalysis.Format(
            codec: stream.audioCodec ?? "", itag: stream.itag,
            durationMs: Int(((stream.durationSeconds ?? 0) * 1000).rounded())
        )
        switch await store.freshness(of: id, matching: expected) {
        case .fresh:
            logger.notice("analysis_skip id=\(id, privacy: .public) why=fresh")
            return .alreadyFresh
        case .staleFormat:
            logger.notice("analysis_stale id=\(id, privacy: .public) why=format")
        case .staleVersion:
            logger.notice("analysis_stale id=\(id, privacy: .public) why=version")
        case .missing:
            break
        }

        // A downloaded song is analysed from its own file: nothing is fetched.
        if let local = await downloads(id) {
            logger.notice("analysis_skip id=\(id, privacy: .public) why=downloaded")
            guard await analyseAndStore(
                stream: stream, file: local.url, duration: local.durationSeconds ?? stream.durationSeconds,
                format: expected, source: .download
            ) else { return .failed }
            return .analysed(file: nil)
        }

        let file: URL
        do {
            await cache.pin(id)
            file = try await cache.fetch(stream, resolve: resolve)
        } catch {
            await cache.unpin(id)
            return MusicBackgroundAnalyzer.isRateLimit(error) ? .rateLimited : .failed
        }
        let stored = await analyseAndStore(
            stream: stream, file: file, duration: stream.durationSeconds, format: expected,
            source: wantsFile(id, token: token) ? .playbackCache : .backgroundCache
        )
        guard stored, !Task.isCancelled else {
            retire(id, token: token)
            await cache.discard(videoId: id)
            return .failed
        }
        // Decided and retired in one step: a caller that comes later starts its own run instead of reading this one.
        if retire(id, token: token) { return .analysed(file: file) }
        await cache.discard(videoId: id)
        return .analysed(file: nil)
    }

    private func analyseAndStore(
        stream: ResolvedStream, file: URL, duration: Double?, format: MusicAnalysis.Format, source: MusicAnalysis.Source
    ) async -> Bool {
        do {
            let result = try await analyze(file, duration)
            var stored = format
            // The reader knows the codec; the stream knows the itag and the exact duration.
            if !result.format.codec.isEmpty { stored.codec = result.format.codec }
            let entry = MusicAnalysis(
                videoId: stream.videoId, measurement: result.measurement, format: stored, source: source,
                analyzedAt: now(), youtubeLoudnessDb: stream.loudnessDb,
                youtubePerceptualLoudnessDb: stream.perceptualLoudnessDb
            )
            try await store.put(entry)
            return true
        } catch {
            return false
        }
    }
}
