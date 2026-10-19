// Deci/Views/Music/MusicLyricRowStyle.swift
import SwiftUI

/// Where a line is relative to the song: sung, being sung, or still to come.
enum MusicLyricPosition: Sendable {
    case past, current, upcoming
}

/// How a lyric row looks. Every row has the same font, bold and 17 pt, whatever its position: a weight or size that
/// changed with the current line would re-wrap lines and shift the list in the middle of a scroll. The position
/// moves only the colour: upcoming lines are dim, sung lines are lit, the current line is full. Hovering a line
/// that is not current brightens it part of the way to the current colour.
struct MusicLyricRowStyle: Equatable {
    static let fontSize: CGFloat = 17
    static let fontWeight = Font.Weight.bold
    /// The room between the wrapped lines of one row.
    static let lineSpacing: CGFloat = 3
    /// The room above and below each row.
    static let verticalPadding: CGFloat = 6

    static let upcomingOpacity = 0.35
    static let pastOpacity = 0.65
    static let currentOpacity = 1.0
    /// How far a hover moves a line from its resting opacity toward the current one: half way.
    static let hoverLift = 0.5

    /// How long a row takes to change colour. Short next to the scroll glide, and only ever on the colour.
    static let colorFadeDuration: TimeInterval = 0.3

    let position: MusicLyricPosition
    var isHovered = false

    var fontSize: CGFloat { Self.fontSize }
    var fontWeight: Font.Weight { Self.fontWeight }
    var font: Font { .system(size: fontSize, weight: fontWeight) }

    var opacity: Double {
        let resting: Double = switch position {
        case .current: Self.currentOpacity
        case .past: Self.pastOpacity
        case .upcoming: Self.upcomingOpacity
        }
        guard isHovered, position != .current else { return resting }
        return resting + (Self.currentOpacity - resting) * Self.hoverLift
    }

    /// The primary text colour at the row's opacity, so a light appearance dims toward the background too.
    var color: Color { DesignTokens.Colors.textPrimary.opacity(opacity) }

    /// Where line `index` is when line `current` is the one being sung (nil before the first line starts).
    static func position(of index: Int, current: Int?) -> MusicLyricPosition {
        guard let current else { return .upcoming }
        if index == current { return .current }
        return index < current ? .past : .upcoming
    }

    /// What a row shows: an empty timed line is an instrumental gap, shown as a note.
    static func shownText(_ text: String) -> String {
        text.isEmpty ? "\u{266A}" : text
    }

    /// What VoiceOver says for a row.
    static func spokenText(_ text: String) -> String {
        text.isEmpty ? "Instrumental break" : text
    }
}

/// Where and how the synced list scrolls to keep up with the song.
enum MusicLyricScroll {
    /// How far down the visible area the current line sits: a third, like Spotify, not the dead centre.
    static let anchorFraction: CGFloat = 1.0 / 3.0
    static let anchor = UnitPoint(x: 0.5, y: anchorFraction)

    /// One long gentle glide from line to line.
    static let glideDuration: TimeInterval = 0.55
    /// A smooth spring: critically damped, so it eases out with no bounce and keeps its speed if the next line
    /// arrives before it settles.
    static let glide = Animation.smooth(duration: glideDuration)
}
