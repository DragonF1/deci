// DeciTests/Music/MusicLyricRowStyleTests.swift
// How a lyric row looks for each place in the song: only the colour moves, never the font, so nothing reflows.

import SwiftUI
import Testing
@testable import Deci

@Suite("MusicLyricRowStyle")
struct MusicLyricRowStyleTests {

    private let positions: [MusicLyricPosition] = [.past, .current, .upcoming]

    private func style(_ position: MusicLyricPosition, hovered: Bool = false) -> MusicLyricRowStyle {
        MusicLyricRowStyle(position: position, isHovered: hovered)
    }

    // MARK: - Opacity

    @Test("Upcoming lines are dim, sung lines are lit, the current line is full")
    func opacityByPosition() {
        #expect(style(.upcoming).opacity == 0.35)
        #expect(style(.past).opacity == 0.65)
        #expect(style(.current).opacity == 1)
    }

    @Test("Sung lines stay brighter than upcoming ones, and the current line is the brightest")
    func opacityOrder() {
        #expect(style(.upcoming).opacity < style(.past).opacity)
        #expect(style(.past).opacity < style(.current).opacity)
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

    @Test("A hovered upcoming line stays dimmer than a hovered sung one")
    func hoverKeepsOrder() {
        #expect(style(.upcoming, hovered: true).opacity < style(.past, hovered: true).opacity)
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

    @Test("The font is bold and 17 points, inside the 16 to 18 that fits the popover")
    func fontIsBoldSeventeen() {
        let value = style(.current)
        #expect(value.fontSize == 17)
        #expect((16...18).contains(value.fontSize))
        #expect(value.fontWeight == .bold)
        #expect(value.font == Font.system(size: 17, weight: .bold))
    }

    @Test("Rows have 7 points above and below, so two rows are 14 points apart, with a little room between wrapped lines")
    func spacing() {
        #expect(MusicLyricRowStyle.verticalPadding * 2 == 14)
        #expect(MusicLyricRowStyle.lineSpacing > 0)
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
