// DeciTests/Music/MusicLyricFilledTextTests.swift
// The current row's text at one moment of its fill: colour only, one run per brightness, same characters.

import SwiftUI
import Testing
@testable import Deci

@Suite("Lyric row filled text")
struct MusicLyricFilledTextTests {

    private func color(_ alpha: Double) -> Color { DesignTokens.Colors.textPrimary.opacity(alpha) }

    private func colors(of text: AttributedString) -> [Color?] {
        text.runs.map(\.foregroundColor)
    }

    @Test("The filled text is the line's own text, character for character, at any point of the sweep")
    func sameCharacters() {
        for sweep in stride(from: -1.0, through: 15.0, by: 0.5) {
            let text = MusicLyricRowStyle.filledText("Made up words", sweep: sweep)
            #expect(String(text.characters) == "Made up words")
        }
    }

    @Test("Before the sweep every character is at the upcoming level, in one run")
    func beforeTheSweep() {
        let text = MusicLyricRowStyle.filledText("Made up words", sweep: 0)
        #expect(colors(of: text) == [color(MusicLyricRowStyle.upcomingOpacity)])
    }

    @Test("After the sweep every character is at full brightness, in one run")
    func afterTheSweep() {
        let text = MusicLyricRowStyle.filledText("Made up words", sweep: 13)
        #expect(colors(of: text) == [color(MusicLyricRowStyle.currentOpacity)])
    }

    @Test("In the middle the front is full, the rest is upcoming, and a few characters between them are the edge")
    func middle() {
        let text = MusicLyricRowStyle.filledText("Made up words", sweep: 6)
        let found = colors(of: text)
        #expect((2...4).contains(found.count))
        #expect(found.first == color(MusicLyricRowStyle.currentOpacity))
        #expect(found.last == color(MusicLyricRowStyle.upcomingOpacity))
    }

    @Test("Nothing but colour is set on a run, so the font and the wrapping never change")
    func colourOnly() {
        let text = MusicLyricRowStyle.filledText("Made up words", sweep: 6)
        for run in text.runs {
            #expect(run.font == nil)
            #expect(run.kern == nil)
            #expect(run.tracking == nil)
            #expect(run.baselineOffset == nil)
            #expect(run.underlineStyle == nil)
        }
    }

    @Test("An empty text is an empty string")
    func empty() {
        #expect(MusicLyricRowStyle.filledText("", sweep: 3).characters.isEmpty)
    }

    @Test("A sweep that is not a number leaves the line at the upcoming level")
    func badSweep() {
        let text = MusicLyricRowStyle.filledText("Made up words", sweep: .nan)
        #expect(colors(of: text) == [color(MusicLyricRowStyle.upcomingOpacity)])
    }

    @Test("An accent or an emoji is one character: the sweep never cuts it")
    func graphemes() {
        let line = "\u{00C7}a va \u{1F3B5} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        for sweep in stride(from: 0.0, through: 12.0, by: 0.5) {
            let text = MusicLyricRowStyle.filledText(line, sweep: sweep)
            #expect(String(text.characters) == line)
            #expect(text.characters.count == line.count)
        }
    }

    @Test("A single note, the gap row, goes from upcoming to full")
    func note() {
        #expect(colors(of: MusicLyricRowStyle.filledText("\u{266A}", sweep: 0)) == [color(MusicLyricRowStyle.upcomingOpacity)])
        #expect(colors(of: MusicLyricRowStyle.filledText("\u{266A}", sweep: 1)) == [color(MusicLyricRowStyle.currentOpacity)])
    }
}
