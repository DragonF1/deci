// Deci/Music/Playback/PlaybackTimeAccumulator.swift
import Foundation

/// Counts real listening time for one playback session from the player's position ticks.
/// A delta counts only while playing and only when it is a plausible step between two
/// ticks, so pauses, seeks and jumps never add to the total.
struct PlaybackTimeAccumulator: Equatable {
    /// Listening time that earns the single history ping.
    static let threshold: TimeInterval = 30
    /// Largest position step between two ticks that still counts as playback.
    static let maxDelta: TimeInterval = 1.5

    private(set) var playedSeconds: TimeInterval = 0
    private(set) var hasFired = false
    private var lastPosition: TimeInterval?

    /// Feeds one tick. Returns true exactly once per session, on the first tick at or past the
    /// threshold where `canFire` is true. While it is false the one-shot stays unspent.
    mutating func record(position: TimeInterval, isPlaying: Bool, canFire: Bool = true) -> Bool {
        guard position.isFinite else { return false }
        defer { lastPosition = position }
        guard isPlaying, let last = lastPosition else { return false }

        let delta = position - last
        guard delta > 0, delta <= Self.maxDelta else { return false }

        playedSeconds += delta
        return canFire && claim()
    }

    /// Spends the one-shot when the threshold is already reached. True only the first time.
    mutating func claim() -> Bool {
        guard !hasFired, playedSeconds >= Self.threshold else { return false }
        hasFired = true
        return true
    }

    /// Starts a new session.
    mutating func reset() {
        self = PlaybackTimeAccumulator()
    }
}
