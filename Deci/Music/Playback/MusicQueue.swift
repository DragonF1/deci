// Deci/Music/Playback/MusicQueue.swift
import Foundation

/// The play order for the Music tab: the tapped track first, then radio pages as they arrive,
/// or a playlist or album page in its own order, loaded in full. Once a page has loaded in full the automix of its
/// playlist (the radio of its last track when it has none) is staged in `autoplay` and joins the queue when the page
/// runs out.
/// A mix page is the exception: its mix is asked near the page's last song and what it answers joins the queue itself,
/// page after page while the mix has a continuation (`mixPlaylistId`, `mixHasMore`).
/// A plain value; `MusicService` decides when to fetch and what to play.
struct MusicQueue: Equatable {
    /// Fetch the next radio page, or ask for a radio to follow, when this many tracks, or fewer, are left after the
    /// current one.
    static let refillThreshold = 3

    /// A fully loaded playlist or album asks for its radio at once, whatever the number of songs left, but only for this
    /// many songs (answered, empty or turned down). After that it waits for `refillThreshold` again, so a radio that keeps
    /// answering nothing is not asked for every song of the playlist.
    static let eagerAskLimit = 3

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
    /// The playlist whose automix follows a page queue, when its page has one. Nil for a radio queue and for an empty one.
    private(set) var automixPlaylistId: String?
    /// The mix playlist this queue is the endless play of, when it was started from a mix page. It stays through the
    /// radio the queue becomes, and goes when the mix is turned down or runs dry into a plain radio. Nil otherwise.
    private(set) var mixPlaylistId: String?
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
    /// The songs the listener put here with Play next or Add to queue. They stay ahead of a shuffle's mix.
    private var queuedIds: Set<String> = []
    /// The songs Add to queue put at the end of a page. A page that is still loading adds its later songs before them.
    private var endIds: Set<String> = []
    /// The songs the listener took out. Later radio pages and a restaged radio do not bring them back.
    private var removedIds: Set<String> = []

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

    /// No radio has answered for this tapped-song queue yet; with Autoplay off none is asked for.
    var awaitsFirstRadioPage: Bool {
        guard case .radio = source else { return false }
        return askedSeeds.isEmpty
    }

    /// The track whose radio should be asked for next: the last one not asked yet. Nil while a later page is still to
    /// load, or when a page already has its radio staged. A playlist or album page that has loaded in full gives its seed
    /// at once, whatever the number of songs left, so its recommendations are staged from the start; it does so for
    /// `eagerAskLimit` songs only, and after that it waits for `refillThreshold` like the rest. A mix page, a tapped-song
    /// radio and a radio that has run out wait for `refillThreshold`. A page hands over to the radio of its last own song
    /// in the page's order, which a shuffle does not change; a radio that has run out carries on from the radio of its
    /// last track.
    var refillSeed: String? {
        guard !isEmpty, continuation == nil else { return nil }
        if case .page = source {
            if !autoplay.isEmpty { return nil }
            let eager = mixPlaylistId == nil && askedSeeds.count < Self.eagerAskLimit
            guard eager || upcomingCount <= Self.refillThreshold else { return nil }
            if let seed = lastPageSong { return seed }
        } else if upcomingCount > Self.refillThreshold {
            return nil
        }
        return tracks.last { !askedSeeds.contains($0.videoId) }?.videoId
    }

    /// The last song of the page itself in the page's order: not one the listener queued, not one already asked.
    /// While shuffled the natural rank gives the page's order back.
    private var lastPageSong: String? {
        let own = tracks.filter { !queuedIds.contains($0.videoId) && !askedSeeds.contains($0.videoId) }
        guard isShuffled else { return own.last?.videoId }
        return own.max { (naturalRank[$0.videoId] ?? Int.max) < (naturalRank[$1.videoId] ?? Int.max) }?.videoId
    }

    /// Replaces the queue with just this track and makes it the radio seed.
    mutating func start(with track: MusicTrack) {
        tracks = [track]
        currentIndex = 0
        continuation = nil
        seedVideoId = track.videoId
        source = .radio(seedVideoId: track.videoId)
        automixPlaylistId = nil
        mixPlaylistId = nil
        forgetShuffle()
        forgetAutoplay()
        forgetEdits()
    }

    /// Replaces the queue with a page's tracks in page order, positioned on `track`. The tracks
    /// before it stay for Previous. A track the page does not list is put in front of it. `automixPlaylistId` is the
    /// playlist whose automix follows the page, nil when the page has none. `mixPlaylistId` is the mix the page is, nil
    /// for any other page; the queue then asks that mix for more instead of staging an automix.
    mutating func start(
        page list: [MusicTrack],
        playing track: MusicTrack,
        browseId: String,
        continuation: String?,
        automixPlaylistId: String? = nil,
        mixPlaylistId: String? = nil
    ) {
        var seen = Set<String>()
        var ordered = list.filter { seen.insert($0.videoId).inserted }
        if !seen.contains(track.videoId) { ordered.insert(track, at: 0) }
        tracks = ordered
        currentIndex = ordered.firstIndex { $0.videoId == track.videoId }
        self.continuation = continuation
        seedVideoId = nil
        source = .page(browseId: browseId)
        self.automixPlaylistId = automixPlaylistId
        self.mixPlaylistId = mixPlaylistId.flatMap { $0.isEmpty ? nil : $0 }
        forgetShuffle()
        forgetAutoplay()
        forgetEdits()
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
        var fresh = addable(from: page)
        self.continuation = continuation
        guard isShuffled else {
            // A song added to the end of a page that was still loading stays behind the rest of the page.
            let from = (currentIndex ?? -1) + 1
            let slot = isPage ? tracks[from...].firstIndex { endIds.contains($0.videoId) } : nil
            tracks.insert(contentsOf: fresh, at: slot ?? tracks.count)
            return fresh.count
        }
        for track in fresh {
            naturalRank[track.videoId] = nextRank
            nextRank += 1
        }
        let from = (currentIndex ?? -1) + 1
        // A song added to the end of the page stays behind the page's later songs when shuffle is turned off.
        for track in tracks[from...] where endIds.contains(track.videoId) {
            naturalRank[track.videoId] = nextRank
            nextRank += 1
        }
        fresh.shuffle(using: &generator)
        // Only the part after the current track moves: never the track that plays next, the songs the listener
        // queued ahead of the mix, or the songs added to the end of the page.
        let lastQueued = tracks[from...].lastIndex { queuedIds.contains($0.videoId) && !endIds.contains($0.videoId) }
        let start = lastQueued.map { $0 + 1 } ?? from
        let protectsNext = lastQueued == nil
        for track in fresh {
            let end = tracks[start...].firstIndex { endIds.contains($0.videoId) } ?? tracks.count
            let count = end - start
            let slot = Int.random(in: (protectsNext ? min(1, count) : 0)...count, using: &generator)
            tracks.insert(track, at: start + slot)
        }
        return fresh.count
    }

    /// How many of a page's tracks `append` would add: the ones the queue does not have and the listener did not take out,
    /// each once. Changes nothing.
    func addableCount(of page: [MusicTrack]) -> Int {
        addable(from: page).count
    }

    private func addable(from page: [MusicTrack]) -> [MusicTrack] {
        var seen = Set(tracks.map(\.videoId))
        return page.filter { !removedIds.contains($0.videoId) && seen.insert($0.videoId).inserted }
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
    /// `moreRadio`. A radio has no playlist to ask the automix of, so that id goes.
    mutating func adoptRadio(seedVideoId: String) {
        self.seedVideoId = seedVideoId
        source = .radio(seedVideoId: seedVideoId)
        automixPlaylistId = nil
        askedSeeds.insert(seedVideoId)
    }

    /// The radio of `seed` was turned down: it is not asked for again in this queue.
    mutating func noteAsked(_ seed: String) {
        askedSeeds.insert(seed)
    }

    /// The mix was turned down or ran dry into a plain radio: the queue is no longer a mix's. Nothing else changes.
    mutating func forgetMix() {
        mixPlaylistId = nil
    }

    /// The mix to ask for its first songs: set only while the queue is still the mix page, before the mix has answered.
    var pendingMixPlaylistId: String? { isPage ? mixPlaylistId : nil }

    /// The mix can still grow: its first answer has not come yet, or the answer left a continuation to load.
    var mixHasMore: Bool { mixPlaylistId != nil && (isPage || continuation != nil) }

    /// Keeps a radio page to play after the page queue runs out, without the tracks the queue already has.
    /// Returns how many tracks it kept; none when the queue is not a page.
    @discardableResult
    mutating func stageAutoplay(_ page: [MusicTrack], continuation: String?, seed: String) -> Int {
        askedSeeds.insert(seed)
        guard case .page = source else { return 0 }
        var seen = Set(tracks.map(\.videoId))
        autoplay = page.filter { !removedIds.contains($0.videoId) && seen.insert($0.videoId).inserted }
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
            // The songs the listener queued play right after the current one, in their order; the rest is mixed behind.
            let ahead = tracks[currentIndex...].filter { queuedIds.contains($0.videoId) }
            let aheadIds = Set(ahead.map(\.videoId))
            tracks.removeAll { aheadIds.contains($0.videoId) }
            tracks.shuffle(using: &generator)
            tracks.insert(contentsOf: [current] + ahead, at: 0)
            self.currentIndex = 0
        } else {
            let start = currentIndex + 1
            let ahead = tracks[start...].filter { queuedIds.contains($0.videoId) }
            var rest = tracks[start...].filter { !queuedIds.contains($0.videoId) }
            rest.shuffle(using: &generator)
            tracks.replaceSubrange(start..., with: ahead + rest)
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

    // MARK: - Edits

    /// Play next: the song plays right after the current one. A song that is already in the queue moves there, so the
    /// queue never lists it twice. False, and nothing changes, when the queue is empty or the song is the current one.
    @discardableResult
    mutating func playNext(_ track: MusicTrack) -> Bool {
        guard let currentIndex = placeable(track) else { return false }
        insert(track, at: detach(track.videoId, current: currentIndex) + 1)
        return true
    }

    /// Add to queue: the song goes after the rest of the queue's own songs and before the radio that follows them. On a
    /// page that is the end of the page; on a radio it is after the songs the listener queued, ahead of the radio's.
    /// A song that is already in the queue moves there. False, and nothing changes, when the queue is empty or the song
    /// is the current one.
    @discardableResult
    mutating func addToQueue(_ track: MusicTrack) -> Bool {
        guard let currentIndex = placeable(track) else { return false }
        let current = detach(track.videoId, current: currentIndex)
        if isPage {
            insert(track, at: tracks.count, endsNaturalOrder: true)
            endIds.insert(track.videoId)
        } else {
            let lastQueued = tracks[(current + 1)...].lastIndex { queuedIds.contains($0.videoId) }
            insert(track, at: (lastQueued ?? current) + 1)
        }
        return true
    }

    /// Remove from queue: takes an upcoming song, or one of the next lap, out of the play order, and a song of the staged
    /// radio out of the radio. It does not come back on the next lap or with a later radio page. False when the song is
    /// not queued or is the current one.
    @discardableResult
    mutating func remove(videoId: String) -> Bool {
        guard let currentIndex, tracks[currentIndex].videoId != videoId else { return false }
        let known = tracks.contains { $0.videoId == videoId } || autoplay.contains { $0.videoId == videoId }
        guard known else { return false }
        detach(videoId, current: currentIndex)
        naturalRank[videoId] = nil
        queuedIds.remove(videoId)
        removedIds.insert(videoId)
        return true
    }

    /// The index of the current song, when `track` may be put into the queue: not empty, and not the song that plays.
    private func placeable(_ track: MusicTrack) -> Int? {
        guard let currentIndex, tracks[currentIndex].videoId != track.videoId else { return nil }
        return currentIndex
    }

    /// Takes `videoId` out of the play order and the staged radio. Returns where the current song is afterwards.
    @discardableResult
    private mutating func detach(_ videoId: String, current: Int) -> Int {
        endIds.remove(videoId)
        autoplay.removeAll { $0.videoId == videoId }
        if autoplay.isEmpty {
            autoplayContinuation = nil
            autoplaySeed = nil
        }
        guard let index = tracks.firstIndex(where: { $0.videoId == videoId }) else { return current }
        tracks.remove(at: index)
        let moved = index < current ? current - 1 : current
        currentIndex = moved
        return moved
    }

    /// Puts a track the listener chose into the play order. While shuffled it takes the natural rank of the song it
    /// follows (the later offset keeps it right behind it), or, with `endsNaturalOrder`, a rank past the end.
    private mutating func insert(_ track: MusicTrack, at index: Int, endsNaturalOrder: Bool = false) {
        if isShuffled {
            if !endsNaturalOrder, let before = tracks[..<index].last, let rank = naturalRank[before.videoId] {
                naturalRank[track.videoId] = rank
            } else {
                naturalRank[track.videoId] = nextRank
                nextRank += 1
            }
        }
        tracks.insert(track, at: index)
        queuedIds.insert(track.videoId)
        removedIds.remove(track.videoId)
    }

    private mutating func forgetEdits() {
        queuedIds = []
        endIds = []
        removedIds = []
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
