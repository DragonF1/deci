// Deci/Music/Lyrics/LRCParser.swift
import Foundation

/// Parses LRC text ("[mm:ss.xx]line") into timed lines, and finds the line a playhead is on.
enum LRCParser {
    /// Lines sorted by time. Metadata tags (`ar`, `ti`, `al`, `by`, `length`, ...) are dropped, `[offset:]` is
    /// applied, empty timed lines stay as gaps and malformed lines are skipped. Enhanced LRC word tags
    /// ("<mm:ss.xx>") never show in the text: a line with them gets its word timings and, when a tag closes the
    /// line, its end.
    static func parse(_ text: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var entries: [(time: TimeInterval, body: Body)] = []

        for line in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(line)
            if rest.first == "\u{FEFF}" { rest = rest.dropFirst() }
            rest = trimmed(rest)

            var stamps: [TimeInterval] = []
            var isOffsetOrMetadata = false
            while rest.first == "[" {
                guard let close = rest.firstIndex(of: "]") else { break }
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                if let stamp = timestamp(inner) {
                    stamps.append(stamp)
                    rest = rest[rest.index(after: close)...]
                } else {
                    // A tag that is not a time ends the run of timestamps. Before any timestamp it is a
                    // metadata line; after one it is the start of the text.
                    if stamps.isEmpty {
                        isOffsetOrMetadata = true
                        if let value = offsetValue(inner) { offset = value }
                    }
                    break
                }
            }
            guard !stamps.isEmpty, !isOffsetOrMetadata else { continue }

            // A line under several timestamps is the same text sung at several moments: the word times belong to
            // one of them only, so the repeats keep the text and nothing else.
            let body = parseBody(trimmed(rest), lineTime: stamps[0])
            for stamp in stamps {
                entries.append((stamp, stamps.count == 1 ? body : Body(text: body.text, words: nil, end: nil)))
            }
        }

        let adjusted = entries.enumerated().map { index, entry in
            (index: index, line: LyricLine(
                time: max(0, entry.time - offset),
                text: entry.body.text,
                end: entry.body.end.map { max(0, $0 - offset) },
                words: entry.body.words?.map { LyricWord(time: max(0, $0.time - offset), text: $0.text) }
            ))
        }
        return adjusted
            .sorted { ($0.line.time, $0.index) < ($1.line.time, $1.index) }
            .map(\.line)
    }

    /// The index of the last line at or before `time`; nil before the first line or without lines.
    /// Binary search: the view asks on every frame while the song plays.
    static func currentIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard time.isFinite, let first = lines.first, first.time <= time else { return nil }
        var low = 0
        var high = lines.count
        // Invariant: lines[low].time <= time, and lines[high].time > time when high is in range.
        while high - low > 1 {
            let middle = (low + high) / 2
            if lines[middle].time <= time { low = middle } else { high = middle }
        }
        return low
    }

    /// The line that is current `lead` seconds early: the one `currentIndex(in:at:)` finds at `time + lead`, so a line
    /// lights up just before it is sung, which is how it looks on time (the eye needs a moment to follow the change).
    /// A lead that is zero or negative is the plain lookup; a time or lead that is not a number finds no line.
    static func currentIndex(in lines: [LyricLine], at time: TimeInterval, lead: TimeInterval) -> Int? {
        guard time.isFinite, lead.isFinite else { return nil }
        return currentIndex(in: lines, at: time + max(0, lead))
    }

    /// Lines with words in them: gaps do not count.
    static func sungLineCount(_ lines: [LyricLine]) -> Int {
        lines.reduce(0) { $0 + ($1.text.isEmpty ? 0 : 1) }
    }

    // MARK: - Pieces

    private static func trimmed(_ text: Substring) -> Substring {
        var result = text
        while let first = result.first, first.isWhitespace { result = result.dropFirst() }
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return result
    }

    private static func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    /// "mm:ss", "m:ss", "mm:ss.x", "mm:ss.xx" or "mm:ss.xxx": minutes 1 to 3 digits, seconds 0 to 59.
    /// The fraction is a decimal, so ".5" is half a second and ".05" five hundredths.
    private static func timestamp(_ inner: Substring) -> TimeInterval? {
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let minutes = parts[0]
        guard (1...3).contains(minutes.count), minutes.allSatisfy(isDigit), let minuteValue = Int(minutes) else { return nil }

        let secondsAndFraction = parts[1].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let seconds = secondsAndFraction[0]
        guard (1...2).contains(seconds.count), seconds.allSatisfy(isDigit), let secondValue = Int(seconds), secondValue < 60 else {
            return nil
        }
        var fractionValue = 0.0
        if secondsAndFraction.count == 2 {
            let fraction = secondsAndFraction[1]
            guard (1...3).contains(fraction.count), fraction.allSatisfy(isDigit), let digits = Double("0." + fraction) else { return nil }
            fractionValue = digits
        }
        return TimeInterval(minuteValue * 60 + secondValue) + fractionValue
    }

    /// The offset in seconds from the inside of an `[offset:+500]` tag; nil for any other tag or a broken value.
    private static func offsetValue(_ inner: Substring) -> TimeInterval? {
        guard let colon = inner.firstIndex(of: ":"),
              inner[inner.startIndex..<colon].lowercased() == "offset",
              let milliseconds = Int(trimmed(inner[inner.index(after: colon)...]))
        else { return nil }
        return TimeInterval(milliseconds) / 1000
    }

    /// The longest time inside a word tag: "mmm:ss.xxx".
    private static let longestTagInside = 10

    /// The most word tags one line is read for. A line with more than this keeps its text and gives up its word
    /// timings: no song has that many words in one line, and the body of a hostile reply can be 2 MB.
    private static let mostTagsPerLine = 256

    /// What follows the timestamps of one line: its text without tags, and the timing the tags gave.
    private struct Body {
        let text: String
        let words: [LyricWord]?
        let end: TimeInterval?
    }

    /// A stretch of text and the tag in front of it. The first stretch of a line has no tag.
    private struct Stretch {
        let time: TimeInterval?
        var text: String
    }

    /// Splits a line's text at its word tags ("<00:05.40>"). The ">" is looked for only as far as a tag can reach, so
    /// a line of nothing but "<" costs a few steps per character instead of a scan to the end of the line for each.
    private static func parseBody(_ text: Substring, lineTime: TimeInterval) -> Body {
        guard text.contains("<") else { return Body(text: String(text), words: nil, end: nil) }

        var stretches = [Stretch(time: nil, text: "")]
        var plain = ""
        var tagCount = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "<", let close = closingBracket(in: text, after: index),
               let time = timestamp(text[text.index(after: index)..<close]) {
                tagCount += 1
                if tagCount <= mostTagsPerLine { stretches.append(Stretch(time: time, text: "")) }
                index = text.index(after: close)
            } else {
                plain.append(character)
                if tagCount <= mostTagsPerLine { stretches[stretches.count - 1].text.append(character) }
                index = text.index(after: index)
            }
        }
        let shown = String(trimmed(Substring(plain)))
        guard tagCount > 0, tagCount <= mostTagsPerLine else { return Body(text: shown, words: nil, end: nil) }

        // A stretch of spacing alone joins the word before it; a stretch with nothing is a tag in a row of tags.
        var pieces: [(time: TimeInterval, text: String)] = []
        var ceiling = lineTime
        for stretch in stretches {
            if stretch.text.isEmpty { continue }
            if trimmed(Substring(stretch.text)).isEmpty {
                if !pieces.isEmpty { pieces[pieces.count - 1].text += stretch.text }
                continue
            }
            // Times never run backward and never start before the line.
            let time = max(ceiling, stretch.time ?? lineTime)
            ceiling = time
            pieces.append((time, stretch.text))
        }
        // The words of a line join into its trimmed text: no spacing before the first or after the last.
        if let first = pieces.first {
            pieces[0].text = String(first.text.drop { $0.isWhitespace })
        }
        if let last = pieces.last {
            var kept = Substring(last.text)
            while let tail = kept.last, tail.isWhitespace { kept = kept.dropLast() }
            pieces[pieces.count - 1].text = String(kept)
        }

        // A tag with nothing after it that closes the line says where the line stops, if that is after its words.
        var end: TimeInterval?
        if let last = stretches.last, last.text.isEmpty, let time = last.time, time > (pieces.last?.time ?? lineTime) {
            end = time
        }
        let words = pieces.count >= 2 ? pieces.map { LyricWord(time: $0.time, text: $0.text) } : nil
        return Body(text: shown, words: words, end: end)
    }

    /// The ">" that could close a word tag opened at `open`; nil when none is within reach.
    private static func closingBracket(in text: Substring, after open: Substring.Index) -> Substring.Index? {
        var probe = text.index(after: open)
        var inside = 0
        while probe < text.endIndex, inside <= longestTagInside {
            if text[probe] == ">" { return probe }
            probe = text.index(after: probe)
            inside += 1
        }
        return nil
    }
}
