// Deci/Music/Playback/MusicShuffleMode.swift
import Foundation

/// What the shuffle button does, in the order it cycles through them: Off (the queue plays in its own order), Shuffle
/// (a random order that nothing decides) and Flow Shuffle (a random shuffle first, then the songs ordered to flow into
/// each other by tempo, key and energy). How songs hand over is a separate choice (`MusicTransitionMode`).
nonisolated enum MusicShuffleMode: String, CaseIterable, Sendable {
    case off
    case shuffle
    case flow

    /// Off, then Shuffle, then Flow Shuffle, then Off again.
    var next: MusicShuffleMode {
        switch self {
        case .off: .shuffle
        case .shuffle: .flow
        case .flow: .off
        }
    }

    /// The plain glyph of Off and Shuffle.
    static let symbol = "shuffle"

    /// Flow Shuffle's glyph, a path that bends from one point to the next (every macOS the app runs on has it).
    static let flowSymbol = "point.topleft.down.to.point.bottomright.curvepath"

    /// What the button is called for VoiceOver and the tooltip.
    var title: String { self == .flow ? "Flow Shuffle" : "Shuffle" }

    var symbol: String { self == .flow ? Self.flowSymbol : Self.symbol }

    /// Shuffle and Flow Shuffle both play in a changed order.
    var isOn: Bool { self != .off }
}
