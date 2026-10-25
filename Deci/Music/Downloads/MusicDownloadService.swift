// Deci/Music/Downloads/MusicDownloadService.swift
import Foundation
import Observation
import os

/// Where one song stands with downloading.
enum MusicDownloadState: Equatable, Sendable {
    /// Not downloaded, not asked for.
    case none
    /// Asked for and waiting its turn.
    case queued
    /// On its way; `fraction` is 0 to 1 of the file.
    case downloading(fraction: Double)
    /// On disk and played from there.
    case downloaded
    /// The last try ended in an error. Asking again tries again.
    case failed
}

/// The app's side of downloads: which songs are downloaded or on their way, one download at a time in the order
/// asked, and the local stream playback prefers to the network.
///
/// What a row shows comes from `state(for:)`, which reads only what that row's own state depends on: a queued row is
/// not redrawn by another song's progress. Progress reaches the row about four times a second at most.
@MainActor
@Observable
final class MusicDownloadService {
    /// The least time between two progress values shown to a row.
    static let progressInterval: TimeInterval = 0.25

    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicDownloads")

    // What rows read. A download's fraction is its own property, so only the row downloading it follows progress.
    private var entries: [String: MusicDownloadStore.Entry] = [:]
    private var queue: [MusicTrack] = []
    private var activeID: String?
    private var activeFraction: Double = 0
    private var failedIDs: Set<String> = []

    private let store: MusicDownloadStore
    private let downloader: MusicDownloader
    private let now: @Sendable () -> Date
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var removedBeforeLoad: Set<String> = []
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var activeTask: Task<MusicDownloadStore.Entry, any Error>?
    @ObservationIgnored private var activeWasRemoved = false
    @ObservationIgnored private var lastProgressAt = Date.distantPast
    @ObservationIgnored private var storeWork: Task<Void, Never>?
    /// The id of the song playing from its file on disk, nil when the player plays from the network or nothing.
    @ObservationIgnored private var playingLocalID: String?
    /// Songs removed while they played from their file: gone from the index, the file kept until playback leaves them.
    @ObservationIgnored private var keptFiles: Set<String> = []

    init(store: MusicDownloadStore, downloader: MusicDownloader, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.downloader = downloader
        self.now = now
        loadTask = Task { [weak self] in
            let loaded = await store.load()
            self?.finishLoading(loaded)
        }
    }

    /// The service for the app: downloads under Application Support, streams resolved by `resolve`.
    static func live(resolve: @escaping @Sendable (String) async throws -> ResolvedStream) -> MusicDownloadService {
        let store = MusicDownloadStore(root: MusicDownloadStore.liveRoot())
        let downloader = MusicDownloader(store: store, transport: URLSessionDownloadTransport(), resolve: resolve)
        return MusicDownloadService(store: store, downloader: downloader)
    }

    // MARK: - Reading

    /// The song's state. A row reading it follows only the pieces its answer rests on.
    func state(for videoId: String) -> MusicDownloadState {
        if entries[videoId] != nil { return .downloaded }
        if activeID == videoId { return .downloading(fraction: activeFraction) }
        if queue.contains(where: { $0.videoId == videoId }) { return .queued }
        if failedIDs.contains(videoId) { return .failed }
        return .none
    }

    /// The file on disk as a stream, or nil when the song is not downloaded, the index has not loaded yet, or the file
    /// has vanished or is not the size the index says (the song then stops showing as downloaded and the file goes). A
    /// `.part` file is never offered.
    func localStream(for videoId: String) -> ResolvedStream? {
        guard let entry = entries[videoId], let url = store.audioURL(for: videoId) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        guard size?.int64Value == entry.bytes else {
            forget(videoId)
            return nil
        }
        // The length the stream stated when it was downloaded: AVFoundation reads the fragmented file at double.
        // Nothing reads the itag of a local file.
        return ResolvedStream(
            videoId: videoId,
            url: url,
            itag: 0,
            durationSeconds: entry.durationSeconds,
            expiresAt: .distantFuture,
            playbackTrackingURL: nil,
            httpHeaders: [:]
        )
    }

    /// Returns once the downloads of earlier launches have been read from disk.
    func waitUntilLoaded() async {
        await loadTask?.value
    }

    /// Returns once nothing is queued or running and every job on the disk has finished, including ones started while it
    /// waited. A removal answers at once and deletes later; this is how a caller knows the disk has caught up.
    func waitUntilIdle() async {
        await waitUntilLoaded()
        while true {
            let running = pump
            let work = storeWork
            await running?.value
            await work?.value
            if pump == nil, storeWork == work { return }
        }
    }

    private func finishLoading(_ loaded: [String: MusicDownloadStore.Entry]) {
        hasLoaded = true
        entries = loaded.filter { !removedBeforeLoad.contains($0.key) }
        removedBeforeLoad = []
    }

    /// The file is gone from disk or damaged: stop calling the song downloaded, drop its entry and what is left of the file.
    private func forget(_ videoId: String) {
        entries[videoId] = nil
        removeFromStore(videoId)
    }

    // MARK: - Downloading

    /// Queues the song. A song already queued, downloading or downloaded is left alone; one that failed tries again.
    func download(_ track: MusicTrack) {
        let videoId = track.videoId
        switch state(for: videoId) {
        case .queued, .downloading, .downloaded: return
        case .none, .failed: break
        }
        guard MusicDownloadStore.isValidVideoId(videoId) else {
            failedIDs.insert(videoId)
            return
        }
        if failedIDs.contains(videoId) { failedIDs.remove(videoId) }
        // A new file is coming for the song: the old one is no longer waiting to be deleted.
        keptFiles.remove(videoId)
        queue.append(track)
        startPumpIfNeeded()
    }

    /// Forgets the song at any stage: a queued song is never fetched, a running one is stopped and its `.part` deleted,
    /// a downloaded one loses its file, and a failure is cleared. Gone from the app at once; the disk follows.
    ///
    /// The song that is playing from its file loses its entry at once but keeps the file until playback has left the
    /// track (see `noteLocalPlayback(of:)`), so removing it does not cut the sound off.
    func remove(videoId: String) {
        if failedIDs.contains(videoId) { failedIDs.remove(videoId) }
        queue.removeAll { $0.videoId == videoId }
        let wasDownloaded = entries[videoId] != nil
        if wasDownloaded { entries[videoId] = nil }
        if activeID == videoId {
            activeWasRemoved = true
            activeID = nil
            activeTask?.cancel()
        }
        if !hasLoaded { removedBeforeLoad.insert(videoId) }
        guard MusicDownloadStore.isValidVideoId(videoId) else { return }
        if wasDownloaded, videoId == playingLocalID {
            keptFiles.insert(videoId)
            removeFromStore(videoId, keepingFile: true)
        } else {
            removeFromStore(videoId)
        }
    }

    /// The player's word on which downloaded file it plays: the song's id, or nil when it plays from the network or
    /// nothing. A file kept for a removed song goes once playback is on any other track.
    func noteLocalPlayback(of videoId: String?) {
        playingLocalID = videoId
        let leaving = keptFiles.filter { $0 != videoId }
        for id in leaving {
            keptFiles.remove(id)
            deleteKeptFile(id)
        }
    }

    /// Deletes on disk after every earlier store job, so a song removed and asked for again is never cut down by the
    /// removal of its earlier copy. With `keepingFile` the index forgets the song and the audio file stays.
    private func removeFromStore(_ videoId: String, keepingFile: Bool = false) {
        enqueueStoreJob { store in
            await store.remove(videoId: videoId, keepingFile: keepingFile)
        }
    }

    /// Deletes the file of a song removed while it played, unless a download has listed the song again since.
    private func deleteKeptFile(_ videoId: String) {
        enqueueStoreJob { store in
            await store.removeFileIfUnlisted(videoId: videoId)
        }
    }

    /// Runs `job` against the store once every earlier job has finished and the index has loaded.
    private func enqueueStoreJob(_ job: @escaping @Sendable (MusicDownloadStore) async -> Void) {
        let previous = storeWork
        let store = store
        storeWork = Task { [weak self] in
            await previous?.value
            await self?.waitUntilLoaded()
            await job(store)
        }
    }

    private func startPumpIfNeeded() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            await self?.runQueue()
        }
    }

    /// Downloads what is queued, one song at a time, until nothing is left.
    private func runQueue() async {
        await waitUntilLoaded()
        while !queue.isEmpty {
            await storeWork?.value
            // The queue may have changed while the store caught up.
            guard !queue.isEmpty else { break }
            let track = queue.removeFirst()
            if entries[track.videoId] != nil { continue }
            await run(track)
        }
        pump = nil
    }

    private func run(_ track: MusicTrack) async {
        let videoId = track.videoId
        activeID = videoId
        activeFraction = 0
        activeWasRemoved = false
        lastProgressAt = now()

        let downloader = downloader
        let task = Task { [weak self] in
            try await downloader.download(track) { fraction in
                self?.progressed(fraction, for: videoId)
            }
        }
        activeTask = task
        let result = await task.result
        activeTask = nil

        let removed = activeWasRemoved
        activeWasRemoved = false
        activeID = nil
        switch result {
        case .success(let entry):
            if removed {
                // Removed just as it finished: the file is on disk, so take it off again.
                removeFromStore(videoId)
            } else {
                entries[videoId] = entry
            }
        case .failure(let error):
            if !removed && !(error is CancellationError) { failedIDs.insert(videoId) }
            if let line = Self.failureLogLine(for: error, removed: removed) {
                Self.log.error("A download failed: \(line, privacy: .public)")
            }
        }
    }

    /// What the log says about a failed download, or nil when nothing is logged: a download that was cancelled, or
    /// removed (whatever error the stopped request ended with), did not fail. Only the kind of failure: a download
    /// error's case, else the error's domain and code. Never the song's id, an address or a path, which an error's
    /// description may carry.
    static func failureLogLine(for error: any Error, removed: Bool) -> String? {
        if removed || error is CancellationError { return nil }
        if let known = error as? MusicDownloadError { return "MusicDownloadError.\(known)" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    /// A new value for the song being downloaded, held back until a quarter second has passed since the last shown.
    private func progressed(_ fraction: Double, for videoId: String) {
        guard activeID == videoId else { return }
        let time = now()
        guard time.timeIntervalSince(lastProgressAt) >= Self.progressInterval else { return }
        lastProgressAt = time
        activeFraction = fraction
    }
}
