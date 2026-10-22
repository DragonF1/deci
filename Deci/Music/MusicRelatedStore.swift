// Deci/Music/MusicRelatedStore.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicRelated")

/// The songs YouTube Music suggests next to one song, for the Music tab's Related panel. `MusicService` owns one
/// (`service.related`). The state lives here, not in the view, because the popover panel hides whenever it loses focus.
///
/// There are two ways to seed it. The player's Related button follows the song that plays (`follow`): the panel is
/// for that song, and `nowPlayingChanged` moves it to the next song when the player does. A right-click menu pins a
/// seed (`show`): a song seeds with itself, an album, playlist, mix or artist with the first song of its page, read
/// through the page call without touching the browse stack. A pinned seed stays until another is chosen or the panel
/// closes.
///
/// Nothing goes out while the panel is closed. The popup stays mounted when it is hidden, so the host tells the store
/// (`setPopupVisible`): while the popup is hidden a panel that follows the player only notes which song it is on, and
/// asks once when the popup is shown again, so autoplay behind a hidden panel costs no calls. A seed a menu pinned
/// loads whatever the popup shows. A song that comes up while following waits a moment first (`debounce`), so
/// skipping through a queue asks only for the song it stops on. The last `cacheLimit` answers with songs in them are
/// kept by video id for the session, so going back to a seed shows at once; an empty answer or a failure is not
/// kept. The first song found on a collection's page is kept the same way, by browse id, so the same album chosen
/// again does not read its page again. A late answer for a seed that is no longer the current one, or for a session
/// that ended, is dropped. Nothing here logs a song, a playlist or an id, only error kinds.
@MainActor
@Observable
final class MusicRelatedStore {
    enum State: Equatable {
        /// The panel is closed.
        case idle
        /// The seed is being read from its page, or its songs are being asked for.
        case loading
        case loaded([MusicTrack])
        /// YouTube Music has no related songs for the seed.
        case empty
        /// There is no song to ask about: nothing plays, or the album, playlist or artist has no song on its page.
        case noSeed
        /// The panel's words for the failure; it shows them with a Retry button.
        case failed(String)
    }

    /// What the panel says when a load failed, whatever the cause. The cause goes to the log, as a kind only.
    static let failureMessage = "Couldn't load related songs."

    /// What the panel says when YouTube Music has no related songs for the seed.
    static let emptyMessage = "No related songs for this one."

    /// What the panel says when there is no song to ask about.
    static let noSeedMessage = "No song to find related songs for."

    /// How long a changed now-playing song waits before it is asked for.
    static let debounce: Duration = .milliseconds(300)

    /// How many seeds' answers are kept, and how many collections' seeds.
    static let cacheLimit = 10

    private(set) var state: State = .idle
    /// The song whose related songs are shown or being asked for. Nil while a collection's seed is being read, when it
    /// has none, and while nothing is shown.
    private(set) var seed: MusicTrack?
    /// The title of what the user chose: the song, or the album, playlist or artist. It does not change when a
    /// collection's seed is found, so the panel's subline holds still.
    private(set) var subject: String?

    /// The panel's quiet line under its title, "From Song Title"; nil while nothing is shown.
    /// Nil as well when the title is blank, since "From " would say nothing.
    var subline: String? {
        guard let subject, !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "From \(subject)"
    }

    /// The popup is on screen. The popup view stays mounted while hidden, so the host tells the store.
    private(set) var isPopupVisible = true

    /// The panel follows the player's song, as opposed to a seed a menu pinned.
    @ObservationIgnored private(set) var isFollowing = false

    /// Told when a call says the session is gone, so the service can sign out.
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?

    /// What the panel was opened for.
    private enum Target {
        case song(MusicTrack)
        case collection(MusicCollection)
    }

    @ObservationIgnored private let backend: any MusicBackend
    /// Where a collection's page is looked for first, so a page the user already opened is not read again.
    @ObservationIgnored private let browse: MusicBrowseStore
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var target: Target?
    /// The player's song changed while the popup was hidden: the panel is on it, and nothing was asked for yet.
    @ObservationIgnored private var pending = false
    /// Each load names itself with the next number and lands only while it is still the current one, so a new seed, a
    /// close or a reset drops a slower earlier answer.
    @ObservationIgnored private var runCounter = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The related songs found, by video id.
    @ObservationIgnored private var answers = Recents<[MusicTrack]>(limit: MusicRelatedStore.cacheLimit)
    /// The first song found on a collection's page, by browse id.
    @ObservationIgnored private var seeds = Recents<MusicTrack>(limit: MusicRelatedStore.cacheLimit)

    init(
        backend: any MusicBackend,
        browse: MusicBrowseStore,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.backend = backend
        self.browse = browse
        self.sleep = sleep
    }

    // MARK: - Popup

    /// The host's word on whether the popup is on screen. Showing it again asks once for a song the panel moved to
    /// while it was hidden.
    func setPopupVisible(_ visible: Bool) {
        isPopupVisible = visible
        guard visible, pending else { return }
        pending = false
        reload()
    }

    // MARK: - Seeds

    /// The player's Related button opened the panel: it shows the playing song's related songs and follows the player
    /// from here on. Nil, when nothing plays, has no seed.
    func follow(_ nowPlaying: MusicTrack?) {
        isFollowing = true
        begin(nowPlaying.map(Target.song), debounced: false)
    }

    /// The player's song, each time the player changes. Moves the panel to it only while the panel follows the player.
    func nowPlayingChanged(_ nowPlaying: MusicTrack?) {
        guard isFollowing else { return }
        if case .song(let current)? = target, current.videoId == nowPlaying?.videoId { return }
        if target == nil, nowPlaying == nil { return }
        begin(nowPlaying.map(Target.song), debounced: true)
    }

    /// A song's menu: the panel is for that song and stays on it.
    func show(_ track: MusicTrack) {
        isFollowing = false
        begin(.song(track), debounced: false)
    }

    /// An album, playlist, mix or artist menu: the panel is for the first song of its page and stays on it.
    func show(_ collection: MusicCollection) {
        isFollowing = false
        begin(.collection(collection), debounced: false)
    }

    /// Asks again after a failure. A collection whose seed was found keeps it and asks only for the songs. Does
    /// nothing in any other state.
    func retry() {
        guard case .failed = state else { return }
        reload()
    }

    /// The panel closed: the answer that is out lands nowhere, the player is no longer followed, and the cache stays.
    func close() {
        isFollowing = false
        pending = false
        _ = newRun()
        target = nil
        seed = nil
        subject = nil
        state = .idle
    }

    /// Sign-out or an account swap: nothing of the old session stays, the cache included.
    func reset() {
        close()
        answers.removeAll()
        seeds.removeAll()
    }

    // MARK: - Loading

    private func begin(_ new: Target?, debounced: Bool) {
        let run = newRun()
        pending = false
        target = new
        seed = nil
        switch new {
        case nil:
            subject = nil
            state = .noSeed
        case .song(let track)?:
            subject = track.title
            loadRelated(of: track, run: run, debounced: debounced)
        case .collection(let collection)?:
            subject = collection.title
            resolveSeed(of: collection, run: run)
        }
    }

    /// Starts a new run: whatever is out for an earlier one is cancelled and will land nowhere.
    private func newRun() -> Int {
        runCounter += 1
        task?.cancel()
        task = nil
        return runCounter
    }

    /// Asks again for what the panel is on, from the start: a collection whose seed is known asks only for its songs.
    private func reload() {
        guard let target else { return }
        let run = newRun()
        switch target {
        case .song(let track):
            loadRelated(of: track, run: run, debounced: false)
        case .collection(let collection):
            if let seed {
                loadRelated(of: seed, run: run, debounced: false)
            } else {
                resolveSeed(of: collection, run: run)
            }
        }
    }

    /// A panel that follows the player waits while the popup is hidden. A pinned seed is the user's own choice and
    /// does not.
    private var holdsWhileHidden: Bool { isFollowing && !isPopupVisible }

    /// Whether the load for `run` may go out now. A run that is no longer the current one is dropped; one that has to
    /// wait for the popup notes that it is waiting.
    private func mayAsk(_ run: Int) -> Bool {
        guard isCurrent(run) else { return false }
        guard holdsWhileHidden else { return true }
        task = nil
        pending = true
        return false
    }

    /// The songs for `track`, from the cache when they are there, else from YouTube Music. `debounced` is for a changed
    /// now-playing song only.
    private func loadRelated(of track: MusicTrack, run: Int, debounced: Bool) {
        guard let id = Self.usableId(track.videoId) else {
            seed = nil
            state = .noSeed
            return
        }
        seed = track
        if let kept = answers.value(for: id) {
            state = .loaded(kept)
            return
        }
        state = .loading
        guard mayAsk(run) else { return }
        task = Task { [weak self, backend, sleep] in
            if debounced {
                // A cancelled task leaves the sleep early; a timer that ignores that is caught by the run check.
                do { try await sleep(Self.debounce) } catch { return }
            }
            guard self?.mayAsk(run) == true else { return }
            do {
                let tracks = try await backend.related(videoId: id)
                self?.land(tracks, id: id, run: run)
            } catch is CancellationError {
                // Whoever cancelled has already set the state.
            } catch {
                self?.fail(error, run: run)
            }
        }
    }

    /// Finds the first song of a collection's page: in the browse store when the page is loaded there, else with the
    /// page call. The page is not pushed on the browse stack.
    private func resolveSeed(of collection: MusicCollection, run: Int) {
        let browseId = collection.browseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !browseId.isEmpty else {
            state = .noSeed
            return
        }
        if let kept = seeds.value(for: browseId) {
            loadRelated(of: kept, run: run, debounced: false)
            return
        }
        state = .loading
        if case .loaded(let page) = browse.pageState(browseId) {
            seedFound(in: page, browseId: browseId, run: run)
            return
        }
        task = Task { [weak self, backend] in
            do {
                let page = try await backend.page(browseId: browseId)
                self?.seedFound(in: page, browseId: browseId, run: run)
            } catch is CancellationError {
                // Whoever cancelled has already set the state.
            } catch {
                self?.fail(error, run: run)
            }
        }
    }

    private func seedFound(in page: MusicBrowsePage, browseId: String, run: Int) {
        guard isCurrent(run) else { return }
        task = nil
        guard let first = page.tracks.first(where: { Self.usableId($0.videoId) != nil }) else {
            seed = nil
            state = .noSeed
            return
        }
        seeds.set(first, for: browseId)
        loadRelated(of: first, run: run, debounced: false)
    }

    private func land(_ tracks: [MusicTrack], id: String, run: Int) {
        guard isCurrent(run) else { return }
        task = nil
        if tracks.isEmpty {
            state = .empty
            return
        }
        answers.set(tracks, for: id)
        state = .loaded(tracks)
    }

    private func fail(_ error: any Error, run: Int) {
        guard isCurrent(run) else { return }
        task = nil
        logger.error("related songs failed: \(MusicService.logDescription(of: error), privacy: .public)")
        state = .failed(Self.failureMessage)
        if (error as? MusicError) == .signedOut { onSessionExpired?() }
    }

    private func isCurrent(_ run: Int) -> Bool {
        run == runCounter
    }

    /// The id a song is asked for by: trimmed, nil when nothing is left.
    private static func usableId(_ videoId: String) -> String? {
        let id = videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}

/// A small map that keeps the `limit` keys used last: reading or writing a key makes it the newest, and the oldest
/// goes when there are too many.
private struct Recents<Value> {
    let limit: Int
    private var values: [String: Value] = [:]
    /// The keys, the least recently used first.
    private var order: [String] = []

    init(limit: Int) {
        self.limit = limit
    }

    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func set(_ value: Value, for key: String) {
        values[key] = value
        touch(key)
        while order.count > limit {
            values[order.removeFirst()] = nil
        }
    }

    mutating func removeAll() {
        values.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
