// Deci/Music/Lyrics/LRCParser.swift
import Foundation

/// Parses LRC text ("[mm:ss.xx]line") into timed lines, and finds the line a playhead is on.
enum LRCParser {
    /// Lines sorted by time. Metadata tags (`ar`, `ti`, `al`, `by`, `length`, ...) are dropped, `[offset:]` is
    /// applied, empty timed lines stay as gaps and malformed lines are skipped.
    static func parse(_ text: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var entries: [(time: TimeInterval, text: String)] = []

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

            let words = stripWordTags(trimmed(rest))
            for stamp in stamps { entries.append((stamp, words)) }
        }

        let adjusted = entries.enumerated().map { index, entry in
            (index: index, line: LyricLine(time: max(0, entry.time - offset), text: entry.text))
        }
        return adjusted
            .sorted { ($0.line.time, $0.index) < ($1.line.time, $1.index) }
            .map(\.line)
    }

    /// The index of the last line at or before `time`; nil before the first line or without lines.
    /// Binary search: the view asks ten times a second.
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

    /// Removes enhanced-LRC word tags such as "<00:05.40>", which a plain line has no use for.
    /// The ">" is looked for only as far as a tag can reach, so a line of nothing but "<" costs a few steps per
    /// character instead of a scan to the end of the line for each one (the body of a hostile reply can be 2 MB).
    private static func stripWordTags(_ text: Substring) -> String {
        guard text.contains("<") else { return String(text) }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = closingBracket(in: text, after: index),
               timestamp(text[text.index(after: index)..<close]) != nil {
                index = text.index(after: close)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return String(trimmed(Substring(result)))
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
