// Deci/Music/Playback/MusicShuffleMode.swift
import Foundation

/// What the shuffle button does, in the order it cycles through them: Off (the queue plays in its own order) and
/// Systematic shuffle (songs ordered to flow into each other by tempo, key and energy). Plain random shuffle is gone.
/// How songs hand over is a separate choice (`MusicTransitionMode`).
nonisolated enum MusicShuffleMode: String, CaseIterable, Sendable {
    case off
    case systematic

    /// Off, then Systematic shuffle, then Off again.
    var next: MusicShuffleMode {
        switch self {
        case .off: .systematic
        case .systematic: .off
        }
    }

    static let symbol = "shuffle"

    /// What the button is called for VoiceOver and the tooltip.
    var title: String { "Systematic shuffle" }

    var symbol: String { Self.symbol }

    /// Systematic shuffle plays in a changed order.
    var isOn: Bool { self != .off }

    /// The mode a plain on or off setting means.
    init(shuffle: Bool) {
        self = shuffle ? .systematic : .off
    }
}
