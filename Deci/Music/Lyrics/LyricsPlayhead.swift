// Deci/Music/Lyrics/LyricsPlayhead.swift
import Foundation

/// Where the song is, between player ticks. The player reports its time every half second; the lyrics
/// view redraws ten times a second, so it takes the last observed time and adds the wall-clock time since.
struct LyricsPlayhead: Equatable, Sendable {
    let time: TimeInterval
    let isPlaying: Bool
    let observedAt: Date

    /// A player that stops reporting (a stall, a hung stream) must not let the highlight run away.
    static let maxExtrapolation: TimeInterval = 1

    static let zero = LyricsPlayhead(time: 0, isPlaying: false, observedAt: .distantPast)

    func position(at date: Date) -> TimeInterval {
        guard time.isFinite else { return 0 }
        let base = max(0, time)
        guard isPlaying else { return base }
        return base + min(max(0, date.timeIntervalSince(observedAt)), Self.maxExtrapolation)
    }
}
