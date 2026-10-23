// Deci/Music/Playback/MusicPlayer.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "Music")

/// Plays one resolved stream at a time and exposes its state to the UI.
/// A stream that fails, or has expired by the time playback resumes, is re-resolved through
/// `onNeedsFreshStream` and playback continues from the same position. Failures get one retry per load.
@MainActor
@Observable
final class MusicPlayer {
    private(set) var nowPlaying: MusicTrack?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    /// Where the track was at the last engine tick (every half second). Observed like a stored property, but kept by
    /// hand so a view that is not on screen can read it without subscribing (`readCurrentTime(observed:)`).
    private(set) var currentTime: TimeInterval {
        get {
            access(keyPath: \.currentTime)
            return storedTime
        }
        set {
            // Same rule the macro applies to a stored property: an equal write publishes nothing.
            guard newValue != storedTime else { return }
            withMutation(keyPath: \.currentTime) { storedTime = newValue }
        }
    }
    @ObservationIgnored private var storedTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// How many times YouTube says the current song was viewed. Nil until the song's stream is resolved, when nothing
    /// plays, and when the response did not carry one: never the previous song's.
    private(set) var viewCount: Int?
    private(set) var error: String?

    /// Position ticks for the service's listening-time accounting.
    @ObservationIgnored var onTick: (@MainActor (_ position: TimeInterval, _ isPlaying: Bool) -> Void)?
    /// Resolves a new stream for the track whose stream died or expired.
    @ObservationIgnored var onNeedsFreshStream: (@MainActor (MusicTrack) async throws -> ResolvedStream)?
    /// The track played to its end. Fires before `onStateChange`, so a successor can be started first.
    @ObservationIgnored var onEnded: (@MainActor () -> Void)?
    /// The player gave up on the track: recovery failed or was already used.
    @ObservationIgnored var onFailed: (@MainActor () -> Void)?
    /// Anything the Now Playing widget or the Chrome auto-Switch cares about changed.
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var stream: ResolvedStream?
    @ObservationIgnored private var recoveryUsed = false
    /// True once the track played to its end, until something restarts or replaces it.
    @ObservationIgnored private(set) var hasEnded = false
    @ObservationIgnored private var wantsPlay = false
    /// Exposed read-only so tests can await a recovery in flight.
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0

    init(engine: any PlaybackEngine = AVPlaybackEngine(), now: @escaping () -> Date = Date.init) {
        self.engine = engine
        self.now = now
        engine.onTick = { [weak self] position, playing in
            self?.handleTick(position: position, isPlaying: playing)
        }
        engine.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    isolated deinit {
        refreshTask?.cancel()
        engine.unload()
    }

    /// False when the current track's stream never resolved, so there is nothing to resume.
    var hasStream: Bool { stream != nil }

    /// Playing, or about to: loading, or wanting to play through a stall. False when paused, ended or failed.
    var isActive: Bool {
        nowPlaying != nil && (isPlaying || isLoading || wantsPlay)
    }

    // MARK: - Public API

    /// Shows the track as loading while its stream is being resolved. Silences whatever was playing.
    func beginLoading(_ track: MusicTrack) {
        defer { notifyStateChange() }
        teardownCurrent()
        nowPlaying = track
        isLoading = true
        error = nil
        duration = Double(track.durationSeconds ?? 0)
    }

    func load(stream: ResolvedStream, track: MusicTrack) {
        loadGeneration += 1
        recoveryUsed = false
        install(stream, track: track, startAt: 0, autoplay: true)
    }

    func play() {
        defer { notifyStateChange() }
        guard nowPlaying != nil, let stream else { return }
        wantsPlay = true
        // A dead or expired stream is replaced before resuming; a new stream carries a new expiry, so this cannot loop.
        if error != nil || stream.expiresAt <= now() {
            if refreshStream(resumeAt: hasEnded ? 0 : currentTime) { return }
        }
        if refreshTask != nil { return }
        if hasEnded {
            hasEnded = false
            currentTime = 0
            engine.seek(to: 0)
        }
        engine.play()
    }

    func pause() {
        wantsPlay = false
        engine.pause()
        notifyStateChange()
    }

    /// Where the track is right now, read from the engine's own clock instead of the last tick (the ticks come every
    /// half second). For the synced lyrics, which have to be on the beat. Changes nothing: a read.
    ///
    /// The player's own `currentTime` is answered while there is no engine clock worth reading: nothing is loaded,
    /// the stream is loading or being replaced (the engine may still hold the last track's time), or the track has
    /// ended (the engine has rewound). A reading that is not a number, or below zero, is not worth reading either.
    func livePosition() -> TimeInterval {
        guard nowPlaying != nil, stream != nil, refreshTask == nil, !isLoading, !hasEnded else { return currentTime }
        let position = engine.position
        return position.isFinite && position >= 0 ? position : currentTime
    }

    /// `currentTime`, for a view. A view that is not on screen passes `observed: false`: it gets the same value but is not
    /// subscribed to the next tick, so a hidden popup is not redrawn twice a second for a time nobody sees. Passing the
    /// popup's visibility makes the flip to visible redraw the view, and that redraw reads the live value.
    func readCurrentTime(observed: Bool) -> TimeInterval {
        observed ? currentTime : storedTime
    }

    /// Jumps to `seconds`, clamped to the track. Does not change whether it is playing.
    func seek(to seconds: TimeInterval) {
        guard nowPlaying != nil, stream != nil, refreshTask == nil, seconds.isFinite else { return }
        let target = min(max(0, seconds), duration > 0 ? duration : .infinity)
        hasEnded = false
        currentTime = target
        engine.seek(to: target)
        notifyStateChange()
    }

    func toggle() {
        if isPlaying || (isLoading && wantsPlay) {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        teardownCurrent()
        nowPlaying = nil
        isLoading = false
        error = nil
        notifyStateChange()
    }

    /// The stream could not be resolved for a reason that says nothing about the track: keep it selected,
    /// stop the spinner and leave playback off. Unlike a failure, it does not ask for a successor.
    func failLoading() {
        guard nowPlaying != nil else { return }
        isLoading = false
        wantsPlay = false
        notifyStateChange()
    }

    // MARK: - Loading

    private func install(_ stream: ResolvedStream, track: MusicTrack, startAt: TimeInterval, autoplay: Bool) {
        refreshTask?.cancel()
        refreshTask = nil
        self.stream = stream
        nowPlaying = track
        error = nil
        isLoading = true
        isPlaying = false
        hasEnded = false
        wantsPlay = autoplay
        currentTime = startAt
        duration = stream.durationSeconds ?? Double(track.durationSeconds ?? 0)
        viewCount = stream.viewCount
        engine.load(stream, startAt: startAt, autoplay: autoplay)
        notifyStateChange()
    }

    private func notifyStateChange() {
        onStateChange?()
    }

    private func teardownCurrent() {
        loadGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        engine.unload()
        stream = nil
        isPlaying = false
        hasEnded = false
        wantsPlay = false
        currentTime = 0
        duration = 0
        viewCount = nil
    }

    // MARK: - Recovery

    /// Re-resolves the current track and resumes. Returns false when no refresh can be started.
    @discardableResult
    private func refreshStream(resumeAt position: TimeInterval) -> Bool {
        guard let track = nowPlaying, let provider = onNeedsFreshStream, refreshTask == nil else { return false }
        let generation = loadGeneration
        isLoading = true
        error = nil
        engine.pause()
        notifyStateChange()
        refreshTask = Task { [weak self] in
            let fresh: ResolvedStream?
            do {
                fresh = try await provider(track)
            } catch {
                fresh = nil
                logger.error("stream refresh failed")
            }
            guard let self, generation == self.loadGeneration, !Task.isCancelled else { return }
            self.refreshTask = nil
            guard let fresh else {
                self.fail("Couldn't reload this track.")
                return
            }
            self.install(fresh, track: track, startAt: position, autoplay: self.wantsPlay)
        }
        return true
    }

    private func fail(_ message: String) {
        isLoading = false
        isPlaying = false
        wantsPlay = false
        error = message
        onFailed?()
        notifyStateChange()
    }

    // MARK: - Engine callbacks

    private func handleTick(position: TimeInterval, isPlaying playing: Bool) {
        if !hasEnded { currentTime = position }
        onTick?(position, playing)
    }

    private func handle(_ event: PlaybackEngineEvent) {
        defer { notifyStateChange() }
        switch event {
        case .ready(let engineDuration):
            if let engineDuration { duration = engineDuration }
            if !wantsPlay { isLoading = false }
        case .playingChanged(let playing):
            isPlaying = playing
            if playing { isLoading = false }
            // The ticks come every 0.5 s: take the exact position, so a pause shows where it stopped.
            if !isLoading, !hasEnded { currentTime = engine.position }
        case .ended:
            hasEnded = true
            wantsPlay = false
            isPlaying = false
            isLoading = false
            if duration > 0 { currentTime = duration }
            onEnded?()
        case .failed:
            guard refreshTask == nil else { return }
            if !recoveryUsed, nowPlaying != nil, onNeedsFreshStream != nil {
                recoveryUsed = true
                logger.info("stream failed, asking for a fresh one")
                refreshStream(resumeAt: currentTime)
            } else {
                fail("Couldn't play this track.")
            }
        }
    }
}
