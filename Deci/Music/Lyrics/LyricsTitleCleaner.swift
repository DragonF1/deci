// Deci/Music/Lyrics/LyricsTitleCleaner.swift
import Foundation

/// Turns a YouTube title and artist line into what LRCLIB tends to index: no "(feat. ...)", "(Official Video)",
/// "[...]" or " - Remastered 2011", and only the first artist. Used for one retry after a search finds nothing,
/// so being a little eager costs nothing.
enum LyricsTitleCleaner {
    /// Words that mark a parenthesis or a dash segment as packaging, not part of the song's name.
    private static let noise: Set<String> = [
        "feat", "ft", "featuring", "official", "video", "audio", "lyric", "lyrics", "visualizer", "visualiser",
        "remaster", "remastered", "explicit", "hd", "hq", "4k", "live", "mono", "stereo", "edit", "version", "mix",
    ]

    private static let artistSeparators = [",", " & ", " feat. ", " feat ", " ft. ", " ft ", " x ", " \u{00D7} "]

    static func cleanTitle(_ title: String) -> String {
        let original = collapsed(title)
        var text = removingGroups(original, open: "[", close: "]") { _ in true }
        text = removingGroups(text, open: "(", close: ")", where: containsNoise)

        // " - Remastered 2011", " - Radio Edit": later dash segments with noise go, the first one always stays.
        let segments = text.components(separatedBy: " - ")
        if segments.count > 1 {
            text = ([segments[0]] + segments.dropFirst().filter { !containsNoise($0) }).joined(separator: " - ")
        }

        // "Song feat. Someone" with no parentheses.
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        if let cut = words.indices.dropFirst().first(where: { ["feat", "feat.", "ft", "ft.", "featuring"].contains(words[$0].lowercased()) }) {
            text = words[..<cut].joined(separator: " ")
        }

        let result = collapsed(text)
        return result.isEmpty ? original : result
    }

    static func firstArtist(_ artist: String) -> String {
        let line = collapsed(artist)
        var cut = line.endIndex
        for separator in artistSeparators {
            if let range = line.range(of: separator, options: .caseInsensitive), range.lowerBound < cut {
                cut = range.lowerBound
            }
        }
        return String(line[..<cut]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Pieces

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func containsNoise(_ text: String) -> Bool {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains { noise.contains(String($0)) }
    }

    /// Drops every `open...close` group whose inside passes `drop`. A group with no closing mark stays.
    private static func removingGroups(_ text: String, open: Character, close: Character, where drop: (String) -> Bool) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == open, let end = text[index...].firstIndex(of: close) {
                let inner = String(text[text.index(after: index)..<end])
                if drop(inner) {
                    index = text.index(after: end)
                    continue
                }
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }
}
