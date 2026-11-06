// Deci/Music/Analysis/MusicBackgroundAnalyzer.swift
import Foundation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicAnalysis")

/// Battery as the idle queue reads it: whether the Mac runs on its battery, and how full that is (nil: no battery).
struct MusicBatteryState: Sendable, Equatable {
    var onBattery: Bool
    var fraction: Double?
}

/// Everything the idle queue asks about the machine and the app. A protocol so tests drive every rule.
protocol MusicBackgroundEnvironment: Sendable {
    /// The Settings toggle "Analyse songs in the background".
    func isEnabled() async -> Bool
    /// Playing, or about to (a song loading under a play).
    func isPlaying() async -> Bool
    func isOnline() async -> Bool
    func isSignedIn() async -> Bool
    /// The Downloads queue has songs waiting or on their way.
    func isDownloadsBusy() async -> Bool
    func isLowPowerMode() async -> Bool
    /// The thermal state is serious or critical.
    func isThermallyConstrained() async -> Bool
    func battery() async -> MusicBatteryState
}

/// What the idle queue reads from the analysis store.
protocol MusicAnalysisLookup: Sendable {
    /// The store holds an entry for the song, of any freshness.
    func hasEntry(_ videoId: String) async -> Bool
    /// Songs whose entry is of an older analysis version, oldest first.
    func staleVideoIds(limit: Int) async -> [String]
}

/// The lists the idle queue works through, as closures over the existing backend: Liked music ("VLLM") and every playlist
/// of the library, read the way a download of a collection reads them (`MusicCollectionEnumerator`).
struct MusicBackgroundSource: Sendable {
    var liked: @Sendable () async throws -> [String]
    /// Browse ids of the library's playlists.
    var playlistIDs: @Sendable () async throws -> [String]
    var playlistSongs: @Sendable (String) async throws -> [String]
}

/// Analyses the songs of the library one at a time while the Mac and the player are idle, so smart transitions have data
/// before a song is ever played. Politeness towards YouTube: one song at a time, a gap between songs, an hourly cap and a
/// long hold after a rate limit. Never touches playback; any block (playback, offline, power) cancels the song in flight.
actor MusicBackgroundAnalyzer {
    struct Policy: Sendable {
        var minGapBetweenSongs: TimeInterval = 20
        var hourlyCap = 30
        var rateLimitHold: TimeInterval = 600
        var repeatedRateLimitHold: TimeInterval = 3600
        var quietAfterPlayback: TimeInterval = 60
        var minBatteryFraction = 0.5
        /// How often the blocks are looked at while the queue waits or a song is in flight.
        var pollInterval: TimeInterval = 5
        var rescanInterval: TimeInterval = 6 * 3600
        /// The rescan after a list could not be read.
        var failedRescanInterval: TimeInterval = 900
        var staleBatch = 50
        var maxSongsPerPlaylist = 500
    }

    enum Block: Equatable, Sendable {
        case disabled, playing, recentlyPlayed, offline, signedOut, downloadsBusy, lowPowerMode, thermal, battery
    }

    private enum Stage { case liked, playlistList, playlists, stale, done }

    /// A fetch error that means YouTube is limiting us: 429, or a 403 (also when the address expired too often).
    nonisolated static func isRateLimit(_ error: any Error) -> Bool {
        if let download = error as? MusicDownloadError {
            switch download {
            case .reResolveLimit: return true
            case .badStatus(let code): return code == 429 || code == 403
            default: return false
            }
        }
        if let music = error as? MusicError, let status = music.httpStatus { return status == 429 || status == 403 }
        return false
    }

    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let provider: any MusicAnalysisProviding
    private let lookup: any MusicAnalysisLookup
    private let source: MusicBackgroundSource
    private let resolve: @Sendable (String) async throws -> ResolvedStream
    private let env: any MusicBackgroundEnvironment
    private let policy: Policy
    private let now: @Sendable () -> Date
    private let sleep: Sleep

    private var loop: Task<Void, Never>?
    private var lastPlayingAt: Date?
    private var nextAllowedAt: Date?
    private var holdUntil: Date?
    private var rateLimitStrikes = 0
    private var starts: [Date] = []

    private var stage: Stage = .liked
    private var pending: [String] = []
    private var pendingIsStale = false
    private var queued: Set<String> = []
    private var attempted: Set<String> = []
    private var playlistQueue: [String] = []
    private var scanHadError = false
    private var exhaustedAt: Date?
    private var interrupted = false

    private(set) var analysedCount = 0

    init(
        provider: any MusicAnalysisProviding,
        lookup: any MusicAnalysisLookup,
        source: MusicBackgroundSource,
        resolve: @escaping @Sendable (String) async throws -> ResolvedStream,
        env: any MusicBackgroundEnvironment,
        policy: Policy = Policy(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.provider = provider
        self.lookup = lookup
        self.source = source
        self.resolve = resolve
        self.env = env
        self.policy = policy
        self.now = now
        self.sleep = sleep
    }

    /// Starts the queue. Idempotent. The queue idles (and polls) while the toggle is off. A queue started after a stop
    /// scans afresh: the stopped loop may still be finishing a step, and it must not leave half a scan behind.
    func start() {
        guard loop == nil else { return }
        resetScan()
        loop = Task { await self.run() }
    }

    /// Ends the queue; a song in flight is cancelled. The loop exits at its next check and touches no state after it.
    func stop() {
        loop?.cancel()
        loop = nil
    }

    var isRunning: Bool { loop != nil }

    // MARK: - Gate

    /// Why nothing may run now, nil when the machine and the app are idle. Also learns when playback was last seen.
    func currentBlock() async -> Block? {
        guard await env.isEnabled() else { return .disabled }
        if await env.isPlaying() {
            lastPlayingAt = now()
            return .playing
        }
        if let last = lastPlayingAt, now().timeIntervalSince(last) < policy.quietAfterPlayback { return .recentlyPlayed }
        guard await env.isOnline() else { return .offline }
        guard await env.isSignedIn() else { return .signedOut }
        if await env.isDownloadsBusy() { return .downloadsBusy }
        if await env.isLowPowerMode() { return .lowPowerMode }
        if await env.isThermallyConstrained() { return .thermal }
        let battery = await env.battery()
        if battery.onBattery, (battery.fraction ?? 1) < policy.minBatteryFraction { return .battery }
        return nil
    }

    /// Seconds until pacing allows the next song: the gap after the last, a rate-limit hold, the hourly cap.
    func paceWait() -> TimeInterval {
        let current = now()
        var until = current
        if let allowed = nextAllowedAt { until = max(until, allowed) }
        if let hold = holdUntil { until = max(until, hold) }
        starts.removeAll { current.timeIntervalSince($0) >= 3600 }
        if starts.count >= policy.hourlyCap, let oldest = starts.first {
            until = max(until, oldest.addingTimeInterval(3600))
        }
        return until.timeIntervalSince(current)
    }

    // MARK: - Loop

    private func run() async {
        while !Task.isCancelled {
            if await currentBlock() != nil {
                if await idle(policy.pollInterval) { return }
                continue
            }
            let wait = paceWait()
            if wait > 0 {
                if await idle(min(wait, policy.pollInterval)) { return }
                continue
            }
            if let done = exhaustedAt {
                let interval = scanHadError ? policy.failedRescanInterval : policy.rescanInterval
                let remaining = interval - now().timeIntervalSince(done)
                if remaining > 0 {
                    if await idle(min(remaining, policy.pollInterval)) { return }
                    continue
                }
                resetScan()
            }
            let next = await nextID()
            // A loop that was stopped (and maybe replaced) while it read a list leaves the shared scan alone.
            if Task.isCancelled { return }
            guard let id = next else {
                exhaustedAt = now()
                continue
            }
            await process(id)
        }
    }

    /// Sleeps; true when the loop was cancelled meanwhile.
    private func idle(_ seconds: TimeInterval) async -> Bool {
        do { try await sleep(seconds) } catch { return true }
        return Task.isCancelled
    }

    private func process(_ id: String) async {
        guard !Task.isCancelled else { return }
        attempted.insert(id)
        interrupted = false
        logger.notice("bg_analysis_start id=\(id, privacy: .public)")
        let began = now()
        let outcome: MusicAnalysisCoordinator.Outcome
        do {
            let stream = try await resolve(id)
            outcome = await runJob(stream)
        } catch {
            if Task.isCancelled { return }
            if interrupted { return giveBack(id) }
            finish(rateLimited: Self.isRateLimit(error))
            return
        }
        // A stopped loop (the scan restarts on the next start) leaves the shared state alone.
        if Task.isCancelled { return }
        if interrupted { return giveBack(id) }
        switch outcome {
        case .alreadyFresh:
            break
        case .analysed:
            analysedCount += 1
            rateLimitStrikes = 0
            let ms = Int(now().timeIntervalSince(began) * 1000)
            logger.notice("bg_analysis_done id=\(id, privacy: .public) ms=\(ms)")
            finish(rateLimited: false)
        case .failed:
            finish(rateLimited: false)
        case .rateLimited:
            finish(rateLimited: true)
        }
    }

    /// The song was cut short by a block or a stop: it stays in line, and costs neither a slot nor a gap.
    private func giveBack(_ id: String) {
        attempted.remove(id)
        pending.insert(id, at: 0)
    }

    private func finish(rateLimited: Bool) {
        let current = now()
        starts.append(current)
        nextAllowedAt = current.addingTimeInterval(policy.minGapBetweenSongs)
        if rateLimited {
            rateLimitStrikes += 1
            let hold = rateLimitStrikes == 1 ? policy.rateLimitHold : policy.repeatedRateLimitHold
            holdUntil = current.addingTimeInterval(hold)
            logger.notice("bg_analysis_hold hold=\(Int(hold)) why=ratelimit")
        }
    }

    /// Runs the coordinator for `stream` while watching the blocks: a block (or a stop) cancels the work.
    private func runJob(_ stream: ResolvedStream) async -> MusicAnalysisCoordinator.Outcome {
        let provider = self.provider
        let id = stream.videoId
        let work = Task { await provider.ensure(stream: stream, wantsFile: false) }
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.sleep(self.policy.pollInterval) } catch { return }
                if Task.isCancelled { return }
                if await self.currentBlock() != nil {
                    await self.markInterrupted()
                    work.cancel()
                    await provider.cancel(videoId: id)
                    return
                }
            }
        }
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
            watcher.cancel()
            Task { await provider.cancel(videoId: id) }
        }
        watcher.cancel()
        return outcome
    }

    private func markInterrupted() { interrupted = true }

    // MARK: - Which song next

    private func resetScan() {
        stage = .liked
        pending = []
        pendingIsStale = false
        queued = []
        attempted = []
        playlistQueue = []
        scanHadError = false
        exhaustedAt = nil
    }

    /// Liked songs, then each playlist in library order, then the songs whose entry is of an old version. Songs with an
    /// entry are skipped (the old ones come back in the last stretch); each song is asked for once per scan.
    private func nextID() async -> String? {
        while !Task.isCancelled {
            while !pending.isEmpty {
                let id = pending.removeFirst()
                if !pendingIsStale, await lookup.hasEntry(id) {
                    if Task.isCancelled { return nil }
                    continue
                }
                return Task.isCancelled ? nil : id
            }
            guard await fill() else { return nil }
        }
        return nil
    }

    /// Each list is applied only if the loop is still live after reading it: a stopped loop adds nothing.
    private func fill() async -> Bool {
        switch stage {
        case .liked:
            stage = .playlistList
            let songs = await read { try await self.source.liked() }
            guard !Task.isCancelled else { return false }
            add(songs)
        case .playlistList:
            stage = .playlists
            let ids = await read { try await self.source.playlistIDs() }
            guard !Task.isCancelled else { return false }
            playlistQueue = ids
        case .playlists:
            guard !playlistQueue.isEmpty else {
                stage = .stale
                return true
            }
            let browseId = playlistQueue.removeFirst()
            let songs = await read { try await self.source.playlistSongs(browseId) }
            guard !Task.isCancelled else { return false }
            add(Array(songs.prefix(policy.maxSongsPerPlaylist)))
        case .stale:
            stage = .done
            pendingIsStale = true
            let stale = await lookup.staleVideoIds(limit: policy.staleBatch)
            guard !Task.isCancelled else { return false }
            pending = stale.filter { !attempted.contains($0) }
        case .done:
            return false
        }
        return true
    }

    private func read(_ body: () async throws -> [String]) async -> [String] {
        do { return try await body() } catch {
            scanHadError = true
            return []
        }
    }

    private func add(_ ids: [String]) {
        for id in ids where MusicDownloadStore.isValidVideoId(id) && queued.insert(id).inserted {
            pending.append(id)
        }
    }
}

extension MusicAnalysisCoordinator: MusicAnalysisLookup {
    func hasEntry(_ videoId: String) async -> Bool { await analysis(for: videoId) != nil }
    func staleVideoIds(limit: Int) async -> [String] { await storeStaleVideoIds(limit: limit) }
}
