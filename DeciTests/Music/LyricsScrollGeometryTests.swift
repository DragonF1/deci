// DeciTests/Music/LyricsScrollGeometryTests.swift
// Where the synced list has to scroll to put a line at the anchor, worked out from plain numbers: the row's place in the
// content, the visible height and the content height. The view reads those from the real scroll view.

import CoreGraphics
import Foundation
import Testing
@testable import Deci

@Suite("Lyrics scroll geometry")
struct LyricsScrollGeometryTests {

    private let third: CGFloat = 1.0 / 3.0

    private func target(
        top: CGFloat, height: CGFloat = 30, viewport: CGFloat = 300, content: CGFloat = 1_000, anchor: CGFloat? = nil
    ) -> CGFloat {
        LyricsScrollGeometry.targetOffset(
            rowTop: top, rowHeight: height, viewportHeight: viewport, contentHeight: content, anchor: anchor ?? third
        )
    }

    // MARK: - Target offset

    @Test("The row's anchor point lands on the visible area's anchor point")
    func anchorsMeet() {
        // The row's third (400 + 10) sits a third down the 300 point window (100), so the window starts at 310.
        #expect(abs(target(top: 400) - 310) < 0.0001)
    }

    @Test("A taller row is anchored by the same fraction of its own height")
    func tallRow() {
        #expect(abs(target(top: 400, height: 90) - 330) < 0.0001)
    }

    @Test("An anchor of 0 puts the row's top at the top, and 1 puts its bottom at the bottom")
    func anchorEnds() {
        #expect(abs(target(top: 400, anchor: 0) - 400) < 0.0001)
        #expect(abs(target(top: 400, anchor: 1) - (400 + 30 - 300)) < 0.0001)
    }

    @Test("An anchor outside 0 to 1 is held to the ends")
    func anchorIsClamped() {
        #expect(target(top: 400, anchor: -2) == target(top: 400, anchor: 0))
        #expect(target(top: 400, anchor: 7) == target(top: 400, anchor: 1))
        #expect(target(top: 400, anchor: .nan) == 0)
    }

    @Test("Near the start the list cannot scroll above its first point")
    func clampsAtTheTop() {
        #expect(target(top: 20) == 0)
        #expect(target(top: -500) == 0)
    }

    @Test("Near the end the list cannot scroll past its last point")
    func clampsAtTheBottom() {
        #expect(target(top: 950) == 700)
        #expect(target(top: 5_000) == 700)
    }

    @Test("Content shorter than the visible area does not scroll at all")
    func shortContent() {
        #expect(target(top: 100, viewport: 300, content: 200) == 0)
        #expect(target(top: 100, viewport: 300, content: 300) == 0)
    }

    @Test("A bad number anywhere leaves the list at the top")
    func badInput() {
        #expect(target(top: .nan) == 0)
        #expect(target(top: .infinity) == 0)
        #expect(target(top: 400, height: .nan) == 0)
        #expect(target(top: 400, viewport: .nan) == 0)
        #expect(target(top: 400, content: .infinity) == 0)
        #expect(target(top: 400, viewport: -50) == 0)
        #expect(target(top: 400, content: -50) == 0)
    }

    @Test("A row with a negative height is taken as no height")
    func negativeHeight() {
        #expect(target(top: 400, height: -40) == target(top: 400, height: 0))
    }

    @Test("With a spacer a third of the window above and two thirds below, the first and the last line both reach the anchor")
    func firstAndLastReachTheAnchor() {
        let window: CGFloat = 300
        let rows = 10
        let rowHeight: CGFloat = 30
        let spacerTop = window * third
        let spacerBottom = window * (1 - third)
        let content = spacerTop + CGFloat(rows) * rowHeight + spacerBottom
        let first = LyricsScrollGeometry.targetOffset(
            rowTop: spacerTop, rowHeight: rowHeight, viewportHeight: window, contentHeight: content, anchor: third
        )
        let lastTop = spacerTop + CGFloat(rows - 1) * rowHeight
        let last = LyricsScrollGeometry.targetOffset(
            rowTop: lastTop, rowHeight: rowHeight, viewportHeight: window, contentHeight: content, anchor: third
        )
        // Neither is held back by an end: the offset is what the anchor asks for.
        #expect(abs(first - rowHeight * third) < 0.0001)
        #expect(first > 0)
        #expect(abs(last - (lastTop + rowHeight * third - window * third)) < 0.0001)
        #expect(last < content - window)
    }

    @Test("Lines further down always ask for an offset at least as far down")
    func monotonic() {
        var previous: CGFloat = -1
        for step in 0..<60 {
            let value = target(top: CGFloat(step) * 40, height: 35, content: 2_600)
            #expect(value >= previous)
            previous = value
        }
    }

    // MARK: - Bounds origin

    @Test("In a flipped document (the top is zero) the origin is the offset")
    func flippedOrigin() {
        #expect(LyricsScrollGeometry.boundsOriginY(forOffset: 310, contentHeight: 1_000, viewportHeight: 300, isFlipped: true) == 310)
        #expect(LyricsScrollGeometry.boundsOriginY(forOffset: 0, contentHeight: 1_000, viewportHeight: 300, isFlipped: true) == 0)
    }

    @Test("In an unflipped document (the bottom is zero) the origin counts up from the bottom")
    func unflippedOrigin() {
        // Scrolled to the very top of a 1000 point document in a 300 point window: the window's bottom is at 700.
        #expect(LyricsScrollGeometry.boundsOriginY(forOffset: 0, contentHeight: 1_000, viewportHeight: 300, isFlipped: false) == 700)
        #expect(LyricsScrollGeometry.boundsOriginY(forOffset: 310, contentHeight: 1_000, viewportHeight: 300, isFlipped: false) == 390)
        #expect(LyricsScrollGeometry.boundsOriginY(forOffset: 700, contentHeight: 1_000, viewportHeight: 300, isFlipped: false) == 0)
    }

    @Test("An offset past either end is held to it, flipped or not")
    func originIsClamped() {
        for flipped in [true, false] {
            let low = LyricsScrollGeometry.boundsOriginY(forOffset: -90, contentHeight: 1_000, viewportHeight: 300, isFlipped: flipped)
            let high = LyricsScrollGeometry.boundsOriginY(forOffset: 9_000, contentHeight: 1_000, viewportHeight: 300, isFlipped: flipped)
            #expect((0...700).contains(low))
            #expect((0...700).contains(high))
        }
        #expect(LyricsScrollGeometry.boundsOriginY(forOffset: -90, contentHeight: 1_000, viewportHeight: 300, isFlipped: true) == 0)
        #expect(LyricsScrollGeometry.boundsOriginY(forOffset: 9_000, contentHeight: 1_000, viewportHeight: 300, isFlipped: true) == 700)
    }

    @Test("Content shorter than the window has its origin at zero, flipped or not")
    func shortOrigin() {
        for flipped in [true, false] {
            #expect(LyricsScrollGeometry.boundsOriginY(forOffset: 50, contentHeight: 200, viewportHeight: 300, isFlipped: flipped) == 0)
        }
    }

    @Test("A bad number gives an origin of zero")
    func badOrigin() {
        #expect(LyricsScrollGeometry.boundsOriginY(forOffset: .nan, contentHeight: 1_000, viewportHeight: 300, isFlipped: true) == 0)
        #expect(LyricsScrollGeometry.boundsOriginY(forOffset: 10, contentHeight: .nan, viewportHeight: 300, isFlipped: false) == 0)
        #expect(LyricsScrollGeometry.boundsOriginY(forOffset: 10, contentHeight: 1_000, viewportHeight: .infinity, isFlipped: true) == 0)
    }

    // MARK: - Already there

    @Test("A move of under half a point is not worth a glide")
    func alreadyThere() {
        #expect(LyricsScrollGeometry.isAtTarget(current: 100, target: 100))
        #expect(LyricsScrollGeometry.isAtTarget(current: 100, target: 100.4))
        #expect(!LyricsScrollGeometry.isAtTarget(current: 100, target: 100.6))
        #expect(!LyricsScrollGeometry.isAtTarget(current: 100, target: 40))
        #expect(!LyricsScrollGeometry.isAtTarget(current: .nan, target: 40))
    }
}
