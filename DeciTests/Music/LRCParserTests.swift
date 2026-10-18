// DeciTests/Music/LRCParserTests.swift
// The LRC parser and the current-line lookup. Fixtures are made-up lines only.

import Foundation
import Testing
@testable import Deci

@Suite("LRC parser")
struct LRCParserTests {

    private func texts(_ lines: [LyricLine]) -> [String] { lines.map(\.text) }
    private func times(_ lines: [LyricLine]) -> [TimeInterval] { lines.map(\.time) }

    // MARK: - Timestamps

    @Test("Parses [mm:ss.xx], [mm:ss.xxx] and [m:ss]")
    func timestampForms() {
        let lines = LRCParser.parse("""
        [00:12.34]Hundredths
        [01:02.345]Thousandths
        [3:04]No fraction
        """)
        #expect(texts(lines) == ["Hundredths", "Thousandths", "No fraction"])
        #expect(abs(lines[0].time - 12.34) < 0.0001)
        #expect(abs(lines[1].time - 62.345) < 0.0001)
        #expect(lines[2].time == 184)
    }

    @Test("A fraction is a decimal: .5 is half a second, .05 is five hundredths")
    func fractionIsDecimal() {
        let lines = LRCParser.parse("[00:01.5]a\n[00:02.05]b\n[00:03.050]c")
        #expect(abs(lines[0].time - 1.5) < 0.0001)
        #expect(abs(lines[1].time - 2.05) < 0.0001)
        #expect(abs(lines[2].time - 3.05) < 0.0001)
    }

    @Test("Minutes past 59 are fine (a long track)")
    func longMinutes() {
        let lines = LRCParser.parse("[75:30.00]Late line")
        #expect(lines.first?.time == 4530)
    }

    @Test("Several timestamps on one line give one entry per timestamp, in time order")
    func repeatedTimestamps() {
        let lines = LRCParser.parse("""
        [00:10.00][00:30.00]Repeated line
        [00:20.00]Middle line
        """)
        #expect(texts(lines) == ["Repeated line", "Middle line", "Repeated line"])
        #expect(times(lines) == [10, 20, 30])
    }

    // MARK: - Offset

    @Test("A positive [offset:] makes the lyrics come sooner, a negative one later")
    func offsetIsApplied() {
        let sooner = LRCParser.parse("[offset:+500]\n[00:10.00]Line")
        #expect(abs((sooner.first?.time ?? 0) - 9.5) < 0.0001)
        let later = LRCParser.parse("[offset:-250]\n[00:10.00]Line")
        #expect(abs((later.first?.time ?? 0) - 10.25) < 0.0001)
    }

    @Test("The offset applies to lines above it too, and tolerates spaces")
    func offsetAppliesToEveryLine() {
        let lines = LRCParser.parse("[00:10.00]Before\n[offset: +1000 ]\n[00:20.00]After")
        #expect(times(lines) == [9, 19])
    }

    @Test("An offset never pushes a line before zero")
    func offsetClampsAtZero() {
        let lines = LRCParser.parse("[offset:+5000]\n[00:02.00]Early line")
        #expect(lines.first?.time == 0)
    }

    @Test("A broken offset is ignored")
    func brokenOffset() {
        let lines = LRCParser.parse("[offset:soon]\n[00:10.00]Line")
        #expect(lines.first?.time == 10)
    }

    // MARK: - Metadata, gaps, junk

    @Test("Metadata tags are not lyrics")
    func metadataIgnored() {
        let lines = LRCParser.parse("""
        [ar:Test Artist]
        [ti:Test Song]
        [al:Test Album]
        [by:Someone]
        [length:03:21]
        [re:Some Tool]
        [ve:1.0]
        [au:Writer]
        [id:abc]
        [00:05.00]Only line
        """)
        #expect(texts(lines) == ["Only line"])
    }

    @Test("An empty timed line is kept as a gap with empty text")
    func emptyTimedLinesAreGaps() {
        let lines = LRCParser.parse("[00:05.00]First test line\n[00:09.00]\n[00:12.00]   \n[00:15.00]Second test line")
        #expect(texts(lines) == ["First test line", "", "", "Second test line"])
        #expect(times(lines) == [5, 9, 12, 15])
    }

    @Test("Lines are sorted by time, equal times keep file order")
    func sortedAndStable() {
        let lines = LRCParser.parse("""
        [00:20.00]Third
        [00:10.00]First
        [00:10.00]Second
        """)
        #expect(texts(lines) == ["First", "Second", "Third"])
    }

    @Test("Malformed lines are skipped without stopping the parse")
    func malformedSkipped() {
        let lines = LRCParser.parse("""
        no timestamp at all
        [Chorus]
        [ab:cd.ef]Letters
        [00:xx]Half a time
        [00:75.00]Seconds past 59
        [00:10.00 Unterminated
        [-1:10.00]Negative minutes
        [00:20.00]Good line
        """)
        #expect(texts(lines) == ["Good line"])
    }

    @Test("Text keeps its own brackets, and is trimmed")
    func textKeepsBrackets() {
        let lines = LRCParser.parse("[00:05.00]   Hello [world] (again)   ")
        #expect(texts(lines) == ["Hello [world] (again)"])
    }

    @Test("Word-level <mm:ss.xx> tags are removed from the text")
    func wordTagsStripped() {
        let lines = LRCParser.parse("[00:05.00]<00:05.00>Made <00:05.40>up <00:05.80>words")
        #expect(texts(lines) == ["Made up words"])
    }

    @Test("Unicode and emoji survive")
    func unicode() {
        let lines = LRCParser.parse("[00:01.00]Ça va très bien 🎵\n[00:02.00]日本語のテスト")
        #expect(texts(lines) == ["Ça va très bien 🎵", "日本語のテスト"])
    }

    // MARK: - Input shapes

    @Test("CRLF, CR and LF line endings all split lines")
    func lineEndings() {
        #expect(texts(LRCParser.parse("[00:01.00]a\r\n[00:02.00]b\r\n")) == ["a", "b"])
        #expect(texts(LRCParser.parse("[00:01.00]a\r[00:02.00]b")) == ["a", "b"])
        #expect(texts(LRCParser.parse("[00:01.00]a\n\n\n[00:02.00]b")) == ["a", "b"])
    }

    @Test("A byte-order mark in front of the first tag is ignored")
    func byteOrderMark() {
        #expect(texts(LRCParser.parse("\u{FEFF}[00:01.00]First test line")) == ["First test line"])
    }

    @Test("Empty and whitespace input give no lines")
    func emptyInput() {
        #expect(LRCParser.parse("").isEmpty)
        #expect(LRCParser.parse("  \n \n").isEmpty)
        #expect(LRCParser.parse("[ar:Only metadata]").isEmpty)
    }

    @Test("The shared sample parses to the expected lines")
    func sampleFile() {
        #expect(LRCParser.parse(LyricsSamples.synced) == LyricsSamples.syncedLines)
    }

    @Test("10 000 lines parse sorted and complete")
    func largeInput() {
        let body = (0..<10_000).reversed().map { index in
            String(format: "[%02d:%02d.00]Line %d", index / 60 % 100, index % 60, index)
        }.joined(separator: "\n")
        let lines = LRCParser.parse(body)
        #expect(lines.count == 10_000)
        #expect(zip(lines, lines.dropFirst()).allSatisfy { $0.time <= $1.time })
    }

    @Test("The number of sung lines ignores gaps")
    func sungLineCount() {
        let lines = LRCParser.parse("[00:01.00]a\n[00:02.00]\n[00:03.00]b")
        #expect(LRCParser.sungLineCount(lines) == 2)
        #expect(LRCParser.sungLineCount([]) == 0)
    }
}

@Suite("Current lyric line")
struct LyricsCurrentIndexTests {

    private let lines = [
        LyricLine(time: 5, text: "a"),
        LyricLine(time: 10, text: "b"),
        LyricLine(time: 20, text: "c"),
    ]

    @Test("No lines, or a time before the first line, has no current line")
    func noCurrentLine() {
        #expect(LRCParser.currentIndex(in: [], at: 3) == nil)
        #expect(LRCParser.currentIndex(in: lines, at: 0) == nil)
        #expect(LRCParser.currentIndex(in: lines, at: 4.999) == nil)
    }

    @Test("A line becomes current exactly at its time")
    func atTheBoundary() {
        #expect(LRCParser.currentIndex(in: lines, at: 5) == 0)
        #expect(LRCParser.currentIndex(in: lines, at: 9.999) == 0)
        #expect(LRCParser.currentIndex(in: lines, at: 10) == 1)
        #expect(LRCParser.currentIndex(in: lines, at: 19.5) == 1)
    }

    @Test("After the last line the last one stays current")
    func afterTheEnd() {
        #expect(LRCParser.currentIndex(in: lines, at: 20) == 2)
        #expect(LRCParser.currentIndex(in: lines, at: 9_999) == 2)
    }

    @Test("Lines sharing a time: the last of them is current")
    func equalTimes() {
        let tied = [LyricLine(time: 5, text: "a"), LyricLine(time: 5, text: "b"), LyricLine(time: 8, text: "c")]
        #expect(LRCParser.currentIndex(in: tied, at: 5) == 1)
        #expect(LRCParser.currentIndex(in: tied, at: 7) == 1)
    }

    @Test("Non-finite times have no current line")
    func nonFinite() {
        #expect(LRCParser.currentIndex(in: lines, at: .nan) == nil)
        #expect(LRCParser.currentIndex(in: lines, at: -.infinity) == nil)
    }

    @Test("Binary search agrees with a linear scan on a big list")
    func matchesLinearScan() {
        let big = (0..<5_000).map { LyricLine(time: Double($0) * 1.7, text: "Line \($0)") }
        for probe in stride(from: -3.0, through: 8_600.0, by: 13.37) {
            let expected = big.lastIndex { $0.time <= probe }
            #expect(LRCParser.currentIndex(in: big, at: probe) == expected)
        }
    }
}
