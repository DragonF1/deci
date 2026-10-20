// DeciTests/Music/MusicLocalSearchTests.swift
// The matcher behind the search field's local scopes: words, case and accents, which fields count, where a match sits
// in a text and which songs and collections a query keeps. Nothing here draws a view.

import Foundation
import Testing
@testable import Deci

@Suite("MusicLocalSearch terms")
struct MusicLocalSearchTermsTests {
    @Test("a query splits on any whitespace into words, none of them empty")
    func splits() {
        #expect(MusicLocalSearch.terms(of: "late night") == ["late", "night"])
        #expect(MusicLocalSearch.terms(of: "  late \t night\n drive  ") == ["late", "night", "drive"])
    }

    @Test("an empty or blank query has no words")
    func blank() {
        #expect(MusicLocalSearch.terms(of: "").isEmpty)
        #expect(MusicLocalSearch.terms(of: "   \n\t ").isEmpty)
    }

    @Test("punctuation, emoji and SQL characters stay in the words as they were typed")
    func special() {
        #expect(MusicLocalSearch.terms(of: "rock'n'roll") == ["rock'n'roll"])
        #expect(MusicLocalSearch.terms(of: "50% OR 1=1; --") == ["50%", "OR", "1=1;", "--"])
        #expect(MusicLocalSearch.terms(of: "\u{1F3B5} mix") == ["\u{1F3B5}", "mix"])
    }
}

@Suite("MusicLocalSearch matches")
struct MusicLocalSearchMatchTests {
    @Test("no words match everything, even a row with no text")
    func emptyTerms() {
        #expect(MusicLocalSearch.matches(["Song", "Artist"], terms: []))
        #expect(MusicLocalSearch.matches([], terms: []))
        #expect(MusicLocalSearch.matches(["", ""], terms: []))
    }

    @Test("case does not matter, either way round")
    func caseInsensitive() {
        #expect(MusicLocalSearch.matches(["Midnight City"], terms: ["MIDNIGHT"]))
        #expect(MusicLocalSearch.matches(["MIDNIGHT CITY"], terms: ["city"]))
    }

    @Test("accents do not matter, either way round")
    func diacriticInsensitive() {
        #expect(MusicLocalSearch.matches(["Caf\u{00E9} del Mar"], terms: ["cafe"]))
        #expect(MusicLocalSearch.matches(["Cafe del Mar"], terms: ["caf\u{00E9}"]))
        #expect(MusicLocalSearch.matches(["Sigur R\u{00F3}s"], terms: ["ros"]))
        #expect(MusicLocalSearch.matches(["Beyonc\u{00E9}"], terms: ["BEYONCE"]))
    }

    @Test("a word matches inside a longer one, not only at its start")
    func substring() {
        #expect(MusicLocalSearch.matches(["Midnight City"], terms: ["night"]))
        #expect(MusicLocalSearch.matches(["Midnight City"], terms: ["ty"]))
    }

    @Test("a word that is nowhere does not match")
    func noMatch() {
        #expect(MusicLocalSearch.matches(["Midnight City", "M83"], terms: ["zzz"]) == false)
        #expect(MusicLocalSearch.matches([], terms: ["a"]) == false)
    }

    @Test("a word may be found in any one of the fields")
    func anyField() {
        let fields = ["Midnight City", "M83", "Hurry Up, We're Dreaming"]
        #expect(MusicLocalSearch.matches(fields, terms: ["city"]))
        #expect(MusicLocalSearch.matches(fields, terms: ["m83"]))
        #expect(MusicLocalSearch.matches(fields, terms: ["dreaming"]))
    }

    @Test("every word has to be found, each in whichever field has it")
    func andOverTerms() {
        let fields = ["Midnight City", "M83", "Hurry Up"]
        #expect(MusicLocalSearch.matches(fields, terms: ["city", "m83"]))
        #expect(MusicLocalSearch.matches(fields, terms: ["m83", "hurry", "midnight"]))
        #expect(MusicLocalSearch.matches(fields, terms: ["city", "zzz"]) == false)
    }

    @Test("a word is never found across the gap between two fields")
    func notAcrossFields() {
        #expect(MusicLocalSearch.matches(["Song", "Artist"], terms: ["songartist"]) == false)
    }

    @Test("a long or odd word is just a word that is not found")
    func oddWords() {
        let long = String(repeating: "x", count: 10_000)
        #expect(MusicLocalSearch.matches(["Song"], terms: [long]) == false)
        #expect(MusicLocalSearch.matches(["50% off"], terms: ["50%"]))
        #expect(MusicLocalSearch.matches(["Robert'); DROP TABLE"], terms: ["');"]))
    }
}

@Suite("MusicLocalSearch highlights")
struct MusicLocalSearchHighlightTests {
    private func pieces(_ text: String, _ terms: [String]) -> [String] {
        MusicLocalSearch.highlights(in: text, terms: terms).map { String(text[$0]) }
    }

    @Test("nothing is marked for no words, no text or no match")
    func nothing() {
        #expect(MusicLocalSearch.highlights(in: "Midnight City", terms: []).isEmpty)
        #expect(MusicLocalSearch.highlights(in: "", terms: ["a"]).isEmpty)
        #expect(MusicLocalSearch.highlights(in: "Midnight City", terms: ["zzz"]).isEmpty)
    }

    @Test("a match is marked in the original text, with its own case")
    func caseKept() {
        #expect(pieces("Midnight City", ["CITY"]) == ["City"])
        #expect(pieces("Midnight City", ["mid"]) == ["Mid"])
    }

    @Test("a match ignores accents and marks the accented letters of the original")
    func diacritics() {
        #expect(pieces("Caf\u{00E9} del Mar", ["cafe"]) == ["Caf\u{00E9}"])
        #expect(pieces("Cafe del Mar", ["caf\u{00E9}"]) == ["Cafe"])
    }

    @Test("every place a word occurs is marked, in order")
    func repeats() {
        let text = "Banana band"
        let ranges = MusicLocalSearch.highlights(in: text, terms: ["ban"])
        #expect(ranges.map { String(text[$0]) } == ["Ban", "ban"])
        #expect(ranges[0].lowerBound < ranges[1].lowerBound)
    }

    @Test("several words are all marked, in text order, not in the order typed")
    func severalWords() {
        #expect(pieces("Midnight City Lights", ["lights", "mid"]) == ["Mid", "Lights"])
    }

    @Test("ranges that overlap merge into one")
    func overlapping() {
        // "abc" covers 0..<3 and "bcd" covers 1..<4 in "abcd": one mark over all four letters.
        #expect(pieces("abcd", ["abc", "bcd"]) == ["abcd"])
        // One word inside another marks the longer.
        #expect(pieces("Midnight", ["night", "ni"]) == ["night"])
    }

    @Test("ranges that touch merge into one")
    func touching() {
        #expect(pieces("Midnight", ["mid", "night"]) == ["Midnight"])
    }

    @Test("ranges with a gap stay apart")
    func apart() {
        #expect(pieces("Mid night", ["mid", "night"]) == ["Mid", "night"])
    }

    @Test("a word is marked whole, with an emoji or a symbol in it")
    func symbols() {
        #expect(pieces("Mix \u{1F3B5} 2024", ["\u{1F3B5}"]) == ["\u{1F3B5}"])
        #expect(pieces("50% off", ["50%"]) == ["50%"])
    }
}

@MainActor
@Suite("MusicLocalSearch songs and collections")
struct MusicLocalSearchItemTests {
    private func track(_ id: String, title: String, artist: String = "Artist", album: String? = nil) -> MusicTrack {
        MusicTrack(videoId: id, title: title, artist: artist, album: album, durationSeconds: 200, thumbnailURL: nil)
    }

    private let songs = [
        MusicSamples.track("a", title: "Midnight City", artist: "M83"),
        MusicSamples.track("b", title: "Caf\u{00E9} Blue", artist: "Someone"),
        MusicSamples.track("c", title: "Intro", artist: "M83"),
    ]

    @Test("a song is searched by its title, its artist and its album")
    func songFields() {
        let song = track("x", title: "Title", artist: "Singer", album: "Record")
        #expect(MusicLocalSearch.fields(of: song) == ["Title", "Singer", "Record"])
        #expect(MusicLocalSearch.fields(of: track("y", title: "Title", artist: "Singer")) == ["Title", "Singer", ""])
    }

    @Test("songs are kept by title, by artist and by album")
    func songsByAnyField() {
        let withAlbum = songs + [track("d", title: "Other", artist: "Else", album: "Hurry Up")]
        #expect(MusicLocalSearch.filter(withAlbum, terms: ["intro"]).map(\.videoId) == ["c"])
        #expect(MusicLocalSearch.filter(withAlbum, terms: ["m83"]).map(\.videoId) == ["a", "c"])
        #expect(MusicLocalSearch.filter(withAlbum, terms: ["hurry"]).map(\.videoId) == ["d"])
    }

    @Test("every word has to be in the song, across its fields")
    func songsAnd() {
        #expect(MusicLocalSearch.filter(songs, terms: ["m83", "city"]).map(\.videoId) == ["a"])
        #expect(MusicLocalSearch.filter(songs, terms: ["m83", "blue"]).isEmpty)
    }

    @Test("case and accents are ignored on songs")
    func songsFolded() {
        #expect(MusicLocalSearch.filter(songs, terms: ["CAFE"]).map(\.videoId) == ["b"])
    }

    @Test("no words keep every song in its order")
    func songsNoTerms() {
        #expect(MusicLocalSearch.filter(songs, terms: []).map(\.videoId) == ["a", "b", "c"])
        #expect(MusicLocalSearch.indices(of: songs, terms: []) == [0, 1, 2])
        #expect(MusicLocalSearch.filter([MusicTrack](), terms: ["a"]).isEmpty)
    }

    @Test("indices are the songs' places in the whole list, so an album keeps its numbers")
    func songIndices() {
        #expect(MusicLocalSearch.indices(of: songs, terms: ["m83"]) == [0, 2])
        #expect(MusicLocalSearch.indices(of: songs, terms: ["zzz"]).isEmpty)
    }

    @Test("a collection is searched by its title and YouTube's second line, with the bullet as a middle dot")
    func collectionFields() {
        let album = MusicSamples.collection("a", kind: .album, title: "Hurry Up", subtitle: "Album \u{2022} M83 \u{2022} 2011")
        #expect(MusicLocalSearch.fields(of: album) == ["Hurry Up", "M83 \u{00B7} 2011"])
        let owned = MusicSamples.collection("p", kind: .playlist, title: "Focus", subtitle: "12 songs \u{2022} Sam")
        #expect(MusicLocalSearch.fields(of: owned) == ["Focus", "12 songs \u{00B7} Sam"])
    }

    @Test("the kind word YouTube leads its second line with is dropped, and nothing else is")
    func detailDropsTheKindWord() {
        #expect(MusicLocalSearch.detail(ofSubtitle: "Album \u{2022} M83 \u{2022} 2011") == "M83 \u{00B7} 2011")
        #expect(MusicLocalSearch.detail(ofSubtitle: "Playlist \u{2022} Sam") == "Sam")
        #expect(MusicLocalSearch.detail(ofSubtitle: "single \u{2022} Kim") == "Kim")
        #expect(MusicLocalSearch.detail(ofSubtitle: "EP \u{2022} Kim") == "Kim")
        #expect(MusicLocalSearch.detail(ofSubtitle: "Artist") == "")
        #expect(MusicLocalSearch.detail(ofSubtitle: "") == "")
        #expect(MusicLocalSearch.detail(ofSubtitle: "Albums by Kim") == "Albums by Kim")
        #expect(MusicLocalSearch.detail(ofSubtitle: "12 songs") == "12 songs")
        #expect(MusicLocalSearch.detail(ofSubtitle: "Sam \u{2022} Album") == "Sam \u{00B7} Album")
    }

    @Test("collections are kept by title or by the owner or artist on the second line")
    func collectionsMatch() {
        let list = [
            MusicSamples.collection("p1", kind: .playlist, title: "Late Night Drive", subtitle: "Playlist \u{2022} Sam"),
            MusicSamples.collection("p2", kind: .playlist, title: "Focus", subtitle: "Playlist \u{2022} Late Owner"),
            MusicSamples.collection("p3", kind: .playlist, title: "Workout", subtitle: "Playlist \u{2022} Kim"),
        ]
        #expect(MusicLocalSearch.filter(list, terms: ["late"]).map(\.browseId) == ["p1", "p2"])
        #expect(MusicLocalSearch.filter(list, terms: ["kim"]).map(\.browseId) == ["p3"])
        #expect(MusicLocalSearch.filter(list, terms: []).map(\.browseId) == ["p1", "p2", "p3"])
    }

    @Test("the kind word is not searched, so \"playlist\" does not match every playlist")
    func kindWordNotSearched() {
        let list = [
            MusicSamples.collection("p1", kind: .playlist, title: "Focus", subtitle: "Playlist \u{2022} Sam"),
            MusicSamples.collection("p3", kind: .playlist, title: "Run", subtitle: "Sam"),
            MusicSamples.collection("p2", kind: .album, title: "Album Title", subtitle: "Album \u{2022} Kim"),
        ]
        #expect(MusicLocalSearch.filter(list, terms: ["playlist"]).isEmpty)
        // A title that really says it still matches.
        #expect(MusicLocalSearch.filter(list, terms: ["album"]).map(\.browseId) == ["p2"])
    }
}
