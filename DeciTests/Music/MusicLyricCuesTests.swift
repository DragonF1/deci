// DeciTests/Music/MusicLyricCuesTests.swift
// Where a song's hook is, read from its lyrics. The words here are made up for the tests.

import Foundation
import Testing
@testable import Deci

@Suite("MusicLyricCues")
struct MusicLyricCuesTests {
    static let hook = ["paint the harbour lights again", "every window turning blue", "carry me over the water"]

    static func verse(_ n: Int) -> [String] {
        [
            ["morning train rolls past empty fields", "somebody left their coat behind", "ticket stubs inside my pocket", "coffee going cold beside me"],
            ["rooftop radio plays an older tune", "neighbours argue about the rent", "shadows stretching down alleyways", "winter came before we noticed"],
            ["telephone wires hum above", "grandfather built this fence himself", "nothing grows there any longer", "still I keep the gate painted"],
        ][n - 1]
    }

    /// Lines from `start`, 4 s apart, each 3.5 s long.
    static func block(_ words: [String], at start: Double) -> [LyricLine] {
        words.enumerated().map { LyricLine(time: start + 4 * Double($0.offset), text: $0.element, end: start + 4 * Double($0.offset) + 3.5) }
    }

    /// Verse 10, hook 30 to 41.5, verse 60, hook 80 to 91.5, verse 110, hook 130 to 141.5.
    static var song: [LyricLine] {
        block(verse(1), at: 10) + block(hook, at: 30) + block(verse(2), at: 60) + block(hook, at: 80)
            + block(verse(3), at: 110) + block(hook, at: 130)
    }

    @Test("the hook is the run of lines that comes back, first line start to last line end")
    func findsHooks() {
        let cues = MusicLyricCues.from(lines: Self.song, duration: 180)
        #expect(cues.hooks == [30...41.5, 80...91.5, 130...141.5])
        #expect(cues.firstLineSec == 10)
    }

    @Test("order, backing vocals in brackets, capitals and punctuation do not matter")
    func normalises() {
        var lines = Self.song.reversed() + []
        lines = lines.map { line in
            line.time == 80 ? LyricLine(time: 80, text: "Paint the harbour LIGHTS, again! (ooh ooh ooh ooh)", end: 83.5) : line
        }
        #expect(MusicLyricCues.from(lines: lines, duration: 180).hooks.count == 3)
        // A bracket that never closes hides nothing.
        let open = Self.song.map { $0.time == 80 ? LyricLine(time: 80, text: "paint the (harbour lights again", end: 83.5) : $0 }
        #expect(MusicLyricCues.from(lines: open, duration: 180).hooks == [30...41.5, 80...91.5, 130...141.5])
    }

    @Test("one new line inside a hook is bridged")
    func bridgesOneLine() {
        var lines = Self.song
        lines.append(LyricLine(time: 90.2, text: "completely different shout", end: 91.4))
        lines.append(contentsOf: Self.block(["paint the harbour lights again"], at: 92))
        #expect(MusicLyricCues.from(lines: lines, duration: 180).hooks == [30...41.5, 80...95.5, 130...141.5])
    }

    @Test("a silence ends a run")
    func gapEndsARun() {
        // The second hook's last line comes 10 s late: two runs, and the lone line is not one.
        let lines = Self.song.map { $0.time == 88 ? LyricLine(time: 98, text: $0.text, end: 101.5) : $0 }
        #expect(MusicLyricCues.from(lines: lines, duration: 180).hooks == [30...41.5, 130...141.5], "what is left of it is 7.5 s")
    }

    @Test("one hook, no repeats, everything repeating, or too few lines: no hooks")
    func saysNothing() {
        let once = Self.block(Self.verse(1), at: 10) + Self.block(Self.hook, at: 30) + Self.block(Self.verse(2), at: 60)
        #expect(MusicLyricCues.from(lines: once, duration: 180).hooks.isEmpty)
        let chant = Self.block(Self.hook, at: 10) + Self.block(Self.hook, at: 40) + Self.block(Self.hook, at: 70)
        #expect(MusicLyricCues.from(lines: chant, duration: 180).hooks.isEmpty, "nearly every line is a hook")
        #expect(MusicLyricCues.from(lines: Self.block(["one", "two"], at: 10), duration: 180).hooks.isEmpty)
        #expect(MusicLyricCues.from(lines: [], duration: 180) == MusicLyricCues())
        // The same line said twice in a row is not a hook coming back.
        let twice = Self.block(Self.verse(1) + ["again and again we go", "again and again we go"] + Self.verse(2), at: 10)
        #expect(MusicLyricCues.from(lines: twice, duration: 180).hooks.isEmpty)
    }

    @Test("a line without an end runs to the next one, and not for ever")
    func missingEnds() throws {
        let lines = Self.song.map { LyricLine(time: $0.time, text: $0.text) }
        let hooks = MusicLyricCues.from(lines: lines, duration: 180).hooks
        #expect(hooks.map(\.lowerBound) == [30, 80, 130])
        let last = try #require(hooks.last)
        #expect(last.upperBound <= 138 + MusicVocalIntervals.maxLineSec && last.upperBound > 138)
    }

    @Test("the first line is the first words: notes and blanks are not")
    func firstLine() {
        let lines = [LyricLine(time: 0, text: "♪"), LyricLine(time: 5, text: "  "), LyricLine(time: 12, text: "hello there")]
        #expect(MusicLyricCues.from(lines: lines, duration: 180).firstLineSec == 12)
        #expect(MusicLyricCues.from(lines: [LyricLine(time: 0, text: "♪")], duration: 180).firstLineSec == nil)
    }

    @Test("times that make no sense are dropped, and a duration that makes none gives nothing")
    func badInput() {
        let bad = [LyricLine(time: .nan, text: "x y z"), LyricLine(time: -4, text: "x y z"), LyricLine(time: 900, text: "x y z")]
        #expect(MusicLyricCues.from(lines: bad + Self.song, duration: 180) == MusicLyricCues.from(lines: Self.song, duration: 180))
        #expect(MusicLyricCues.from(lines: Self.song, duration: .nan) == MusicLyricCues())
        #expect(MusicLyricCues.from(lines: Self.song, duration: 0) == MusicLyricCues())
    }
}
