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
    /// The room between the wrapped lines of one row: with the font's own leading it makes the design's 22 pt line.
    static let lineSpacing: CGFloat = 2
    /// The room above and below each row: two of them are the design's 14 pt gap between lines.
    static let verticalPadding: CGFloat = 7

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

    /// The text of the line being sung, at one moment of its fill: each character at the brightness the sweep gives it,
    /// full where the singer has been, upcoming ahead, with a soft edge between. Only the colour is set on a run, so
    /// the font, the size and the wrapping are exactly those of the plain row, and the characters are the line's own
    /// (a character is never cut: an accent or an emoji keeps its one colour). A sweep that is not a number is the start.
    static func filledText(_ text: String, sweep: Double) -> AttributedString {
        let characters = Array(text)
        guard !characters.isEmpty else { return AttributedString() }
        let alphas = LyricFill.alphas(
            characterCount: characters.count, sweep: sweep, unsung: upcomingOpacity, sung: currentOpacity
        )
        var result = AttributedString()
        for run in LyricFill.runs(of: alphas) {
            var piece = AttributedString(String(characters[run.range]))
            piece.foregroundColor = DesignTokens.Colors.textPrimary.opacity(run.alpha)
            result.append(piece)
        }
        return result
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

    /// How long before a line's time it becomes the current one: the eye needs a moment to follow a change, so a line
    /// that lights up exactly on its beat looks late. Also the lead of the word fill.
    static let lineLead: TimeInterval = 0.1

    /// One long gentle glide from line to line.
    static let glideDuration: TimeInterval = 0.55
    /// The glide's ease-out curve as the control points of a cubic Bezier (x1, y1, x2, y2): fast off the mark, long soft
    /// landing. The real scroll view is animated with it, since SwiftUI's own scroll to a row does not animate on macOS.
    static let glideControlPoints: [Float] = [0.25, 0.1, 0.25, 1]
    /// The fallback when the real scroll view cannot be found: SwiftUI's own animated scroll, which on macOS may jump.
    static let glide = Animation.smooth(duration: glideDuration)
}
