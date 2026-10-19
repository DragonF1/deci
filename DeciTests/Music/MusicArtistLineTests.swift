// DeciTests/Music/MusicArtistLineTests.swift
// The artist line under a song: the joined artist text cut into plain pieces and clickable names, from the
// links the parser found. The pieces always read back as the same text.

import Foundation
import Testing
@testable import Deci

@Suite("MusicArtistSegment")
struct MusicArtistLineTests {
    private static func link(_ name: String, _ id: String? = nil) -> MusicArtistLink {
        MusicArtistLink(name: name, browseId: id ?? "UC\(name)")
    }

    private func texts(_ segments: [MusicArtistSegment]) -> [String] { segments.map(\.text) }
    private func linked(_ segments: [MusicArtistSegment]) -> [String?] { segments.map { $0.link?.browseId } }

    /// The pieces put back together, which must be exactly what the row shows today.
    private func joined(_ segments: [MusicArtistSegment]) -> String { segments.map(\.text).joined() }

    // MARK: - Shapes

    @Test("no links leave the whole line as one plain piece")
    func noLinks() {
        let segments = MusicArtistSegment.split("Various artists", links: [])
        #expect(texts(segments) == ["Various artists"])
        #expect(linked(segments) == [nil])
    }

    @Test("an empty line has no pieces")
    func emptyLine() {
        #expect(MusicArtistSegment.split("", links: []).isEmpty)
        #expect(MusicArtistSegment.split("", links: [Self.link("A")]).isEmpty)
    }

    @Test("one link that is the whole line is one clickable piece")
    func wholeLine() {
        let segments = MusicArtistSegment.split("Some Band", links: [Self.link("Some Band")])
        #expect(texts(segments) == ["Some Band"])
        #expect(linked(segments) == ["UCSome Band"])
    }

    @Test("names split by commas and an ampersand each get a button, the separators stay plain")
    func commaAndAmpersand() {
        let links = [Self.link("Alpha"), Self.link("Beta"), Self.link("Gamma")]
        let segments = MusicArtistSegment.split("Alpha, Beta & Gamma", links: links)
        #expect(texts(segments) == ["Alpha", ", ", "Beta", " & ", "Gamma"])
        #expect(linked(segments) == ["UCAlpha", nil, "UCBeta", nil, "UCGamma"])
    }

    @Test("an unlinked name stays plain next to a linked one")
    func unlinkedBesideLinked() {
        let segments = MusicArtistSegment.split("Various artists, Alpha", links: [Self.link("Alpha")])
        #expect(texts(segments) == ["Various artists, ", "Alpha"])
        #expect(linked(segments) == [nil, "UCAlpha"])
    }

    @Test("text after the last link stays plain")
    func trailingText() {
        let segments = MusicArtistSegment.split("Alpha feat. Someone", links: [Self.link("Alpha")])
        #expect(texts(segments) == ["Alpha", " feat. Someone"])
        #expect(linked(segments) == ["UCAlpha", nil])
    }

    @Test("a link whose name is not in the line is ignored")
    func missingName() {
        let segments = MusicArtistSegment.split("Alpha & Beta", links: [Self.link("Gamma"), Self.link("Beta")])
        #expect(texts(segments) == ["Alpha & ", "Beta"])
        #expect(linked(segments) == [nil, "UCBeta"])
    }

    @Test("a link with a blank name is ignored")
    func blankName() {
        let segments = MusicArtistSegment.split("Alpha", links: [Self.link(""), Self.link("  ", "UCblank")])
        #expect(texts(segments) == ["Alpha"])
        #expect(linked(segments) == [nil])
    }

    // MARK: - Matching

    @Test("a name inside another word is not a match")
    func wholeWordsOnly() {
        let segments = MusicArtistSegment.split("Abo, Ab", links: [Self.link("Ab")])
        #expect(texts(segments) == ["Abo, ", "Ab"])
        #expect(linked(segments) == [nil, "UCAb"])
    }

    @Test("a name at the start of a longer name only matches as a whole")
    func prefixNames() {
        let links = [Self.link("Kel"), Self.link("Kelmore")]
        let segments = MusicArtistSegment.split("Kelmore, Kel", links: links)
        #expect(texts(segments) == ["Kelmore", ", ", "Kel"])
        #expect(linked(segments) == ["UCKelmore", nil, "UCKel"])
    }

    @Test("links given in another order than the line still land on their names")
    func linksOutOfOrder() {
        let links = [Self.link("Beta"), Self.link("Alpha")]
        let segments = MusicArtistSegment.split("Alpha, Beta", links: links)
        #expect(texts(segments) == ["Alpha", ", ", "Beta"])
        #expect(linked(segments) == ["UCAlpha", nil, "UCBeta"])
    }

    @Test("two links never claim the same stretch of text")
    func noOverlap() {
        let links = [Self.link("Alpha", "UC1"), Self.link("Alpha", "UC2")]
        let segments = MusicArtistSegment.split("Alpha & Alpha", links: links)
        #expect(texts(segments) == ["Alpha", " & ", "Alpha"])
        #expect(linked(segments) == ["UC1", nil, "UC2"])
    }

    @Test("one link for a name that appears twice makes only one button")
    func oneLinkTwoNames() {
        let segments = MusicArtistSegment.split("Alpha & Alpha", links: [Self.link("Alpha")])
        #expect(segments.filter { $0.link != nil }.count == 1)
        #expect(joined(segments) == "Alpha & Alpha")
    }

    // MARK: - Whole entries first

    @Test("a name that is also the start of an earlier entry links the entry that is exactly the name")
    func entryBeatsInnerWord() {
        let segments = MusicArtistSegment.split("Alpha Beta, Alpha", links: [Self.link("Alpha")])
        #expect(texts(segments) == ["Alpha Beta, ", "Alpha"])
        #expect(linked(segments) == [nil, "UCAlpha"])
    }

    @Test("a name with a hyphen does not link the first half of an earlier hyphenated name")
    func hyphenatedEntryBeatsInnerWord() {
        let segments = MusicArtistSegment.split("Gee-Kay, Gee", links: [Self.link("Gee")])
        #expect(texts(segments) == ["Gee-Kay, ", "Gee"])
        #expect(linked(segments) == [nil, "UCGee"])
    }

    @Test("both a hyphenated name and its first half link to their own entries, in either link order")
    func hyphenatedAndShortBothLinked() {
        let orders = [[Self.link("Gee"), Self.link("Gee-Kay")], [Self.link("Gee-Kay"), Self.link("Gee")]]
        for links in orders {
            let segments = MusicArtistSegment.split("Gee-Kay, Gee", links: links)
            #expect(texts(segments) == ["Gee-Kay", ", ", "Gee"])
            #expect(linked(segments) == ["UCGee-Kay", nil, "UCGee"])
        }
    }

    @Test("when the first match already is a whole entry it stays the one that links")
    func firstEntryStillWins() {
        let segments = MusicArtistSegment.split("Alpha, Alpha Beta", links: [Self.link("Alpha")])
        #expect(texts(segments) == ["Alpha", ", Alpha Beta"])
        #expect(linked(segments) == ["UCAlpha", nil])
    }

    @Test("a name that is only part of an entry still links when no entry is exactly the name")
    func fallsBackToAnyWholeWord() {
        let segments = MusicArtistSegment.split("Alpha feat. Beta", links: [Self.link("Beta")])
        #expect(texts(segments) == ["Alpha feat. ", "Beta"])
        #expect(linked(segments) == [nil, "UCBeta"])
    }

    @Test("two links with one name land on the entries that are exactly the name, not on the word inside another entry")
    func twoLinksSkipTheInnerWord() {
        let segments = MusicArtistSegment.split("Alpha, Alpha Beta, Alpha", links: [Self.link("Alpha", "UC1"), Self.link("Alpha", "UC2")])
        #expect(texts(segments) == ["Alpha", ", Alpha Beta, ", "Alpha"])
        #expect(linked(segments) == ["UC1", nil, "UC2"])
    }

    @Test("a name that holds a comma is found as an entry of its own")
    func nameWithComma() {
        let segments = MusicArtistSegment.split("Zed, The Maker, Alpha", links: [Self.link("Zed, The Maker"), Self.link("Alpha")])
        #expect(texts(segments) == ["Zed, The Maker", ", ", "Alpha"])
        #expect(linked(segments) == ["UCZed, The Maker", nil, "UCAlpha"])
    }

    @Test("names with punctuation match as plain text, not as a pattern")
    func punctuation() {
        let links = [Self.link("AB/XY"), Self.link("Q!zz"), Self.link("B$QR Tester"), Self.link("(K)L-MNO")]
        let line = "AB/XY, Q!zz, B$QR Tester & (K)L-MNO"
        let segments = MusicArtistSegment.split(line, links: links)
        #expect(linked(segments) == ["UCAB/XY", nil, "UCQ!zz", nil, "UCB$QR Tester", nil, "UC(K)L-MNO"])
        #expect(joined(segments) == line)
    }

    @Test("a name has to match letter for letter, case included")
    func caseSensitive() {
        let segments = MusicArtistSegment.split("alpha", links: [Self.link("Alpha")])
        #expect(texts(segments) == ["alpha"])
        #expect(linked(segments) == [nil])
    }

    @Test("unicode names and emoji split on the right characters")
    func unicode() {
        let links = [Self.link("Müvra"), Self.link("字音楽"), Self.link("🎵 Testers"), Self.link("Sunnar Réd")]
        let line = "Müvra, 字音楽, 🎵 Testers & Sunnar Réd"
        let segments = MusicArtistSegment.split(line, links: links)
        #expect(linked(segments) == ["UCMüvra", nil, "UC字音楽", nil, "UC🎵 Testers", nil, "UCSunnar Réd"])
        #expect(joined(segments) == line)
    }

    @Test("a decomposed accent in the line still matches the name as typed in the link")
    func normalisedAccents() {
        let line = "Mu\u{0308}vra"
        let segments = MusicArtistSegment.split(line, links: [Self.link("Müvra")])
        #expect(joined(segments) == line)
        #expect(linked(segments) == ["UCMüvra"])
    }

    @Test("a name next to a combining mark is not cut in the middle of a character")
    func combiningBoundary() {
        let line = "Ave\u{0301}ra, Ave"
        let segments = MusicArtistSegment.split(line, links: [Self.link("Ave")])
        #expect(joined(segments) == line)
        #expect(texts(segments).last == "Ave")
        #expect(linked(segments).last == "UCAve")
    }

    // MARK: - Invariants

    @Test("the pieces always read back as the original line")
    func alwaysJoinsBack() {
        let cases: [(String, [MusicArtistLink])] = [
            ("", []),
            ("A", []),
            ("A", [Self.link("A")]),
            ("A, B & C", [Self.link("C"), Self.link("A")]),
            ("  A  ,  B  ", [Self.link("A"), Self.link("B")]),
            ("A\nB", [Self.link("B")]),
            ("A, A, A", [Self.link("A")]),
            ("Alpha Alphabet", [Self.link("Alpha"), Self.link("Alphabet")]),
            ("x", [Self.link("xyz")]),
        ]
        for (line, links) in cases {
            #expect(joined(MusicArtistSegment.split(line, links: links)) == line)
        }
    }

    @Test("no piece is empty")
    func noEmptyPieces() {
        let links = [Self.link("A"), Self.link("B")]
        for line in ["A", "AB", "A,B", "A B", "A, B", ", A", "B, ", "A&B"] {
            let segments = MusicArtistSegment.split(line, links: links)
            #expect(segments.allSatisfy { !$0.text.isEmpty })
        }
    }

    @Test("every clickable piece is exactly its link's name")
    func linkedPiecesAreTheName() {
        let links = [Self.link("Alpha"), Self.link("Beta")]
        let segments = MusicArtistSegment.split("Alpha, Beta & Alpha Beta", links: links)
        for segment in segments {
            if let link = segment.link { #expect(segment.text == link.name) }
        }
    }

    @Test("two plain stretches never sit side by side")
    func plainPiecesMerge() {
        let segments = MusicArtistSegment.split("One, Two, Three", links: [Self.link("Gone")])
        #expect(texts(segments) == ["One, Two, Three"])
    }

    @Test("a long line with many links stays fast and correct")
    func manyLinks() {
        let names = (0..<500).map { "Artist\($0)" }
        let links = names.map { Self.link($0) }
        let line = names.joined(separator: ", ")
        let segments = MusicArtistSegment.split(line, links: links)
        #expect(segments.filter { $0.link != nil }.count == 500)
        #expect(joined(segments) == line)
    }
}
