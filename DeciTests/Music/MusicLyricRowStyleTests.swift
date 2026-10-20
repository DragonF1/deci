// DeciTests/Music/MusicLyricRowStyleTests.swift
// How a lyric row looks for each place in the song: only the colour moves, never the font, so nothing reflows.

import SwiftUI
import Testing
@testable import Deci

@Suite("MusicLyricRowStyle")
struct MusicLyricRowStyleTests {

    private let positions: [MusicLyricPosition] = [.past, .current, .upcoming]

    private func style(_ position: MusicLyricPosition, hovered: Bool = false, ahead: Int = 1) -> MusicLyricRowStyle {
        MusicLyricRowStyle(position: position, isHovered: hovered, ahead: ahead)
    }

    // MARK: - Opacity

    @Test("Sung lines are dim, the next line is lit, the current line is nearly full")
    func opacityByPosition() {
        #expect(style(.past).opacity == 0.28)
        #expect(style(.upcoming, ahead: 1).opacity == 0.56)
        #expect(style(.current).opacity == 0.98)
    }

    @Test("The unsung part of the current line and its sung part use the spec's two levels")
    func currentLineLevels() {
        #expect(MusicLyricRowStyle.upcomingOpacity == 0.50)
        #expect(MusicLyricRowStyle.currentOpacity == 0.98)
    }

    @Test("The current line is the brightest, and a sung line is dimmer than the next one")
    func opacityOrder() {
        #expect(style(.past).opacity < style(.upcoming, ahead: 1).opacity)
        #expect(style(.upcoming, ahead: 1).opacity < style(.current).opacity)
    }

    @Test("The lines after the current one fade by 0.09 each: 0.56, 0.47, 0.38, 0.29, 0.20")
    func aheadRamp() {
        let expected = [0.56, 0.47, 0.38, 0.29, 0.20]
        for (offset, value) in expected.enumerated() {
            #expect(abs(MusicLyricRowStyle.aheadOpacity(offset + 1) - value) < 0.0001)
        }
    }

    @Test("The fade stops at a floor of 0.16, however far ahead a line is")
    func aheadFloor() {
        #expect(abs(MusicLyricRowStyle.aheadOpacity(6) - 0.16) < 0.0001)
        #expect(MusicLyricRowStyle.aheadOpacity(40) == 0.16)
        #expect(MusicLyricRowStyle.aheadOpacity(Int.max) == 0.16)
    }

    @Test("A distance below one counts as the next line, and the fade only ever gets dimmer")
    func aheadClampsAndDescends() {
        #expect(MusicLyricRowStyle.aheadOpacity(0) == MusicLyricRowStyle.aheadOpacity(1))
        #expect(MusicLyricRowStyle.aheadOpacity(-3) == MusicLyricRowStyle.aheadOpacity(1))
        var last = MusicLyricRowStyle.aheadOpacity(1)
        for distance in 2...12 {
            let value = MusicLyricRowStyle.aheadOpacity(distance)
            #expect(value <= last)
            last = value
        }
    }

    @Test("A row's place in the fade follows how far ahead of the current line it is")
    func rowUsesItsDistance() {
        #expect(style(.upcoming, ahead: 3).opacity == MusicLyricRowStyle.aheadOpacity(3))
        #expect(style(.upcoming, ahead: 9).opacity == MusicLyricRowStyle.aheadFloorOpacity)
        // The distance means nothing to a sung or a current row.
        #expect(style(.past, ahead: 4).opacity == style(.past, ahead: 0).opacity)
        #expect(style(.current, ahead: 4).opacity == style(.current, ahead: 0).opacity)
    }

    @Test("The distance ahead is 0 for sung and current lines and counts up from 1 after the current one")
    func aheadOfIndex() {
        #expect(MusicLyricRowStyle.ahead(of: 0, current: 2) == 0)
        #expect(MusicLyricRowStyle.ahead(of: 2, current: 2) == 0)
        #expect(MusicLyricRowStyle.ahead(of: 3, current: 2) == 1)
        #expect(MusicLyricRowStyle.ahead(of: 7, current: 2) == 5)
    }

    @Test("Before the first line starts the first line is the next one")
    func aheadWithNoCurrentLine() {
        #expect(MusicLyricRowStyle.ahead(of: 0, current: nil) == 1)
        #expect(MusicLyricRowStyle.ahead(of: 4, current: nil) == 5)
    }

    @Test("A line far ahead counts as the floor distance, where the fade has already stopped")
    func aheadIsCapped() {
        let cap = MusicLyricRowStyle.aheadFloorDistance
        #expect(MusicLyricRowStyle.ahead(of: 40, current: 2) == cap)
        #expect(MusicLyricRowStyle.ahead(of: 90, current: nil) == cap)
        #expect(MusicLyricRowStyle.aheadOpacity(cap) == MusicLyricRowStyle.aheadFloorOpacity)
        #expect(MusicLyricRowStyle.aheadOpacity(cap - 1) > MusicLyricRowStyle.aheadFloorOpacity)
    }

    @Test("The colour is the primary text colour at that opacity, so a light appearance still works")
    func colourFromPrimary() {
        for position in positions {
            let value = style(position)
            #expect(value.color == DesignTokens.Colors.textPrimary.opacity(value.opacity))
        }
    }

    @Test("Hovering a line that is not current brightens it toward the current colour, but never past it")
    func hoverBrightens() {
        for position in [MusicLyricPosition.past, .upcoming] {
            let resting = style(position).opacity
            let hovered = style(position, hovered: true).opacity
            #expect(hovered > resting)
            #expect(hovered < style(.current).opacity)
        }
    }

    @Test("A hovered far line stays dimmer than a hovered near one")
    func hoverKeepsOrder() {
        #expect(style(.upcoming, hovered: true, ahead: 8).opacity < style(.upcoming, hovered: true, ahead: 1).opacity)
    }

    @Test("Hovering the current line changes nothing: it is already full")
    func hoverOnCurrent() {
        #expect(style(.current, hovered: true).opacity == style(.current).opacity)
    }

    @Test("Every opacity is a real opacity, whatever the position or hover")
    func opacitiesInRange() {
        for position in positions {
            for hovered in [false, true] {
                let value = style(position, hovered: hovered).opacity
                #expect(value > 0 && value <= 1)
            }
        }
    }

    // MARK: - Font

    @Test("Every position and hover state uses one font: no weight or size difference, so nothing reflows")
    func oneFontForAll() {
        var sizes = Set<CGFloat>()
        var weights = Set<Font.Weight>()
        var fonts = Set<Font>()
        for position in positions {
            for hovered in [false, true] {
                let value = style(position, hovered: hovered)
                sizes.insert(value.fontSize)
                weights.insert(value.fontWeight)
                fonts.insert(value.font)
            }
        }
        #expect(sizes.count == 1)
        #expect(weights.count == 1)
        #expect(fonts.count == 1)
    }

    @Test("The font is semibold and 17 points, the spec's size for the lines around the current one")
    func fontIsSemiboldSeventeen() {
        let value = style(.current)
        #expect(value.fontSize == 17)
        #expect(value.fontWeight == .semibold)
        #expect(value.font == Font.system(size: 17, weight: .semibold))
    }

    @Test("Rows have 7 points above and below, so two rows are 14 points apart, with a little room between wrapped lines")
    func spacing() {
        #expect(MusicLyricRowStyle.verticalPadding * 2 == 14)
        #expect(MusicLyricRowStyle.lineSpacing == 3)
    }

    // MARK: - Text

    @Test("An empty timed line is an instrumental gap: shown as a note, spoken as a break")
    func gapLine() {
        #expect(MusicLyricRowStyle.shownText("") == "\u{266A}")
        #expect(MusicLyricRowStyle.spokenText("") == "Instrumental break")
    }

    @Test("A line with words is shown and spoken as it is")
    func wordsLine() {
        #expect(MusicLyricRowStyle.shownText("Synthetic line one") == "Synthetic line one")
        #expect(MusicLyricRowStyle.spokenText("Synthetic line one") == "Synthetic line one")
    }

    @Test("A line that is already a note is a normal line, and follows the same colour rules")
    func noteLine() {
        #expect(MusicLyricRowStyle.shownText("\u{266A}") == "\u{266A}")
        #expect(MusicLyricRowStyle.spokenText("\u{266A}") == "\u{266A}")
    }

    // MARK: - Position

    @Test("With no current line yet every line is still to come")
    func noCurrentLine() {
        for index in 0..<4 {
            #expect(MusicLyricRowStyle.position(of: index, current: nil) == .upcoming)
        }
    }

    @Test("Lines before the current one are sung, the current one is current, the rest are to come")
    func positionAroundCurrent() {
        #expect(MusicLyricRowStyle.position(of: 0, current: 2) == .past)
        #expect(MusicLyricRowStyle.position(of: 1, current: 2) == .past)
        #expect(MusicLyricRowStyle.position(of: 2, current: 2) == .current)
        #expect(MusicLyricRowStyle.position(of: 3, current: 2) == .upcoming)
        #expect(MusicLyricRowStyle.position(of: 9, current: 2) == .upcoming)
    }

    @Test("The first line is current at index 0, and has nothing sung before it")
    func firstLineCurrent() {
        #expect(MusicLyricRowStyle.position(of: 0, current: 0) == .current)
        #expect(MusicLyricRowStyle.position(of: 1, current: 0) == .upcoming)
    }

    // MARK: - Scroll

    @Test("The current line sits about a third of the way down, not in the middle")
    func anchorIsAboutAThird() {
        #expect(abs(MusicLyricScroll.anchorFraction - 1.0 / 3.0) < 0.0001)
        #expect(MusicLyricScroll.anchor.y == MusicLyricScroll.anchorFraction)
    }

    @Test("The glide is one long gentle curve of about half a second")
    func glideLength() {
        #expect((0.5...0.6).contains(MusicLyricScroll.glideDuration))
    }

    @Test("The colour fade is quick next to the glide, so the two never feel tangled")
    func fadeIsShorterThanGlide() {
        #expect((0.25...0.35).contains(MusicLyricRowStyle.colorFadeDuration))
        #expect(MusicLyricRowStyle.colorFadeDuration < MusicLyricScroll.glideDuration)
    }
}
