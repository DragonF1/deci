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
    /// The track played to its end and the preloaded one plays on, gaplessly. Fires before the player takes the new track
    /// over (`nowPlaying` and the position are still the old track's, at its end), so the service can close the old
    /// session first. The handler calls `adoptPreloaded()` when it accepts, and returns whether it did; false leaves the
    /// player treating it as an ordinary end (`onEnded`), which starts the right track the old way.
    @ObservationIgnored var onAdvanced: (@MainActor (_ next: MusicTrack) -> Bool)?
    /// Anything the Now Playing widget or the Chrome auto-Switch cares about changed.
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?
    /// Fires when the downloaded file under the player changes: with the song's video id when a file is loaded, with nil
    /// when the stream is from the network or nothing is loaded. The downloads use it to keep a file that was removed
    /// while it played until playback has left it.
    @ObservationIgnored var onLocalFileChange: (@MainActor (_ videoId: String?) -> Void)?

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var stream: ResolvedStream? {
        didSet {
            let current = Self.localFileID(of: stream)
            guard current != Self.localFileID(of: oldValue) else { return }
            onLocalFileChange?(current)
        }
    }
    @ObservationIgnored private var recoveryUsed = false
    /// True once the track played to its end, until something restarts or replaces it.
    @ObservationIgnored private(set) var hasEnded = false
    @ObservationIgnored private var wantsPlay = false
    /// Exposed read-only so tests can await a recovery in flight.
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    /// The track handed to the engine to start when the current one ends.
    @ObservationIgnored private var preloaded: (stream: ResolvedStream, track: MusicTrack)?
    /// The engine was emptied while `stream` is still the current track's (a refused advance): playing it loads it again.
    @ObservationIgnored private var engineDropped = false

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
    /// Whether the stream loaded is a file on disk (a downloaded song) and not an address on the network.
    var isPlayingLocalFile: Bool { stream?.origin == .download }

    /// The video id of `stream` when it is a file on disk, nil for a network stream or none.
    private static func localFileID(of stream: ResolvedStream?) -> String? {
        guard let stream, stream.origin == .download else { return nil }
        return stream.videoId
    }

    /// Playing, or about to: the engine is playing, or the listener wants it to (a song that is loading, or stalled). A
    /// song loading under a pause is not active. False when paused, ended or failed.
    var isActive: Bool {
        nowPlaying != nil && (isPlaying || wantsPlay)
    }

    /// The track the engine holds ready to play on from the current one, nil when none (or the engine dropped it).
    var preloadedTrack: MusicTrack? {
        guard let preloaded, engine.preloadedVideoId == preloaded.track.videoId else { return nil }
        return preloaded.track
    }

    /// The stream of the preloaded track, for the service's bookkeeping when it starts. Not checked against the engine: at
    /// the moment of an advance the engine has already let go of it.
    var preloadedStream: ResolvedStream? { preloaded?.stream }

    /// The stream of the track that plays now (tier 2b: the planner needs its exact duration and format).
    var currentStream: ResolvedStream? { stream }

    /// Where the preloaded song starts: the engine's park offset (0 when its park seek failed), read late so the real
    /// value counts. The engine clears its plan at the hand-over, so the last value seen is kept.
    @ObservationIgnored private var parkedOffset: TimeInterval = 0

    /// Where the song that plays now began on its own timeline: 0 for every load, the plan's trim offset for a song the
    /// engine handed over to already parked. `currentTime` and the engine position are item times that begin here, so the
    /// listener's elapsed time in the song is `currentTime - playbackStartOffset`.
    @ObservationIgnored private(set) var playbackStartOffset: TimeInterval = 0

    /// Prepares the track after the current one on the engine's standby deck. Nothing changes for the listener. With a
    /// `plan` (tier 2b) the standby is parked at `plan.incomingStartSec` and the plan drives the transition.
    func preload(stream: ResolvedStream, track: MusicTrack, plan: TransitionPlan? = nil) {
        guard nowPlaying != nil, self.stream != nil, !hasEnded, refreshTask == nil else { return }
        preloaded = (stream, track)
        parkedOffset = plan?.incomingStartSec ?? 0
        outgoingEndSnapshot = plan?.outgoingEndSec
        engine.preload(stream, plan: plan)
    }

    /// Replaces the plan of the current preload (same park offset, new mode). The engine ignores it otherwise.
    func updateTransitionPlan(_ plan: TransitionPlan?) {
        guard preloaded != nil else { return }
        engine.updateTransitionPlan(plan)
        refreshParkedOffset()
    }

    /// The plan of the current preload as the engine holds it.
    var transitionPlan: TransitionPlan? { engine.transitionPlan }

    /// The style the engine's last crossfade really ran, nil when the engine does not say.
    var lastTransitionStyle: MusicTransitionStyle? { engine.lastTransitionStyle }

    /// Where the playing song is cut short, as the engine's plan last said (nil: it plays to its natural end, also after a
    /// seek brought that end back). The engine clears its plan before `.advanced`, so the last value seen is kept.
    @ObservationIgnored private(set) var outgoingEndSnapshot: TimeInterval?

    private func refreshParkedOffset() {
        guard preloaded != nil, let plan = engine.transitionPlan else { return }
        parkedOffset = plan.incomingStartSec
        outgoingEndSnapshot = plan.outgoingEndSec
    }

    func cancelPreload() {
        preloaded = nil
        parkedOffset = 0
        outgoingEndSnapshot = nil
        engine.cancelPreload()
    }

    /// How long the next track fades in over the end of this one; 0 is the gapless switch. See `PlaybackEngine`.
    var crossfadeSeconds: TimeInterval {
        get { engine.crossfadeSeconds }
        set { if engine.crossfadeSeconds != newValue { engine.crossfadeSeconds = newValue } }
    }

    /// The preloaded track is built and prerolled, so it can start at once.
    var preloadIsReady: Bool { preloaded != nil && engine.preloadedVideoId == preloaded?.track.videoId && engine.preloadIsReady }

    /// A manual skip onto the preloaded track: the engine starts it now and crossfades over `seconds`. The caller then
    /// calls `adoptPreloaded()`. False, with nothing changed, when it cannot.
    var canCrossfadeToPreloaded: Bool {
        isPlaying && !hasEnded && preloadIsReady && engine.canCrossfadeToPreloaded
    }

    func crossfadeToPreloaded(seconds: TimeInterval) -> Bool {
        guard isPlaying, !hasEnded, preloadIsReady else { return false }
        // Before the engine hands over and clears its plan.
        refreshParkedOffset()
        return engine.crossfadeToPreloaded(seconds: seconds)
    }

    /// Takes the preloaded track over as the current one: the engine is already playing it. Called from `onAdvanced`.
    func adoptPreloaded() {
        guard let preloaded else { return }
        self.preloaded = nil
        outgoingEndSnapshot = nil
        // The song starts where the engine parked it (its trimmed start), not at 0.
        let start = max(0, engine.transitionPlan?.incomingStartSec ?? parkedOffset)
        parkedOffset = 0
        loadGeneration += 1
        recoveryUsed = false
        refreshTask?.cancel()
        refreshTask = nil
        stream = preloaded.stream
        nowPlaying = preloaded.track
        error = nil
        isLoading = false
        isPlaying = true
        hasEnded = false
        wantsPlay = true
        duration = preloaded.stream.durationSeconds ?? Double(preloaded.track.durationSeconds ?? 0)
        currentTime = duration > 0 ? min(start, duration) : start
        playbackStartOffset = currentTime
        viewCount = preloaded.stream.viewCount
    }

    // MARK: - Public API

    /// Shows the track as loading while its stream is being resolved. Silences whatever was playing. The track is
    /// wanted: it plays when its stream arrives, unless `pause()` comes first (and `play()` takes that back).
    func beginLoading(_ track: MusicTrack) {
        defer { notifyStateChange() }
        teardownCurrent()
        nowPlaying = track
        isLoading = true
        wantsPlay = true
        error = nil
        duration = Double(track.durationSeconds ?? 0)
    }

    /// Loads the resolved stream and plays it. A song that was showing as loading for this track (`beginLoading`) plays
    /// only if it is still wanted: a pause pressed while its stream was resolving leaves it loaded and paused, like a
    /// session picked up from the last launch. A load nobody began always plays.
    func load(stream: ResolvedStream, track: MusicTrack) {
        let awaitedHere = isLoading && self.stream == nil && nowPlaying?.videoId == track.videoId
        let autoplay = awaitedHere ? wantsPlay : true
        loadGeneration += 1
        recoveryUsed = false
        install(stream, track: track, startAt: 0, autoplay: autoplay, loading: autoplay)
    }

    /// Loads the track and leaves it paused at `position`: no sound until `play()`. For a session picked up from the last
    /// launch. It never shows as loading, so nothing outside sees the player as busy before the listener plays it.
    func loadPaused(stream: ResolvedStream, track: MusicTrack, at position: TimeInterval) {
        loadGeneration += 1
        recoveryUsed = false
        install(stream, track: track, startAt: position, autoplay: false, loading: false)
    }

    func play() {
        defer { notifyStateChange() }
        guard nowPlaying != nil else { return }
        guard let stream else {
            // The stream is still being resolved: nothing to start yet, but the song plays as soon as it arrives.
            if isLoading { wantsPlay = true }
            return
        }
        wantsPlay = true
        // A dead or expired stream is replaced before resuming; a new stream carries a new expiry, so this cannot loop.
        if error != nil || engineDropped || stream.expiresAt <= now() {
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

    /// Pauses, and stays paused through a load: the song no longer wants to play, so a stream that arrives later loads
    /// without starting and the engine drops the autoplay it was holding.
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
        guard nowPlaying != nil, stream != nil, refreshTask == nil, !engineDropped, seconds.isFinite else { return }
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

    private func install(
        _ stream: ResolvedStream, track: MusicTrack, startAt: TimeInterval, autoplay: Bool, loading: Bool = true
    ) {
        refreshTask?.cancel()
        refreshTask = nil
        preloaded = nil
        engineDropped = false
        playbackStartOffset = 0
        outgoingEndSnapshot = nil
        self.stream = stream
        nowPlaying = track
        error = nil
        isLoading = loading
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
        preloaded = nil
        engineDropped = false
        loadGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        engine.unload()
        stream = nil
        isPlaying = false
        hasEnded = false
        wantsPlay = false
        currentTime = 0
        playbackStartOffset = 0
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
        cancelPreload()
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
        refreshParkedOffset()
        onTick?(position, playing)
    }

    /// The engine moved on to a track the queue does not want: it is silenced and the old track's end is handled as an
    /// ordinary one, which starts the queue's own next track (or leaves the player finished).
    private func rejectAdvance() {
        preloaded = nil
        // The engine already plays the next item: drop it, or a Play after this end would sound the next track under the
        // old track's name. `play()` loads the old stream again when the engine holds nothing.
        engine.unload()
        engineDropped = true
        handle(.ended)
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
        case .advanced(let videoId):
            guard let next = preloaded?.track, next.videoId == videoId, let onAdvanced else {
                // Nothing here knows this track: the old track is over, and the service starts the right one.
                rejectAdvance()
                return
            }
            // The old track ran out: its position is its length, as for an end. A crossfade started earlier than that,
            // and the old track really was at the position the engine noted.
            if let outgoing = engine.outgoingPositionAtCrossfade {
                currentTime = outgoing
            } else if duration > 0 {
                currentTime = duration
            }
            if !onAdvanced(next) {
                rejectAdvance()
                return
            }
            if preloaded != nil { adoptPreloaded() }
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
