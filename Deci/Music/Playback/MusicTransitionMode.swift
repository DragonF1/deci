// Deci/Music/Playback/MusicTransitionMode.swift
import Foundation

/// How one song hands over to the next, in the order the Transitions button cycles through them: Off (gapless),
/// Crossfade (a plain fade of the length Settings gives) and Mixing (beat-matched blends with a style per pair). It is
/// independent of the order the songs play in (`MusicShuffleMode`): Mixing works on a playlist in its own order too.
nonisolated enum MusicTransitionMode: String, Codable, CaseIterable, Sendable {
    case off
    case crossfade
    case mixing

    /// Off, then Crossfade, then Mixing, then Off again.
    var next: MusicTransitionMode {
        switch self {
        case .off: .crossfade
        case .crossfade: .mixing
        case .mixing: .off
        }
    }

    /// What the button is called for VoiceOver and the tooltip.
    var title: String {
        switch self {
        case .off: "Transitions"
        case .crossfade: "Crossfade"
        case .mixing: "Mixing"
        }
    }

    /// Not an SF Symbol: `MusicGlyph` draws its own icon for this name.
    static let crossfadeSymbol = "deci.crossfade"
    static let mixingSymbol = "waveform.path"

    var symbol: String { self == .mixing ? Self.mixingSymbol : Self.crossfadeSymbol }

    /// Songs hand over with a fade, plain or mixed.
    var isOn: Bool { self != .off }
}
