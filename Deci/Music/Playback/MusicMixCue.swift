// Deci/Music/Playback/MusicMixCue.swift
import Foundation

/// What the "Mixing" label follows: the engine has scheduled an overlap of this song with the next one, or is playing
/// one. Only a scheduled transition with a fade counts: a gapless switch has no overlap, and a manual skip's short fade
/// is a cut the listener asked for, not a mix.
nonisolated enum MusicMixCue: Equatable, Sendable {
    /// The overlap starts at `startsAt` (wall clock). The engine knows it about 6 s ahead.
    case upcoming(startsAt: Date)
    /// The two songs are overlapping now.
    case mixing

    /// How long before the overlap the label shows.
    static let lead: TimeInterval = 5

    /// Whether the label shows at `now`: from `lead` before the overlap, and all through it.
    func showsLabel(at now: Date) -> Bool {
        secondsUntilLabel(from: now) <= 0
    }

    /// How long from `now` until the label is due, 0 once it is.
    func secondsUntilLabel(from now: Date) -> TimeInterval {
        switch self {
        case .mixing:
            return 0
        case .upcoming(let startsAt):
            let wait = startsAt.timeIntervalSince(now) - Self.lead
            return wait.isFinite ? max(0, wait) : 0
        }
    }
}
