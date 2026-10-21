// DeciTests/Music/MusicChipLayoutTests.swift
// The Now playing chip in the menu bar: its measures, how wide the title's window is and when a title scrolls, and the
// words around it. Pure numbers, nothing is drawn.

import Foundation
import Testing
@testable import Deci

@Suite("Music chip layout")
struct MusicChipLayoutTests {
    /// A fixed 6 pt per character, so the widths in these tests are plain arithmetic.
    private let sixPerCharacter: (String) -> Double = { Double($0.count) * 6 }

    @Test("the chip is an 18 pt pill: 3 pt inset, 12 pt cover, 5 pt gap, 8 pt trailing inset")
    func metrics() {
        #expect(MusicChipLayout.height == 18)
        #expect(MusicChipLayout.cornerRadius == 9)
        #expect(MusicChipLayout.leadingInset == 3)
        #expect(MusicChipLayout.thumbnailSize == 12)
        #expect(MusicChipLayout.gap == 5)
        #expect(MusicChipLayout.trailingInset == 8)
        #expect(MusicChipLayout.titleFontSize == 12)
        #expect(MusicChipLayout.titleOriginX == 20)
    }

    @Test("the longest title that shows in full is 20 characters")
    func maxCharacters() {
        #expect(MusicChipLayout.maxCharacters == 20)
    }

    @Test("a short title makes a pill as wide as the title and its insets")
    func shortTitleGeometry() {
        let geometry = MusicChipLayout.geometry(title: "Night Drive", measure: sixPerCharacter)
        #expect(geometry.textWidth == 66)
        #expect(geometry.windowWidth == 66)
        #expect(geometry.pillWidth == 94)
        #expect(!geometry.scrolls)
    }

    @Test("a title of exactly the max shows in full and does not scroll")
    func titleAtTheMax() {
        let title = String(repeating: "a", count: MusicChipLayout.maxCharacters)
        let geometry = MusicChipLayout.geometry(title: title, measure: sixPerCharacter)
        #expect(geometry.windowWidth == 120)
        #expect(geometry.textWidth == 120)
        #expect(geometry.pillWidth == 148)
        #expect(!geometry.scrolls)
    }

    @Test("one character over the max gets a window as wide as the first 20 characters, and scrolls")
    func titleOverTheMax() {
        let title = String(repeating: "a", count: MusicChipLayout.maxCharacters + 1)
        let geometry = MusicChipLayout.geometry(title: title, measure: sixPerCharacter)
        #expect(geometry.windowWidth == 120)
        #expect(geometry.textWidth == 126)
        #expect(geometry.pillWidth == 148)
        #expect(geometry.scrolls)
    }

    @Test("the pill stops growing past the max: a very long title makes the same pill")
    func pillStopsGrowing() {
        let medium = MusicChipLayout.geometry(title: String(repeating: "a", count: 25), measure: sixPerCharacter)
        let huge = MusicChipLayout.geometry(title: String(repeating: "a", count: 5000), measure: sixPerCharacter)
        #expect(medium.pillWidth == huge.pillWidth)
        #expect(huge.textWidth == 30_000)
    }

    @Test("the window is measured on the first characters only, not on the whole title")
    func windowMeasuresThePrefix() {
        // A wide character costs 10, any other 5: the tail's wide characters must not widen the window.
        let measure: (String) -> Double = { text in text.reduce(0) { $0 + ($1 == "W" ? 10.0 : 5.0) } }
        let title = String(repeating: "a", count: 20) + "WWWW"
        let geometry = MusicChipLayout.geometry(title: title, measure: measure)
        #expect(geometry.windowWidth == 100)
        #expect(geometry.textWidth == 140)
        #expect(geometry.scrolls)
    }

    @Test("characters are counted as a reader sees them: an emoji family or a flag is one character")
    func countsGraphemes() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        #expect(family.count == 1)
        let fits = String(repeating: family, count: MusicChipLayout.maxCharacters)
        #expect(!MusicChipLayout.geometry(title: fits, measure: sixPerCharacter).scrolls)
        let over = String(repeating: family, count: MusicChipLayout.maxCharacters + 1)
        #expect(MusicChipLayout.geometry(title: over, measure: sixPerCharacter).scrolls)
    }

    @Test("widths are whole points, so the status item does not shimmer between two sizes")
    func wholePoints() {
        let geometry = MusicChipLayout.geometry(title: "x", measure: { _ in 40.2 })
        #expect(geometry.textWidth == 41)
        #expect(geometry.windowWidth == 41)
        #expect(geometry.pillWidth == 69)
        #expect(MusicChipLayout.geometry(title: "x", measure: { _ in 40.0 }).pillWidth == 68)
    }

    @Test("a title that cannot be measured leaves just the cover and the insets", arguments: [0.0, -5.0, .nan, .infinity])
    func unmeasurableWidth(natural: Double) {
        let geometry = MusicChipLayout.geometry(title: "x", measure: { _ in natural })
        #expect(geometry.pillWidth == 28)
        #expect(geometry.windowWidth == 0)
        #expect(!geometry.scrolls)
    }

    @Test("the pill is the inset, cover and gap, then the window, then the trailing inset")
    func pillWidth() {
        #expect(MusicChipLayout.pillWidth(windowWidth: 0) == 28)
        #expect(MusicChipLayout.pillWidth(windowWidth: 100) == 128)
        #expect(MusicChipLayout.pillWidth(windowWidth: 100.2) == 129)
        #expect(MusicChipLayout.pillWidth(windowWidth: .nan) == 28)
    }

    @Test("a title scrolls only when it has more characters than the max and its text is wider than the window")
    func scrollsRule() {
        #expect(MusicChipLayout.scrolls(characterCount: 21, textWidth: 130, windowWidth: 120))
        #expect(!MusicChipLayout.scrolls(characterCount: 20, textWidth: 130, windowWidth: 120))
        #expect(!MusicChipLayout.scrolls(characterCount: 5, textWidth: 30, windowWidth: 30))
        #expect(!MusicChipLayout.scrolls(characterCount: 40, textWidth: 120, windowWidth: 120))
        #expect(!MusicChipLayout.scrolls(characterCount: 40, textWidth: .nan, windowWidth: 120))
    }

    @Test("a paused song's cover and title are gone, a playing one's are at full strength")
    func contentAlpha() {
        #expect(MusicChipLayout.contentAlpha(isPlaying: true) == 1)
        #expect(MusicChipLayout.contentAlpha(isPlaying: false) == 0)
    }

    @Test("the play glyph shows only on a paused pill")
    func playGlyphAlpha() {
        #expect(MusicChipLayout.playGlyphAlpha(isPlaying: true) == 0)
        #expect(MusicChipLayout.playGlyphAlpha(isPlaying: false) == 1)
    }

    @Test("the paused pill is a small pill: wider than it is high, in whole points, narrower than any title's pill")
    func pausedPillWidth() {
        #expect(MusicChipLayout.pausedPillWidth == 34)
        #expect(MusicChipLayout.pausedPillWidth == MusicChipLayout.pausedPillWidth.rounded())
        #expect(MusicChipLayout.pausedPillWidth > MusicChipLayout.height)
        #expect(MusicChipLayout.pausedPillWidth < MusicChipLayout.height * 2.5)
    }

    @Test("the play glyph fits the paused pill, and is nudged right by less than a few points")
    func playGlyphFits() {
        #expect(MusicChipLayout.playGlyphSide <= MusicChipLayout.height)
        #expect(MusicChipLayout.playGlyphSide <= MusicChipLayout.pausedPillWidth)
        #expect(MusicChipLayout.playGlyphNudge > 0)
        #expect(MusicChipLayout.playGlyphNudge <= 2)
    }

    @Test("the pill is as wide as the title while it plays and the paused width while it does not")
    func shownPillWidth() {
        let geometry = MusicChipLayout.geometry(title: "Night Drive", measure: { Double($0.count) * 6 })
        #expect(MusicChipLayout.shownPillWidth(for: geometry, isPlaying: true) == geometry.pillWidth)
        #expect(MusicChipLayout.shownPillWidth(for: geometry, isPlaying: false) == MusicChipLayout.pausedPillWidth)
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

    @Test("VoiceOver hears the whole title, not the part that shows")
    func accessibilityLabelIsTheFullTitle() {
        let title = String(repeating: "long ", count: 30)
        #expect(MusicChipLayout.accessibilityLabel(title: title, isPlaying: true).contains(title))
    }

    @Test("the chip needs the chip style, a visible Music item and a loaded song")
    func showsChip() {
        #expect(MusicChipLayout.showsChip(style: .chip, isMusicShown: true, hasTrack: true))
        #expect(!MusicChipLayout.showsChip(style: .icon, isMusicShown: true, hasTrack: true))
        #expect(!MusicChipLayout.showsChip(style: .chip, isMusicShown: false, hasTrack: true))
        #expect(!MusicChipLayout.showsChip(style: .chip, isMusicShown: true, hasTrack: false))
    }
}
