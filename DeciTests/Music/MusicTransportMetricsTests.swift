// DeciTests/Music/MusicTransportMetricsTests.swift
// The transport row's layout rule: five boxes (Shuffle, Previous, play and pause, Next, Loop) with the row's spare width
// shared equally between four Spacers. The rule is shared, so what is placed against the glyphs (the Like and Dislike
// strip above them) stands where the glyphs do. Pure values.

import Foundation
import Testing
@testable import Deci

@Suite("Music transport metrics")
struct MusicTransportMetricsTests {
    private typealias Slot = MusicTransportMetrics.Slot
    private let columnWidth = Double(MusicPopupMetrics.playerColumnContentWidth)

    private func centre(_ slot: Slot, width: Double? = nil) -> Double {
        Double(MusicTransportMetrics.centreX(of: slot, width: CGFloat(width ?? columnWidth)))
    }

    @Test("the five boxes are 13, 16, 32, 16 and 13 wide, in a row 32 high")
    func boxes() {
        #expect(Slot.allCases == [.shuffle, .previous, .playPause, .next, .loop])
        #expect(Slot.allCases.map { Double(MusicTransportMetrics.box($0)) } == [13, 16, 32, 16, 13])
        #expect(MusicTransportMetrics.height == 32)
    }

    @Test("in the 142 pt column the four gaps are 13 pt each")
    func gapInTheColumn() {
        #expect(columnWidth == 142)
        #expect(Double(MusicTransportMetrics.gap()) == 13)
        #expect(Double(MusicTransportMetrics.gap(width: 142)) == 13)
    }

    @Test("the glyphs' centres in the 142 pt column are 6.5, 34, 71, 108 and 135.5")
    func centresInTheColumn() {
        #expect(centre(.shuffle) == 6.5)
        #expect(centre(.previous) == 34)
        #expect(centre(.playPause) == 71)
        #expect(centre(.next) == 108)
        #expect(centre(.loop) == 135.5)
    }

    @Test("Like stands at the middle of Shuffle and Previous, Dislike at the middle of Next and Loop")
    func ratingCentres() {
        #expect(Double(MusicTransportMetrics.likeCentreX()) == 20.25)
        #expect(Double(MusicTransportMetrics.dislikeCentreX()) == 121.75)
        #expect(Double(MusicTransportMetrics.likeCentreX()) == (centre(.shuffle) + centre(.previous)) / 2)
        #expect(Double(MusicTransportMetrics.dislikeCentreX()) == (centre(.next) + centre(.loop)) / 2)
    }

    @Test("the two icons are mirrored about the play button, which is the middle of the column")
    func mirrored() {
        #expect(centre(.playPause) == columnWidth / 2)
        let like = Double(MusicTransportMetrics.likeCentreX())
        let dislike = Double(MusicTransportMetrics.dislikeCentreX())
        #expect(columnWidth / 2 - like == dislike - columnWidth / 2)
    }

    @Test("a wider row spreads the same boxes with a wider gap, the centres following the Spacer rule")
    func widerRow() {
        // 170 pt: 80 pt spare, 20 pt per gap.
        #expect(Double(MusicTransportMetrics.gap(width: 170)) == 20)
        #expect(centre(.shuffle, width: 170) == 6.5)
        #expect(centre(.previous, width: 170) == 41)
        #expect(centre(.playPause, width: 170) == 85)
        #expect(centre(.next, width: 170) == 129)
        #expect(centre(.loop, width: 170) == 163.5)
        #expect(Double(MusicTransportMetrics.likeCentreX(width: 170)) == 23.75)
        #expect(Double(MusicTransportMetrics.dislikeCentreX(width: 170)) == 146.25)
    }

    @Test("a row with no room to spare has no gap, and the boxes follow one another")
    func noRoom() {
        #expect(Double(MusicTransportMetrics.gap(width: 90)) == 0)
        #expect(Double(MusicTransportMetrics.gap(width: 40)) == 0)
        #expect(Double(MusicTransportMetrics.gap(width: .nan)) == 0)
        #expect(centre(.previous, width: 40) == 21)
        #expect(centre(.loop, width: 40) == 83.5)
    }

    @Test("the icons' 24 pt hit areas fit inside the column and clear of each other")
    func hitAreasFit() {
        let half = Double(MusicPopupMetrics.rateHitWidth) / 2
        let like = Double(MusicTransportMetrics.likeCentreX())
        let dislike = Double(MusicTransportMetrics.dislikeCentreX())
        #expect(like - half >= 0)
        #expect(dislike + half <= columnWidth)
        #expect(like + half < dislike - half)
    }

    @Test("Shuffle and Loop rest at half brightness, the strip's icons too")
    func restingBrightness() {
        #expect(MusicTransportMetrics.restingGlyphOpacity == 0.50)
    }
}
