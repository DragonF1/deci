// Deci/Views/MenuBar/MusicChipLayout.swift
// The Now playing chip in the menu bar: its measures, how wide the title's window is, when a title scrolls and the words
// around it. Pure numbers and text, so the rules are unit tested; MusicChipContent and MusicChipView draw them.

import Foundation

/// What a title makes of the pill. Widths are whole points, so the status item does not shimmer between two sizes.
nonisolated struct MusicChipGeometry: Equatable, Sendable {
    /// The whole title set in the chip font.
    var textWidth: Double
    /// The part of the title that shows at rest: all of it up to `MusicChipLayout.maxCharacters`, else as wide as its
    /// first characters.
    var windowWidth: Double
    /// The pill: its insets and cover around the window.
    var pillWidth: Double
    /// Whether the title is longer than its window and so scrolls (or, with Reduce Motion, ends in an ellipsis).
    var scrolls: Bool
}

/// An 18 pt pill: a 3 pt inset, the 12 pt round cover, a 5 pt gap, the title (12 pt semibold) and an 8 pt trailing
/// inset. The pill is as wide as the title it shows. A title of up to `maxCharacters` characters shows in full; a longer
/// one gets a window as wide as its first `maxCharacters` characters and scrolls inside it, so the pill never grows past
/// that. While the song is paused the pill is a small one holding only a play glyph, `pausedPillWidth` wide.
nonisolated enum MusicChipLayout {
    static let height: Double = 18
    static let cornerRadius: Double = 9
    static let leadingInset: Double = 3
    static let thumbnailSize: Double = 12
    static let gap: Double = 5
    static let trailingInset: Double = 8
    static let titleFontSize: Double = 12

    /// The most characters of a title that show in full. A longer title scrolls.
    static let maxCharacters = 20

    /// The pill's width while the song is paused: just the play glyph in the middle, a little wider than the pill is high.
    static let pausedPillWidth: Double = 34

    /// The play glyph that shows on a paused pill: the square it is drawn into and the size of the symbol in it.
    static let playGlyphSide: Double = 12
    static let playGlyphPointSize: Double = 9

    /// How far the play glyph sits right of the pill's middle: a triangle's weight is at its base, so it looks left heavy
    /// when its box is centred.
    static let playGlyphNudge: Double = 1

    /// The title's left edge: after the inset, the cover and the gap.
    static let titleOriginX: Double = leadingInset + thumbnailSize + gap

    /// The room the status item leaves on each side of the pill when its width is set explicitly, for a button whose
    /// own padding could not be read.
    static let defaultItemPadding: Double = 6

    /// The widest side padding a measurement may give; anything above it is a misreading.
    static let maxItemPadding: Double = 14

    /// What a title makes of the pill, measured by `measure` in the chip font. A width that cannot be measured counts
    /// as none. The window is measured on the first `maxCharacters` characters only, so a long title's tail does not
    /// widen it.
    static func geometry(title: String, measure: (String) -> Double) -> MusicChipGeometry {
        let fullWidth = usable(measure(title))
        let isLong = title.count > maxCharacters
        let prefixWidth = isLong ? min(usable(measure(String(title.prefix(maxCharacters)))), fullWidth) : fullWidth
        let window = prefixWidth.rounded(.up)
        return MusicChipGeometry(
            textWidth: fullWidth.rounded(.up),
            windowWidth: window,
            pillWidth: pillWidth(windowWidth: window),
            scrolls: scrolls(characterCount: title.count, textWidth: fullWidth, windowWidth: prefixWidth)
        )
    }

    /// The pill's width, in whole points: the title's window and the pill's own insets.
    static func pillWidth(windowWidth: Double) -> Double {
        (titleOriginX + usable(windowWidth) + trailingInset).rounded(.up)
    }

    /// A title scrolls only when it has more characters than the max and its text is really wider than its window.
    /// Widths that are not numbers never scroll.
    static func scrolls(characterCount: Int, textWidth: Double, windowWidth: Double) -> Bool {
        guard textWidth.isFinite, windowWidth.isFinite else { return false }
        return characterCount > maxCharacters && textWidth > windowWidth
    }

    /// The status item's length for a pill: the pill and the item's padding on both sides.
    static func itemLength(pillWidth: Double, itemPadding: Double) -> Double {
        pillWidth + itemPadding * 2
    }

    /// The padding each side of an item has, read from an item that holds only an icon: what the icon leaves over,
    /// halved, to the half point. Nil when the reading makes no sense (a button not laid out yet, a width that is not a
    /// number), so the caller keeps its fallback.
    static func measuredItemPadding(buttonWidth: Double, iconWidth: Double) -> Double? {
        guard buttonWidth.isFinite, iconWidth.isFinite else { return nil }
        let padding = (buttonWidth - iconWidth).rounded() / 2
        guard padding >= 0, padding <= maxItemPadding else { return nil }
        return padding
    }

    /// The pill's width for a song: the title's while it plays, the small `pausedPillWidth` while it is paused.
    static func shownPillWidth(for geometry: MusicChipGeometry, isPlaying: Bool) -> Double {
        isPlaying ? geometry.pillWidth : pausedPillWidth
    }

    /// The strength the cover and the title are drawn at: full while the song plays, gone while it is paused.
    static func contentAlpha(isPlaying: Bool) -> Double {
        isPlaying ? 1 : 0
    }

    /// The strength the play glyph is drawn at: only on a paused pill.
    static func playGlyphAlpha(isPlaying: Bool) -> Double {
        isPlaying ? 0 : 1
    }

    /// What the chip says: the song's title, else its artist, else a plain phrase. One line: a line break in a title
    /// becomes a space.
    static func displayTitle(title: String, artist: String) -> String {
        let cleaned = singleLine(title)
        if !cleaned.isEmpty { return cleaned }
        let artistLine = singleLine(artist)
        return artistLine.isEmpty ? "Now playing" : artistLine
    }

    /// What VoiceOver reads on the item: its name, the whole song title and whether it plays.
    static func accessibilityLabel(title: String, isPlaying: Bool) -> String {
        "\(MenuBarItemID.music.title), \(title), \(isPlaying ? "playing" : "paused")"
    }

    /// The chip replaces the icon only for the chip style, on a Music item that is in the menu bar, with a song loaded.
    /// The hover card is offered under the same rule.
    static func showsChip(style: MusicMenuBarStyle, isMusicShown: Bool, hasTrack: Bool) -> Bool {
        style == .chip && isMusicShown && hasTrack
    }

    /// A width that can be used: a finite number, never below zero. One that cannot be measured counts as none.
    private static func usable(_ width: Double) -> Double {
        width.isFinite ? max(width, 0) : 0
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
