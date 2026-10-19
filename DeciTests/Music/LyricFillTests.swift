// DeciTests/Music/LyricFillTests.swift
// The word-by-word fill of the current line: estimating word times for a line that only has a start, the sweep from
// the clock to a character position, and the soft edge of lit and dim characters. Fixtures are made-up lines only.

import Foundation
import Testing
@testable import Deci

@Suite("Lyric fill: words")
struct LyricFillWordsTests {

    // MARK: - Syllables

    @Test("A syllable is a group of vowels, with a floor of one", arguments: [
        ("the", 1), ("hello", 2), ("beautiful", 3), ("queue", 1), ("rhythm", 1), ("I", 1), ("you", 1),
        ("extraordinary", 5), ("hmm", 1), ("123", 1), ("...", 1), ("", 1),
    ])
    func syllables(word: String, expected: Int) {
        #expect(LyricFill.syllableCount(word) == expected)
    }

    @Test("Case and accents do not change the count")
    func syllablesIgnoreCaseAndAccents() {
        #expect(LyricFill.syllableCount("HELLO") == LyricFill.syllableCount("hello"))
        #expect(LyricFill.syllableCount("na\u{00EF}ve") == 2)
        #expect(LyricFill.syllableCount("\u{00C7}a") == 1)
    }

    // MARK: - Splitting

    @Test("Words keep the spacing after them, so they join back into the line")
    func splitKeepsSpacing() {
        #expect(LyricFill.splitWords("Sing up words") == ["Sing ", "up ", "words"])
        #expect(LyricFill.splitWords("a  b") == ["a  ", "b"])
        #expect(LyricFill.splitWords("  hi there") == ["  hi ", "there"])
        #expect(LyricFill.splitWords("one, two!") == ["one, ", "two!"])
    }

    @Test("Splitting never loses a character", arguments: [
        "Sing up words", "  padded  line  ", "single", "\u{00C7}a va tr\u{00E8}s bien \u{1F3B5}", "x", "a\tb",
    ])
    func splitJoinsBack(text: String) {
        #expect(LyricFill.splitWords(text).joined() == text)
    }

    @Test("Text with no words has no words, and a line with no spaces is one word")
    func splitEdges() {
        #expect(LyricFill.splitWords("").isEmpty)
        #expect(LyricFill.splitWords("   ").isEmpty)
        #expect(LyricFill.splitWords("\u{65E5}\u{672C}\u{8A9E}") == ["\u{65E5}\u{672C}\u{8A9E}"])
    }

    // MARK: - Where the singing ends

    private func line(_ text: String = "Sing up words", at time: TimeInterval = 10, end: TimeInterval? = nil) -> LyricLine {
        LyricLine(time: time, text: text, end: end)
    }

    @Test("A line's own end is where it stops, even when the next line is nearer or further")
    func ownEndWins() {
        #expect(LyricFill.singEnd(for: line(end: 12), nextStart: 20) == 12)
        #expect(LyricFill.singEnd(for: line(end: 12), nextStart: 11) == 12)
        #expect(LyricFill.singEnd(for: line(end: 12), nextStart: nil) == 12)
    }

    @Test("With no end, the next line's start closes the line when it comes before the cap")
    func nextStartCloses() {
        #expect(LyricFill.singEnd(for: line(), nextStart: 11) == 11)
    }

    @Test("With no end, a long wait for the next line is capped at 0.6 s a word, so the fill does not crawl")
    func capped() {
        #expect(LyricFill.secondsPerWord == 0.6)
        let end = LyricFill.singEnd(for: line(), nextStart: 40)
        #expect(abs((end ?? 0) - 11.8) < 0.0001)
    }

    @Test("The last line has no next one: it takes the cap")
    func lastLine() {
        let end = LyricFill.singEnd(for: line("One two", at: 100), nextStart: nil)
        #expect(abs((end ?? 0) - 101.2) < 0.0001)
    }

    @Test("An end at or before the start is not an end")
    func uselessEnd() {
        #expect(LyricFill.singEnd(for: line(end: 10), nextStart: 11) == 11)
        #expect(LyricFill.singEnd(for: line(end: 4), nextStart: 11) == 11)
    }

    @Test("A next line that starts with this one leaves no time to sing in")
    func tiedNextStart() {
        #expect(LyricFill.singEnd(for: line(), nextStart: 10) == 10)
        #expect(LyricFill.singEnd(for: line(), nextStart: 8) == 10)
    }

    @Test("A gap fills across the whole gap: its end, else the next start, never the word cap")
    func gapDuration() {
        let gap = LyricLine(time: 20, text: "")
        #expect(LyricFill.singEnd(for: gap, nextStart: 50) == 50)
        #expect(LyricFill.singEnd(for: LyricLine(time: 20, text: "", end: 30), nextStart: 50) == 30)
        #expect(LyricFill.singEnd(for: gap, nextStart: nil) == nil)
    }

    // MARK: - Estimating

    @Test("Equal words share the time equally, in order, from the start")
    func estimateEqualWords() {
        let words = LyricFill.estimateWords(for: line(end: 13), nextStart: nil)
        #expect(words.map(\.text) == ["Sing ", "up ", "words"])
        #expect(words.map(\.time) == [10, 11, 12])
    }

    @Test("A word with more syllables takes more of the time")
    func estimateWeights() {
        // I (1), love (2), you (1): four shares over four seconds.
        let words = LyricFill.estimateWords(for: LyricLine(time: 0, text: "I love you", end: 4), nextStart: nil)
        #expect(words.map(\.time) == [0, 1, 3])
    }

    @Test("A one-word line is one word at the start")
    func estimateSingleWord() {
        let words = LyricFill.estimateWords(for: LyricLine(time: 7, text: "Hey", end: 9), nextStart: nil)
        #expect(words == [LyricWord(time: 7, text: "Hey")])
    }

    @Test("Estimated words always join back into the line, and start inside it")
    func estimateJoinsBack() {
        for text in ["Sing up words", "  padded  line ", "\u{00C7}a va \u{1F3B5}", "x"] {
            let words = LyricFill.estimateWords(for: LyricLine(time: 5, text: text, end: 9), nextStart: nil)
            #expect(words.map(\.text).joined() == text)
            #expect(words.allSatisfy { $0.time >= 5 && $0.time < 9 })
            #expect(words.map(\.time) == words.map(\.time).sorted())
        }
    }

    @Test("A line with no singing time, or no words, has nothing to estimate")
    func estimateNothing() {
        #expect(LyricFill.estimateWords(for: LyricLine(time: 5, text: "Sing up words"), nextStart: 5).isEmpty)
        #expect(LyricFill.estimateWords(for: LyricLine(time: 5, text: "   ", end: 9), nextStart: nil).isEmpty)
        #expect(LyricFill.estimateWords(for: LyricLine(time: 5, text: ""), nextStart: nil).isEmpty)
    }
}

@Suite("Lyric fill: sweep")
struct LyricFillSweepTests {

    private let estimated = LyricLine(time: 10, text: "Sing up words", end: 13)

    private func timing(_ line: LyricLine, next: TimeInterval? = nil) -> LyricFill.Timing {
        guard let timing = LyricFill.timing(for: line, nextStart: next) else {
            Issue.record("expected a timing")
            return LyricFill.Timing(characterCount: 0, spans: [])
        }
        return timing
    }

    @Test("The sweep is zero before the line, and zero when it starts")
    func before() {
        let timing = timing(estimated)
        #expect(timing.sweep(at: 0) == 0)
        #expect(timing.sweep(at: 9.99) == 0)
        #expect(timing.sweep(at: 10) == 0)
    }

    @Test("Inside a word the sweep runs through its characters evenly, and a word hands over to the next")
    func inside() {
        let timing = timing(estimated)
        #expect(timing.characterCount == 13)
        #expect(abs(timing.sweep(at: 10.5) - 2.5) < 0.0001)
        #expect(abs(timing.sweep(at: 11) - 5) < 0.0001)
        #expect(abs(timing.sweep(at: 11.5) - 6.5) < 0.0001)
        #expect(abs(timing.sweep(at: 12) - 8) < 0.0001)
        #expect(abs(timing.sweep(at: 12.5) - 10.5) < 0.0001)
    }

    @Test("The sweep is the whole line once the singing ends, and stays there")
    func after() {
        let timing = timing(estimated)
        #expect(timing.sweep(at: 13) == 13)
        #expect(timing.sweep(at: 500) == 13)
    }

    @Test("The sweep never goes backward as the clock moves forward")
    func monotonic() {
        let timing = timing(estimated)
        var last = -1.0
        for step in 0...300 {
            let value = timing.sweep(at: 9 + Double(step) * 0.0166)
            #expect(value >= last)
            last = value
        }
    }

    @Test("A bad clock reading leaves the sweep at zero")
    func nonFiniteClock() {
        let timing = timing(estimated)
        #expect(timing.sweep(at: .nan) == 0)
        #expect(timing.sweep(at: -.infinity) == 0)
    }

    @Test("Real word times from a source are used as they are, and hold between a word's end and the next")
    func explicitWords() {
        let line = LyricLine(
            time: 5, text: "Sing up words", end: 9,
            words: [LyricWord(time: 5, text: "Sing "), LyricWord(time: 6, text: "up "), LyricWord(time: 8, text: "words")]
        )
        let timing = timing(line)
        #expect(abs(timing.sweep(at: 5.5) - 2.5) < 0.0001)
        #expect(abs(timing.sweep(at: 7) - 6.5) < 0.0001)
        #expect(abs(timing.sweep(at: 8.5) - 10.5) < 0.0001)
        #expect(timing.sweep(at: 9) == 13)
    }

    @Test("Real word times that do not add up to the line's text are ignored for an estimate")
    func mismatchedWordsFallBack() {
        let line = LyricLine(
            time: 10, text: "Sing up words", end: 13,
            words: [LyricWord(time: 10, text: "Something "), LyricWord(time: 12, text: "else")]
        )
        let timing = timing(line)
        #expect(timing.characterCount == 13)
        #expect(abs(timing.sweep(at: 11) - 5) < 0.0001)
    }

    @Test("Word times that go backward are held, never run in reverse")
    func explicitOutOfOrder() {
        let line = LyricLine(
            time: 5, text: "a b c", end: 8,
            words: [LyricWord(time: 5, text: "a "), LyricWord(time: 7, text: "b "), LyricWord(time: 6, text: "c")]
        )
        let timing = timing(line)
        var last = -1.0
        for step in 0...80 {
            let value = timing.sweep(at: 4.5 + Double(step) * 0.05)
            #expect(value >= last)
            last = value
        }
        #expect(timing.sweep(at: 8) == 5)
    }

    @Test("The last real word ends at the line's end, else at the cap, never at a distant next line")
    func explicitLastWordEnd() {
        let words = [LyricWord(time: 5, text: "one "), LyricWord(time: 6, text: "two")]
        let capped = timing(LyricLine(time: 5, text: "one two", words: words), next: 60)
        #expect(abs(capped.sweep(at: 6.3) - 5.5) < 0.0001)
        #expect(capped.sweep(at: 6.6) == 7)
        let closed = timing(LyricLine(time: 5, text: "one two", end: 8, words: words))
        #expect(abs(closed.sweep(at: 7) - 5.5) < 0.0001)
    }

    @Test("A gap fills its one note across the gap")
    func gapFills() {
        let timing = timing(LyricLine(time: 20, text: ""), next: 30)
        #expect(timing.characterCount == 1)
        #expect(timing.sweep(at: 20) == 0)
        #expect(abs(timing.sweep(at: 25) - 0.5) < 0.0001)
        #expect(timing.sweep(at: 30) == 1)
    }

    @Test("A line with no time to sing in has no fill")
    func noFill() {
        #expect(LyricFill.timing(for: LyricLine(time: 20, text: ""), nextStart: nil) == nil)
        #expect(LyricFill.timing(for: LyricLine(time: 20, text: "Sing up words"), nextStart: 20) == nil)
        #expect(LyricFill.timing(for: LyricLine(time: 20, text: "   ", end: 25), nextStart: nil) == nil)
    }
}

@Suite("Lyric fill: characters")
struct LyricFillCharacterTests {

    private let dim = MusicLyricRowStyle.upcomingOpacity
    private let lit = MusicLyricRowStyle.currentOpacity

    private func alphas(_ count: Int, _ sweep: Double) -> [Double] {
        LyricFill.alphas(characterCount: count, sweep: sweep, unsung: dim, sung: lit)
    }

    @Test("Before the sweep starts every character is at the upcoming level")
    func beforeTheSweep() {
        #expect(alphas(10, 0) == Array(repeating: dim, count: 10))
    }

    @Test("When the sweep has gone through the line every character is at full brightness")
    func afterTheSweep() {
        #expect(alphas(10, 10) == Array(repeating: lit, count: 10))
        #expect(alphas(10, 400) == Array(repeating: lit, count: 10))
    }

    @Test("In the middle, what has been sung is lit, what is to come is dim, and the edge is in between")
    func edge() {
        let values = alphas(20, 10)
        #expect(values.first == lit)
        #expect(values.last == dim)
        let between = values.filter { $0 > dim && $0 < lit }
        #expect(!between.isEmpty)
        #expect(between.count <= 2)
    }

    @Test("Along the line brightness only ever falls: lit, then the edge, then dim")
    func descending() {
        for sweep in stride(from: 0.0, through: 20.0, by: 0.37) {
            let values = alphas(20, sweep)
            #expect(values == values.sorted(by: >))
        }
    }

    @Test("As the sweep moves on, no character gets dimmer")
    func ascendingInTime() {
        var previous = alphas(16, 0)
        for sweep in stride(from: 0.1, through: 16.0, by: 0.1) {
            let next = alphas(16, sweep)
            for index in next.indices { #expect(next[index] >= previous[index]) }
            previous = next
        }
    }

    @Test("Every value is between the unsung and the sung level")
    func inRange() {
        for sweep in stride(from: -2.0, through: 25.0, by: 0.5) {
            for value in alphas(20, sweep) { #expect(value >= dim && value <= lit) }
        }
    }

    @Test("An empty line has no characters")
    func emptyLine() {
        #expect(alphas(0, 0).isEmpty)
        #expect(alphas(0, 5).isEmpty)
        #expect(alphas(-3, 1).isEmpty)
    }

    @Test("A one-word line sweeps left to right like any other")
    func singleWord() {
        let start = alphas(5, 0)
        let half = alphas(5, 2.5)
        let end = alphas(5, 5)
        #expect(start == Array(repeating: dim, count: 5))
        #expect(end == Array(repeating: lit, count: 5))
        #expect(half.first == lit)
        #expect(half.last == dim)
    }

    @Test("A single character goes from dim to lit")
    func singleCharacter() {
        #expect(alphas(1, 0) == [dim])
        #expect(alphas(1, 1) == [lit])
        let middle = alphas(1, 0.5)[0]
        #expect(middle > dim && middle < lit)
    }

    @Test("A sweep that is not a number, or is below zero, is the start")
    func badSweep() {
        #expect(alphas(6, .nan) == Array(repeating: dim, count: 6))
        #expect(alphas(6, -4) == Array(repeating: dim, count: 6))
        #expect(alphas(6, -.infinity) == Array(repeating: dim, count: 6))
    }

    @Test("The edge is about two characters wide")
    func edgeWidth() {
        #expect(LyricFill.edgeWidth == 2)
    }

    // MARK: - Runs

    @Test("Neighbouring characters at one brightness are one run")
    func runsGroup() {
        let runs = LyricFill.runs(of: [1, 1, 0.5, 0.35, 0.35])
        #expect(runs == [
            LyricFill.Run(range: 0..<2, alpha: 1),
            LyricFill.Run(range: 2..<3, alpha: 0.5),
            LyricFill.Run(range: 3..<5, alpha: 0.35),
        ])
    }

    @Test("No characters, no runs; one brightness, one run")
    func runsEdges() {
        #expect(LyricFill.runs(of: []).isEmpty)
        #expect(LyricFill.runs(of: [0.35, 0.35, 0.35]) == [LyricFill.Run(range: 0..<3, alpha: 0.35)])
    }

    @Test("A frame of the sweep is a few runs, not one per character")
    func fewRuns() {
        let runs = LyricFill.runs(of: alphas(60, 30))
        #expect(runs.count <= 4)
        #expect(runs.reduce(0) { $0 + $1.range.count } == 60)
    }
}
