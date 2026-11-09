// Deci/Music/SongFacts/MusicSongFactsMatcher.swift
// Decides whether a Deezer search hit is the song that was asked about. Pure.

import Foundation

enum MusicSongFactsMatcher {
    /// How far a hit's length may be from the song's, either way, in seconds.
    static let durationTolerance = 2.0

    /// One Deezer search hit, as much of it as matching needs.
    struct Candidate: Sendable, Equatable {
        var id: Int
        var title: String
        var titleShort: String?
        var titleVersion: String?
        var isrc: String?
        var duration: Int
        var rank: Int
        var explicit: Bool?
        var artist: String
    }

    // MARK: - Normalising

    /// Lowercase, no accents, no "(feat ...)", "(Official ...)", "Remaster..." or " - Topic", no VEVO, "&" as "and", no
    /// punctuation, single spaces.
    static func normalize(_ raw: String) -> String {
        var text = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
        text = replace(text, bracketNoise, " ")
        text = replace(text, remasterTail, " ")
        text = replace(text, topicTail, " ")
        text = replace(text, featuringTail, " ")
        text = replace(text, vevoTail, " ")
        text = text.replacingOccurrences(of: "&", with: " and ")
        // An apostrophe is part of the word ("don't" is "dont"), not a break between two.
        text = text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        let kept = text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static let bracketNoise = #"[\(\[][^\)\]]*\b(feat|ft|featuring|official|remaster|remastered|lyrics?|audio|video|visuali[sz]er|explicit)\b[^\)\]]*[\)\]]"#
    private static let remasterTail = #"\s+-\s+(\d{4}\s+)?(digital\s+)?remaster(ed)?(\s+\d{4})?(\s+version)?\s*$|\s+(\d{4}\s+)?remaster(ed)?(\s+\d{4})?\s*$"#
    private static let topicTail = #"\s+-\s+topic\s*$"#
    private static let featuringTail = #"\s+(feat|ft|featuring)\b\.?\s+.*$"#
    private static let vevoTail = #"\s*vevo\s*$"#

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    private static func compact(_ normalised: String) -> String {
        normalised.replacingOccurrences(of: " ", with: "")
    }

    private static let stopWords: Set<String> = ["the", "and", "a", "of"]

    static func titlesMatch(_ asked: String, _ candidate: String) -> Bool {
        let left = normalize(asked)
        let right = normalize(candidate)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || compact(left) == compact(right)
    }

    /// The main artist of the hit is the song's artist, or the two share a word ("Weeknd" and "The Weeknd", or one name of
    /// several in "A, B").
    static func artistsMatch(_ asked: String, _ candidate: String) -> Bool {
        let left = normalize(asked)
        let right = normalize(candidate)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right || compact(left) == compact(right) { return true }
        let leftWords = Set(left.split(separator: " ").map(String.init)).subtracting(stopWords)
        let rightWords = Set(right.split(separator: " ").map(String.init)).subtracting(stopWords)
        if !leftWords.isDisjoint(with: rightWords) { return true }
        // A name written without spaces ("TheWeeknd") may hold the other; a short name is too likely to sit inside any.
        let (short, long) = compact(left).count <= compact(right).count ? (compact(left), compact(right)) : (compact(right), compact(left))
        return short.count >= 5 && long.contains(short)
    }

    // MARK: - Matching

    /// The hit to use: titles equal, artists matching, the length within two seconds, and no live or remix version unless
    /// the song's own title says so. The most popular (highest rank) of those that pass. A song with no usable length is
    /// matched on title and artist alone, and only when the hits that pass agree on the length (within two seconds of each
    /// other), so two different recordings under one title are not mixed up.
    static func bestMatch(query: MusicSongFactsQuery, in candidates: [Candidate]) -> Candidate? {
        let seconds = query.durationSeconds.flatMap { $0.isFinite ? $0 : nil }
        let askedTitle = stripArtistPrefix(from: query.title, artist: query.artist)
        let wantsLive = mentions(query.title, "live")
        let wantsRemix = mentions(query.title, "remix")
        let passing = candidates.filter { candidate in
            let titleOK = titlesMatch(askedTitle, candidate.title)
                || candidate.titleShort.map { titlesMatch(askedTitle, $0) } == true
                // The YouTube title may carry the version ("Song (Live at the Forum)") that Deezer keeps apart.
                || candidate.titleVersion.map { !$0.isEmpty && titlesMatch(askedTitle, "\(candidate.title) \($0)") } == true
            guard titleOK, artistsMatch(query.artist, candidate.artist) else { return false }
            if let seconds, abs(Double(candidate.duration) - seconds) > durationTolerance { return false }
            let version = "\(candidate.titleVersion ?? "") \(candidate.title)"
            if mentions(version, "live"), !wantsLive { return false }
            if mentions(version, "remix"), !wantsRemix { return false }
            return true
        }
        if seconds == nil, let shortest = passing.map(\.duration).min(), let longest = passing.map(\.duration).max(),
           Double(longest - shortest) > durationTolerance {
            return nil
        }
        return passing.max { $0.rank < $1.rank }
    }

    /// "The Weeknd - Blinding Lights" asked for under the artist "The Weeknd" is the song "Blinding Lights".
    private static func stripArtistPrefix(from title: String, artist: String) -> String {
        for separator in [" - ", " \u{2013} ", " \u{2014} "] {
            guard let range = title.range(of: separator) else { continue }
            let head = String(title[..<range.lowerBound])
            if artistsMatch(artist, head) { return String(title[range.upperBound...]) }
        }
        return title
    }

    private static func mentions(_ text: String, _ word: String) -> Bool {
        text.lowercased().range(of: #"\b\#(word)(s|ed)?\b"#, options: .regularExpression) != nil
    }
}
