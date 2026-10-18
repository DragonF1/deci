// Deci/Music/Lyrics/LyricsIdentity.swift
import Foundation

/// Does an LRCLIB search hit describe the song that was asked for? A hit within the length window by another artist
/// ("Stay", "Intro") would otherwise win and be cached for 30 days.
///
/// Both sides are folded (case, diacritics, apostrophes, punctuation, "&" as "and") and compared in whole words, so
/// "Stay (Remastered 2011)" matches "Stay" but "Stayin Alive" does not. The title also passes when the cleaned forms
/// (no "(feat. ...)", "[Live]", " - Remastered 2011") match, and only the first queried artist counts: the record
/// artist must contain it or be contained by it. Lenient on purpose, because the length window is the other half of
/// the check.
enum LyricsIdentity {
    static func matches(recordTitle: String?, recordArtist: String?, title: String, artist: String) -> Bool {
        guard let recordTitle, let recordArtist else { return false }
        return titleMatches(recordTitle, title) && artistMatches(recordArtist, artist)
    }

    // MARK: - Pieces

    private static func titleMatches(_ recordTitle: String, _ title: String) -> Bool {
        let record = candidates(recordTitle)
        let queried = candidates(title)
        guard !record.isEmpty, !queried.isEmpty else { return false }
        for a in record {
            for b in queried where overlaps(a, b) { return true }
        }
        return false
    }

    private static func artistMatches(_ recordArtist: String, _ artist: String) -> Bool {
        let record = words(recordArtist)
        // The record has to name an artist to be checked at all.
        guard !record.isEmpty else { return false }
        let queried = words(LyricsTitleCleaner.firstArtist(artist))
        // No queried artist, no condition on it.
        guard !queried.isEmpty else { return true }
        return overlaps(record, queried)
    }

    /// The title as it is and with its packaging removed, each as folded words; empty ones left out.
    private static func candidates(_ title: String) -> [[String]] {
        var result: [[String]] = []
        for text in [title, LyricsTitleCleaner.cleanTitle(title)] {
            let folded = words(text)
            if !folded.isEmpty, !result.contains(folded) { result.append(folded) }
        }
        return result
    }

    /// One contains the other as a run of whole words (equal counts).
    private static func overlaps(_ a: [String], _ b: [String]) -> Bool {
        contains(a, b) || contains(b, a)
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }

    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "`"]

    /// Lowercase, diacritics gone, apostrophes dropped, "&" as "and", every other punctuation mark a word break.
    /// Letters, digits and symbols such as emoji stay, so a title in another script or an emoji still compares.
    /// A title made only of punctuation is compared as it is (trimmed and lowercased) instead of as nothing.
    private static func words(_ text: String) -> [String] {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        var spaced = ""
        spaced.reserveCapacity(folded.count)
        for character in folded where !apostrophes.contains(character) {
            spaced.append(character.isWhitespace || character.isPunctuation ? " " : character)
        }
        let result = spaced.split(separator: " ").map(String.init)
        if !result.isEmpty { return result }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw.isEmpty ? [] : [raw]
    }
}
