// DeciTests/Music/SongFacts/MusicSongFactsMatcherTests.swift
// Normalising titles and artists, and picking the Deezer hit that is the YouTube song.

import Foundation
import Testing
@testable import Deci

@Suite("Music song facts matcher")
struct MusicSongFactsMatcherTests {
    private typealias Matcher = MusicSongFactsMatcher

    private func candidate(
        title: String = "Blinding Lights", version: String? = nil, duration: Int = 200, rank: Int = 100,
        artist: String = "The Weeknd", id: Int = 1
    ) -> Matcher.Candidate {
        Matcher.Candidate(
            id: id, title: title, titleShort: title, titleVersion: version, isrc: nil, duration: duration, rank: rank,
            explicit: nil, artist: artist
        )
    }

    private func query(_ title: String = "Blinding Lights", artist: String = "The Weeknd", seconds: Double? = 200) -> MusicSongFactsQuery {
        MusicSongFactsQuery(artist: artist, title: title, durationSeconds: seconds)
    }

    // MARK: - Normalising

    @Test("normalising drops feat., Official, Remaster, Topic and VEVO tails", arguments: [
        ("Blinding Lights (feat. Rosalia)", "blinding lights"),
        ("Blinding Lights [feat. Rosalia]", "blinding lights"),
        ("Blinding Lights (Official Video)", "blinding lights"),
        ("Blinding Lights - 2011 Remaster", "blinding lights"),
        ("Blinding Lights - Remastered 2011", "blinding lights"),
        ("The Weeknd - Topic", "the weeknd"),
        ("TheWeekndVEVO", "theweeknd"),
        ("Tom & Jerry", "tom and jerry"),
        ("Beyoncé", "beyonce"),
        ("  Don't   Stop!!  ", "dont stop"),
        ("", "")
    ])
    func normalising(raw: String, expected: String) {
        #expect(Matcher.normalize(raw) == expected)
    }

    @Test("a title matches across feat. and remaster noise, and a different song does not")
    func titles() {
        #expect(Matcher.titlesMatch("Blinding Lights (Official Audio)", "Blinding Lights"))
        #expect(Matcher.titlesMatch("Blinding Lights", "Blinding Lights - 2020 Remaster"))
        #expect(!Matcher.titlesMatch("Blinding Lights", "Blinding Nights"))
        #expect(!Matcher.titlesMatch("", ""))
    }

    @Test("an artist matches when equal, when the words overlap, and not when unrelated")
    func artists() {
        #expect(Matcher.artistsMatch("The Weeknd", "The Weeknd"))
        #expect(Matcher.artistsMatch("The Weeknd - Topic", "the weeknd"))
        #expect(Matcher.artistsMatch("Drake, Future", "Drake"))
        #expect(Matcher.artistsMatch("Simon & Garfunkel", "Simon and Garfunkel"))
        #expect(!Matcher.artistsMatch("The Weeknd", "Ariana Grande"))
    }

    // MARK: - Choosing

    @Test("a plain match is accepted")
    func plainMatch() {
        #expect(Matcher.bestMatch(query: query(), in: [candidate()])?.id == 1)
    }

    @Test("a title with feat. and a Topic artist still matches")
    func featAndTopic() {
        let asked = query("Blinding Lights (feat. Someone)", artist: "The Weeknd - Topic")
        #expect(Matcher.bestMatch(query: asked, in: [candidate()]) != nil)
    }

    @Test("a remaster of the same song matches")
    func remaster() {
        #expect(Matcher.bestMatch(query: query(), in: [candidate(title: "Blinding Lights - Remastered 2021")]) != nil)
    }

    @Test("a live version is rejected unless the YouTube title says live")
    func live() {
        let live = candidate(version: "Live at the Forum")
        #expect(Matcher.bestMatch(query: query(), in: [live]) == nil)
        #expect(Matcher.bestMatch(query: query("Blinding Lights (Live at the Forum)"), in: [live]) != nil)
    }

    @Test("a remix is rejected unless the YouTube title says remix")
    func remix() {
        let remix = candidate(version: "Chromatics Remix")
        #expect(Matcher.bestMatch(query: query(), in: [remix]) == nil)
        #expect(Matcher.bestMatch(query: query("Blinding Lights (Chromatics Remix)"), in: [remix]) != nil)
    }

    @Test("a length 2 s off is accepted and 3 s off is rejected, either way")
    func durations() {
        #expect(Matcher.bestMatch(query: query(), in: [candidate(duration: 202)]) != nil)
        #expect(Matcher.bestMatch(query: query(), in: [candidate(duration: 198)]) != nil)
        #expect(Matcher.bestMatch(query: query(), in: [candidate(duration: 203)]) == nil)
        #expect(Matcher.bestMatch(query: query(), in: [candidate(duration: 197)]) == nil)
    }

    @Test("a song with no known length is never matched")
    func unknownLength() {
        #expect(Matcher.bestMatch(query: query(seconds: nil), in: [candidate()]) == nil)
    }

    @Test("a different artist is rejected")
    func wrongArtist() {
        #expect(Matcher.bestMatch(query: query(), in: [candidate(artist: "Ariana Grande")]) == nil)
    }

    @Test("of several passing hits the highest rank wins")
    func highestRank() {
        let hits = [candidate(rank: 10, id: 1), candidate(rank: 900, id: 2), candidate(rank: 500, id: 3)]
        #expect(Matcher.bestMatch(query: query(), in: hits)?.id == 2)
    }

    @Test("a higher ranked hit that fails the checks does not win")
    func rankedButWrong() {
        let hits = [candidate(version: "Live", rank: 9_999, id: 1), candidate(duration: 230, rank: 8_000, id: 2), candidate(rank: 5, id: 3)]
        #expect(Matcher.bestMatch(query: query(), in: hits)?.id == 3)
    }

    @Test("no hits is no match")
    func empty() {
        #expect(Matcher.bestMatch(query: query(), in: []) == nil)
    }
}
