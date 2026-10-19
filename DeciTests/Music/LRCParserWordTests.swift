// DeciTests/Music/LRCParserWordTests.swift
// Enhanced LRC: "<mm:ss.xx>" tags inside a line become real word timings, and never show as text. Fixtures are
// made-up lines only.

import Foundation
import Testing
@testable import Deci

@Suite("LRC parser: word timing")
struct LRCParserWordTests {

    private func first(_ text: String) -> LyricLine? { LRCParser.parse(text).first }

    private func close(_ a: TimeInterval?, _ b: TimeInterval) -> Bool { abs((a ?? .nan) - b) < 0.0001 }

    @Test("A tag in front of each word gives that word its start, with the spacing kept on the word")
    func tagPerWord() {
        let line = first("[00:05.00]<00:05.00>Made <00:05.40>up <00:05.80>words")
        #expect(line?.text == "Made up words")
        #expect(line?.words == [
            LyricWord(time: 5.0, text: "Made "),
            LyricWord(time: 5.4, text: "up "),
            LyricWord(time: 5.8, text: "words"),
        ])
        #expect(line?.end == nil)
    }

    @Test("A tag after the last word is where the line ends")
    func trailingTagIsTheEnd() {
        let line = first("[00:05.00]<00:05.00>Made <00:05.40>up <00:06.20>")
        #expect(line?.text == "Made up")
        #expect(line?.words == [LyricWord(time: 5.0, text: "Made "), LyricWord(time: 5.4, text: "up")])
        #expect(close(line?.end, 6.2))
    }

    @Test("Text before the first tag starts with the line")
    func untaggedStart() {
        let line = first("[00:05.00]Made <00:05.40>up")
        #expect(line?.text == "Made up")
        #expect(line?.words == [LyricWord(time: 5.0, text: "Made "), LyricWord(time: 5.4, text: "up")])
    }

    @Test("A tag with only spacing after it joins the word before it")
    func spacingOnlySegment() {
        let line = first("[00:05.00]<00:05.00>Made<00:05.40> <00:05.50>up")
        #expect(line?.text == "Made up")
        #expect(line?.words == [LyricWord(time: 5.0, text: "Made "), LyricWord(time: 5.5, text: "up")])
    }

    @Test("A tag can cover more than one word")
    func tagCoversSeveralWords() {
        let line = first("[00:05.00]<00:05.00>Made up <00:06.00>words")
        #expect(line?.words == [LyricWord(time: 5.0, text: "Made up "), LyricWord(time: 6.0, text: "words")])
    }

    @Test("The words of a line always join back into its text")
    func wordsJoinIntoText() {
        let samples = [
            "[00:05.00]<00:05.00>Made <00:05.40>up <00:05.80>words",
            "[00:05.00]   <00:05.00>  Padded <00:05.40> line   ",
            "[00:05.00]Made <00:05.40>up<00:05.60> <00:05.70>words <00:06.00>",
            "[00:05.00]<00:05.00>\u{00C7}a <00:05.40>va <00:05.80>\u{1F3B5}",
        ]
        for sample in samples {
            guard let line = first(sample), let words = line.words else {
                Issue.record("expected words for a tagged line")
                continue
            }
            #expect(words.map(\.text).joined() == line.text)
            #expect(!line.text.contains("<0"))
        }
    }

    @Test("A line with no tags has no word timing and no end")
    func plainLineHasNoWords() {
        let line = first("[00:05.00]Made up words")
        #expect(line?.words == nil)
        #expect(line?.end == nil)
    }

    @Test("Tags never show as text, wherever they sit")
    func tagsNeverShow() {
        for sample in [
            "[00:05.00]<00:05.00>Made <00:05.40>up <00:05.80>words",
            "[00:05.00]<00:05.00><00:05.10>Doubled <0:06>tags<00:06.50>",
            "[00:05.00]Made <00:05.40>",
        ] {
            let text = first(sample)?.text ?? ""
            #expect(!text.contains("<") && !text.contains(">"))
        }
    }

    @Test("An [offset:] moves the words and the end with the line")
    func offsetMovesWords() {
        let line = first("[offset:+500]\n[00:05.00]<00:05.00>Made <00:05.40>up <00:06.20>")
        #expect(close(line?.time, 4.5))
        #expect(close(line?.words?.first?.time, 4.5))
        #expect(close(line?.words?.last?.time, 4.9))
        #expect(close(line?.end, 5.7))
    }

    @Test("A line that repeats under several timestamps keeps its text and drops the word times")
    func repeatedStampsDropWords() {
        let lines = LRCParser.parse("[00:10.00][00:30.00]<00:10.00>Repeated <00:10.50>line")
        #expect(lines.map(\.text) == ["Repeated line", "Repeated line"])
        #expect(lines.allSatisfy { $0.words == nil && $0.end == nil })
    }

    @Test("Word times never run backward, and never start before the line")
    func wordTimesAreOrdered() {
        let line = first("[00:05.00]<00:04.00>one <00:07.00>two <00:06.00>three")
        let times = line?.words?.map(\.time) ?? []
        #expect(times == [5, 7, 7])
    }

    @Test("A tag that ends at or before the last word start is not an end")
    func uselessEnd() {
        #expect(first("[00:05.00]<00:05.00>one <00:06.00>two <00:05.50>")?.end == nil)
    }

    @Test("A line of only tags is a gap, which may carry the end of the gap")
    func gapWithEnd() {
        let line = first("[00:05.00]<00:09.00>")
        #expect(line?.text == "")
        #expect(line?.words == nil)
        #expect(close(line?.end, 9))
    }

    @Test("A line with a flood of tags keeps its text and gives up the word times")
    func tooManyTags() {
        let body = String(repeating: "<00:01.00>a ", count: 5_000)
        let line = first("[00:00.50]" + body)
        #expect(line?.words == nil)
        #expect(line?.text.hasPrefix("a a a") == true)
        #expect(line?.text.contains("<") == false)
    }

    @Test("Tags in the text do not change how a tagged song parses: same lines, same order")
    func linesStillInOrder() {
        let lines = LRCParser.parse("""
        [00:10.00]<00:10.00>Third <00:10.50>line
        [00:05.00]<00:05.00>First <00:05.50>line
        """)
        #expect(lines.map(\.text) == ["First line", "Third line"])
        #expect(lines.map(\.time) == [5, 10])
        #expect(lines.first?.words?.first?.text == "First ")
    }
}

@Suite("Current lyric line with a lead")
struct LyricsLeadTests {

    private let lines = [
        LyricLine(time: 5, text: "a"),
        LyricLine(time: 10, text: "b"),
        LyricLine(time: 20, text: "c"),
    ]

    @Test("The lead is a tenth of a second")
    func leadValue() {
        #expect(MusicLyricScroll.lineLead == 0.1)
    }

    @Test("A line becomes current its lead before its time")
    func flipsEarly() {
        #expect(LRCParser.currentIndex(in: lines, at: 9.85, lead: 0.1) == 0)
        #expect(LRCParser.currentIndex(in: lines, at: 9.95, lead: 0.1) == 1)
        #expect(LRCParser.currentIndex(in: lines, at: 10, lead: 0.1) == 1)
        #expect(LRCParser.currentIndex(in: lines, at: 19.85, lead: 0.1) == 1)
        #expect(LRCParser.currentIndex(in: lines, at: 19.95, lead: 0.1) == 2)
    }

    @Test("The first line also starts its lead early, and nothing is current before that")
    func firstLineLead() {
        #expect(LRCParser.currentIndex(in: lines, at: 4.85, lead: 0.1) == nil)
        #expect(LRCParser.currentIndex(in: lines, at: 4.95, lead: 0.1) == 0)
    }

    @Test("No lead is the plain lookup, and a negative lead is no lead")
    func zeroAndNegative() {
        for probe in [0.0, 4.99, 5, 9.99, 10, 25] {
            #expect(LRCParser.currentIndex(in: lines, at: probe, lead: 0) == LRCParser.currentIndex(in: lines, at: probe))
            #expect(LRCParser.currentIndex(in: lines, at: probe, lead: -3) == LRCParser.currentIndex(in: lines, at: probe))
        }
    }

    @Test("A bad time or lead has no current line, and no lines have none")
    func degenerate() {
        #expect(LRCParser.currentIndex(in: lines, at: .nan, lead: 0.1) == nil)
        #expect(LRCParser.currentIndex(in: lines, at: 10, lead: .nan) == nil)
        #expect(LRCParser.currentIndex(in: [], at: 10, lead: 0.1) == nil)
    }
}
