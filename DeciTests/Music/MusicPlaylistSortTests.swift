// DeciTests/Music/MusicPlaylistSortTests.swift
// Sorting a playlist's songs: the options, picking one twice to flip it, stable and case- and
// diacritic-insensitive order, and songs without a value for the sorted field going last.

import Foundation
import Testing
@testable import Deci

@Suite("MusicPlaylistSort")
struct MusicPlaylistSortTests {
    private func track(
        _ id: String,
        title: String = "Song",
        artist: String = "Artist",
        album: String? = nil,
        seconds: Int? = 200
    ) -> MusicTrack {
        MusicTrack(videoId: id, title: title, artist: artist, album: album, durationSeconds: seconds, thumbnailURL: nil)
    }

    private func ids(_ tracks: [MusicTrack]) -> [String] { tracks.map(\.videoId) }

    private func sorted(_ field: MusicSortField, ascending: Bool = true, _ tracks: [MusicTrack]) -> [String] {
        ids(MusicPlaylistSort(field: field, ascending: ascending).sorted(tracks))
    }

    // MARK: - Choosing

    @Test("the options are Default order, Title, Artist, Album and Duration, in that order")
    func options() {
        #expect(MusicSortField.allCases == [.defaultOrder, .title, .artist, .album, .duration])
        #expect(MusicSortField.allCases.map(\.label) == ["Default order", "Title", "Artist", "Album", "Duration"])
    }

    @Test("a playlist starts in its default order")
    func startsDefault() {
        #expect(MusicPlaylistSort.default.field == .defaultOrder)
        #expect(MusicPlaylistSort.default.isDefault)
        #expect(MusicPlaylistSort().isDefault)
    }

    @Test("picking a new option sorts ascending and picking the same one again flips the direction")
    func picking() {
        var sort = MusicPlaylistSort.default
        sort = sort.picking(.title)
        #expect(sort == MusicPlaylistSort(field: .title, ascending: true))
        sort = sort.picking(.title)
        #expect(sort == MusicPlaylistSort(field: .title, ascending: false))
        sort = sort.picking(.title)
        #expect(sort.ascending)
    }

    @Test("picking another option after a descending one starts ascending again")
    func pickingResetsDirection() {
        let sort = MusicPlaylistSort(field: .title, ascending: false).picking(.artist)
        #expect(sort == MusicPlaylistSort(field: .artist, ascending: true))
    }

    @Test("default order has no direction: picking it again stays put, and it always resets to ascending")
    func pickingDefault() {
        let sort = MusicPlaylistSort(field: .duration, ascending: false).picking(.defaultOrder)
        #expect(sort == .default)
        #expect(sort.picking(.defaultOrder) == .default)
    }

    // MARK: - Ordering

    @Test("default order returns the songs untouched, even when the direction says descending")
    func defaultOrder() {
        let list = [track("a", title: "Zed"), track("b", title: "Alpha"), track("c", title: "Mid")]
        #expect(sorted(.defaultOrder, list) == ["a", "b", "c"])
        #expect(sorted(.defaultOrder, ascending: false, list) == ["a", "b", "c"])
    }

    @Test("title sorts A to Z and Z to A")
    func byTitle() {
        let list = [track("a", title: "Charlie"), track("b", title: "Alpha"), track("c", title: "Bravo")]
        #expect(sorted(.title, list) == ["b", "c", "a"])
        #expect(sorted(.title, ascending: false, list) == ["a", "c", "b"])
    }

    @Test("artist sorts by the artist line")
    func byArtist() {
        let list = [track("a", artist: "Muse"), track("b", artist: "Daft Punk"), track("c", artist: "Radiohead")]
        #expect(sorted(.artist, list) == ["b", "a", "c"])
        #expect(sorted(.artist, ascending: false, list) == ["c", "a", "b"])
    }

    @Test("album sorts by the album name")
    func byAlbum() {
        let list = [track("a", album: "Random Access Memories"), track("b", album: "Discovery"), track("c", album: "Homework")]
        #expect(sorted(.album, list) == ["b", "c", "a"])
        #expect(sorted(.album, ascending: false, list) == ["a", "c", "b"])
    }

    @Test("duration sorts shortest first and longest first")
    func byDuration() {
        let list = [track("a", seconds: 300), track("b", seconds: 90), track("c", seconds: 200)]
        #expect(sorted(.duration, list) == ["b", "c", "a"])
        #expect(sorted(.duration, ascending: false, list) == ["a", "c", "b"])
    }

    @Test("case and accents do not matter")
    func caseAndDiacriticInsensitive() {
        let list = [
            track("a", title: "zebra"),
            track("b", title: "Émile"),
            track("c", title: "apple"),
            track("d", title: "Banana"),
            track("e", title: "eclair")
        ]
        // Without folding, "Banana" and "Émile" would sort before every lower-case title.
        #expect(sorted(.title, list) == ["c", "d", "e", "b", "a"])
    }

    @Test("numbers inside titles sort by value")
    func numeric() {
        let list = [track("a", title: "Track 10"), track("b", title: "Track 2"), track("c", title: "Track 1")]
        #expect(sorted(.title, list) == ["c", "b", "a"])
    }

    @Test("songs that tie keep the order they had, in both directions")
    func stable() {
        let list = [
            track("a", artist: "Muse"),
            track("b", artist: "daft punk"),
            track("c", artist: "MUSE"),
            track("d", artist: "Daft Punk"),
            track("e", artist: "muse")
        ]
        #expect(sorted(.artist, list) == ["b", "d", "a", "c", "e"])
        #expect(sorted(.artist, ascending: false, list) == ["a", "c", "e", "b", "d"])
    }

    @Test("titles that differ only in case, accents or width tie and keep the playlist order both ways")
    func foldedTies() {
        let list = [
            track("a", title: "Émile"),
            track("b", title: "emile"),
            track("c", title: "ÉMILE"),
            track("d", title: "\u{FF25}mile"),
            track("e", title: "Zed")
        ]
        #expect(sorted(.title, list) == ["a", "b", "c", "d", "e"])
        #expect(sorted(.title, ascending: false, list) == ["e", "a", "b", "c", "d"])
    }

    @Test("numbers are still read by value in titles that also have capitals and accents")
    func numericWithFolding() {
        let list = [track("a", title: "Étude 10"), track("b", title: "etude 9"), track("c", title: "ÉTUDE 100")]
        #expect(sorted(.title, list) == ["b", "a", "c"])
        #expect(sorted(.title, ascending: false, list) == ["c", "a", "b"])
    }

    @Test("a text sort and a number sort give the same order however often they run on the same songs")
    func repeatable() {
        let list = (0..<300).map { track("id\($0)", title: "Tune \(($0 * 37) % 23) é", artist: "Band \($0 % 5)", seconds: ($0 * 13) % 17) }
        for field in [MusicSortField.title, .artist, .duration] {
            let sort = MusicPlaylistSort(field: field, ascending: false)
            #expect(sort.sorted(list) == sort.sorted(list))
        }
    }

    @Test("songs with no album or no length go last, whichever way it sorts")
    func missingValuesLast() {
        let albums = [track("a", album: nil), track("b", album: "Zed"), track("c", album: ""), track("d", album: "Alpha")]
        #expect(sorted(.album, albums) == ["d", "b", "a", "c"])
        #expect(sorted(.album, ascending: false, albums) == ["b", "d", "a", "c"])

        let lengths = [track("a", seconds: nil), track("b", seconds: 100), track("c", seconds: 50), track("d", seconds: nil)]
        #expect(sorted(.duration, lengths) == ["c", "b", "a", "d"])
        #expect(sorted(.duration, ascending: false, lengths) == ["b", "c", "a", "d"])
    }

    @Test("an empty list and a single song come back as they are")
    func tiny() {
        #expect(sorted(.title, []).isEmpty)
        #expect(sorted(.title, [track("a")]) == ["a"])
    }

    @Test("the sort keeps every song exactly once")
    func keepsEverySong() {
        let list = (0..<500).map { track("id\($0)", title: "T\($0 % 7)", artist: "A\($0 % 3)", seconds: $0 % 11) }
        for field in MusicSortField.allCases {
            let result = MusicPlaylistSort(field: field, ascending: false).sorted(list)
            #expect(result.count == list.count)
            #expect(Set(ids(result)) == Set(ids(list)))
        }
    }

    @Test("a large list sorts without trouble and in order")
    func large() {
        let list = (0..<10_000).map { track("id\($0)", title: "Song \(($0 * 7919) % 10_000)", seconds: ($0 * 31) % 400) }
        let byDuration = MusicPlaylistSort(field: .duration).sorted(list)
        let lengths = byDuration.compactMap(\.durationSeconds)
        #expect(lengths == lengths.sorted())
        let byTitle = MusicPlaylistSort(field: .title).sorted(list)
        #expect(byTitle.first?.title == "Song 0")
        #expect(byTitle.last?.title == "Song 9999")
    }

    @Test("special characters and emoji do not break the sort")
    func specialCharacters() {
        let list = [track("a", title: "日本語"), track("b", title: "🎵 Song"), track("c", title: "O'Brien"), track("d", title: "100%")]
        let result = sorted(.title, list)
        #expect(result.count == 4)
        #expect(Set(result) == ["a", "b", "c", "d"])
    }
}
