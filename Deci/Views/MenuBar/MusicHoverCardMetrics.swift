// Deci/Views/MenuBar/MusicHoverCardMetrics.swift
// The hover card's measures and where it opens under the status item. Pure numbers, so both are unit tested.

import CoreGraphics
import Foundation

/// The card is 300 pt wide and its rows add up to its height (about 115 pt): nothing in it wraps or grows, so the panel
/// is sized once and never relaid out while it is up.
nonisolated enum MusicHoverCardMetrics {
    static let width: Double = 300
    static let horizontalInset: Double = 12
    static let cornerRadius: Double = 14

    static let topInset: Double = 12
    static let titleRowHeight: Double = 18
    static let afterTitleRow: Double = 4
    static let waveHeight: Double = MusicWave.boxHeight
    static let timesRowHeight: Double = 12
    static let afterTimesRow: Double = 6
    static let controlsRowHeight: Double = 28
    static let bottomInset: Double = 12

    /// The round buttons of the controls row.
    static let controlCircleSize: Double = 28

    /// The Dislike and Like icons at the end of the title row: a 12 pt glyph in a hit area as high as the row, so the row
    /// keeps its height, with a little room between the two.
    static let rateGlyphSize: Double = 12
    static let rateButtonWidth: Double = 22
    static let rateButtonHeight: Double = 18
    static let rateButtonSpacing: Double = 2

    /// The room the wave, the times and the controls have across the card.
    static let contentWidth: Double = width - 2 * horizontalInset

    static let height: Double = topInset + titleRowHeight + afterTitleRow
        + waveHeight + timesRowHeight + afterTimesRow + controlsRowHeight + bottomInset

    static var size: CGSize { CGSize(width: width, height: height) }
}

/// Where the card sits: centred under the status item and a few points below the menu bar, kept inside the screen.
nonisolated enum MusicHoverCardPlacement {
    /// The space between the menu bar (or the item) and the card's top edge.
    static let gap: CGFloat = 4

    /// The least space kept between the card and the screen's side edges.
    static let margin: CGFloat = 8

    /// The card's frame, in screen coordinates (y grows upward). `buttonFrame` is the status item button on screen and
    /// `visibleFrame` the screen's usable area, so the card hangs below the menu bar and stays clear of the Dock.
    static func frame(
        buttonFrame: CGRect,
        size: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = MusicHoverCardPlacement.gap,
        margin: CGFloat = MusicHoverCardPlacement.margin
    ) -> CGRect {
        let top = min(buttonFrame.minY, visibleFrame.maxY) - gap
        let lowest = visibleFrame.minX + margin
        let highest = visibleFrame.maxX - size.width - margin
        let centred = buttonFrame.midX - size.width / 2
        // A screen narrower than the card has no room to clamp into: the card is centred on it instead.
        let x = highest >= lowest ? min(max(centred, lowest), highest) : visibleFrame.midX - size.width / 2
        let y = max(top - size.height, visibleFrame.minY)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
