// Deci/Music/MusicLyricsStore.swift
import Foundation
import Observation

/// The lyrics of the playing track, for the Music tab's lyrics panel. `MusicService` owns one
/// (`service.lyrics`). The state lives here, not in the view, because the popover panel hides whenever it
/// loses focus.
///
/// Lyrics are fetched only while the panel is open and the popup is on screen, for the current track, and
/// again when the track changes while it is. A closed panel never touches the network. A track change waits a
/// moment first (`debounce`), so skipping through a queue sends one request, for the song it stops on. When a lyrics
/// source asks us to wait (busy, or a server-error window), the store asks again by itself as the window ends, but
/// only while the panel is being watched.
///
/// Where the lyrics came from is the provider's business (the live one tries YouTube Music, then LRCLIB); the store
/// carries the credit line the provider gave with the answer, for the panel to print under the lyrics.
@MainActor
@Observable
final class MusicLyricsStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded(LyricsResult)
        /// A lyrics source asked us to wait; nothing goes out before the date, and the store asks again then.
        case busy(until: Date)
        /// A short message for the user; the panel shows it with a Retry button. With `retryAfter` (a server error
        /// that opened a short window) Retry comes once that date has passed, nothing goes out before it, and the
        /// store asks again by itself then.
        case failed(String, retryAfter: Date? = nil)
    }

    /// How long a track change waits before asking. A newer change inside it replaces the pending request.
    static let debounce: Duration = .milliseconds(300)

    /// The panel's words while a lyrics source asks us to wait.
    static let busyMessage = "Lyrics service is busy. Trying again shortly."

    /// The store the app uses: lyrics from YouTube Music, with LRCLIB behind it and a disk cache in front.
    static func live() -> MusicLyricsStore {
        MusicLyricsStore(provider: LyricsChain.live())
    }

    private(set) var state: State = .idle
    /// The track the lyrics are for: the one the player has loaded, nil when nothing plays.
    private(set) var track: MusicTrack?
    /// The user has the lyrics panel open. It stays true while the popup is hidden.
    private(set) var isPanelOpen = false
    /// The popup is on screen. The popup view stays mounted while hidden, so it has to be told.
    private(set) var isPopupVisible = true
    /// The last position the player reported, for the highlight to run ahead of between ticks.
    private(set) var playhead = LyricsPlayhead.zero
    /// The credit that came with the lyrics now on screen. Only meaningful while `state` is `.loaded`: every other
    /// state is entered without it, and `credit` hides it there.
    private var loadedCredit: String?

    /// The line that says where the lyrics on screen came from ("Lyrics from LRCLIB"). Nil while loading, after a
    /// failure, when the track changes (it goes with the lyrics it belonged to), and when the source names no one.
    var credit: String? {
        guard case .loaded = state else { return nil }
        return loadedCredit
    }

    /// The panel is open and can be seen: the only time anything is fetched or animated.
    var isWatching: Bool { isPanelOpen && isPopupVisible }

    /// Retry would send a request now: the last load failed (and its window, if any, has passed), or the busy
    /// window has passed.
    var canRetry: Bool {
        switch state {
        case .failed(_, let retryAfter): retryAfter.map { $0 <= now() } ?? true
        case .busy(let until): until <= now()
        case .idle, .loading, .loaded: false
        }
    }

    /// Reads the player's position and whether it plays, for the one fresh sample taken when the panel comes
    /// into view (ticks are ignored while it is not). Set by `MusicService`; nil means no sample.
    @ObservationIgnored var playbackSampler: (@MainActor () -> (position: TimeInterval, isPlaying: Bool))?

    @ObservationIgnored let provider: any LyricsProviding
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// The player's length of the track, in seconds, once it is known; nil until then.
    @ObservationIgnored private var duration: TimeInterval?
    /// The lookup in flight or last done ran with no duration, and its answer may be a guess (LRCLIB matches on the
    /// length). A duration that shows up for the same track while this is set redoes the lookup once. An answer that
    /// does not depend on the length (`LyricsAnswer.lengthMatters` false) clears it: nothing is left to improve.
    @ObservationIgnored private var lookupLacksDuration = false
    /// A fetch names itself with the next number and only lands while it is still the current one, so a
    /// track change, a close or a reset drops a slower earlier answer.
    @ObservationIgnored private var runCounter = 0
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    /// The timer that asks again when a busy or server-error window ends. At most one, and only while watching.
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    init(
        provider: any LyricsProviding,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.provider = provider
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Panel and popup

    func setPanelOpen(_ open: Bool) {
        guard open != isPanelOpen else { return }
        isPanelOpen = open
        watchingChanged()
    }

    func setPopupVisible(_ visible: Bool) {
        guard visible != isPopupVisible else { return }
        isPopupVisible = visible
        watchingChanged()
    }

    /// Coming into view: the player's position is read once (ticks were ignored while hidden), so the highlight is
    /// right at once, and the lyrics are fetched if they are not there. A window that is still open gets its timer
    /// back. Going out of view drops the fetch and the timer.
    private func watchingChanged() {
        if isWatching {
            samplePlayer()
            fetchIfNeeded(debounced: false)
            scheduleAutoRetry()
        } else {
            cancelFetch()
        }
    }

    private func samplePlayer() {
        guard let sample = playbackSampler?() else { return }
        playhead = LyricsPlayhead(time: sample.position, isPlaying: sample.isPlaying, observedAt: now())
    }

    // MARK: - Track and playback

    /// The player's current track. A new one clears the lyrics and, while watching, fetches its; the same one
    /// again only updates the length (the stream's exact length arrives after the track does).
    func trackChanged(_ new: MusicTrack?, duration: TimeInterval) {
        let known = duration.isFinite && duration > 0 ? duration : nil
        if let new, new.videoId == track?.videoId {
            if track != new { track = new }
            if let known {
                let lookupRanBlind = lookupLacksDuration
                self.duration = known
                if lookupRanBlind { durationArrived() }
            }
            return
        }
        cancelFetch()
        state = .idle
        track = new
        self.duration = known
        lookupLacksDuration = false
        fetchIfNeeded(debounced: true)
    }

    /// The exact length reached a track whose lookup ran without one. The answer may be a guess and was not
    /// kept, so it is dropped and asked for again, once: at once while watching, else on the next open. A failed
    /// or busy lookup stays as it is, and its Retry uses the new length.
    private func durationArrived() {
        switch state {
        case .loading, .loaded:
            lookupLacksDuration = false
            cancelFetch()
            state = .idle
            fetchIfNeeded(debounced: false)
        case .idle, .busy, .failed:
            break
        }
    }

    /// The player's position, for the highlight. Only while the panel is open and the popup is showing: a hidden
    /// panel does not redraw on every tick, and the next sample is taken when it comes back.
    func observePlayback(position: TimeInterval, isPlaying: Bool) {
        guard isWatching else { return }
        playhead = LyricsPlayhead(time: position, isPlaying: isPlaying, observedAt: now())
    }

    // MARK: - Loading

    /// Asks again after a failure, or once the busy window has passed. Nothing goes out earlier.
    func retry() {
        guard isWatching, track != nil, canRetry else { return }
        fetchIfNeeded(debounced: false)
    }

    /// Sign-out or an account swap: nothing of the old session stays. The disk cache may.
    func reset() {
        cancelFetch()
        state = .idle
        track = nil
        duration = nil
        lookupLacksDuration = false
        isPanelOpen = false
        playhead = .zero
    }

    /// `debounced` is for a track change only: it waits `debounce` first, and a newer change, a close or a reset
    /// during the wait drops this one before it sends anything. Opening, showing, Retry and the late-duration
    /// refetch are the user's or the player's own doing and go out at once.
    private func fetchIfNeeded(debounced: Bool) {
        guard isWatching, track != nil else { return }
        switch state {
        case .idle: break
        case .failed(_, let retryAfter): if let retryAfter, retryAfter > now() { return }
        case .busy(let until): guard until <= now() else { return }
        case .loading, .loaded: return
        }
        runCounter += 1
        let run = runCounter
        retryTask?.cancel()
        retryTask = nil
        state = .loading
        loadTask = Task { [weak self, provider, sleep] in
            if debounced {
                // A cancelled task leaves the sleep early; a timer that ignores that is caught by the run check.
                do { try await sleep(Self.debounce) } catch { return }
            }
            guard let query = self?.queryIfCurrent(run) else { return }
            do {
                let answer = try await provider.answer(for: query)
                self?.land(answer, run: run)
            } catch is CancellationError {
                // Whoever cancelled has already set the state.
            } catch let error as LyricsError {
                self?.land(Self.state(for: error), run: run)
            } catch {
                self?.land(.failed(Self.message(for: error)), run: run)
            }
        }
    }

    /// The query for the track as it is now, with the length the player knows now (it may have arrived during the
    /// wait); nil when this run is no longer the current one.
    private func queryIfCurrent(_ run: Int) -> LyricsQuery? {
        guard run == runCounter, let track else { return nil }
        lookupLacksDuration = duration == nil
        return LyricsQuery(
            videoId: track.videoId, title: track.title, artist: track.artist, album: track.album, duration: duration
        )
    }

    private static func state(for error: LyricsError) -> State {
        switch error {
        case .busy(let until): .busy(until: until)
        case .backoff(_, let until): .failed(message(for: error), retryAfter: until)
        case .http, .parse: .failed(message(for: error))
        }
    }

    /// An answer for the current run: its credit is set before the state, so a view that sees `.loaded` sees the
    /// credit with it. An answer that does not depend on the length ends the wait for one.
    private func land(_ answer: LyricsAnswer, run: Int) {
        guard run == runCounter else { return }
        if !answer.lengthMatters { lookupLacksDuration = false }
        loadedCredit = answer.credit
        land(.loaded(answer.result), run: run)
    }

    private func land(_ new: State, run: Int) {
        guard run == runCounter else { return }
        state = new
        loadTask = nil
        scheduleAutoRetry()
    }

    /// Drops the fetch in flight and the retry timer: an answer or a wake-up that comes later is no longer the
    /// current run.
    private func cancelFetch() {
        runCounter += 1
        loadTask?.cancel()
        loadTask = nil
        retryTask?.cancel()
        retryTask = nil
        if state == .loading { state = .idle }
    }

    /// While watching, a busy or server-error window that is still on gets one timer: when the window ends, the fetch
    /// goes out again with no tap on Retry. The wait is what is left of the window, never negative. Nothing else is
    /// retried by itself: a failure with no window waits for Retry. The timer belongs to the run it was set in, so
    /// a track change, a close, a reset or a Retry tap in the meantime drops it even if the sleep does not end early.
    private func scheduleAutoRetry() {
        retryTask?.cancel()
        retryTask = nil
        guard isWatching, track != nil else { return }
        let until: Date
        switch state {
        case .busy(let date):
            until = date
        case .failed(_, let retryAfter):
            guard let retryAfter else { return }
            until = retryAfter
        case .idle, .loading, .loaded:
            return
        }
        let run = runCounter
        let wait = Duration.seconds(max(until.timeIntervalSince(now()), 0))
        retryTask = Task { [weak self, sleep] in
            do { try await sleep(wait) } catch { return }
            self?.windowEnded(run: run)
        }
    }

    private func windowEnded(run: Int) {
        guard run == runCounter else { return }
        retryTask = nil
        fetchIfNeeded(debounced: false)
    }

    /// What the panel says about a failure. Never a URL or a piece of the response.
    static func message(for error: any Error) -> String {
        switch error {
        case LyricsError.http(let status): "The lyrics service returned an error (\(status))."
        case LyricsError.backoff(let status, _): "\(message(for: LyricsError.http(status))) Trying again shortly."
        case LyricsError.parse: "Couldn't read the lyrics response."
        case LyricsError.busy: busyMessage
        case is URLError: "Network problem. Check your connection."
        default: "Something went wrong. Try again."
        }
    }
}
