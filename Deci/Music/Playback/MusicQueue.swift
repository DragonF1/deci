// Deci/Music/Playback/MusicQueue.swift
import Foundation

/// The play order for the Music tab: the tapped track first, then radio pages as they arrive,
/// or a playlist or album page in its own order, loaded in full. Near the end of a page the radio of its last track
/// is staged in `autoplay` and joins the queue when the page runs out.
/// A plain value; `MusicService` decides when to fetch and what to play.
struct MusicQueue: Equatable {
    /// Fetch the next radio page, or ask for a radio to follow, when this many tracks, or fewer, are left after the
    /// current one.
    static let refillThreshold = 3

    /// A page keeps loading pages until it holds this many tracks, so Up next and the shuffle cover the playlist.
    /// The playlist sort loads up to the same number.
    static let fullLoadCap = 2000

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
    /// The radio that plays after a finished page, fetched while the page's last tracks play. Not part of `tracks`
    /// until `takeAutoplay()`, so Loop playlist and a reshuffle never touch it. Empty for a radio queue.
    private(set) var autoplay: [MusicTrack] = []
    private var autoplayContinuation: String?
    private var autoplaySeed: String?
    /// The tracks whose radio has been asked for in this queue, answered or turned down. None is asked twice.
    private var askedSeeds: Set<String> = []

    var isEmpty: Bool { tracks.isEmpty }
    /// The queue plays a playlist or album page (not a radio).
    var isPage: Bool {
        guard case .page = source else { return false }
        return true
    }
    var current: MusicTrack? { currentIndex.map { tracks[$0] } }

    /// Everything after the current track.
    var upcoming: ArraySlice<MusicTrack> {
        guard let currentIndex else { return [] }
        return tracks[(currentIndex + 1)...]
    }

    var upcomingCount: Int { upcoming.count }
    var hasNext: Bool { upcomingCount > 0 }
    var hasPrevious: Bool { (currentIndex ?? 0) > 0 }
    var needsMore: Bool {
        guard continuation != nil else { return false }
        // A page loads in full, up to the cap, so Up next lists the whole playlist and a shuffle mixes all of it.
        // A radio has no end, so it keeps the threshold.
        if case .page = source, tracks.count < Self.fullLoadCap { return true }
        return upcomingCount <= Self.refillThreshold
    }

    /// The radio started with the queue has not answered yet.
    var awaitsFirstRadioPage: Bool {
        guard case .radio = source else { return false }
        return askedSeeds.isEmpty
    }

    /// The track whose radio should be asked for next: the last one not asked yet. Nil unless the queue is running out
    /// with no later page to load, or when a page already has its radio staged. A page hands over to the radio of its
    /// last track; a radio that has run out carries on from the radio of its last track.
    var refillSeed: String? {
        guard !isEmpty, continuation == nil, upcomingCount <= Self.refillThreshold else { return nil }
        if case .page = source, !autoplay.isEmpty { return nil }
        return tracks.last { !askedSeeds.contains($0.videoId) }?.videoId
    }

    /// Replaces the queue with just this track and makes it the radio seed.
    mutating func start(with track: MusicTrack) {
        tracks = [track]
        currentIndex = 0
        continuation = nil
        seedVideoId = track.videoId
        source = .radio(seedVideoId: track.videoId)
        forgetShuffle()
        forgetAutoplay()
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
        forgetAutoplay()
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

    /// Plays a queued track. A track of the staged radio brings the radio into the queue first.
    @discardableResult
    mutating func jump(to videoId: String) -> MusicTrack? {
        if !tracks.contains(where: { $0.videoId == videoId }), autoplay.contains(where: { $0.videoId == videoId }) {
            takeAutoplay()
        }
        guard let index = tracks.firstIndex(where: { $0.videoId == videoId }) else { return nil }
        currentIndex = index
        return tracks[index]
    }

    /// Ends paging: the tracks and the position stay, no further page is asked for.
    mutating func clearContinuation() {
        continuation = nil
    }

    /// Loop playlist: back to the first track of the play order. A shuffled queue keeps its mix, so every lap starts
    /// from the same shuffled start.
    @discardableResult
    mutating func wrapToStart() -> MusicTrack? {
        guard !tracks.isEmpty else { return nil }
        currentIndex = 0
        return tracks[0]
    }

    /// The queue carries on as the radio seeded by `seedVideoId`: the tracks and the position stay, later pages are
    /// `moreRadio`.
    mutating func adoptRadio(seedVideoId: String) {
        self.seedVideoId = seedVideoId
        source = .radio(seedVideoId: seedVideoId)
        askedSeeds.insert(seedVideoId)
    }

    /// The radio of `seed` was turned down: it is not asked for again in this queue.
    mutating func noteAsked(_ seed: String) {
        askedSeeds.insert(seed)
    }

    /// Keeps a radio page to play after the page queue runs out, without the tracks the queue already has.
    /// Returns how many tracks it kept; none when the queue is not a page.
    @discardableResult
    mutating func stageAutoplay(_ page: [MusicTrack], continuation: String?, seed: String) -> Int {
        askedSeeds.insert(seed)
        guard case .page = source else { return 0 }
        var seen = Set(tracks.map(\.videoId))
        autoplay = page.filter { seen.insert($0.videoId).inserted }
        autoplayContinuation = autoplay.isEmpty ? nil : continuation
        autoplaySeed = autoplay.isEmpty ? nil : seed
        return autoplay.count
    }

    /// The staged radio joins the end of the queue and the queue carries on as that radio. Shuffle never mixes it into
    /// the page. False when nothing is staged.
    @discardableResult
    mutating func takeAutoplay() -> Bool {
        guard case .page = source, !autoplay.isEmpty, let seed = autoplaySeed else { return false }
        var seen = Set(tracks.map(\.videoId))
        let fresh = autoplay.filter { seen.insert($0.videoId).inserted }
        if isShuffled {
            for track in fresh {
                naturalRank[track.videoId] = nextRank
                nextRank += 1
            }
        }
        tracks.append(contentsOf: fresh)
        continuation = autoplayContinuation
        adoptRadio(seedVideoId: seed)
        forgetAutoplay(keepingAsked: true)
        return !fresh.isEmpty
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

    private mutating func forgetAutoplay(keepingAsked: Bool = false) {
        autoplay = []
        autoplayContinuation = nil
        autoplaySeed = nil
        if !keepingAsked { askedSeeds = [] }
    }

    mutating func clear() {
        self = MusicQueue()
    }
}
