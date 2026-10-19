// DeciTests/Music/MusicPopupMetricsTests.swift
// The Music popup keeps the size it had as a tab of the one popup: a 32 pt header row with the
// gear, then a body capped at 520 pt. These pins catch an accidental resize.

import CoreGraphics
import Testing
@testable import Deci

@Suite("MusicPopupMetrics")
struct MusicPopupMetricsTests {
    @Test("the header row is 32 pt, as tall as the old Mixer and Music pill row")
    func headerHeight() {
        #expect(MusicPopupMetrics.headerHeight == 32)
    }

    @Test("the body is 520 pt at every popup size", arguments: MenuBarPopupSize.allCases)
    func bodyHeightAtEverySize(size: MenuBarPopupSize) {
        #expect(MusicPopupMetrics.bodyHeight(maxContentHeight: size.dimensions.maxContentHeight) == 520)
    }

    @Test("the body never grows past 520 pt on a tall popup")
    func bodyCappedAtTheTop() {
        #expect(MusicPopupMetrics.bodyHeight(maxContentHeight: 2000) == 520)
    }

    @Test("a popup limit of exactly 520 pt gives 520 pt")
    func bodyAtTheBoundary() {
        #expect(MusicPopupMetrics.bodyHeight(maxContentHeight: 520) == 520)
    }

    @Test("a popup limit below 520 pt wins, so a small screen is never overrun")
    func bodyFollowsSmallerLimit() {
        #expect(MusicPopupMetrics.bodyHeight(maxContentHeight: 400) == 400)
    }
}
