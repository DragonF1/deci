// Deci/Views/MenuBar/MusicChipLayout.swift
// The Now playing chip in the menu bar: its measures, how a long title fades and the words around it. Pure numbers and
// text, so the rules are unit tested; MusicChipRenderer draws them.

import Foundation

/// An 18 pt pill: a 3 pt inset, the 12 pt round cover, a 5 pt gap, the title (12 pt semibold, at most 96 pt wide) and an
/// 8 pt trailing inset. A title longer than 96 pt ends in a short fade to nothing, not an ellipsis, and nothing moves:
/// the chip is drawn once for a song and the menu bar stays idle.
nonisolated enum MusicChipLayout {
    static let height: Double = 18
    static let cornerRadius: Double = 9
    static let leadingInset: Double = 3
    static let thumbnailSize: Double = 12
    static let gap: Double = 5
    static let trailingInset: Double = 8
    static let titleFontSize: Double = 12
    static let maxTitleWidth: Double = 96

    /// How much of the title's end the fade takes.
    static let fadeLength: Double = 14

    /// What a paused song's cover and title are drawn at.
    static let pausedAlpha: Double = 0.6

    /// The title's left edge: after the inset, the cover and the gap.
    static let titleOriginX: Double = leadingInset + thumbnailSize + gap

    /// The title's drawn width: as long as it is, up to the most it gets. A width that cannot be measured counts as none.
    static func titleWidth(naturalTitleWidth: Double) -> Double {
        guard !naturalTitleWidth.isNaN else { return 0 }
        return min(max(naturalTitleWidth, 0), maxTitleWidth)
    }

    /// The chip's width, in whole points so the status item does not shimmer between two sizes.
    static func width(naturalTitleWidth: Double) -> Double {
        (titleOriginX + titleWidth(naturalTitleWidth: naturalTitleWidth) + trailingInset).rounded(.up)
    }

    /// Where, from the title's left edge, the fade begins; nil when the whole title fits and nothing fades.
    static func fadeStart(naturalTitleWidth: Double) -> Double? {
        guard !naturalTitleWidth.isNaN, naturalTitleWidth > maxTitleWidth else { return nil }
        return maxTitleWidth - fadeLength
    }

    /// The strength the cover and the title are drawn at: full while the song plays, dimmed while it is paused.
    static func contentAlpha(isPlaying: Bool) -> Double {
        isPlaying ? 1 : pausedAlpha
    }

    /// What the chip says: the song's title, else its artist, else a plain phrase. One line: a line break in a title
    /// becomes a space.
    static func displayTitle(title: String, artist: String) -> String {
        let cleaned = singleLine(title)
        if !cleaned.isEmpty { return cleaned }
        let artistLine = singleLine(artist)
        return artistLine.isEmpty ? "Now playing" : artistLine
    }

    /// What VoiceOver reads on the item: its name, the song and whether it plays.
    static func accessibilityLabel(title: String, isPlaying: Bool) -> String {
        "\(MenuBarItemID.music.title), \(title), \(isPlaying ? "playing" : "paused")"
    }

    /// The chip replaces the icon only for the chip style, on a Music item that is in the menu bar, with a song loaded.
    /// The hover card is offered under the same rule.
    static func showsChip(style: MusicMenuBarStyle, isMusicShown: Bool, hasTrack: Bool) -> Bool {
        style == .chip && isMusicShown && hasTrack
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
