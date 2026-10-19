// Deci/Music/Lyrics/LyricsFill.swift
import Foundation

/// The word-by-word fill of the line being sung: where in the line the singer is at a given moment, and how bright each
/// character is for that. Pure arithmetic with no UI framework, so it is tested with plain numbers; the view turns the
/// brightness into colour.
///
/// Time goes in as a clock reading and comes out as a position in characters (the sweep). A word the source timed
/// is used as it is. A line that only has a start gets its words estimated: split at the spaces, weighted by an
/// estimate of the syllables, spread over the time the line is sung in.
enum LyricFill {
    /// How long one word is allowed to take when nothing says when the line ends: a long wait for the next line is
    /// an instrumental break, not a slow word, so the fill must not crawl across it.
    static let secondsPerWord: TimeInterval = 0.6

    /// How many characters the soft edge of the fill is wide: the front of a word is not a hard cut.
    static let edgeWidth: Double = 2

    // MARK: - Words

    /// A rough syllable count: groups of vowels (a, e, i, o, u, y, accents and case ignored), never fewer than one.
    /// Wrong for plenty of English words, but only weights how the line's time is shared between its words.
    static func syllableCount(_ word: String) -> Int {
        let folded = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var groups = 0
        var inGroup = false
        for character in folded {
            let isVowel = "aeiouy".contains(character)
            if isVowel && !inGroup { groups += 1 }
            inGroup = isVowel
        }
        return max(1, groups)
    }

    /// The words of a line, each with the spacing after it, so they join back into the line. Spacing in front of the
    /// first word stays with it; a line with nothing but spacing has no words.
    static func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasLetters = false
        var inTrailingSpace = false
        for character in text {
            if character.isWhitespace {
                current.append(character)
                if hasLetters { inTrailingSpace = true }
            } else {
                if inTrailingSpace {
                    words.append(current)
                    current = ""
                    hasLetters = false
                    inTrailingSpace = false
                }
                current.append(character)
                hasLetters = true
            }
        }
        if hasLetters { words.append(current) }
        return words
    }

    // MARK: - Where the singing ends

    /// When the line stops being sung, or nil when there is no way to tell (a gap with no end and no next line).
    ///
    /// The line's own end wins when it has one. Without it the next line's start closes the line, but never later than
    /// `secondsPerWord` for each word: past that the wait is a break. A gap fills across the whole gap, with no cap.
    /// A line that starts with or after the next one has no time at all: the answer is its own start.
    static func singEnd(for line: LyricLine, nextStart: TimeInterval?) -> TimeInterval? {
        guard line.time.isFinite else { return nil }
        let own = validEnd(line.end, after: line.time)
        let next = nextStart.flatMap { $0.isFinite ? $0 : nil }
        if line.text.isEmpty {
            if let own { return own }
            if let next, next > line.time { return next }
            return nil
        }
        if let own { return own }
        let cap = line.time + Double(max(1, splitWords(line.text).count)) * secondsPerWord
        return max(line.time, min(next ?? cap, cap))
    }

    private static func validEnd(_ end: TimeInterval?, after start: TimeInterval) -> TimeInterval? {
        guard let end, end.isFinite, end > start else { return nil }
        return end
    }

    // MARK: - Estimating

    /// The words of a line that only has a start, each with the moment it starts: the line's singing time shared out
    /// by syllable weight. Empty when the line has no words or no time to sing in.
    static func estimateWords(for line: LyricLine, nextStart: TimeInterval?) -> [LyricWord] {
        let words = splitWords(line.text)
        guard !words.isEmpty, let end = singEnd(for: line, nextStart: nextStart), end > line.time else { return [] }
        let weights = words.map(syllableCount)
        let total = Double(weights.reduce(0, +))
        let duration = end - line.time
        var before = 0
        var result: [LyricWord] = []
        result.reserveCapacity(words.count)
        for (word, weight) in zip(words, weights) {
            result.append(LyricWord(time: line.time + duration * Double(before) / total, text: word))
            before += weight
        }
        return result
    }

    // MARK: - Timing

    /// One word's stretch of time and the characters it covers.
    struct Span: Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        /// Index of the word's first character in the line.
        let firstCharacter: Int
        let characterCount: Int
    }

    /// A line's words as stretches of time, back to back. `sweep(at:)` turns a clock reading into a position in the line.
    struct Timing: Equatable, Sendable {
        let characterCount: Int
        let spans: [Span]

        /// How far through the line the singer is at `time`, in characters: 0 until the first word starts, a
        /// fraction of a word's length while it is sung, the whole line once the last word is done. A clock that is
        /// not a number is the start.
        func sweep(at time: TimeInterval) -> Double {
            guard time.isFinite else { return 0 }
            for span in spans {
                if time < span.start { return Double(span.firstCharacter) }
                if time < span.end {
                    let through = (time - span.start) / (span.end - span.start)
                    return Double(span.firstCharacter) + through * Double(span.characterCount)
                }
            }
            return spans.isEmpty ? 0 : Double(characterCount)
        }
    }

    /// The fill timing of a line, or nil when it has none: nothing to fill, or no time to sing in.
    ///
    /// Real word times are used when they add up to the line's text (words from a source that timed them). Anything
    /// else gets the estimate. A word runs until the next one starts; the last runs to the line's end, else for one
    /// `secondsPerWord` (sooner if the next line starts first), so a distant next line does not stretch it.
    static func timing(for line: LyricLine, nextStart: TimeInterval?) -> Timing? {
        guard line.time.isFinite else { return nil }
        if line.text.isEmpty {
            guard let end = singEnd(for: line, nextStart: nextStart), end > line.time else { return nil }
            return Timing(characterCount: 1, spans: [Span(start: line.time, end: end, firstCharacter: 0, characterCount: 1)])
        }

        let characterCount = line.text.count
        if let words = line.words, !words.isEmpty, words.map(\.text).joined() == line.text,
           words.allSatisfy({ $0.time.isFinite }),
           words.reduce(0, { $0 + $1.text.count }) == characterCount {
            return explicitTiming(words, line: line, nextStart: nextStart, characterCount: characterCount)
        }

        let words = estimateWords(for: line, nextStart: nextStart)
        guard !words.isEmpty, let end = singEnd(for: line, nextStart: nextStart), words.reduce(0, { $0 + $1.text.count }) == characterCount else {
            return nil
        }
        return Timing(characterCount: characterCount, spans: spans(of: words, lastEnd: end))
    }

    private static func explicitTiming(
        _ words: [LyricWord], line: LyricLine, nextStart: TimeInterval?, characterCount: Int
    ) -> Timing? {
        // Times never run backward: a word that claims to start before the one ahead of it starts with it.
        var ceiling = -TimeInterval.infinity
        let ordered = words.map { word -> LyricWord in
            ceiling = max(ceiling, word.time)
            return LyricWord(time: ceiling, text: word.text)
        }
        guard let last = ordered.last else { return nil }
        let cap = last.time + secondsPerWord
        let next = nextStart.flatMap { $0.isFinite ? $0 : nil }
        let lastEnd = validEnd(line.end, after: last.time) ?? max(last.time, min(next ?? cap, cap))
        guard lastEnd > ordered[0].time else { return nil }
        return Timing(characterCount: characterCount, spans: spans(of: ordered, lastEnd: lastEnd))
    }

    private static func spans(of words: [LyricWord], lastEnd: TimeInterval) -> [Span] {
        var result: [Span] = []
        result.reserveCapacity(words.count)
        var first = 0
        for (index, word) in words.enumerated() {
            let end = index + 1 < words.count ? words[index + 1].time : lastEnd
            let count = word.text.count
            result.append(Span(start: word.time, end: max(word.time, end), firstCharacter: first, characterCount: count))
            first += count
        }
        return result
    }

    // MARK: - Characters

    /// The brightness of each character of a line when the singer is `sweep` characters in: `sung` behind the front,
    /// `unsung` ahead of it and a ramp about `edgeWidth` characters wide between them.
    ///
    /// The front is scaled so that it has crossed the whole ramp exactly when the sweep reaches the end of the
    /// line: the last character is fully lit when the line is done, with no jump. Brightness only ever falls along
    /// the line and only ever rises as the sweep moves on. A sweep that is not a number or below zero is the start.
    static func alphas(characterCount: Int, sweep: Double, unsung: Double, sung: Double) -> [Double] {
        guard characterCount > 0 else { return [] }
        guard sweep.isFinite, sweep > 0 else { return Array(repeating: unsung, count: characterCount) }
        let front = sweep * (Double(characterCount) + edgeWidth) / Double(characterCount)
        return (0..<characterCount).map { index in
            let lit = (front - Double(index)) / edgeWidth
            if lit <= 0 { return unsung }
            if lit >= 1 { return sung }
            return min(sung, max(unsung, unsung + (sung - unsung) * lit))
        }
    }

    /// A stretch of neighbouring characters at one brightness.
    struct Run: Equatable, Sendable {
        let range: Range<Int>
        let alpha: Double
    }

    /// The brightness list as runs: a frame of the sweep is a few runs, not one per character.
    static func runs(of alphas: [Double]) -> [Run] {
        var result: [Run] = []
        var start = 0
        while start < alphas.count {
            var end = start + 1
            while end < alphas.count, alphas[end] == alphas[start] { end += 1 }
            result.append(Run(range: start..<end, alpha: alphas[start]))
            start = end
        }
        return result
    }
}
