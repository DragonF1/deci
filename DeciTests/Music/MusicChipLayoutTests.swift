// DeciTests/Music/MusicChipLayoutTests.swift
// The Now playing chip in the menu bar: its measures, when a long title fades, and the words around it. Pure numbers,
// nothing is drawn.

import Foundation
import Testing
@testable import Deci

@Suite("Music chip layout")
struct MusicChipLayoutTests {
    @Test("the chip is an 18 pt pill: 3 pt inset, 12 pt cover, 5 pt gap, 8 pt trailing inset")
    func metrics() {
        #expect(MusicChipLayout.height == 18)
        #expect(MusicChipLayout.cornerRadius == 9)
        #expect(MusicChipLayout.leadingInset == 3)
        #expect(MusicChipLayout.thumbnailSize == 12)
        #expect(MusicChipLayout.gap == 5)
        #expect(MusicChipLayout.trailingInset == 8)
        #expect(MusicChipLayout.titleFontSize == 12)
        #expect(MusicChipLayout.maxTitleWidth == 96)
        #expect(MusicChipLayout.titleOriginX == 20)
    }

    @Test("a short title makes a chip as wide as the title and its insets")
    func shortTitleWidth() {
        #expect(MusicChipLayout.width(naturalTitleWidth: 40) == 68)
        #expect(MusicChipLayout.titleWidth(naturalTitleWidth: 40) == 40)
    }

    @Test("a long title is held to 96 pt, so the chip stops growing")
    func longTitleWidth() {
        #expect(MusicChipLayout.titleWidth(naturalTitleWidth: 300) == 96)
        #expect(MusicChipLayout.width(naturalTitleWidth: 300) == 124)
        #expect(MusicChipLayout.width(naturalTitleWidth: 97) == MusicChipLayout.width(naturalTitleWidth: 5000))
    }

    @Test("the chip's width is a whole number of points, so the item does not shimmer")
    func wholePoints() {
        #expect(MusicChipLayout.width(naturalTitleWidth: 40.2) == 69)
        #expect(MusicChipLayout.width(naturalTitleWidth: 40.0) == 68)
    }

    @Test("a title that cannot be measured leaves just the cover and the insets", arguments: [0.0, -5.0, .nan, .infinity])
    func unmeasurableWidth(natural: Double) {
        let width = MusicChipLayout.width(naturalTitleWidth: natural)
        #expect(width.isFinite)
        #expect(width >= 28)
        #expect(width <= 124)
    }

    @Test("a title that fits has no fade")
    func shortTitleHasNoFade() {
        #expect(MusicChipLayout.fadeStart(naturalTitleWidth: 40) == nil)
        #expect(MusicChipLayout.fadeStart(naturalTitleWidth: 96) == nil)
        #expect(MusicChipLayout.fadeStart(naturalTitleWidth: 0) == nil)
        #expect(MusicChipLayout.fadeStart(naturalTitleWidth: .nan) == nil)
    }

    @Test("a long title fades over its last stretch and never reaches an ellipsis")
    func longTitleFades() {
        let start = MusicChipLayout.fadeStart(naturalTitleWidth: 97)
        #expect(start == MusicChipLayout.maxTitleWidth - MusicChipLayout.fadeLength)
        #expect(MusicChipLayout.fadeStart(naturalTitleWidth: 500) == start)
        #expect(MusicChipLayout.fadeLength > 0)
        #expect(MusicChipLayout.fadeLength <= 20)
    }

    @Test("a paused song draws at 0.6, a playing one at full strength")
    func contentAlpha() {
        #expect(MusicChipLayout.contentAlpha(isPlaying: true) == 1)
        #expect(MusicChipLayout.contentAlpha(isPlaying: false) == 0.6)
    }

    @Test("the chip shows the title, or the artist, or a plain phrase, on one line")
    func displayTitle() {
        #expect(MusicChipLayout.displayTitle(title: "  Night Drive ", artist: "Someone") == "Night Drive")
        #expect(MusicChipLayout.displayTitle(title: "", artist: "Someone") == "Someone")
        #expect(MusicChipLayout.displayTitle(title: "   ", artist: "  ") == "Now playing")
        #expect(MusicChipLayout.displayTitle(title: "Two\nLines\r\nHere", artist: "") == "Two Lines Here")
    }

    @Test("VoiceOver hears the item's name, the song and whether it plays")
    func accessibilityLabel() {
        #expect(MusicChipLayout.accessibilityLabel(title: "Night Drive", isPlaying: true) == "Deci Music, Night Drive, playing")
        #expect(MusicChipLayout.accessibilityLabel(title: "Night Drive", isPlaying: false) == "Deci Music, Night Drive, paused")
    }

    @Test("the chip needs the chip style, a visible Music item and a loaded song")
    func showsChip() {
        #expect(MusicChipLayout.showsChip(style: .chip, isMusicShown: true, hasTrack: true))
        #expect(!MusicChipLayout.showsChip(style: .icon, isMusicShown: true, hasTrack: true))
        #expect(!MusicChipLayout.showsChip(style: .chip, isMusicShown: false, hasTrack: true))
        #expect(!MusicChipLayout.showsChip(style: .chip, isMusicShown: true, hasTrack: false))
    }
}
