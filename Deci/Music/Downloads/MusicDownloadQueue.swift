// Deci/Music/Downloads/MusicDownloadQueue.swift
import Foundation

/// The order downloads run in: listings of collections first (so a page's songs are known before any of them is
/// fetched), then songs asked for on their own in the order asked, then collection songs in page order. A song waits at
/// most once, however many collections list it. Plain values with no disk, network or clock.
///
/// Built for a long playlist: a removal marks a slot dead instead of shifting the array, and `next()` skips the dead
/// ones, so queueing and running ten thousand songs costs a pass over them, not a pass for each.
nonisolated struct MusicDownloadQueue {
    enum Job: Equatable, Sendable {
        /// Read the page and decide what to download (or sync a collection already downloaded).
        case collection(String)
        case song(MusicTrack)
    }

    private enum Group {
        case standalone
        case listed
    }

    /// One place in an array. Live only while the song's `Place` carries the same token.
    private struct Slot {
        let token: Int
        let order: Int
        let track: MusicTrack
    }

    /// Where a waiting song is. `order` is its place among the collection songs, kept while it is promoted so that it can
    /// go back to it.
    private struct Place {
        let group: Group
        let token: Int
        let order: Int
    }

    private var collections: [String] = []
    private var standalone: [Slot] = []
    private var standaloneHead = 0
    private var listed: [Slot] = []
    private var listedHead = 0
    private var places: [String: Place] = [:]
    private var nextToken = 0
    private var nextOrder = 0
    /// The order of the next song put back to the front: counts down from -1, under every ordinary one.
    private var nextFrontOrder = -1

    init() {}

    /// Nothing waits: no listing and no song.
    var isEmpty: Bool { collections.isEmpty && places.isEmpty }

    /// How many songs wait.
    var songCount: Int { places.count }

    // MARK: - Asking

    /// Queues the listing of a collection, once.
    mutating func enqueueCollection(_ browseId: String) {
        if !collections.contains(browseId) { collections.append(browseId) }
    }

    func hasCollection(_ browseId: String) -> Bool { collections.contains(browseId) }

    mutating func removeCollection(_ browseId: String) {
        collections.removeAll { $0 == browseId }
    }

    /// Queues a song a collection lists, after those already waiting. False, and nothing changes, when the song waits
    /// already.
    @discardableResult
    mutating func enqueueListed(_ track: MusicTrack) -> Bool {
        guard places[track.videoId] == nil else { return false }
        let token = takeToken(), order = takeOrder()
        listed.append(Slot(token: token, order: order, track: track))
        places[track.videoId] = Place(group: .listed, token: token, order: order)
        return true
    }

    /// Queues a song asked for on its own, after the ones asked for before it and ahead of every collection song. A
    /// collection song waiting is promoted; one waiting on its own already stays where it is.
    mutating func enqueueStandalone(_ track: MusicTrack) {
        let existing = places[track.videoId]
        if existing?.group == .standalone { return }
        let token = takeToken()
        let order = existing?.order ?? takeOrder()
        standalone.append(Slot(token: token, order: order, track: track))
        places[track.videoId] = Place(group: .standalone, token: token, order: order)
    }

    /// Returns a standalone song that waits to its place among the collection songs: its page position if it came from
    /// one, else the end. Nothing changes for a song that does not wait or is not standalone.
    mutating func demote(_ videoId: String) {
        guard let place = places[videoId], place.group == .standalone,
              let slot = standalone.last(where: { $0.token == place.token }) else { return }
        let token = takeToken()
        let moved = Slot(token: token, order: place.order, track: slot.track)
        var low = listedHead, high = listed.count
        while low < high {
            let middle = (low + high) / 2
            if listed[middle].order <= place.order { low = middle + 1 } else { high = middle }
        }
        listed.insert(moved, at: low)
        places[videoId] = Place(group: .listed, token: token, order: place.order)
    }

    /// Puts back a song that was taken to be fetched and could not be, because the network went: it runs before the songs
    /// still waiting in its group (a standalone song before the standalone ones, a collection song before the collection
    /// ones, so a standalone song still goes first). Put back in the reverse of the order they were taken, several songs
    /// run in the order they were taken. Nothing changes for a song that waits already.
    mutating func requeueFront(_ track: MusicTrack, standalone isStandalone: Bool) {
        guard places[track.videoId] == nil else { return }
        let token = takeToken()
        // Below every order handed out so far, so a collection's songs stay sorted by order for `demote`.
        let order = nextFrontOrder
        nextFrontOrder -= 1
        let slot = Slot(token: token, order: order, track: track)
        if isStandalone {
            standalone.insert(slot, at: standaloneHead)
            places[track.videoId] = Place(group: .standalone, token: token, order: order)
        } else {
            listed.insert(slot, at: listedHead)
            places[track.videoId] = Place(group: .listed, token: token, order: order)
        }
    }

    /// Puts back the listing of a collection that was taken to be read and could not be: it runs before the listings
    /// still waiting. Once, however often it is asked.
    mutating func requeueCollection(_ browseId: String) {
        guard !collections.contains(browseId) else { return }
        collections.insert(browseId, at: 0)
    }

    /// Takes a waiting song out, wherever it waits.
    mutating func removeSong(_ videoId: String) {
        places[videoId] = nil
    }

    func contains(_ videoId: String) -> Bool { places[videoId] != nil }

    func isStandalone(_ videoId: String) -> Bool { places[videoId]?.group == .standalone }

    // MARK: - Running

    /// The next job, taken out of the queue: a listing, else a standalone song, else a collection song.
    mutating func next() -> Job? {
        if !collections.isEmpty { return .collection(collections.removeFirst()) }
        if let track = Self.takeLive(from: &standalone, head: &standaloneHead, places: &places) { return .song(track) }
        if let track = Self.takeLive(from: &listed, head: &listedHead, places: &places) { return .song(track) }
        return nil
    }

    private static func takeLive(
        from slots: inout [Slot], head: inout Int, places: inout [String: Place]
    ) -> MusicTrack? {
        defer {
            // The front is dead weight once it is long and more than half the array.
            if head > 1_024, head * 2 > slots.count {
                slots.removeFirst(head)
                head = 0
            }
        }
        while head < slots.count {
            let slot = slots[head]
            head += 1
            if places[slot.track.videoId]?.token == slot.token {
                places[slot.track.videoId] = nil
                return slot.track
            }
        }
        return nil
    }

    private mutating func takeToken() -> Int {
        defer { nextToken += 1 }
        return nextToken
    }

    private mutating func takeOrder() -> Int {
        defer { nextOrder += 1 }
        return nextOrder
    }
}

/// What a sync does with the list the page has now against the list stored. A pure comparison; when a deletion may run is
/// the service's rule.
nonisolated struct MusicCollectionSyncPlan: Equatable {
    /// On the page now and not in the stored list, in page order.
    let added: [String]
    /// In the stored list and not on the page now, in stored order.
    let removed: [String]
    /// The page's list, each song once, in page order: what is stored after the sync.
    let order: [String]
    /// The songs to download: every one on the page that is not downloaded, in page order. That is the new songs and the
    /// ones an earlier sync listed but never fetched.
    let toQueue: [String]

    /// The plan, or nil when the page has no songs: a list that went empty is never read as every song gone.
    static func make(old: [String], new: [String], downloaded: Set<String>) -> MusicCollectionSyncPlan? {
        var seen = Set<String>()
        let order = new.filter { seen.insert($0).inserted }
        guard !order.isEmpty else { return nil }
        let oldSet = Set(old)
        let newSet = Set(order)
        var removedSeen = Set<String>()
        return MusicCollectionSyncPlan(
            added: order.filter { !oldSet.contains($0) },
            removed: old.filter { !newSet.contains($0) && removedSeen.insert($0).inserted },
            order: order,
            toQueue: order.filter { !downloaded.contains($0) }
        )
    }
}
