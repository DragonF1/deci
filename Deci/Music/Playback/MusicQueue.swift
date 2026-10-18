// Deci/Music/Playback/MusicQueue.swift
import Foundation

/// The play order for the Music tab: the tapped track first, then radio pages as they arrive,
/// or a playlist or album page in its own order.
/// A plain value; `MusicService` decides when to fetch and what to play.
struct MusicQueue: Equatable {
    /// Fetch the next page when this many tracks, or fewer, are left after the current one.
    static let refillThreshold = 3

    /// Where the queue's later pages come from.
    enum Source: Equatable {
        /// The radio seeded from this track; later pages are `moreRadio`.
        case radio(seedVideoId: String)
        /// A playlist or album page; later pages are `moreTracks`.
        case page(browseId: String)
    }

    private(set) var tracks: [MusicTrack] = []
    private(set) var currentIndex: Int?
    /// Token for the next page. Nil before the first radio page and after the last page of either source.
    private(set) var continuation: String?
    /// The track the radio was seeded from; every later page is requested against it. Nil for a page queue.
    private(set) var seedVideoId: String?
    /// What `continuation` continues. Nil for an empty queue.
    private(set) var source: Source?
    /// The play order is shuffled. `tracks` is then the shuffled order and `unshuffle()` brings the natural one back.
    private(set) var isShuffled = false
    /// Where each track sits in the natural order, kept only while shuffled.
    private var naturalRank: [String: Int] = [:]
    private var nextRank = 0

    var isEmpty: Bool { tracks.isEmpty }
    var current: MusicTrack? { currentIndex.map { tracks[$0] } }

    /// Everything after the current track.
    var upcoming: ArraySlice<MusicTrack> {
        guard let currentIndex else { return [] }
        return tracks[(currentIndex + 1)...]
    }

    /// The current track and everything after it: what the "Up next" list shows.
    var fromCurrent: ArraySlice<MusicTrack> {
        guard let currentIndex else { return tracks[...] }
        return tracks[currentIndex...]
    }

    var upcomingCount: Int { upcoming.count }
    var hasNext: Bool { upcomingCount > 0 }
    var hasPrevious: Bool { (currentIndex ?? 0) > 0 }
    var needsMore: Bool { continuation != nil && upcomingCount <= Self.refillThreshold }

    /// A page queue on its last track with no later page to load: a playlist or an album that has run out.
    var hasReachedPageEnd: Bool {
        guard case .page = source else { return false }
        return continuation == nil && !isEmpty && upcomingCount == 0
    }

    /// Replaces the queue with just this track and makes it the radio seed.
    mutating func start(with track: MusicTrack) {
        tracks = [track]
        currentIndex = 0
        continuation = nil
        seedVideoId = track.videoId
        source = .radio(seedVideoId: track.videoId)
        forgetShuffle()
    }

    /// Replaces the queue with a page's tracks in page order, positioned on `track`. The tracks
    /// before it stay for Previous. A track the page does not list is put in front of it.
    mutating func start(page list: [MusicTrack], playing track: MusicTrack, browseId: String, continuation: String?) {
        var seen = Set<String>()
        var ordered = list.filter { seen.insert($0.videoId).inserted }
        if !seen.contains(track.videoId) { ordered.insert(track, at: 0) }
        tracks = ordered
        currentIndex = ordered.firstIndex { $0.videoId == track.videoId }
        self.continuation = continuation
        seedVideoId = nil
        source = .page(browseId: browseId)
        forgetShuffle()
    }

    /// Adds the tracks that are not queued yet, in order, and keeps the page's continuation.
    /// Returns how many were new.
    @discardableResult
    mutating func append(_ page: [MusicTrack], continuation: String?) -> Int {
        var generator = SystemRandomNumberGenerator()
        return append(page, continuation: continuation, using: &generator)
    }

    /// Like `append(_:continuation:)`, but while the queue is shuffled the new tracks are mixed in at random places
    /// after the next track instead of going on the end. The tracks that were already queued keep their order.
    @discardableResult
    mutating func append<G: RandomNumberGenerator>(_ page: [MusicTrack], continuation: String?, using generator: inout G) -> Int {
        var seen = Set(tracks.map(\.videoId))
        var fresh = page.filter { seen.insert($0.videoId).inserted }
        self.continuation = continuation
        guard isShuffled else {
            tracks.append(contentsOf: fresh)
            return fresh.count
        }
        for track in fresh {
            naturalRank[track.videoId] = nextRank
            nextRank += 1
        }
        fresh.shuffle(using: &generator)
        // Only the part after the current track moves, and never the track that plays next.
        let start = (currentIndex ?? -1) + 1
        for track in fresh {
            let count = tracks.count - start
            let slot = Int.random(in: min(1, count)...count, using: &generator)
            tracks.insert(track, at: start + slot)
        }
        return fresh.count
    }

    @discardableResult
    mutating func advance() -> MusicTrack? {
        guard let currentIndex, currentIndex + 1 < tracks.count else { return nil }
        self.currentIndex = currentIndex + 1
        return tracks[currentIndex + 1]
    }

    @discardableResult
    mutating func retreat() -> MusicTrack? {
        guard let currentIndex, currentIndex > 0 else { return nil }
        self.currentIndex = currentIndex - 1
        return tracks[currentIndex - 1]
    }

    @discardableResult
    mutating func jump(to videoId: String) -> MusicTrack? {
        guard let index = tracks.firstIndex(where: { $0.videoId == videoId }) else { return nil }
        currentIndex = index
        return tracks[index]
    }

    /// Ends paging: the tracks and the position stay, no further page is asked for.
    mutating func clearContinuation() {
        continuation = nil
    }

    /// Loop playlist: back to the first track of the play order.
    @discardableResult
    mutating func wrapToStart() -> MusicTrack? {
        guard let first = tracks.first else { return nil }
        currentIndex = 0
        return first
    }

    /// A page queue that has run out carries on as the radio of its last track. The tracks and the position stay,
    /// later pages are `moreRadio`. Returns the track to seed the radio with, or nil when the queue is not at a page end.
    @discardableResult
    mutating func adoptRadioOfLastTrack() -> String? {
        guard hasReachedPageEnd, let last = tracks.last else { return nil }
        seedVideoId = last.videoId
        source = .radio(seedVideoId: last.videoId)
        return last.videoId
    }

    /// Mixes what comes after the current track. The tracks before it stay where they are, so Previous still goes
    /// back. With `mixingEarlier` the current track moves to the front and every other track is mixed in after it
    /// (a page started from a row in the middle). Does nothing when the queue is already shuffled.
    mutating func shuffle<G: RandomNumberGenerator>(mixingEarlier: Bool = false, using generator: inout G) {
        guard !isShuffled else { return }
        isShuffled = true
        guard let currentIndex else { return }
        naturalRank = Dictionary(tracks.enumerated().map { ($0.element.videoId, $0.offset) }) { first, _ in first }
        nextRank = tracks.count
        if mixingEarlier {
            let current = tracks.remove(at: currentIndex)
            tracks.shuffle(using: &generator)
            tracks.insert(current, at: 0)
            self.currentIndex = 0
        } else {
            tracks[(currentIndex + 1)...].shuffle(using: &generator)
        }
    }

    /// Puts every track back in its natural order and stays on the current track.
    mutating func unshuffle() {
        guard isShuffled else { return }
        let currentId = current?.videoId
        let rank = naturalRank
        tracks = tracks.enumerated()
            .sorted { lhs, rhs in
                let left = rank[lhs.element.videoId] ?? Int.max
                let right = rank[rhs.element.videoId] ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        currentIndex = currentId.flatMap { id in tracks.firstIndex { $0.videoId == id } }
        forgetShuffle()
    }

    private mutating func forgetShuffle() {
        isShuffled = false
        naturalRank = [:]
        nextRank = 0
    }

    mutating func clear() {
        self = MusicQueue()
    }
}
