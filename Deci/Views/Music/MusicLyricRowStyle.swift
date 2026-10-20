// Deci/Views/Music/MusicLyricRowStyle.swift
import SwiftUI

/// Where a line is relative to the song: sung, being sung, or still to come.
enum MusicLyricPosition: Sendable {
    case past, current, upcoming
}

/// How a lyric row looks. Every row has the same font, semibold and 17 pt, whatever its position: a weight or size that
/// changed with the current line would re-wrap lines and shift the list in the middle of a scroll. The position
/// moves only the colour: the lines to come fade out the further ahead they are, sung lines are dim, and the current
/// line is full where it has been sung and half lit after that. Hovering a line that is not current brightens it part
/// of the way to the current colour.
struct MusicLyricRowStyle: Equatable {
    static let fontSize: CGFloat = 17
    static let fontWeight = Font.Weight.semibold
    /// The room between the wrapped lines of one row: with the font's own leading it makes a comfortable line.
    static let lineSpacing: CGFloat = 3
    /// The room above and below each row: two of them are the gap between lines.
    static let verticalPadding: CGFloat = 7

    /// The part of the current line the singer has not reached yet.
    static let upcomingOpacity = 0.50
    static let pastOpacity = 0.28
    /// The current line, and the part of it that has been sung.
    static let currentOpacity = 0.98
    /// How far a hover moves a line from its resting opacity toward the current one: half way.
    static let hoverLift = 0.5

    /// The lines after the current one fade out: the first is this bright, each next one a step less, down to the floor.
    static let aheadFirstOpacity = 0.56
    static let aheadStep = 0.09
    static let aheadFloorOpacity = 0.16
    /// The distance at which the fade reaches its floor; a line further ahead is no dimmer, so it counts as this far.
    static let aheadFloorDistance = 6

    /// How long a row takes to change colour. Short next to the scroll glide, and only ever on the colour.
    static let colorFadeDuration: TimeInterval = 0.3

    let position: MusicLyricPosition
    var isHovered = false
    /// How many lines ahead of the current one this row is (1 is the next line); 0 for a sung or current row.
    var ahead = 0

    var fontSize: CGFloat { Self.fontSize }
    var fontWeight: Font.Weight { Self.fontWeight }
    var font: Font { .system(size: fontSize, weight: fontWeight) }

    /// The opacity of the line `distance` lines after the current one: 0.56, 0.47, 0.38, 0.29, 0.20, then 0.16. A
    /// distance below 1 counts as the next line.
    static func aheadOpacity(_ distance: Int) -> Double {
        let steps = Double(max(distance, 1) - 1)
        return max(aheadFirstOpacity - aheadStep * steps, aheadFloorOpacity)
    }

    var opacity: Double {
        let resting: Double = switch position {
        case .current: Self.currentOpacity
        case .past: Self.pastOpacity
        case .upcoming: Self.aheadOpacity(ahead)
        }
        guard isHovered, position != .current else { return resting }
        return resting + (Self.currentOpacity - resting) * Self.hoverLift
    }

    /// The primary text colour at the row's opacity, so a light appearance dims toward the background too.
    var color: Color { DesignTokens.Colors.textPrimary.opacity(opacity) }

    /// How many lines ahead of the current one line `index` is: 0 for a sung or current line, and no more than
    /// `aheadFloorDistance` however far ahead, so a row far from the current line is not redrawn as the song moves.
    /// Before the first line starts there is no current line, and line 0 is the next one.
    static func ahead(of index: Int, current: Int?) -> Int {
        guard let current else { return min(index + 1, aheadFloorDistance) }
        return min(max(index - current, 0), aheadFloorDistance)
    }

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
