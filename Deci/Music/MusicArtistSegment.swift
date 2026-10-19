// Deci/Music/MusicArtistSegment.swift
import Foundation

/// One piece of the artist line under a song: plain text, or a name that opens an artist page.
struct MusicArtistSegment: Equatable, Sendable {
    let text: String
    /// The artist this piece opens; nil for plain text (separators, names with no page, anything else).
    let link: MusicArtistLink?

    /// Cuts the joined artist text ("A, B & C") into plain pieces and linked names, from the links the parser found.
    /// The pieces always join back to exactly `artist`. A name is found as a whole word (letters and digits on
    /// either side do not count), letter for letter, never inside another name; it is matched as plain text, not a
    /// pattern. Each link claims its first free stretch of the line, in link order, so two links with the same
    /// name land on the first and the second spot. A stretch that is a whole entry of the line (the parser joins
    /// the names with ", ") comes before one that is only part of an entry, so "Alpha" in "Alpha Beta, Alpha" is
    /// the last entry, not the first word of the first. A link whose name is not in the line is ignored.
    static func split(_ artist: String, links: [MusicArtistLink]) -> [MusicArtistSegment] {
        guard !artist.isEmpty else { return [] }
        // Characters, not bytes: "e" plus a combining accent is one character, and equals the single "é".
        let line = Array(artist)
        var claimed: [(range: Range<Int>, link: MusicArtistLink)] = []
        for link in links {
            let name = Array(link.name.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !name.isEmpty,
                  let range = firstFreeMatch(of: name, in: line, avoiding: claimed.map(\.range))
            else { continue }
            claimed.append((range, link))
        }
        guard !claimed.isEmpty else { return [MusicArtistSegment(text: artist, link: nil)] }

        claimed.sort { $0.range.lowerBound < $1.range.lowerBound }
        var segments: [MusicArtistSegment] = []
        var cursor = 0
        for (range, link) in claimed {
            if range.lowerBound > cursor {
                segments.append(MusicArtistSegment(text: String(line[cursor..<range.lowerBound]), link: nil))
            }
            segments.append(MusicArtistSegment(text: String(line[range]), link: link))
            cursor = range.upperBound
        }
        if cursor < line.count {
            segments.append(MusicArtistSegment(text: String(line[cursor...]), link: nil))
        }
        return segments
    }

    /// Where `name` stands in `line` without touching a range already `taken`: the first whole entry, or failing
    /// that the first whole word.
    private static func firstFreeMatch(of name: [Character], in line: [Character], avoiding taken: [Range<Int>]) -> Range<Int>? {
        guard name.count <= line.count else { return nil }
        var firstWholeWord: Range<Int>?
        for start in 0...(line.count - name.count) {
            let end = start + name.count
            guard line[start] == name[0],
                  line[start..<end].elementsEqual(name),
                  start == 0 || !isWordCharacter(line[start - 1]),
                  end == line.count || !isWordCharacter(line[end]),
                  !taken.contains(where: { $0.lowerBound < end && start < $0.upperBound })
            else { continue }
            if startsEntry(at: start, in: line), endsEntry(at: end, in: line) { return start..<end }
            if firstWholeWord == nil { firstWholeWord = start..<end }
        }
        return firstWholeWord
    }

    /// How the parser joins the names of one line.
    private static let separator = Array(", ")

    private static func startsEntry(at index: Int, in line: [Character]) -> Bool {
        index == 0 || (index >= separator.count && line[(index - separator.count)..<index].elementsEqual(separator))
    }

    private static func endsEntry(at index: Int, in line: [Character]) -> Bool {
        index == line.count || (index + separator.count <= line.count && line[index..<(index + separator.count)].elementsEqual(separator))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
