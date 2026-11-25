// Deci/Music/Playback/MusicLyricCues.swift
// Where a song's hook is, read from synced lyrics. A hook is a run of lines that come back later in the song, which is what a
// chorus is in the words. It finds sections in songs whose level never moves (the energy map finds nothing there) and in
// songs with no beat grid. Pure: the lines in, the runs out. Nothing is stored and the words never leave this file.
//
// Two shapes say nothing and give no hooks: a song that repeats fewer than two runs, and one where nearly every line repeats
// (then every line is a hook and none of them is).

import Foundation

nonisolated struct MusicLyricCues: Equatable, Sendable {
    /// The runs of repeated lines, first line start to last line end, in song seconds, in order. Two or more, or none.
    var hooks: [ClosedRange<Double>] = []
    /// When the first words are sung. nil = none are.
    var firstLineSec: Double?
    /// Every sung line on its own, in song seconds, in order: what a cut would split. The vocal intervals join lines that follow
    /// each other, so a whole verse is one of those.
    var lines: [ClosedRange<Double>] = []

    /// Two lines further apart than this can repeat each other: nearer ones are one line said twice, not a hook coming back.
    static let minRepeatGapSec = 15.0
    /// The share of the longer line's words two lines have in common to count as the same line.
    static let minSimilarity = 0.75
    /// A silence this long between two lines ends a run.
    static let maxLineGapSec = 8.0
    /// A run is at least this long and has at least this many repeated lines.
    static let minHookSec = 8.0
    static let minHookLines = 2
    /// More of the sung time than this in hooks means that everything repeats.
    static let maxHookShare = 0.8
    /// A song with fewer lines than this has no shape to read.
    static let minLines = 6

    private struct Line {
        var start: Double
        var end: Double
        var words: Set<String>
    }

    static func from(lines: [LyricLine], duration: Double) -> MusicLyricCues {
        guard duration.isFinite, duration > 0 else { return MusicLyricCues() }
        let sung = lines.filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration }.sorted { $0.time < $1.time }
        // A line of notes ("♪") is not words.
        let first = sung.first { $0.text.contains { $0.isLetter || $0.isNumber } }?.time
        var prepared = sung.compactMap { line -> Line? in
            let words = words(line.text)
            guard !words.isEmpty else { return nil }
            let end = line.end.flatMap { $0.isFinite ? $0 : nil } ?? .infinity
            return Line(start: line.time, end: min(end, line.time + MusicVocalIntervals.maxLineSec), words: words)
        }
        for i in prepared.indices.dropLast() {
            let next = prepared[i + 1].start
            if next > prepared[i].start { prepared[i].end = min(prepared[i].end, next) }
        }
        let spans = prepared.compactMap { line -> ClosedRange<Double>? in
            let end = min(line.end, duration)
            return end > line.start ? line.start...end : nil
        }
        return MusicLyricCues(hooks: hooks(prepared, duration: duration), firstLineSec: first, lines: spans)
    }

    private static func hooks(_ lines: [Line], duration: Double) -> [ClosedRange<Double>] {
        guard lines.count >= minLines else { return [] }
        let repeats = lines.map { line in
            lines.contains { abs($0.start - line.start) > minRepeatGapSec && similarity($0.words, line.words) >= minSimilarity }
        }
        var runs: [(range: ClosedRange<Double>, lines: Int)] = []
        var i = 0
        while i < lines.count {
            guard repeats[i] else { i += 1; continue }
            var last = i
            var j = i + 1
            // One line that does not repeat is bridged when the one after it does (an ad-lib inside a chorus).
            while j < lines.count, repeats[j] || (j + 1 < lines.count && repeats[j + 1]),
                  lines[j].start - lines[j - 1].end < maxLineGapSec {
                if repeats[j] { last = j }
                j += 1
            }
            let end = min(max(lines[last].end, lines[i].start), duration)
            if end >= lines[i].start { runs.append((lines[i].start...end, last - i + 1)) }
            i = max(j, last + 1)
        }
        let kept = runs.filter { $0.range.upperBound - $0.range.lowerBound >= minHookSec && $0.lines >= minHookLines }.map(\.range)
        guard kept.count >= 2 else { return [] }
        let sungSec = lines.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let hookSec = kept.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        guard sungSec > 0, hookSec / sungSec <= maxHookShare else { return [] }
        return kept
    }

    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let longest = max(a.count, b.count)
        let shortest = min(a.count, b.count)
        // Too different in length to reach the bar: this runs for every pair of lines, so the words are not compared.
        guard longest > 0, Double(shortest) / Double(longest) >= minSimilarity else { return 0 }
        let shared = a.reduce(0) { $0 + (b.contains($1) ? 1 : 0) }
        return Double(shared) / Double(longest)
    }

    /// The words of a line: lowercased, without anything in round brackets (backing vocals) or punctuation.
    private static func words(_ text: String) -> Set<String> {
        var kept = ""
        var bracketed = ""
        var inBrackets = false
        for character in text.lowercased() {
            if inBrackets {
                bracketed.append(character)
                if character == ")" { inBrackets = false; bracketed = "" }
            } else if character == "(" {
                inBrackets = true
                bracketed = ""
            } else {
                kept.append(character)
            }
        }
        // A bracket that never closes hides nothing.
        kept += bracketed
        let clean = kept.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0.isWhitespace }
        return Set(clean.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
