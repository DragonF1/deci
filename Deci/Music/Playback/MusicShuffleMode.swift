// Deci/Music/Playback/MusicShuffleMode.swift
import Foundation

/// What the shuffle button does, in the order it cycles through them: Off, Shuffle (random), Mix (songs ordered to blend
/// into each other by tempo, key and energy).
nonisolated enum MusicShuffleMode: String, CaseIterable, Sendable {
    case off
    case shuffle
    case mix

    /// Off, then Shuffle, then Mix, then Off again.
    var next: MusicShuffleMode {
        switch self {
        case .off: .shuffle
        case .shuffle: .mix
        case .mix: .off
        }
    }

    /// The glyph Mix has of its own, so the button tells it from plain Shuffle.
    static let mixSymbol = "waveform.path"
    static let shuffleSymbol = "shuffle"

    /// What the button is called for VoiceOver and the tooltip.
    var title: String {
        switch self {
        case .off, .shuffle: "Shuffle"
        case .mix: "Mix"
        }
    }

    var symbol: String {
        self == .mix ? Self.mixSymbol : Self.shuffleSymbol
    }

    /// Shuffle and Mix both play in a changed order.
    var isOn: Bool { self != .off }

    /// The mode a plain on or off setting means, for a caller that knows nothing of Mix.
    init(shuffle: Bool) {
        self = shuffle ? .shuffle : .off
    }
}
