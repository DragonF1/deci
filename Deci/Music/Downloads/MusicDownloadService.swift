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

/// Where one downloaded playlist or album stands, as its page's Download pill shows it.
enum MusicCollectionDownloadState: Equatable, Sendable {
    /// Not downloaded, not asked for.
    case none
    /// On its way: `done` of `total` songs are on disk and `fraction` (0 to 1) is the whole collection, counting the part
    /// of the song being fetched. `total` is 0 while the page is still being read.
    case downloading(done: Int, total: Int, fraction: Double)
    /// A collection whose first download finished is fetching songs again (new on the page, or left over from a failure).
    /// The numbers are those of `downloading`. What is on disk stays; Cancel only stops the fetching.
    case updating(done: Int, total: Int, fraction: Double)
    /// Stored and nothing is running. `done` is below `total` when songs failed or are still to be fetched.
    case downloaded(done: Int, total: Int)
}

/// What a page's Download pill asks for.
struct MusicCollectionRequest: Equatable, Sendable {
    let browseId: String
    let title: String
    let subtitle: String
    let kind: MusicDownloadStore.Collection.Kind
    let coverURL: URL?
}

/// The app's side of downloads: which songs and collections are downloaded or on their way, one download at a time, and
/// the local stream playback prefers to the network.
///
/// One serial queue runs everything. A collection's page is read first (as a job of its own), then songs asked for on
/// their own in the order asked, then the collection's songs in page order (see `MusicDownloadQueue`). After a song the
/// queue rests half a second, and after a rate limit (429 or a 5xx) it waits 30, 60 and 120 seconds before the song is
/// given up on and the queue goes on.
///
/// What a row shows comes from `state(for:)`, which reads only what that row's own state depends on: a queued row is
/// not redrawn by another song's progress. Progress reaches the row about four times a second at most.
///
/// A downloaded collection is kept current by `sync(_:)`, which deletes songs only after a page was read to its end with
/// no error and still lists songs, and then only as `MusicCollectionSyncRules` allows: a greyed-out row is still listed, a
/// page shorter than its header says deletes nothing, and a big drop waits for a second read an hour on. Anything else
/// leaves everything as it was.
///
/// The store alone says whether a file goes: the service's own list of what collections hold lags the store's, so a
/// removal asks the store and applies its answer.
@MainActor
@Observable
final class MusicDownloadService {
    /// A wait that can be replaced, so tests never sit through the real ones.
    typealias Pause = @Sendable (TimeInterval) async throws -> Void

    /// The least time between two progress values shown to a row.
    nonisolated static let progressInterval: TimeInterval = 0.25
    /// The rest between two songs.
    nonisolated static let songGap: TimeInterval = 0.5
    /// How long a rate limit holds the queue, once per try. After the last the song fails.
    nonisolated static let backoffDelays: [TimeInterval] = [30, 60, 120]
    /// How long the queue rests after a song gave up on a rate limit, when more songs wait.
    nonisolated static let rateLimitHold: TimeInterval = 600
    /// The least time between two syncs a page opening starts for one collection.
    nonisolated static let pageSyncInterval: TimeInterval = 600
    /// The Liked music page, which belongs to one channel.
    nonisolated private static let likedBrowseId = "VLLM"

    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicDownloads")

    // What rows and pills read. A download's fraction is its own property, so only the row downloading it follows progress.
    private var entries: [String: MusicDownloadStore.Entry] = [:]
    private var queue = MusicDownloadQueue()
    private var activeID: String?
    private var activeFraction: Double = 0
    private var failedIDs: Set<String> = []
    private var collections: [String: MusicDownloadStore.Collection] = [:]
    /// Collections asked for whose page has not been read yet.
    private var pendingCollections: [String: MusicCollectionRequest] = [:]

    private let store: MusicDownloadStore
    private let downloader: MusicDownloader
    private let source: MusicCollectionSource?
    private let covers: (any MusicCoverFetching)?
    private let pause: Pause
    private let songGap: TimeInterval
    private let backoff: [TimeInterval]
    private let pageSyncInterval: TimeInterval
    private let now: @Sendable () -> Date
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var removedBeforeLoad: Set<String> = []
    @ObservationIgnored private var removedCollectionsBeforeLoad: Set<String> = []
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var activeTask: Task<MusicDownloadStore.Entry, any Error>?
    @ObservationIgnored private var activeWasRemoved = false
    @ObservationIgnored private var lastProgressAt = Date.distantPast
    @ObservationIgnored private var storeWork: Task<Void, Never>?
    /// The id of the song playing from its file on disk, nil when the player plays from the network or nothing.
    @ObservationIgnored private var playingLocalID: String?
    /// Songs removed while they played from their file: gone from the index, the file kept until playback leaves them.
    @ObservationIgnored private var keptFiles: Set<String> = []
    /// Every video id a stored collection lists.
    @ObservationIgnored private var listedIDs: Set<String> = []
    /// Songs asked for on their own that are not on disk yet: queued, or on their way.
    @ObservationIgnored private var wantedStandalone: Set<String> = []
    /// Bumped when a collection is removed, so a read of its page that was under way finds out and saves nothing.
    @ObservationIgnored private var generations: [String: Int] = [:]
    /// Bumped when a collection's download is cancelled, so a read of its page that was under way queues nothing.
    @ObservationIgnored private var cancels: [String: Int] = [:]
    /// Collections whose songs were queued: their sync result is written once the queue has run dry.
    @ObservationIgnored private var awaitingFinish: Set<String> = []
    /// When each collection's page was last read by itself (a download, a launch or a page opening).
    @ObservationIgnored private var lastAutoSync: [String: Date] = [:]
    @ObservationIgnored private var didLaunchSync = false
    @ObservationIgnored private var launchSyncWanted = false
    @ObservationIgnored private var pendingPageOpens: Set<String> = []
    @ObservationIgnored private var enumerationTask: Task<ListingRead, any Error>?
    @ObservationIgnored private var enumeratingID: String?
    /// Cover pictures waiting to be fetched, in order, by a task of their own so the queue never waits for one.
    @ObservationIgnored private var coverJobs: [CoverJob] = []
    @ObservationIgnored private var coverTask: Task<Void, Never>?

    private enum CoverJob {
        case song(MusicTrack)
        case collection(String)
    }

    init(
        store: MusicDownloadStore,
        downloader: MusicDownloader,
        source: MusicCollectionSource? = nil,
        covers: (any MusicCoverFetching)? = nil,
        pause: @escaping Pause = { seconds in try await Task.sleep(for: .seconds(seconds)) },
        songGap: TimeInterval = MusicDownloadService.songGap,
        backoff: [TimeInterval] = MusicDownloadService.backoffDelays,
        pageSyncInterval: TimeInterval = MusicDownloadService.pageSyncInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.downloader = downloader
        self.source = source
        self.covers = covers
        self.pause = pause
        self.songGap = songGap
        self.backoff = backoff
        self.pageSyncInterval = pageSyncInterval
        self.now = now
        loadTask = Task { [weak self] in
            let loaded = await store.load()
            let stored = await store.collectionList()
            self?.finishLoading(loaded, collections: stored)
        }
    }

    /// The service for the app: downloads under Application Support, streams resolved by `resolve`, collection pages read
    /// through `source` (nil turns whole-page downloads off).
    static func live(
        resolve: @escaping @Sendable (String) async throws -> ResolvedStream,
        source: MusicCollectionSource? = nil
    ) -> MusicDownloadService {
        let store = MusicDownloadStore(root: MusicDownloadStore.liveRoot())
        let downloader = MusicDownloader(store: store, transport: URLSessionDownloadTransport(), resolve: resolve)
        return MusicDownloadService(store: store, downloader: downloader, source: source, covers: URLSessionCoverFetcher())
    }

    // MARK: - Reading

    /// The song's state. A row reading it follows only the pieces its answer rests on.
    func state(for videoId: String) -> MusicDownloadState {
        if entries[videoId] != nil { return .downloaded }
        if activeID == videoId { return .downloading(fraction: activeFraction) }
        if queue.contains(videoId) { return .queued }
        if failedIDs.contains(videoId) { return .failed }
        return .none
    }

    /// The collection's state. Busy while a song of it is queued or on its way (or its page is being read for the first
    /// time); a sync that only reads the page is not shown, so opening a page does not flicker its pill. Busy is
    /// `updating` once a first download has finished, and `downloading` before.
    func collectionState(for browseId: String) -> MusicCollectionDownloadState {
        guard let collection = collections[browseId] else {
            return pendingCollections[browseId] != nil ? .downloading(done: 0, total: 0, fraction: 0) : .none
        }
        // One read of each property, not one per song.
        let entries = entries, queue = queue, activeID = activeID
        var done = 0
        var busy = false
        var activeInside = false
        for videoId in collection.videoIds {
            if entries[videoId] != nil {
                done += 1
            } else if videoId == activeID {
                busy = true
                activeInside = true
            } else if queue.contains(videoId) {
                busy = true
            }
        }
        let total = collection.videoIds.count
        guard busy else { return .downloaded(done: done, total: total) }
        let partial = activeInside ? activeFraction : 0
        let fraction = total > 0 ? (Double(done) + partial) / Double(total) : 0
        let clamped = min(1, max(0, fraction))
        if collection.lastSyncedAt != nil { return .updating(done: done, total: total, fraction: clamped) }
        return .downloading(done: done, total: total, fraction: clamped)
    }

    /// Whether a downloaded collection lists the song and the song was not downloaded on its own: its file stays only for
    /// the collection, so its menu offers neither Download nor Remove download.
    func isCollectionOnly(_ videoId: String) -> Bool {
        guard listedIDs.contains(videoId) else { return false }
        if let entry = entries[videoId] { return !entry.standalone }
        return !wantedStandalone.contains(videoId)
    }

    /// The song's small cover picture on disk, nil when it has none saved.
    func localCoverURL(forVideoId videoId: String) -> URL? {
        guard let name = entries[videoId]?.coverFile, store.hasCover(named: name) else { return nil }
        return store.coverURL(named: name)
    }

    /// The collection's small cover picture on disk, nil when it has none saved.
    func localCoverURL(forCollection browseId: String) -> URL? {
        guard let name = collections[browseId]?.coverFile, store.hasCover(named: name) else { return nil }
        return store.coverURL(named: name)
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

    /// Returns once nothing is queued or running, every cover has been fetched and every job on the disk has finished,
    /// including ones started while it waited. A removal answers at once and deletes later; this is how a caller knows the
    /// disk has caught up.
    func waitUntilIdle() async {
        await waitUntilLoaded()
        while true {
            let running = pump
            let covering = coverTask
            let work = storeWork
            await running?.value
            await covering?.value
            await work?.value
            if pump == nil, coverTask == nil, storeWork == work { return }
        }
    }

    /// Writes the index changes that are waiting for their timer, for a quit. Blocks for at most a second and a half.
    func flushOnQuit() {
        let store = store
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await store.flushIndex()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    private func finishLoading(_ loaded: [String: MusicDownloadStore.Entry], collections stored: [String: MusicDownloadStore.Collection]) {
        hasLoaded = true
        entries = loaded.filter { !removedBeforeLoad.contains($0.key) }
        collections = stored.filter { !removedCollectionsBeforeLoad.contains($0.key) }
        recomputeListed()
        removedBeforeLoad = []
        removedCollectionsBeforeLoad = []
        // A collection asked for before the index loaded may be stored already: there is no first download to make.
        for browseId in Array(pendingCollections.keys) where collections[browseId] != nil {
            pendingCollections[browseId] = nil
            queue.removeCollection(browseId)
        }
        // What was asked for while the index was still being read.
        let opened = pendingPageOpens
        pendingPageOpens = []
        for browseId in opened.sorted() { pageOpened(browseId) }
        if launchSyncWanted {
            launchSyncWanted = false
            signInKnown()
        }
    }

    /// The file is gone from disk or damaged: stop calling the song downloaded, drop its entry and what is left of the file.
    /// A collection that lists the song keeps listing it, and its next sync fetches the song again.
    private func forget(_ videoId: String) {
        entries[videoId] = nil
        enqueueStoreJob { store in await store.discard(videoId: videoId) }
    }

    private func recomputeListed() {
        var all = Set<String>()
        for collection in collections.values { all.formUnion(collection.videoIds) }
        listedIDs = all
    }

    // MARK: - Songs

    /// Queues the song on its own, ahead of any collection song waiting, so it stays when a collection holding it goes. A
    /// song already queued, downloading or downloaded is left alone, except that a collection's song becomes the user's
    /// own; one that failed tries again.
    func download(_ track: MusicTrack) {
        let videoId = track.videoId
        switch state(for: videoId) {
        case .queued:
            if !wantedStandalone.contains(videoId) {
                wantedStandalone.insert(videoId)
                queue.enqueueStandalone(track)
            }
            return
        case .downloading:
            wantedStandalone.insert(videoId)
            return
        case .downloaded:
            if entries[videoId]?.standalone == false {
                entries[videoId]?.standalone = true
                enqueueStoreJob { store in await store.setStandalone(videoId: videoId) }
            }
            return
        case .none, .failed:
            break
        }
        guard MusicDownloadStore.isValidVideoId(videoId) else {
            failedIDs.insert(videoId)
            return
        }
        if failedIDs.contains(videoId) { failedIDs.remove(videoId) }
        // A new file is coming for the song: the old one is no longer waiting to be deleted.
        keptFiles.remove(videoId)
        wantedStandalone.insert(videoId)
        queue.enqueueStandalone(track)
        startPumpIfNeeded()
    }

    /// Forgets the song at any stage: a queued song is never fetched, a running one is stopped and its `.part` deleted,
    /// a downloaded one loses its file, and a failure is cleared. Gone from the app at once; the disk follows.
    ///
    /// A song a downloaded collection lists only stops being the user's own: the file stays for the collection, and a
    /// song only the collection holds is not touched at all. The store has the last word, since a collection it holds may
    /// not have reached the service yet: it keeps the file for any collection that lists the song.
    ///
    /// The song that is playing from its file loses its entry at once but keeps the file until playback has left the
    /// track (see `noteLocalPlayback(of:)`), so removing it does not cut the sound off.
    func remove(videoId: String) {
        wantedStandalone.remove(videoId)
        if listedIDs.contains(videoId) {
            queue.demote(videoId)
            if entries[videoId]?.standalone == true {
                entries[videoId]?.standalone = false
                removeFromStore(videoId, keepingFile: videoId == playingLocalID)
            }
            return
        }
        if failedIDs.contains(videoId) { failedIDs.remove(videoId) }
        queue.removeSong(videoId)
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

    // MARK: - Collections

    /// Downloads every song of the playlist or album. Its page is read first (a job of its own in the queue); nothing is
    /// stored if that fails, the list is empty or the page is not one that can be downloaded whole. Asking again for a
    /// collection that is stored or on its way changes nothing.
    func downloadCollection(_ request: MusicCollectionRequest) {
        let browseId = request.browseId
        guard source != nil, MusicCollectionEnumerator.isDownloadable(browseId: browseId) else { return }
        guard collections[browseId] == nil, pendingCollections[browseId] == nil else { return }
        pendingCollections[browseId] = request
        queue.enqueueCollection(browseId)
        startPumpIfNeeded()
    }

    /// Stops a collection's download without deleting anything it has. A collection whose first download finished only
    /// stops fetching: songs waiting are not fetched, the song on its way is stopped (unless another collection or the
    /// user's own request wants it), and everything on disk and the record stay, so the pill reads downloaded. A first
    /// download still under way is dropped, as `removeCollection(_:)` does, since a half-made collection is no use.
    func cancelCollectionDownload(_ browseId: String) {
        guard let stored = collections[browseId], stored.lastSyncedAt != nil else {
            removeCollection(browseId)
            return
        }
        cancels[browseId, default: 0] += 1
        queue.removeCollection(browseId)
        if enumeratingID == browseId { enumerationTask?.cancel() }
        var heldElsewhere = Set<String>()
        for (otherID, other) in collections where otherID != browseId { heldElsewhere.formUnion(other.videoIds) }
        for videoId in stored.videoIds {
            guard entries[videoId] == nil, !heldElsewhere.contains(videoId), !wantedStandalone.contains(videoId) else { continue }
            stopFetching(videoId)
        }
    }

    /// Drops the collection and everything only it held: songs waiting are never fetched, the song on its way is stopped,
    /// and the files of finished ones are deleted. Songs another collection lists, or that were downloaded on their own,
    /// stay. This is Remove, and Cancel of a first download.
    func removeCollection(_ browseId: String) {
        generations[browseId, default: 0] += 1
        pendingCollections[browseId] = nil
        queue.removeCollection(browseId)
        awaitingFinish.remove(browseId)
        lastAutoSync[browseId] = nil
        pendingPageOpens.remove(browseId)
        if enumeratingID == browseId { enumerationTask?.cancel() }
        guard let removed = collections.removeValue(forKey: browseId) else {
            // The index has not loaded: the record is not known yet, but the store's job runs after the load.
            if !hasLoaded {
                removedCollectionsBeforeLoad.insert(browseId)
                removeCollectionInStore(browseId)
            }
            return
        }
        recomputeListed()

        var kept: Set<String> = []
        var letGo: [String: MusicDownloadStore.Entry] = [:]
        var seen = Set<String>()
        for videoId in removed.videoIds where seen.insert(videoId).inserted {
            guard !listedIDs.contains(videoId), !wantedStandalone.contains(videoId) else { continue }
            if let entry = entries[videoId] {
                guard !entry.standalone else { continue }
                entries[videoId] = nil
                letGo[videoId] = entry
                if videoId == playingLocalID {
                    keptFiles.insert(videoId)
                    kept.insert(videoId)
                }
            } else {
                stopFetching(videoId)
            }
        }
        removeCollectionInStore(browseId, keepingFiles: kept, letGo: letGo)
    }

    /// A song nobody wants any more and that is not on disk: not fetched if it waits, stopped if it is on its way.
    private func stopFetching(_ videoId: String) {
        queue.removeSong(videoId)
        failedIDs.remove(videoId)
        if activeID == videoId {
            activeWasRemoved = true
            activeID = nil
            activeTask?.cancel()
        }
    }

    /// Removes the record in the store once earlier jobs are done and applies what the store says: the songs it dropped
    /// lose their entries here, and the songs the service let go of that the store kept come back. A record the store put
    /// back, because the index could not be written, comes back here too.
    private func removeCollectionInStore(
        _ browseId: String, keepingFiles: Set<String> = [], letGo: [String: MusicDownloadStore.Entry] = [:]
    ) {
        enqueueStoreJob { [weak self] store in
            let removal = await store.removeCollection(browseId, keepingFiles: keepingFiles)
            await self?.collectionRemoved(browseId, removal, letGo: letGo)
        }
    }

    private func collectionRemoved(
        _ browseId: String, _ removal: MusicDownloadStore.CollectionRemoval, letGo: [String: MusicDownloadStore.Entry]
    ) {
        let dropped = Set(removal.dropped)
        for videoId in removal.dropped where videoId != activeID { entries[videoId] = nil }
        for (videoId, entry) in letGo where !dropped.contains(videoId) {
            keptFiles.remove(videoId)
            guard entries[videoId] == nil, activeID != videoId else { continue }
            entries[videoId] = entry
            failedIDs.remove(videoId)
        }
        guard let restored = removal.restored else { return }
        Self.log.error("A collection could not be removed, so it is back")
        guard collections[browseId] == nil, pendingCollections[browseId] == nil else { return }
        collections[browseId] = restored
        recomputeListed()
    }

    /// Reads the collection's page again and brings the stored list in line with it: new songs are downloaded, songs taken
    /// off the page are deleted (unless another collection lists them or they were downloaded on their own, and only as
    /// `MusicCollectionSyncRules` allows), and the order follows the page. A page that could not be read to its end, or
    /// reads as empty, leaves everything as it was and records that the sync could not run. Does nothing for a collection
    /// that is not downloaded.
    func sync(_ browseId: String) {
        guard source != nil, collections[browseId] != nil else { return }
        queue.enqueueCollection(browseId)
        startPumpIfNeeded()
    }

    /// A downloaded collection's page was opened: syncs it, at most once every ten minutes. Held back until the index has
    /// loaded.
    func pageOpened(_ browseId: String) {
        guard hasLoaded else {
            pendingPageOpens.insert(browseId)
            return
        }
        guard collections[browseId] != nil else { return }
        if let last = lastAutoSync[browseId], now().timeIntervalSince(last) < pageSyncInterval { return }
        lastAutoSync[browseId] = now()
        sync(browseId)
    }

    /// Whether the app is signed in is known: syncs every downloaded collection, the oldest first, once per launch. Held
    /// back until the index has loaded.
    func signInKnown() {
        guard !didLaunchSync else { return }
        guard hasLoaded else {
            launchSyncWanted = true
            return
        }
        didLaunchSync = true
        let ordered = collections.sorted { ($0.value.addedAt, $0.key) < ($1.value.addedAt, $1.key) }
        for (browseId, _) in ordered {
            lastAutoSync[browseId] = now()
            sync(browseId)
        }
    }

    // MARK: - The queue

    /// Takes the song off its own list in the store after every earlier store job, so a song removed and asked for again is
    /// never cut down by the removal of its earlier copy. The store decides what goes and the answer is applied here. With
    /// `keepingFile` the index forgets the song and the audio file stays.
    private func removeFromStore(_ videoId: String, keepingFile: Bool = false) {
        enqueueStoreJob { [weak self] store in
            let release = await store.remove(videoId: videoId, keepingFile: keepingFile)
            await self?.applyRemoval(release, of: videoId, keptFile: keepingFile)
        }
    }

    /// Makes the service agree with what the store did to a song. A song a stored collection lists was kept, with its
    /// file: the entry comes back here if the service had let go of it. A song that was deleted loses a stale entry; one
    /// whose file was kept for the player is deleted when playback leaves it.
    private func applyRemoval(_ release: MusicDownloadStore.Release, of videoId: String, keptFile: Bool) {
        switch release {
        case .untouched:
            break
        case .deleted:
            guard activeID != videoId else { return }
            entries[videoId] = nil
            if keptFile { keptFiles.insert(videoId) }
        case .keptForCollection(let entry):
            keptFiles.remove(videoId)
            guard entries[videoId] == nil, activeID != videoId else { return }
            entries[videoId] = entry
            failedIDs.remove(videoId)
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

    /// Runs what is queued, one job at a time, until nothing is left.
    private func runQueue() async {
        await waitUntilLoaded()
        while true {
            await storeWork?.value
            // Nothing suspends between taking the job and the end of the loop, so a job queued meanwhile is never missed.
            guard let job = queue.next() else { break }
            switch job {
            case .collection(let browseId):
                await readPage(of: browseId)
            case .song(let track):
                if entries[track.videoId] != nil {
                    wantedStandalone.remove(track.videoId)
                    continue
                }
                let gaveUp = await run(track)
                // A song that gave up on a rate limit holds the rest back for ten minutes, not half a second.
                if queue.songCount > 0 { try? await pause(gaveUp ? Self.rateLimitHold : songGap) }
            }
        }
        finishCollections()
        // The index is written when the queue goes idle, not for every song on the way.
        enqueueStoreJob { store in await store.flushIndex() }
        pump = nil
    }

    /// Downloads one song. True when it gave up on a rate limit (a 429 or a 5xx that did not lift), so the queue should rest.
    private func run(_ track: MusicTrack) async -> Bool {
        let videoId = track.videoId
        activeID = videoId
        activeFraction = 0
        activeWasRemoved = false
        lastProgressAt = now()

        let downloader = downloader, pause = pause, delays = backoff
        let standalone = wantedStandalone.contains(videoId)
        let progress: @MainActor @Sendable (Double) -> Void = { [weak self] fraction in
            self?.progressed(fraction, for: videoId)
        }
        let task = Task {
            try await Self.withBackoff(pause: pause, delays: delays) {
                try await downloader.download(track, standalone: standalone, progress: progress)
            }
        }
        activeTask = task
        let result = await task.result
        activeTask = nil

        let removed = activeWasRemoved
        activeWasRemoved = false
        activeID = nil
        var gaveUp = false
        switch result {
        case .success(let entry):
            if removed && !listedIDs.contains(videoId) {
                // Removed just as it finished: the file is on disk, so ask the store to take it off again.
                removeFromStore(videoId)
            } else {
                settle(entry, track: track)
                enqueueCover(.song(track))
            }
        case .failure(let error):
            if !removed {
                wantedStandalone.remove(videoId)
                if !(error is CancellationError) { failedIDs.insert(videoId) }
                gaveUp = Self.isRateLimited(error)
            }
            if let line = Self.failureLogLine(for: error, removed: removed) {
                Self.log.error("A download failed: \(line, privacy: .public)")
            }
        }
        return gaveUp
    }

    /// Lists a finished download and makes its standing match what was asked for while it ran: the user's own, only a
    /// collection's, or (when nothing wants it any more) nothing.
    private func settle(_ entry: MusicDownloadStore.Entry, track: MusicTrack) {
        let videoId = track.videoId
        let wanted = wantedStandalone.remove(videoId) != nil
        let listed = listedIDs.contains(videoId)
        guard wanted || listed else {
            // Nothing here wants it. The store keeps it if a collection it holds lists it, and says so.
            removeFromStore(videoId)
            return
        }
        var settled = entry
        settled.standalone = wanted
        entries[videoId] = settled
        if wanted, !entry.standalone {
            enqueueStoreJob { store in await store.setStandalone(videoId: videoId) }
        } else if !wanted, entry.standalone {
            removeFromStore(videoId)
        }
    }

    /// Writes how each collection that was queued ended once the queue has run dry: complete, or how many songs are not
    /// on disk. Does not suspend.
    private func finishCollections() {
        guard !awaitingFinish.isEmpty else { return }
        let finished = awaitingFinish
        awaitingFinish = []
        let time = now()
        for browseId in finished.sorted() {
            guard let collection = collections[browseId] else { continue }
            let missing = collection.videoIds.filter { entries[$0] == nil }.count
            let result: MusicDownloadStore.Collection.SyncResult = missing == 0 ? .complete : .failed(missing)
            collections[browseId]?.syncResult = result
            collections[browseId]?.lastSyncedAt = time
            enqueueStoreJob { store in await store.setSyncResult(browseId, result, syncedAt: time) }
        }
    }

    // MARK: - Reading a collection's page

    /// How a read of a page checks the account it is read under.
    private enum ChannelRule: Sendable {
        case any
        /// The page belongs to this channel; nil means the channel was not known, so no read counts.
        case matching(String?)
    }

    private enum ListingFailure: Error {
        case signedOut
        case otherChannel
    }

    /// What one read of a page found: the list and, for Liked music, the channel it was read under.
    nonisolated private struct ListingRead: Sendable {
        let listing: MusicCollectionEnumerator.Listing
        let channelKey: String?
    }

    /// Reads the collection's page, a first download's or a sync's, and acts on it. Anything but a complete list leaves
    /// the stored collection as it was.
    private func readPage(of browseId: String) async {
        guard let source else {
            pendingCollections[browseId] = nil
            return
        }
        let stored = collections[browseId]
        // A request for a collection the index already holds is a sync, not a first download.
        if stored != nil { pendingCollections[browseId] = nil }
        guard stored != nil || pendingCollections[browseId] != nil else { return }
        let generation = generations[browseId, default: 0]
        let cancelled = cancels[browseId, default: 0]
        lastAutoSync[browseId] = now()
        let rule: ChannelRule = stored != nil && browseId == Self.likedBrowseId ? .matching(stored?.channelKey) : .any

        let pause = pause, delays = backoff
        let task = Task {
            try await Self.read(browseId, source: source, rule: rule, pause: pause, delays: delays)
        }
        enumerationTask = task
        enumeratingID = browseId
        let result = await task.result
        enumerationTask = nil
        enumeratingID = nil
        // Removed or cancelled while the page was being read: nothing is saved, queued or noted.
        guard generations[browseId, default: 0] == generation, cancels[browseId, default: 0] == cancelled else { return }

        switch result {
        case .success(let read):
            if collections[browseId] != nil {
                await applySync(browseId, read: read, generation: generation, cancelled: cancelled)
            } else if let request = pendingCollections[browseId] {
                await storeFirstDownload(request, read: read, generation: generation)
            }
        case .failure(let error):
            if collections[browseId] != nil {
                markUnreachable(browseId)
            } else {
                pendingCollections[browseId] = nil
            }
            if let line = Self.failureLogLine(for: error, removed: false) {
                Self.log.error("A collection's page could not be read: \(line, privacy: .public)")
            }
        }
    }

    /// The page, read to its end with each page of it backing off on its own. Liked music belongs to one channel: the
    /// session's channel is read before the page and again after it, and a read the account changed under belongs to
    /// neither. A stored collection must also match the channel it was stored under.
    nonisolated private static func read(
        _ browseId: String, source: MusicCollectionSource, rule: ChannelRule, pause: Pause, delays: [TimeInterval]
    ) async throws -> ListingRead {
        guard await source.isSignedIn() else { throw ListingFailure.signedOut }
        let isLiked = browseId == likedBrowseId
        var channel: String?
        if isLiked { channel = await source.identity() }
        if case .matching(let key) = rule {
            guard let key, channel == key else { throw ListingFailure.otherChannel }
        }
        let listing = try await MusicCollectionEnumerator.enumerate(browseId, source: source, pause: pause, delays: delays)
        if isLiked, await source.identity() != channel { throw ListingFailure.otherChannel }
        return ListingRead(listing: listing, channelKey: channel)
    }

    /// The first read of a page: stores the collection (before any song, so a quit leaves something to finish) and queues
    /// the songs that are not on disk. Only the songs that can be played are stored.
    private func storeFirstDownload(
        _ request: MusicCollectionRequest, read: ListingRead, generation: Int
    ) async {
        let browseId = request.browseId
        let listing = read.listing
        let ids = listing.tracks.map(\.videoId)
        guard !ids.isEmpty else {
            pendingCollections[browseId] = nil
            return
        }
        let record = MusicDownloadStore.Collection(
            title: request.title.isEmpty ? listing.title : request.title,
            videoIds: ids,
            subtitle: request.subtitle.isEmpty ? listing.subtitle : request.subtitle,
            kind: request.kind,
            coverURL: request.coverURL ?? listing.coverURL,
            addedAt: now(),
            channelKey: read.channelKey
        )
        await storeWork?.value
        do {
            try await store.saveCollection(browseId, record)
        } catch {
            pendingCollections[browseId] = nil
            Self.log.error("A collection could not be stored")
            return
        }
        guard generations[browseId, default: 0] == generation else {
            // Removed while it was being written: the store has the record again, so it goes again.
            removeCollectionInStore(browseId)
            return
        }
        collections[browseId] = record
        pendingCollections[browseId] = nil
        recomputeListed()
        queueListed(listing.tracks)
        awaitingFinish.insert(browseId)
        enqueueCover(.collection(browseId))
    }

    /// Brings a stored collection in line with its page. Called only with a list that was read to its end. What may be
    /// deleted is `MusicCollectionSyncRules`' call. The songs to fetch are worked out after the store has answered, from
    /// what is on disk by then, since a removal made meanwhile is only settled by the store.
    private func applySync(_ browseId: String, read: ListingRead, generation: Int, cancelled: Int) async {
        let listing = read.listing
        // What is playing is read after the disk has caught up: it may have changed while earlier jobs ran.
        await storeWork?.value
        guard generations[browseId, default: 0] == generation, let stored = collections[browseId] else { return }
        guard let decision = MusicCollectionSyncRules.decide(
            stored: stored.videoIds,
            playable: listing.tracks.map(\.videoId),
            unavailable: listing.unavailableVideoIds,
            statedCount: listing.statedCount,
            held: stored.heldDrop,
            now: now()
        ) else {
            // A page that reads as empty is never taken for every song gone.
            markUnreachable(browseId)
            return
        }
        if !decision.isComplete {
            Self.log.error("A page lists fewer songs than its header states, so nothing was deleted")
        }

        var updated = stored
        updated.videoIds = decision.order
        updated.heldDrop = decision.held
        if updated != stored {
            var keeping: Set<String> = []
            if let playing = playingLocalID, decision.deleteNow.contains(playing) { keeping.insert(playing) }
            let dropped: [String]
            do {
                dropped = try await store.saveCollection(browseId, updated, keepingFiles: keeping)
            } catch {
                Self.log.error("A collection could not be stored after a sync")
                markUnreachable(browseId)
                return
            }
            guard generations[browseId, default: 0] == generation, collections[browseId] != nil else {
                removeCollectionInStore(browseId)
                return
            }
            for videoId in dropped {
                entries[videoId] = nil
                if keeping.contains(videoId) { keptFiles.insert(videoId) }
            }
            // Playback may have left the song while the store worked: its file goes now, not never.
            if !keeping.isEmpty { noteLocalPlayback(of: playingLocalID) }
            collections[browseId] = updated
            recomputeListed()
            // Songs taken off the page that nothing else wants are not fetched, or stopped if they are on their way.
            for videoId in decision.deleteNow where !listedIDs.contains(videoId) && !wantedStandalone.contains(videoId) {
                guard entries[videoId] == nil else { continue }
                stopFetching(videoId)
            }
        }

        if cancels[browseId, default: 0] == cancelled {
            queueListed(listing.tracks)
            awaitingFinish.insert(browseId)
        }
        enqueueCover(.collection(browseId))
    }

    /// Queues the collection songs given, in order, that nothing has in hand: not on disk, not on their way and not asked
    /// for on their own. A song already queued is left alone; one that failed before tries again.
    private func queueListed(_ tracks: [MusicTrack]) {
        for track in tracks
        where entries[track.videoId] == nil && activeID != track.videoId && !wantedStandalone.contains(track.videoId) {
            if queue.enqueueListed(track) {
                failedIDs.remove(track.videoId)
                keptFiles.remove(track.videoId)
            }
        }
    }

    /// The sync could not run (signed out, an error, an empty page, another channel): nothing changes but this note.
    private func markUnreachable(_ browseId: String) {
        guard collections[browseId] != nil else { return }
        collections[browseId]?.syncResult = .unreachable
        enqueueStoreJob { store in await store.setSyncResult(browseId, .unreachable, syncedAt: nil) }
    }

    // MARK: - Covers

    /// Queues a cover picture to be fetched by the cover task, which runs at low priority apart from the download queue:
    /// a slow image never holds up the next song.
    private func enqueueCover(_ job: CoverJob) {
        guard covers != nil else { return }
        coverJobs.append(job)
        guard coverTask == nil else { return }
        coverTask = Task(priority: .utility) { [weak self] in
            await self?.drainCovers()
        }
    }

    /// Fetches the waiting covers one at a time, then writes the index. A song removed since, or whose picture is saved
    /// already, costs nothing.
    private func drainCovers() async {
        while !coverJobs.isEmpty {
            switch coverJobs.removeFirst() {
            case .song(let track): await saveCover(of: track)
            case .collection(let browseId): await saveCollectionCover(browseId)
            }
        }
        // Nothing suspends between the empty check and here, so a job queued meanwhile is never missed.
        coverTask = nil
        enqueueStoreJob { store in await store.flushIndex() }
    }

    /// Saves the song's small thumbnail beside its file. Best effort: no picture, no network or a refusal changes nothing.
    private func saveCover(of track: MusicTrack) async {
        guard let covers, let url = track.thumbnailURL, let entry = entries[track.videoId] else { return }
        let small = MusicArtworkURL.small(url)
        let name = MusicDownloadCovers.name(for: small)
        if entry.coverFile == name, store.hasCover(named: name) { return }
        var data = Data()
        if !store.hasCover(named: name) {
            guard let fetched = try? await covers.fetch(small) else { return }
            data = fetched
        }
        guard await store.saveCover(data, named: name, forVideoId: track.videoId) else { return }
        entries[track.videoId]?.coverFile = name
    }

    /// Saves the collection's small cover, as `saveCover(of:)` does for a song.
    private func saveCollectionCover(_ browseId: String) async {
        guard let covers, let url = collections[browseId]?.coverURL else { return }
        let small = MusicArtworkURL.small(url)
        let name = MusicDownloadCovers.name(for: small)
        if collections[browseId]?.coverFile == name, store.hasCover(named: name) { return }
        var data = Data()
        if !store.hasCover(named: name) {
            guard let fetched = try? await covers.fetch(small) else { return }
            data = fetched
        }
        guard await store.saveCover(data, named: name, forCollection: browseId) else { return }
        collections[browseId]?.coverFile = name
    }

    // MARK: - Waiting out a rate limit

    /// Whether the error is the server asking to slow down: a 429, or a 5xx, from the stream or from the page.
    nonisolated static func isRateLimited(_ error: any Error) -> Bool {
        let status: Int?
        if let download = error as? MusicDownloadError, case .badStatus(let code) = download {
            status = code
        } else if let music = error as? MusicError, case .http(let code) = music {
            status = code
        } else {
            status = nil
        }
        guard let status else { return false }
        return status == 429 || (500...599).contains(status)
    }

    /// Runs `operation`; after a rate limit waits the next of `delays` and runs it again. The error of the last try is
    /// thrown once the delays are used up, and any other error at once. A cancel ends a wait.
    nonisolated static func withBackoff<Value: Sendable>(
        pause: Pause, delays: [TimeInterval], _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                guard isRateLimited(error), attempt < delays.count else { throw error }
                try await pause(delays[attempt])
                attempt += 1
            }
        }
    }

    // MARK: - Logging and progress

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
