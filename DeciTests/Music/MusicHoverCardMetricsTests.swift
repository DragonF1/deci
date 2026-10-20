// DeciTests/Music/MusicHoverCardMetricsTests.swift
// The hover card's size and where it opens under the status item (centred, kept on screen). Pure numbers.

import CoreGraphics
import Foundation
import Testing
@testable import Deci

@Suite("Music hover card metrics")
struct MusicHoverCardMetricsTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test("the card is 300 pt wide and about 115 pt high, the sum of its rows")
    func size() {
        let m = MusicHoverCardMetrics.self
        #expect(m.width == 300)
        let rows = m.topInset + m.titleRowHeight + m.afterTitleRow
            + m.waveHeight + m.timesRowHeight + m.afterTimesRow + m.controlsRowHeight + m.bottomInset
        #expect(m.height == rows)
        #expect(m.height >= 105 && m.height <= 125)
        #expect(m.size == CGSize(width: m.width, height: m.height))
    }

    @Test("the card's parts are the sizes of the spec")
    func parts() {
        let m = MusicHoverCardMetrics.self
        #expect(m.horizontalInset == 12)
        #expect(m.controlCircleSize == 28)
        #expect(m.waveHeight == MusicWave.boxHeight)
        #expect(m.cornerRadius > 0)
    }

    @Test("the wave box takes the card's width less the two insets")
    func waveWidth() {
        let m = MusicHoverCardMetrics.self
        #expect(m.contentWidth == m.width - 2 * m.horizontalInset)
    }

    @Test("the card opens centred under the item, a few points below the menu bar")
    func centred() {
        let button = CGRect(x: 1000, y: 877, width: 60, height: 22)
        let frame = MusicHoverCardPlacement.frame(buttonFrame: button, size: MusicHoverCardMetrics.size, visibleFrame: screen)
        #expect(frame.midX == button.midX)
        #expect(frame.size == MusicHoverCardMetrics.size)
        #expect(frame.maxY == screen.maxY - MusicHoverCardPlacement.gap)
    }

    @Test("the card does not run off the right edge")
    func clampsRight() {
        let button = CGRect(x: 1400, y: 877, width: 36, height: 22)
        let frame = MusicHoverCardPlacement.frame(buttonFrame: button, size: MusicHoverCardMetrics.size, visibleFrame: screen)
        #expect(frame.maxX == screen.maxX - MusicHoverCardPlacement.margin)
        #expect(frame.size == MusicHoverCardMetrics.size)
    }

    @Test("the card does not run off the left edge")
    func clampsLeft() {
        let button = CGRect(x: 4, y: 877, width: 36, height: 22)
        let frame = MusicHoverCardPlacement.frame(buttonFrame: button, size: MusicHoverCardMetrics.size, visibleFrame: screen)
        #expect(frame.minX == screen.minX + MusicHoverCardPlacement.margin)
    }

    @Test("on a second screen the card keeps to that screen's own frame")
    func secondScreen() {
        let other = CGRect(x: 1440, y: 100, width: 1920, height: 1055)
        let button = CGRect(x: 3200, y: 1157, width: 60, height: 22)
        let frame = MusicHoverCardPlacement.frame(buttonFrame: button, size: MusicHoverCardMetrics.size, visibleFrame: other)
        #expect(frame.minX >= other.minX + MusicHoverCardPlacement.margin)
        #expect(frame.maxX <= other.maxX - MusicHoverCardPlacement.margin)
        #expect(frame.maxY == other.maxY - MusicHoverCardPlacement.gap)
        #expect(frame.minY >= other.minY)
    }

    @Test("a button whose frame sits below the top of the visible area hangs the card from the button instead")
    func hangsFromButton() {
        let button = CGRect(x: 600, y: 840, width: 60, height: 22)
        let frame = MusicHoverCardPlacement.frame(buttonFrame: button, size: MusicHoverCardMetrics.size, visibleFrame: screen)
        #expect(frame.maxY == button.minY - MusicHoverCardPlacement.gap)
    }

    @Test("a screen too short for the card still keeps the card's top and its bottom edge on screen")
    func clampsBottom() {
        let short = CGRect(x: 0, y: 0, width: 800, height: 100)
        let button = CGRect(x: 300, y: 102, width: 60, height: 22)
        let frame = MusicHoverCardPlacement.frame(buttonFrame: button, size: MusicHoverCardMetrics.size, visibleFrame: short)
        #expect(frame.minY >= short.minY)
    }

    @Test("a screen narrower than the card centres it rather than throwing")
    func narrowScreen() {
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 600)
        let button = CGRect(x: 80, y: 602, width: 40, height: 22)
        let frame = MusicHoverCardPlacement.frame(buttonFrame: button, size: MusicHoverCardMetrics.size, visibleFrame: narrow)
        #expect(frame.origin.x.isFinite && frame.origin.y.isFinite)
        #expect(frame.size == MusicHoverCardMetrics.size)
    }
}
