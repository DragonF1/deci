// Deci/Music/MusicLocalSearch.swift
import Foundation

/// The matcher behind the search field's local scopes (Library, a playlist, an album, Up next): what was typed is split
/// into words, and an item matches when every word is found in one of its fields, ignoring case and accents. It also
/// says where each word sits in a text, so the rows can tint the match. Pure and tested; the views only call it.
nonisolated enum MusicLocalSearch {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The words of a query: split on whitespace, none empty. An empty or blank query has no words and matches everything.
    static func terms(of query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether every word is in at least one of the fields. No words, no filter: everything matches.
    static func matches(_ fields: [String], terms: [String]) -> Bool {
        terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: options) != nil }
        }
    }

    /// Where the words are in `text`, as ranges of the original string, in order, with overlapping and touching
    /// ranges merged. Nothing for no words or no match.
    static func highlights(in text: String, terms: [String]) -> [Range<String.Index>] {
        guard !terms.isEmpty, !text.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        for term in terms {
            var from = text.startIndex
            while from < text.endIndex,
                  let range = text.range(of: term, options: options, range: from..<text.endIndex),
                  !range.isEmpty {
                found.append(range)
                from = range.upperBound
            }
        }
        return merged(found)
    }

    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

// MARK: - Songs and collections

extension MusicLocalSearch {
    /// What a song is searched by: its title, its artist line and its album.
    @MainActor
    static func fields(of track: MusicTrack) -> [String] {
        [track.title, track.artist, track.album ?? ""]
    }

    /// What a playlist, album or artist is searched by: its title and YouTube's own second line (owner, artist, year).
    @MainActor
    static func fields(of collection: MusicCollection) -> [String] {
        [collection.title, detail(ofSubtitle: collection.subtitle)]
    }

    /// The words YouTube leads a second line with to say what the item is.
    private static let kindWords: Set<String> = ["playlist", "album", "single", "ep", "artist"]

    /// YouTube's second line as the design shows it, without the kind word it may lead with ("Album \u{00B7} M83 \u{00B7} 2011"
    /// is searched as "M83 \u{00B7} 2011"), so "playlist" does not match every playlist.
    static func detail(ofSubtitle subtitle: String) -> String {
        let line = MusicHomeText.subtitle(subtitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = " \u{00B7} "
        let first = line.range(of: separator).map { String(line[..<$0.lowerBound]) } ?? line
        guard kindWords.contains(first.lowercased()) else { return line }
        guard let cut = line.range(of: separator) else { return "" }
        return String(line[cut.upperBound...])
    }

    /// The positions in `tracks` of the songs that match, in order. Positions, not songs: an album numbers its rows by
    /// where the song sits in the album, filtered or not.
    @MainActor
    static func indices(of tracks: [MusicTrack], terms: [String]) -> [Int] {
        guard !terms.isEmpty else { return Array(tracks.indices) }
        return tracks.indices.filter { matches(fields(of: tracks[$0]), terms: terms) }
    }

    @MainActor
    static func filter(_ tracks: [MusicTrack], terms: [String]) -> [MusicTrack] {
        indices(of: tracks, terms: terms).map { tracks[$0] }
    }

    @MainActor
    static func filter(_ collections: [MusicCollection], terms: [String]) -> [MusicCollection] {
        guard !terms.isEmpty else { return collections }
        return collections.filter { matches(fields(of: $0), terms: terms) }
    }
}
