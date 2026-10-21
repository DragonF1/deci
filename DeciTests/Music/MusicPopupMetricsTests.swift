// DeciTests/Music/MusicPopupMetricsTests.swift
// The Music popup is a split pane: a 170 pt player column, a 1 pt divider and the right column, inside a 1 pt border
// and 520 pt tall at every popup size. These pins catch an accidental resize and keep the account card on the avatar.

import CoreGraphics
import Testing
@testable import Deci

@Suite("MusicPopupMetrics")
struct MusicPopupMetricsTests {
    @Test("the popup is 520 pt tall at every popup size", arguments: MenuBarPopupSize.allCases)
    func heightAtEverySize(size: MenuBarPopupSize) {
        #expect(MusicPopupMetrics.height == 520)
        #expect(size.dimensions.maxContentHeight >= MusicPopupMetrics.height)
    }

    @Test("the player column is 170 pt wide and the right column takes the rest inside the border and the divider")
    func columnWidths() {
        #expect(MusicPopupMetrics.playerColumnWidth == 170)
        #expect(MusicPopupMetrics.dividerWidth == 1)
        #expect(MusicPopupMetrics.rightColumnWidth(popupWidth: 510) == 337)
        #expect(MusicPopupMetrics.rightColumnContentWidth(popupWidth: 510) == 305)
        #expect(MusicPopupMetrics.rightColumnWidth(popupWidth: 0) == 0)
    }

    @Test("the player column pads its content 14 pt, which leaves the 142 pt the cover and the spectrum are")
    func playerColumnContent() {
        #expect(MusicPopupMetrics.playerColumnPadding == 14)
        #expect(MusicPopupMetrics.playerColumnContentWidth == 142)
        #expect(Double(MusicPopupMetrics.playerColumnContentWidth) == MusicSpectrum.boxWidth)
    }

    @Test("the right column keeps room for content at every popup size", arguments: MenuBarPopupSize.allCases)
    func rightColumnFits(size: MenuBarPopupSize) {
        let width = size.dimensions.width
        let total = 2 * MusicPopupMetrics.borderWidth + MusicPopupMetrics.playerColumnWidth
            + MusicPopupMetrics.dividerWidth + MusicPopupMetrics.rightColumnWidth(popupWidth: width)
        #expect(total == width)
        #expect(MusicPopupMetrics.rightColumnContentWidth(popupWidth: width) >= 250)
    }

    @Test("the right header is 32 pt tall and starts 8 pt under the border")
    func header() {
        #expect(MusicPopupMetrics.headerHeight == 32)
        #expect(MusicPopupMetrics.rightPaddingTop == 8)
        #expect(MusicPopupMetrics.headerTop == 9)
    }

    @Test("the right column pads its content 16 pt at the sides and 14 pt at the bottom")
    func rightPadding() {
        #expect(MusicPopupMetrics.rightPaddingSide == 16)
        #expect(MusicPopupMetrics.rightPaddingBottom == 14)
    }

    @Test("the open search field keeps its 154 pt base width, and the compact column has it to spare beside one tab")
    func openFieldWidth() {
        #expect(MusicPopupMetrics.openFieldMinWidth == 154)
        // One tab (60 pt at most) and the 12 pt gap leave the compact content at least that for the field.
        let content = MusicPopupMetrics.rightColumnContentWidth(popupWidth: MenuBarPopupSize.compact.dimensions.width)
        #expect(content - 60 - 12 >= MusicPopupMetrics.openFieldMinWidth)
    }

    @Test("the account card hangs 6 pt under the avatar and ends where it does")
    func accountCardPlacement() {
        // The avatar is centred in the header: 9 + (32 + 22) / 2 = 36 is its bottom edge, and the card sits 6 below it.
        #expect(MusicPopupMetrics.avatarSize == 22)
        #expect(MusicPopupMetrics.accountCardTop == 42)
        // The avatar's right edge: the border and the right column's side padding.
        #expect(MusicPopupMetrics.accountCardTrailing == 17)
    }

    @Test("the account card fits inside the right column at every popup size", arguments: MenuBarPopupSize.allCases)
    @MainActor
    func accountCardFits(size: MenuBarPopupSize) {
        let width = size.dimensions.width
        let cardLeft = width - MusicPopupMetrics.accountCardTrailing - MusicAccountCard.width
        let rightColumnLeft = MusicPopupMetrics.borderWidth + MusicPopupMetrics.playerColumnWidth + MusicPopupMetrics.dividerWidth
        #expect(cardLeft >= rightColumnLeft)
    }

    @Test("the popup is a 12 pt rounded rectangle")
    func corner() {
        #expect(MusicPopupMetrics.cornerRadius == 12)
    }
}
