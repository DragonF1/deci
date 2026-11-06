// Deci/Music/Analysis/MusicTrackCache.swift
import Foundation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicAnalysis")

/// A short-lived folder of whole songs, apart from the Downloads store (tier 2a P3). The next song is fetched here in
/// full so it can be analysed and then played from the file; the file is deleted once it has been played.
///
/// Nothing here goes through the Downloads index: a cached song is never "downloaded", never shown as such and never
/// protected from deletion. Only the transport and the ranged-fetch loop are shared with the Downloads queue.
actor MusicTrackCache {
    struct Limits: Sendable {
        var maxFiles = 4
        var maxBytes: Int64 = 200 * 1_048_576
        var minFreeBytes: Int64 = 1_024 * 1_048_576
        var staleAfter: TimeInterval = 3600
        /// A draining deck may still hold the old file for a crossfade (12 s at most).
        var graceAfterRelease: TimeInterval = 20
    }

    enum Failure: Error, Equatable { case diskFull, tooLarge, invalidVideoId, alreadyFetching }

    enum ReleaseReason: String, Sendable { case played, skipped, evicted, launch }

    static let sentinelName = ".deci-track-cache"
    static let fileExtension = "m4a"

    /// ~/Library/Caches/Deci/TrackCache
    static func liveRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Deci", isDirectory: true).appendingPathComponent("TrackCache", isDirectory: true)
    }

    /// Free bytes on the volume of `url`, or nil when the system will not say.
    static func liveFreeBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private let root: URL
    private let transport: any MusicDownloadTransport
    private let limits: Limits
    private let chunkSize: Int64
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let freeBytes: @Sendable (URL) -> Int64?

    private var inFlight: Set<String> = []
    private var pinned: Set<String> = []
    private var released: Set<String> = []
    private var releaseTasks: [String: Task<Void, Never>] = [:]
    /// When each finished file landed, for oldest-first eviction.
    private var finishedAt: [String: Date] = [:]

    init(
        root: URL,
        transport: any MusicDownloadTransport,
        limits: Limits = Limits(),
        chunkSize: Int = MusicDownloader.defaultChunkSize,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        freeBytes: @escaping @Sendable (URL) -> Int64? = MusicTrackCache.liveFreeBytes(at:)
    ) {
        self.root = root
        self.transport = transport
        self.limits = limits
        self.chunkSize = Int64(max(1, chunkSize))
        self.now = now
        self.sleep = sleep
        self.freeBytes = freeBytes
    }

    // MARK: - Fetch

    /// The whole song behind `stream`, in `<root>/<id>.m4a`. A finished file is reused with no request. Fresh streams
    /// come from `resolve` on expiry or a 403, as in the Downloads queue (three at most). A failure or a cancel leaves no
    /// `.part` file behind.
    func fetch(
        _ stream: ResolvedStream, resolve: @escaping @Sendable (String) async throws -> ResolvedStream
    ) async throws -> URL {
        let id = stream.videoId
        guard MusicDownloadStore.isValidVideoId(id) else { throw Failure.invalidVideoId }
        if let ready = readyFile(for: id) {
            unrelease(id)
            return ready
        }
        guard inFlight.insert(id).inserted else { throw Failure.alreadyFetching }
        defer { inFlight.remove(id) }
        try Task.checkCancellation()
        unrelease(id)

        let expected = MusicRangedFetch.contentLength(in: stream.url) ?? 0
        if expected > limits.maxBytes { throw Failure.tooLarge }
        try prepareRoot()
        if let free = freeBytes(root), free - expected < limits.minFreeBytes { throw Failure.diskFull }
        evict(toMakeRoomFor: 1)

        let started = now()
        logger.notice("track_cache_start id=\(id, privacy: .public)")
        let part = partURL(id)
        let final = fileURL(id)
        try? FileManager.default.removeItem(at: part)
        guard FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.diskFull
        }
        do {
            let handle = try FileHandle(forWritingTo: part)
            var isClosed = false
            defer { if !isClosed { try? handle.close() } }
            let result = try await MusicRangedFetch.run(
                videoId: id, stream: stream, transport: transport, chunkSize: chunkSize, handle: handle,
                now: now, resolve: resolve, maxBytes: limits.maxBytes, progress: { _ in }
            )
            try handle.synchronize()
            isClosed = true
            try handle.close()
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
            finishedAt[id] = now()
            let ms = Int(now().timeIntervalSince(started) * 1000)
            logger.notice("track_cache_ready id=\(id, privacy: .public) bytes=\(result.bytes) ms=\(ms)")
        } catch {
            try? FileManager.default.removeItem(at: part)
            logger.notice("track_cache_failed id=\(id, privacy: .public)")
            if let failure = error as? MusicRangedFetch.Failure, failure == .tooLarge { throw Failure.tooLarge }
            throw error
        }
        evict(toMakeRoomFor: 0)
        return final
    }

    /// A finished file that still exists; nil while only the `.part` is there.
    func readyFile(for videoId: String) -> URL? {
        guard MusicDownloadStore.isValidVideoId(videoId) else { return nil }
        let url = fileURL(videoId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Release

    /// The song was played or skipped: its file goes after the grace, unless it is pinned until then.
    func release(videoId: String, reason: ReleaseReason = .played) {
        guard MusicDownloadStore.isValidVideoId(videoId), readyFile(for: videoId) != nil else { return }
        released.insert(videoId)
        releaseTasks[videoId]?.cancel()
        releaseTasks[videoId] = Task { [grace = limits.graceAfterRelease, sleep] in
            do { try await sleep(grace) } catch { return }
            self.finishRelease(videoId, reason: reason)
        }
    }

    /// Deletes the file now, with no grace: for a file nobody plays (an analysis that ran on it and is done, or failed).
    func discard(videoId: String) {
        guard MusicDownloadStore.isValidVideoId(videoId) else { return }
        pinned.remove(videoId)
        unrelease(videoId)
        guard !inFlight.contains(videoId) else { return }
        remove(videoId, reason: .skipped)
    }

    /// Current and next songs are never evicted and never released while pinned.
    func pin(_ videoId: String) { pinned.insert(videoId) }

    func unpin(_ videoId: String) {
        pinned.remove(videoId)
        if released.contains(videoId), releaseTasks[videoId] == nil { finishRelease(videoId, reason: .played) }
    }

    /// Returns when every pending release has run, so a test does not race the delete.
    func drainReleases() async {
        let tasks = Array(releaseTasks.values)
        for task in tasks { await task.value }
    }

    private func finishRelease(_ videoId: String, reason: ReleaseReason) {
        releaseTasks[videoId] = nil
        guard released.contains(videoId), !pinned.contains(videoId) else { return }
        remove(videoId, reason: reason)
    }

    private func unrelease(_ videoId: String) {
        released.remove(videoId)
        releaseTasks[videoId]?.cancel()
        releaseTasks[videoId] = nil
    }

    private func remove(_ videoId: String, reason: ReleaseReason) {
        released.remove(videoId)
        finishedAt[videoId] = nil
        guard (try? FileManager.default.removeItem(at: fileURL(videoId))) != nil else { return }
        logger.notice("track_cache_released id=\(videoId, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
    }

    // MARK: - Housekeeping

    /// Empties the folder at launch: it is ours alone. A folder without the sentinel is not ours and is left alone.
    func sweepAtLaunch() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        guard names.isEmpty || names.contains(Self.sentinelName) else { return }
        for name in names where name != Self.sentinelName {
            let id = (name as NSString).deletingPathExtension
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
            if name.hasSuffix(".\(Self.fileExtension)") {
                logger.notice("track_cache_released id=\(id, privacy: .public) reason=launch")
            }
        }
        finishedAt.removeAll()
        released.removeAll()
    }

    /// Bytes of the finished files.
    func totalBytes() -> Int64 {
        finishedFiles().reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Private

    private func fileURL(_ id: String) -> URL { root.appendingPathComponent("\(id).\(Self.fileExtension)", isDirectory: false) }
    private func partURL(_ id: String) -> URL { root.appendingPathComponent("\(id).\(Self.fileExtension).part", isDirectory: false) }

    private func prepareRoot() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let sentinel = root.appendingPathComponent(Self.sentinelName)
        if !fileManager.fileExists(atPath: sentinel.path) {
            fileManager.createFile(atPath: sentinel.path, contents: Data())
        }
    }

    private func finishedFiles() -> [(id: String, bytes: Int64, date: Date)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".\(Self.fileExtension)") else { return nil }
            let id = (name as NSString).deletingPathExtension
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let date = finishedAt[id] ?? (attributes?[.modificationDate] as? Date) ?? .distantPast
            return (id, bytes, date)
        }
    }

    /// Deletes the oldest unpinned files while there are more than `maxFiles - reserve` or more than `maxBytes`.
    private func evict(toMakeRoomFor reserve: Int) {
        var files = finishedFiles().sorted { $0.date < $1.date }
        var bytes = files.reduce(Int64(0)) { $0 + $1.bytes }
        while files.count > max(0, limits.maxFiles - reserve) || bytes > limits.maxBytes {
            guard let index = files.firstIndex(where: { !pinned.contains($0.id) && !inFlight.contains($0.id) }) else { break }
            let victim = files.remove(at: index)
            bytes -= victim.bytes
            unrelease(victim.id)
            remove(victim.id, reason: .evicted)
        }
    }
}
