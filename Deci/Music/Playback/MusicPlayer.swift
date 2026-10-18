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
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var error: String?

    /// Position ticks for the service's listening-time accounting.
    @ObservationIgnored var onTick: (@MainActor (_ position: TimeInterval, _ isPlaying: Bool) -> Void)?
    /// Resolves a new stream for the track whose stream died or expired.
    @ObservationIgnored var onNeedsFreshStream: (@MainActor (MusicTrack) async throws -> ResolvedStream)?

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var stream: ResolvedStream?
    @ObservationIgnored private var recoveryUsed = false
    @ObservationIgnored private var hasEnded = false
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

    // MARK: - Public API

    /// Shows the track as loading while its stream is being resolved. Silences whatever was playing.
    func beginLoading(_ track: MusicTrack) {
        teardownCurrent()
        nowPlaying = track
        isLoading = true
        duration = Double(track.durationSeconds ?? 0)
    }

    func load(stream: ResolvedStream, track: MusicTrack) {
        loadGeneration += 1
        recoveryUsed = false
        install(stream, track: track, startAt: 0, autoplay: true)
    }

    func play() {
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
        engine.load(stream, startAt: startAt, autoplay: autoplay)
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
        refreshTask = Task { [weak self] in
            let fresh: ResolvedStream?
            do {
                fresh = try await provider(track)
            } catch {
                fresh = nil
                logger.error("stream refresh failed for \(track.videoId, privacy: .public)")
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
        error = message
    }

    // MARK: - Engine callbacks

    private func handleTick(position: TimeInterval, isPlaying playing: Bool) {
        if !hasEnded { currentTime = position }
        onTick?(position, playing)
    }

    private func handle(_ event: PlaybackEngineEvent) {
        switch event {
        case .ready(let engineDuration):
            if let engineDuration { duration = engineDuration }
            if !wantsPlay { isLoading = false }
        case .playingChanged(let playing):
            isPlaying = playing
            if playing { isLoading = false }
        case .ended:
            hasEnded = true
            wantsPlay = false
            isPlaying = false
            isLoading = false
            if duration > 0 { currentTime = duration }
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
