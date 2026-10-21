// DeciTests/Music/MusicRateButtonTests.swift
// The Like and Dislike icons of the Now playing hover card and of the popup's player column: which glyph, brightness and
// words each shows for the song's state, and the measures that keep them inside the title row, or in the strip between
// the times and the transport. Pure values, and a few small layouts measured offscreen.

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

    @Test("A look can dim its outline glyph differently, and an active one stays full white either way")
    func inactiveOpacity() {
        for status in statuses {
            let like = MusicRateButtonLook(kind: .like, status: status, inactiveOpacity: 0.5)
            #expect(like.glyphOpacity == (status == .like ? 1 : 0.5))
            let dislike = MusicRateButtonLook(kind: .dislike, status: status, inactiveOpacity: 0.5)
            #expect(dislike.glyphOpacity == (status == .dislike ? 1 : 0.5))
            // The card does not pass one, so it keeps its 0.6.
            #expect(MusicRateButtonLook(kind: .like, status: status).glyphOpacity == (status == .like ? 1 : 0.6))
        }
    }

    // MARK: - In the popup's player column

    @Test("The strip is 12 pt high with a 12 pt glyph, in the 23 pt between the times and the transport, 2 pt over the transport")
    func stripMeasures() {
        let m = MusicPopupMetrics.self
        #expect(m.rateGlyphSize == 12)
        #expect((12.0...13.0).contains(Double(m.rateGlyphSize)))
        #expect(m.rateStripHeight == 12)
        #expect(m.rateGlyphSize <= m.rateStripHeight)
        #expect(m.spectrumBlockSpacing == 6)
        #expect(m.playerColumnSpacing == 10)
        #expect(m.timesToTransport == 23)
        #expect(m.rateStripLift == 2)
        // The spectrum block's own padding makes up the rest of the gap over the column's spacing.
        #expect(m.timesToTransport >= m.playerColumnSpacing)
    }

    @Test("The times' digits end as far over the icons as the icons end over Previous and Next")
    func stripEvenGaps() {
        let m = MusicPopupMetrics.self
        // Measured in the popup: the digits' ink ends 3 pt above the 13 pt times row's bottom, the icons' ink runs 1 pt
        // past their box, and Previous and Next's ink starts 11 pt into the 32 pt transport.
        let digitsInkBottom = -(m.timesToTransport + 3)
        let iconTop = -(m.rateStripHeight + m.rateStripLift)
        let iconInkBottom = -m.rateStripLift + 1
        let skipInkTop: CGFloat = 11
        let above = iconTop - digitsInkBottom
        let below = skipInkTop - iconInkBottom
        #expect(above == below)
        #expect(above == 12)
    }

    @Test("Each icon's hit area is 24 by 20, reaching past its 12 by 12 box, and stays inside the gaps above and below the strip")
    func stripHitArea() {
        let m = MusicPopupMetrics.self
        #expect(m.rateHitWidth == 24)
        #expect(m.rateHitHeight == 20)
        #expect(m.rateReachX == 6)
        #expect(m.rateReachY == 4)
        #expect(m.rateGlyphSize + 2 * m.rateReachX == m.rateHitWidth)
        #expect(m.rateStripHeight + 2 * m.rateReachY == m.rateHitHeight)
        // Above the strip, the reach ends at the times row and never covers it.
        #expect(m.rateReachY <= m.timesToTransport - (m.rateStripHeight + m.rateStripLift))
    }

    @Test("The icons rest at the brightness of Shuffle and Loop")
    func stripRestingBrightness() {
        #expect(MusicTransportMetrics.restingGlyphOpacity == 0.50)
    }

    @MainActor
    @Test("The strip is the column's width and 12 pt high with the icons and without, so the layout never jumps")
    func stripKeepsItsSpace() {
        let width = MusicPopupMetrics.playerColumnContentWidth
        for available in [true, false] {
            for status in statuses {
                let size = fittingSize(MusicRateStrip(isAvailable: available, status: status, onDislike: {}, onLike: {}))
                #expect(size.width == width)
                #expect(size.height == MusicPopupMetrics.rateStripHeight)
            }
        }
    }

    @MainActor
    @Test("Like stands over the gap between Shuffle and Previous, Dislike over the gap between Next and Loop")
    func stripPlacesTheIcons() throws {
        let ink = try inkOfStrip(status: nil)
        let like = try #require(ink.left)
        let dislike = try #require(ink.right)
        // The glyphs' own ink is not quite symmetric in their boxes, so a point of slack.
        #expect(abs(like.centreX - Double(MusicTransportMetrics.likeCentreX())) <= 1)
        #expect(abs(dislike.centreX - Double(MusicTransportMetrics.dislikeCentreX())) <= 1)
        // 20.25 and 121.75 in the 142 pt column: Like is the left one.
        #expect(like.centreX < Double(MusicPopupMetrics.playerColumnContentWidth) / 2)
        #expect(dislike.centreX > Double(MusicPopupMetrics.playerColumnContentWidth) / 2)
        // Both sit in the middle of the strip's height.
        #expect(abs(like.centreY - Double(MusicPopupMetrics.rateStripHeight) / 2) <= 1.5)
        #expect(abs(dislike.centreY - Double(MusicPopupMetrics.rateStripHeight) / 2) <= 1.5)
    }

    @MainActor
    @Test("A liked song fills the left icon in full white and leaves the right one outlined at half brightness")
    func likedSong() throws {
        let ink = try inkOfStrip(status: .like)
        #expect(try #require(ink.left).peak > 0.9)
        let right = try #require(ink.right).peak
        #expect(right > 0.45)
        #expect(right <= 0.52)
    }

    @MainActor
    @Test("A disliked song fills the right icon in full white and leaves the left one outlined at half brightness")
    func dislikedSong() throws {
        let ink = try inkOfStrip(status: .dislike)
        #expect(try #require(ink.right).peak > 0.9)
        let left = try #require(ink.left).peak
        #expect(left > 0.45)
        #expect(left <= 0.52)
    }

    @MainActor
    @Test("With nothing to rate the strip is empty")
    func unavailableStripIsEmpty() throws {
        let ink = try inkOfStrip(status: .like, available: false)
        #expect(ink.left == nil)
        #expect(ink.right == nil)
    }

    @MainActor
    @Test("The card's pair stays a row of two 22 by 18 areas, 2 pt apart")
    func cardKeepsItsLayout() {
        let card = fittingSize(MusicRateButtons(status: nil, onDislike: {}, onLike: {}))
        #expect(Double(card.width) == 2 * MusicHoverCardMetrics.rateButtonWidth + MusicHoverCardMetrics.rateButtonSpacing)
        #expect(Double(card.height) == MusicHoverCardMetrics.rateButtonHeight)
    }

    // MARK: - Helpers

    /// Where one half of the strip has ink: its middle, in points from the strip's top left, and its brightest pixel.
    private struct Ink {
        let centreX: Double
        let centreY: Double
        let peak: Double
    }

    /// The ink of the strip's left and right halves, drawn at four times the size on black. A half with none is nil.
    @MainActor
    private func inkOfStrip(status: MusicLikeStatus?, available: Bool = true) throws -> (left: Ink?, right: Ink?) {
        let strip = MusicRateStrip(isAvailable: available, status: status, onDislike: {}, onLike: {})
            .background(Color.black)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 4
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let middle = rep.pixelsWide / 2
        func measure(_ columns: Range<Int>) -> Ink? {
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            var peak = 0.0
            for y in 0..<rep.pixelsHigh {
                for x in columns {
                    let red = rep.colorAt(x: x, y: y)?.redComponent ?? 0
                    guard red > 0.15 else { continue }
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    peak = max(peak, Double(red))
                }
            }
            guard maxX >= minX else { return nil }
            return Ink(centreX: Double(minX + maxX + 1) / 8, centreY: Double(minY + maxY + 1) / 8, peak: peak)
        }
        return (measure(0..<middle), measure(middle..<rep.pixelsWide))
    }

    @MainActor
    private func fittingSize<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }
}
