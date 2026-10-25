// Deci/Music/Downloads/MusicDownloadsSettingsModel.swift
import Foundation
import Observation
import os

/// What the Downloads section of Settings > General shows and does: how many songs and collections are downloaded, how much
/// room they take on the disk, and the Remove all button.
///
/// The counts come from the download service once it has loaded (live, so a download finishing updates them at once) and,
/// before there is a service (the Music popup was never opened), from the index file. The size is always measured from the
/// disk, off the main thread, and measured again only when what the service reports has changed in value: the song count,
/// the collection count, or its disk revision (a change of the files the counts do not show, such as a cover picture saved
/// or a kept file deleted). It is settled for a moment first, so a burst of songs finishing is measured once, and a record
/// written again with the same counts, or a progress tick, measures nothing. A measurement that finishes after a newer one
/// has started is dropped, and one still running when its task is cancelled is told to stop.
///
/// Remove all goes through the service, which is the only thing that deletes downloads; when the service does not exist yet
/// (and something is there to remove) it is built first. What it did is kept in `lastWipe` and said under the button when
/// it fell short.
@MainActor
@Observable
final class MusicDownloadsSettingsModel {
    /// nil until read.
    private(set) var songs: Int?
    private(set) var collections: Int?
    /// The room the folder takes and whether it holds anything besides the index; nil until measured.
    private(set) var usage: MusicDownloadDiskUsage.Usage?
    private(set) var isRemoving = false
    /// What the last Remove all did; nil if none ran, or while the next one is running.
    private(set) var lastWipe: MusicDownloadStore.Wipe?

    @ObservationIgnored private let downloads: @MainActor () -> MusicDownloadService?
    @ObservationIgnored private let prepare: @MainActor () -> MusicDownloadService?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let measure: @Sendable (URL) -> MusicDownloadDiskUsage.Usage
    @ObservationIgnored private let storedCounts: @Sendable (URL) -> MusicDownloadDiskUsage.Counts
    /// Counts the measurements asked for, so an older one finishing late knows it was overtaken.
    @ObservationIgnored private var generation = 0

    /// What the service reported when the folder was last measured, compared by value.
    private struct Signature: Equatable {
        var songs: Int
        var collections: Int
        var diskRevision: Int
    }

    /// - Parameters:
    ///   - downloads: The download service if it exists. Never builds it.
    ///   - prepare: Builds the service if it does not exist yet and returns it.
    ///   - root: The Downloads folder.
    ///   - debounce: How long the download set must stay still before the folder is measured again.
    init(
        downloads: @escaping @MainActor () -> MusicDownloadService?,
        prepare: @escaping @MainActor () -> MusicDownloadService?,
        root: URL = MusicDownloadStore.liveRoot(),
        debounce: Duration = .seconds(1),
        measure: @escaping @Sendable (URL) -> MusicDownloadDiskUsage.Usage = { MusicDownloadDiskUsage.measure(root: $0) },
        storedCounts: @escaping @Sendable (URL) -> MusicDownloadDiskUsage.Counts = { MusicDownloadDiskUsage.storedCounts(at: $0) }
    ) {
        self.downloads = downloads
        self.prepare = prepare
        self.root = root
        self.debounce = debounce
        self.measure = measure
        self.storedCounts = storedCounts
    }

    // MARK: - What the section shows

    var summary: String {
        MusicDownloadSettingsText.summary(songs: songs, collections: collections)
    }

    var sizeText: String {
        MusicDownloadSettingsText.sizeText(usage?.bytes)
    }

    var confirmationMessage: String {
        MusicDownloadSettingsText.confirmationMessage(bytes: usage?.bytes)
    }

    var canRemoveAll: Bool {
        MusicDownloadSettingsText.canRemoveAll(
            songs: songs, collections: collections, hasFiles: usage?.hasFiles, isRemoving: isRemoving
        )
    }

    /// The line under the Remove all row after a removal that fell short; nil when there is nothing to say.
    var wipeCaption: MusicDownloadSettingsText.WipeCaption? {
        MusicDownloadSettingsText.caption(for: lastWipe)
    }

    /// "Removing" while a removal runs, for the row.
    var removingText: String? {
        isRemoving ? MusicDownloadSettingsText.removing : nil
    }

    // MARK: - Reading

    /// Reads the counts and measures the folder, once. A reading that is overtaken by a newer one while it runs is dropped,
    /// and so is one whose task was cancelled (the measurement is told to stop as soon as the cancel arrives).
    func refresh() async {
        generation &+= 1
        let mine = generation
        let service = downloads()
        await service?.waitUntilLoaded()
        let needsStoredCounts = service?.isLoaded != true
        let root = self.root
        let measure = self.measure
        let storedCounts = self.storedCounts

        let work = Task.detached(priority: .utility) { () -> (stored: MusicDownloadDiskUsage.Counts?, usage: MusicDownloadDiskUsage.Usage) in
            let stored = needsStoredCounts ? storedCounts(root) : nil
            return (stored, measure(root))
        }
        let read = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }

        guard !Task.isCancelled, mine == generation else { return }
        if let service, service.isLoaded {
            takeCounts(from: service)
        } else if let stored = read.stored {
            songs = stored.songs
            collections = stored.collections
        }
        usage = read.usage
    }

    /// Keeps the section current until the task is cancelled: reads once, then again after the download set changes (the
    /// counts at once, the folder once the set has stayed still for `debounce`). Progress ticks change nothing it watches,
    /// and a change that leaves the counts and the disk revision as they were (a record written again, a cover named in an
    /// entry) does not measure the folder.
    func watch() async {
        var change = await armed()
        var measured = signature()
        await refresh()
        while !Task.isCancelled {
            await change.wait()
            guard !Task.isCancelled else { return }
            var lastChange = change.firedAt ?? ContinuousClock.now
            repeat {
                change = await armed()
                syncCounts()
                let remaining = lastChange + debounce - ContinuousClock.now
                if remaining > .zero { try? await Task.sleep(for: remaining) }
                if let firedAt = change.firedAt { lastChange = firedAt }
            } while change.hasFired && !Task.isCancelled
            guard !Task.isCancelled else { return }
            let current = signature()
            // Only the value counts: the service reports a change for any write to what it holds.
            guard current != measured else { continue }
            measured = current
            await refresh()
        }
    }

    /// What the service reports now that decides whether the folder is measured again; nil without a loaded service.
    private func signature() -> Signature? {
        guard let service = downloads(), service.isLoaded else { return nil }
        return Signature(
            songs: service.downloadedSongCount, collections: service.downloadedCollectionCount,
            diskRevision: service.diskRevision
        )
    }

    /// Starts watching the download set once the service has read its index (loading flips what is watched, and a change
    /// that only says "loaded" is not worth a second measurement): the returned signal fires at the first change after this.
    private func armed() async -> ChangeSignal {
        await downloads()?.waitUntilLoaded()
        return arm()
    }

    private func arm() -> ChangeSignal {
        let signal = ChangeSignal()
        withObservationTracking {
            if let service = downloads() {
                _ = service.isLoaded
                _ = service.downloadedSongCount
                _ = service.downloadedCollectionCount
                _ = service.diskRevision
            }
        } onChange: {
            signal.fire()
        }
        return signal
    }

    /// Takes the counts from the service when it has loaded; until then they stay as they were.
    private func syncCounts() {
        guard let service = downloads(), service.isLoaded else { return }
        takeCounts(from: service)
    }

    private func takeCounts(from service: MusicDownloadService) {
        songs = service.downloadedSongCount
        collections = service.downloadedCollectionCount
    }

    // MARK: - Remove all

    /// Deletes every download through the service, then reads the section again. Does nothing when nothing is there to
    /// remove or a removal is already running. The note of the run before is cleared first, even when this one never
    /// reaches the service.
    func removeAll() async {
        guard !isRemoving, canRemoveAll else { return }
        isRemoving = true
        lastWipe = nil
        // A measurement that started before the wipe must not put its size back.
        generation &+= 1
        if let service = downloads() ?? prepare() {
            lastWipe = await service.removeAll()
        }
        await refresh()
        isRemoving = false
    }
}

/// A one-shot signal between the observation callback (on whatever thread changes the value) and the task waiting for it.
private nonisolated final class ChangeSignal: Sendable {
    private struct State {
        var firedAt: ContinuousClock.Instant?
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func fire() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.firedAt == nil { state.firedAt = .now }
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    var hasFired: Bool { state.withLock { $0.firedAt != nil } }
    var firedAt: ContinuousClock.Instant? { state.withLock { $0.firedAt } }

    /// Returns once the signal has fired, or at once when the waiting task is cancelled (which also counts as fired).
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state -> Bool in
                    if state.firedAt != nil { return true }
                    state.waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            fire()
        }
    }
}
