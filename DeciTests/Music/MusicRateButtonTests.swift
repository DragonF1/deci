// DeciTests/Music/MusicRateButtonTests.swift
// The Like and Dislike icons of the Now playing hover card and of the popup's player column: which glyph, brightness and
// words each shows for the song's state, and the measures that keep them inside the title row, or beside the popup's
// spectrum. Pure values, and a few small layouts measured offscreen.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Deci

@Suite("Music rate buttons")
struct MusicRateButtonTests {
    private let statuses: [MusicLikeStatus?] = [nil, .indifferent, .like, .dislike]

    @Test("Like is filled and full white only on a liked song")
    func likeActive() {
        for status in statuses {
            let look = MusicRateButtonLook(kind: .like, status: status)
            let liked = status == .like
            #expect(look.isActive == liked)
            #expect(look.symbolName == (liked ? "hand.thumbsup.fill" : "hand.thumbsup"))
            #expect(look.glyphOpacity == (liked ? 1 : 0.6))
        }
    }

    @Test("Dislike is filled and full white only on a disliked song")
    func dislikeActive() {
        for status in statuses {
            let look = MusicRateButtonLook(kind: .dislike, status: status)
            let disliked = status == .dislike
            #expect(look.isActive == disliked)
            #expect(look.symbolName == (disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
            #expect(look.glyphOpacity == (disliked ? 1 : 0.6))
        }
    }

    @Test("A song neither liked nor disliked, or not known yet, shows both outlined")
    func neitherActive() {
        for status in [nil, .indifferent] as [MusicLikeStatus?] {
            #expect(!MusicRateButtonLook(kind: .like, status: status).isActive)
            #expect(!MusicRateButtonLook(kind: .dislike, status: status).isActive)
        }
    }

    @Test("The help and the accessibility label are the action, and only an active button is selected")
    func words() {
        let like = MusicRateButtonLook(kind: .like, status: .like)
        let dislike = MusicRateButtonLook(kind: .dislike, status: .like)
        #expect(like.title == "Like")
        #expect(dislike.title == "Dislike")
        #expect(like.isSelected)
        #expect(!dislike.isSelected)
    }

    @Test("The icons are about 12 pt in a 22 by 18 hit area with 2 to 4 pt between them, so the title row keeps its height")
    func measures() {
        let m = MusicHoverCardMetrics.self
        #expect(m.rateGlyphSize == 12)
        #expect(m.rateButtonWidth == 22)
        #expect(m.rateButtonHeight == 18)
        #expect(m.rateButtonHeight <= m.titleRowHeight)
        #expect((2...4).contains(m.rateButtonSpacing))
        #expect(m.titleRowHeight == 18)
    }

    // MARK: - In the popup's player column

    @Test("The popup's icons are a 13 pt glyph in an 18 by 24 hit area, one over the other with 2 pt between")
    func popupMeasures() {
        let m = MusicPopupMetrics.self
        #expect(m.rateGlyphSize == 13)
        #expect(m.rateButtonWidth == 18)
        #expect(m.rateButtonHeight == 24)
        #expect(m.rateButtonSpacing == 2)
        #expect(m.rateGap == 4)
        #expect(m.rateGlyphSize < m.rateButtonWidth)
        #expect(m.rateGlyphSize < m.rateButtonHeight)
        // The pair stands in the room beside the spectrum, which is never lower than its 104 pt.
        #expect(2 * Double(m.rateButtonHeight) + Double(m.rateButtonSpacing) <= MusicSpectrum.boxHeight)
    }

    @Test("The hit area reaches 3 pt past the icon on each side, inside the gap to the spectrum, without taking layout room")
    func popupReach() {
        let m = MusicPopupMetrics.self
        #expect(m.rateButtonReach == 3)
        #expect(m.rateButtonReach < m.rateGap)
        let popup = MusicRateButtonMetrics.popup
        #expect(popup.horizontalReach == Double(m.rateButtonReach))
        #expect(popup.axis == .vertical)
        // The Now playing card keeps its hit area, and its row, as they are.
        #expect(MusicRateButtonMetrics.hoverCard.horizontalReach == 0)
        #expect(MusicRateButtonMetrics.hoverCard.axis == .horizontal)
    }

    @Test("Beside the icons the spectrum takes what the icons and their gap leave of the column")
    func popupSpectrumWidth() {
        let m = MusicPopupMetrics.self
        #expect(m.spectrumWidth(showsRate: true) + m.rateGap + m.rateButtonWidth == m.playerColumnContentWidth)
        #expect(m.spectrumWidth(showsRate: true) == 120)
    }

    @Test("Without the icons the spectrum keeps the column's full width")
    func popupSpectrumWidthWithoutIcons() {
        let m = MusicPopupMetrics.self
        #expect(m.spectrumWidth(showsRate: false) == m.playerColumnContentWidth)
        #expect(m.spectrumWidth(showsRate: false) == 142)
        #expect(Double(m.spectrumWidth(showsRate: false)) == MusicSpectrum.boxWidth)
    }

    @MainActor
    @Test("The icons are 18 pt wide and 2 pt apart in the layout, whatever the hit area reaches")
    func iconsKeepTheirLayoutSize() {
        let size = fittingSize(MusicRateButtons(status: nil, metrics: .popup, onDislike: {}, onLike: {}))
        #expect(size.width == MusicPopupMetrics.rateButtonWidth)
        #expect(size.height == 2 * MusicPopupMetrics.rateButtonHeight + MusicPopupMetrics.rateButtonSpacing)
        // The card's pair stays a row.
        let card = fittingSize(MusicRateButtons(status: nil, onDislike: {}, onLike: {}))
        #expect(Double(card.width) == 2 * MusicHoverCardMetrics.rateButtonWidth + MusicHoverCardMetrics.rateButtonSpacing)
        #expect(Double(card.height) == MusicHoverCardMetrics.rateButtonHeight)
    }

    @MainActor
    @Test("Beside the spectrum the icons are centred on its height and the row is the column's width")
    func iconsCentredBesideTheSpectrum() throws {
        let height = 150.0
        let row = HStack(spacing: MusicPopupMetrics.rateGap) {
            Color.clear.frame(width: MusicPopupMetrics.spectrumWidth(showsRate: true))
            MusicRateButtons(status: .like, metrics: .popup, onDislike: {}, onLike: {})
        }
        .frame(width: MusicPopupMetrics.playerColumnContentWidth, height: height)
        .background(Color.black)
        #expect(fittingSize(row).width == MusicPopupMetrics.playerColumnContentWidth)

        let renderer = ImageRenderer(content: row)
        renderer.scale = 4
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        var top = Int.max
        var bottom = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.25 {
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        try #require(bottom >= top)
        let centre = Double(top + bottom + 1) / 8
        #expect(abs(centre - height / 2) <= 1)
    }

    @MainActor
    private func fittingSize<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    @Test("The card keeps its measures and the popup's are its own, set for the column beside the spectrum")
    func buttonMetrics() {
        let card = MusicRateButtonMetrics.hoverCard
        let popup = MusicRateButtonMetrics.popup
        #expect(card == MusicRateButtonMetrics(glyphSize: 12, buttonWidth: 22, buttonHeight: 18, spacing: 2))
        #expect(card.glyphSize == MusicHoverCardMetrics.rateGlyphSize)
        #expect(card.buttonWidth == MusicHoverCardMetrics.rateButtonWidth)
        #expect(card.buttonHeight == MusicHoverCardMetrics.rateButtonHeight)
        #expect(card.spacing == MusicHoverCardMetrics.rateButtonSpacing)
        #expect(popup == MusicRateButtonMetrics(
            glyphSize: 13, buttonWidth: 18, buttonHeight: 24, spacing: 2, axis: .vertical, horizontalReach: 3
        ))
        #expect(popup.glyphSize == Double(MusicPopupMetrics.rateGlyphSize))
        #expect(popup.buttonWidth == Double(MusicPopupMetrics.rateButtonWidth))
        #expect(popup.buttonHeight == Double(MusicPopupMetrics.rateButtonHeight))
        #expect(popup.spacing == Double(MusicPopupMetrics.rateButtonSpacing))
        #expect(popup.horizontalReach == Double(MusicPopupMetrics.rateButtonReach))
        #expect(popup != card)
    }
}
