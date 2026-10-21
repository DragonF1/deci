// DeciTests/Music/MusicViewCountFormatTests.swift
// The view count under the player column's spectrum: YouTube's short form ("1.2M"), the label around it, the full
// number for the tooltip, and the check that the widest common row still fits the column.

import AppKit
import Testing
@testable import Deci

@MainActor
@Suite("MusicViewCountFormat")
struct MusicViewCountFormatTests {
    @Test("counts abbreviate the way YouTube writes them", arguments: [
        (0, "0"), (1, "1"), (999, "999"),
        (1_000, "1K"), (1_099, "1K"), (1_250, "1.2K"), (9_999, "9.9K"),
        (10_000, "10K"), (354_812, "354K"), (999_999, "999K"),
        (1_000_000, "1M"), (1_299_999, "1.2M"), (12_345_678, "12M"), (999_999_999, "999M"),
        (1_000_000_000, "1B"), (1_900_000_000, "1.9B"), (123_456_789_012, "123B"),
    ])
    func abbreviating(count: Int, expected: String) {
        #expect(MusicViewCountFormat.abbreviated(count) == expected)
    }

    @Test("an abbreviation truncates and never rounds up")
    func truncates() {
        #expect(MusicViewCountFormat.abbreviated(1_999) == "1.9K")
        #expect(MusicViewCountFormat.abbreviated(9_999_999) == "9.9M")
        #expect(MusicViewCountFormat.abbreviated(999_999_999_999) == "999B")
    }

    @Test("a negative count has no abbreviation")
    func negative() {
        #expect(MusicViewCountFormat.abbreviated(-1) == nil)
        #expect(MusicViewCountFormat.abbreviated(Int.min) == nil)
        #expect(MusicViewCountFormat.label(-5) == nil)
        #expect(MusicViewCountFormat.fullLabel(-5) == nil)
    }

    @Test("the label adds the word views, and one view is singular")
    func label() {
        #expect(MusicViewCountFormat.label(1_234_567) == "1.2M views")
        #expect(MusicViewCountFormat.label(999) == "999 views")
        #expect(MusicViewCountFormat.label(0) == "0 views")
        #expect(MusicViewCountFormat.label(1) == "1 view")
        #expect(MusicViewCountFormat.label(1_000) == "1K views")
    }

    @Test("an unknown count has no label")
    func unknown() {
        #expect(MusicViewCountFormat.label(nil) == nil)
        #expect(MusicViewCountFormat.fullLabel(nil) == nil)
    }

    @Test("the full label writes every digit, grouped by thousands")
    func fullLabel() {
        #expect(MusicViewCountFormat.fullLabel(1_234_567) == "1,234,567 views")
        #expect(MusicViewCountFormat.fullLabel(1_000) == "1,000 views")
        #expect(MusicViewCountFormat.fullLabel(999) == "999 views")
        #expect(MusicViewCountFormat.fullLabel(1) == "1 view")
        #expect(MusicViewCountFormat.fullLabel(0) == "0 views")
    }

    @Test("the common rows fit the column, and the times alone always do")
    func widthsAgainstTheColumn() {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let column = MusicPopupMetrics.playerColumnContentWidth
        let gap = MusicPopupMetrics.timesRowGap

        // An ordinary song: both times under ten minutes, the longest label.
        #expect(width("9:59 / 9:59") + gap + width("999K views") <= column)
        // A song past ten minutes is too wide for the long label, so it keeps the short count.
        #expect(width("12:34 / 45:59") + gap + width("1.2K views") > column)
        #expect(width("12:34 / 45:59") + gap + width("999K") <= column)
        // A song with an hour in it keeps the short count.
        #expect(width("1:02:03 / 1:23:45") + gap + width("999K") <= column)
        // The times alone fit even at their longest, so a row can always drop the count.
        #expect(width("10:00:00 / 10:00:00") <= column)
    }
}
