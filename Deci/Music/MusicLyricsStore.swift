// Deci/Music/MusicLyricsStore.swift
import Foundation
import Observation

/// The lyrics of the playing track, for the Music tab's lyrics panel. `MusicService` owns one
/// (`service.lyrics`). The state lives here, not in the view, because the popover panel hides whenever it
/// loses focus.
///
/// Lyrics are fetched only while the panel is open and the popup is on screen, for the current track, and
/// again when the track changes while it is. A closed panel never touches the network.
@MainActor
@Observable
final class MusicLyricsStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded(LyricsResult)
        /// LRCLIB asked us to wait; nothing goes out before the date.
        case busy(until: Date)
        /// A short message for the user; the panel shows it with a Retry button.
        case failed(String)
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

    /// The panel is open and can be seen: the only time anything is fetched or animated.
    var isWatching: Bool { isPanelOpen && isPopupVisible }

    /// Retry would send a request now: the last load failed, or the busy window has passed.
    var canRetry: Bool {
        switch state {
        case .failed: true
        case .busy(let until): until <= now()
        case .idle, .loading, .loaded: false
        }
    }

    @ObservationIgnored private let provider: any LyricsProviding
    @ObservationIgnored private let now: @Sendable () -> Date
    /// The player's length of the track, in seconds, once it is known; nil until then.
    @ObservationIgnored private var duration: TimeInterval?
    /// A fetch names itself with the next number and only lands while it is still the current one, so a
    /// track change, a close or a reset drops a slower earlier answer.
    @ObservationIgnored private var runCounter = 0
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?

    init(provider: any LyricsProviding, now: @escaping @Sendable () -> Date = Date.init) {
        self.provider = provider
        self.now = now
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

    private func watchingChanged() {
        if isWatching { fetchIfNeeded() } else { cancelFetch() }
    }

    // MARK: - Track and playback

    /// The player's current track. A new one clears the lyrics and, while watching, fetches its; the same one
    /// again only updates the length (the stream's exact length arrives after the track does).
    func trackChanged(_ new: MusicTrack?, duration: TimeInterval) {
        let known = duration.isFinite && duration > 0 ? duration : nil
        if let new, new.videoId == track?.videoId {
            if track != new { track = new }
            if let known { self.duration = known }
            return
        }
        cancelFetch()
        state = .idle
        track = new
        self.duration = known
        fetchIfNeeded()
    }

    func observePlayback(position: TimeInterval, isPlaying: Bool) {
        playhead = LyricsPlayhead(time: position, isPlaying: isPlaying, observedAt: now())
    }

    // MARK: - Loading

    /// Asks again after a failure, or once the busy window has passed. Nothing goes out earlier.
    func retry() {
        guard isWatching, track != nil, canRetry else { return }
        fetchIfNeeded()
    }

    /// Sign-out or an account swap: nothing of the old session stays. The disk cache may.
    func reset() {
        cancelFetch()
        state = .idle
        track = nil
        duration = nil
        isPanelOpen = false
        playhead = .zero
    }

    private func fetchIfNeeded() {
        guard isWatching, let track else { return }
        switch state {
        case .idle, .failed: break
        case .busy(let until): guard until <= now() else { return }
        case .loading, .loaded: return
        }
        let query = LyricsQuery(
            videoId: track.videoId, title: track.title, artist: track.artist, album: track.album, duration: duration
        )
        runCounter += 1
        let run = runCounter
        state = .loading
        loadTask = Task { [weak self, provider] in
            do {
                let result = try await provider.lyrics(for: query)
                self?.land(.loaded(result), run: run)
            } catch is CancellationError {
                // Whoever cancelled has already set the state.
            } catch let error as LyricsError {
                if case .busy(let until) = error {
                    self?.land(.busy(until: until), run: run)
                } else {
                    self?.land(.failed(Self.message(for: error)), run: run)
                }
            } catch {
                self?.land(.failed(Self.message(for: error)), run: run)
            }
        }
    }

    private func land(_ new: State, run: Int) {
        guard run == runCounter else { return }
        state = new
        loadTask = nil
    }

    /// Drops the fetch in flight: its answer, when it comes, is no longer the current run.
    private func cancelFetch() {
        runCounter += 1
        loadTask?.cancel()
        loadTask = nil
        if state == .loading { state = .idle }
    }

    /// What the panel says about a failure. Never a URL or a piece of the response.
    static func message(for error: any Error) -> String {
        switch error {
        case LyricsError.http(let status): "The lyrics service returned an error (\(status))."
        case LyricsError.parse: "Couldn't read the lyrics response."
        case LyricsError.busy: "Lyrics service is busy. Try again in a minute."
        case is URLError: "Network problem. Check your connection."
        default: "Something went wrong. Try again."
        }
    }
}
