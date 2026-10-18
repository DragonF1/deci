// Deci/Music/Playback/MusicQueue.swift
import Foundation

/// The play order for the Music tab: the tapped track first, then radio pages as they arrive.
/// A plain value; `MusicService` decides when to fetch and what to play.
struct MusicQueue: Equatable {
    /// Fetch the next page when this many tracks, or fewer, are left after the current one.
    static let refillThreshold = 3

    private(set) var tracks: [MusicTrack] = []
    private(set) var currentIndex: Int?
    /// Token for the next radio page. Nil before the first page and after the last one.
    private(set) var continuation: String?
    /// The track the radio was seeded from; every later page is requested against it.
    private(set) var seedVideoId: String?

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

    /// Replaces the queue with just this track and makes it the radio seed.
    mutating func start(with track: MusicTrack) {
        tracks = [track]
        currentIndex = 0
        continuation = nil
        seedVideoId = track.videoId
    }

    /// Adds the tracks that are not queued yet, in order, and keeps the page's continuation.
    /// Returns how many were new.
    @discardableResult
    mutating func append(_ page: [MusicTrack], continuation: String?) -> Int {
        var seen = Set(tracks.map(\.videoId))
        let fresh = page.filter { seen.insert($0.videoId).inserted }
        tracks.append(contentsOf: fresh)
        self.continuation = continuation
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

    mutating func clear() {
        self = MusicQueue()
    }
}
