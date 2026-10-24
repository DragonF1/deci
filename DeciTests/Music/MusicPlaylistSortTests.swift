// DeciTests/Music/MusicPlaylistSortTests.swift
// Sorting a playlist's songs: the options, picking one twice to flip it, Date added reading the playlist position in
// either direction, stable and case- and diacritic-insensitive order, and songs without a value for the sorted field
// going last.

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
        seconds: Int? = 200,
        plays: Int? = nil,
        albumId: String? = nil
    ) -> MusicTrack {
        var track = MusicTrack(videoId: id, title: title, artist: artist, album: album, durationSeconds: seconds, thumbnailURL: nil, plays: plays)
        track.albumBrowseId = albumId
        return track
    }

    private func ids(_ tracks: [MusicTrack]) -> [String] { tracks.map(\.videoId) }

    private func sorted(_ field: MusicSortField, ascending: Bool = true, _ tracks: [MusicTrack]) -> [String] {
        ids(MusicPlaylistSort(field: field, ascending: ascending).sorted(tracks))
    }

    /// The years of some albums, read from subtitles like the ones a discography grid has.
    private func albumYears(_ albums: (id: String, title: String, year: Int)...) -> MusicReleaseYears {
        var years = MusicReleaseYears()
        years.add(albums.map { MusicSamples.collection($0.id, kind: .album, title: $0.title, subtitle: "Album \u{2022} \($0.year)") })
        return years
    }

    private func sortedByYear(ascending: Bool, _ years: MusicReleaseYears, _ tracks: [MusicTrack]) -> [String] {
        ids(MusicPlaylistSort(field: .releaseDate, ascending: ascending).sorted(tracks, releaseYears: years))
    }

    // MARK: - Choosing

    @Test("a playlist's options are Date added, Playlist order, Title, Artist, Album and Duration, in that order")
    func options() {
        #expect(MusicSortField.playlistOptions == [.dateAdded, .playlistOrder, .title, .artist, .album, .duration])
        #expect(MusicSortField.playlistOptions.map(\.label) == ["Date added", "Playlist order", "Title", "Artist", "Album", "Duration"])
        #expect(MusicSortField.options(artistSongs: false) == MusicSortField.playlistOptions)
        #expect(MusicSortField.playlistOptions.map { $0.label(onArtistSongs: false) } == MusicSortField.playlistOptions.map(\.label))
    }

    @Test("an artist's songs offer Popular, Album, Release date and Plays, in that order, and Popular is YouTube's own order")
    func artistSongsOptions() {
        #expect(MusicSortField.artistSongsOptions == [.playlistOrder, .album, .releaseDate, .plays])
        #expect(MusicSortField.options(artistSongs: true) == MusicSortField.artistSongsOptions)
        #expect(MusicSortField.artistSongsOptions.map { $0.label(onArtistSongs: true) } == ["Popular", "Album", "Release date", "Plays"])
        #expect(MusicSortField.plays.label == "Plays")
        #expect(MusicSortField.releaseDate.label == "Release date")
    }

    @Test("Plays and Release date are sort keys, but no playlist's menu offers them")
    func playsOnlyOnArtistSongs() {
        #expect(MusicSortField.allCases.contains(.plays))
        #expect(!MusicSortField.playlistOptions.contains(.plays))
        #expect(MusicSortField.allCases.contains(.releaseDate))
        #expect(!MusicSortField.playlistOptions.contains(.releaseDate))
    }

    @Test("Playlist order is the order YouTube lists, and a bare sort is that order")
    func playlistOrderConstant() {
        #expect(MusicPlaylistSort.playlistOrder.field == .playlistOrder)
        #expect(MusicPlaylistSort.playlistOrder.isPlaylistOrder)
        #expect(MusicPlaylistSort().isPlaylistOrder)
        #expect(MusicPlaylistSort() == .playlistOrder)
    }

    @Test("the newest-first Date added sort is Date added running descending, and is not Playlist order")
    func dateAddedConstant() {
        #expect(MusicPlaylistSort.dateAddedNewestFirst == MusicPlaylistSort(field: .dateAdded, ascending: false))
        #expect(!MusicPlaylistSort.dateAddedNewestFirst.isPlaylistOrder)
    }

    @Test("picking a new option sorts ascending and picking the same one again flips the direction")
    func picking() {
        var sort = MusicPlaylistSort.playlistOrder
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

    @Test("Plays starts with the most played song first, and picking it again flips it")
    func pickingPlays() {
        var sort = MusicPlaylistSort.playlistOrder.picking(.plays)
        #expect(sort == MusicPlaylistSort(field: .plays, ascending: false))
        sort = sort.picking(.plays)
        #expect(sort == MusicPlaylistSort(field: .plays, ascending: true))
        sort = sort.picking(.plays)
        #expect(!sort.ascending)
    }

    @Test("Release date starts with the newest song first, and picking it again flips it")
    func pickingReleaseDate() {
        var sort = MusicPlaylistSort.playlistOrder.picking(.releaseDate)
        #expect(sort == MusicPlaylistSort(field: .releaseDate, ascending: false))
        sort = sort.picking(.releaseDate)
        #expect(sort == MusicPlaylistSort(field: .releaseDate, ascending: true))
        sort = sort.picking(.releaseDate)
        #expect(!sort.ascending)
        #expect(sort.picking(.album) == MusicPlaylistSort(field: .album, ascending: true))
    }

    @Test("picking Album after Plays starts ascending, and picking Popular puts YouTube's order back")
    func pickingBetweenArtistSongsOptions() {
        let plays = MusicPlaylistSort(field: .plays, ascending: false)
        #expect(plays.picking(.album) == MusicPlaylistSort(field: .album, ascending: true))
        #expect(plays.picking(.playlistOrder) == .playlistOrder)
    }

    @Test("Date added starts newest first, unlike the other options, and picking it again flips it")
    func pickingDateAdded() {
        var sort = MusicPlaylistSort.playlistOrder.picking(.dateAdded)
        #expect(sort == MusicPlaylistSort(field: .dateAdded, ascending: false))
        sort = sort.picking(.dateAdded)
        #expect(sort == MusicPlaylistSort(field: .dateAdded, ascending: true))
        sort = sort.picking(.dateAdded)
        #expect(sort == MusicPlaylistSort(field: .dateAdded, ascending: false))
    }

    @Test("Date added starts newest first from any other option, whichever way that one ran")
    func pickingDateAddedFromElsewhere() {
        #expect(MusicPlaylistSort(field: .title, ascending: true).picking(.dateAdded) == .dateAddedNewestFirst)
        #expect(MusicPlaylistSort(field: .duration, ascending: false).picking(.dateAdded) == .dateAddedNewestFirst)
    }

    @Test("an option picked after Date added starts ascending")
    func pickingAfterDateAdded() {
        #expect(MusicPlaylistSort.dateAddedNewestFirst.picking(.title) == MusicPlaylistSort(field: .title, ascending: true))
    }

    @Test("Playlist order has no direction: picking it gives the explicit playlist order from anywhere, and again stays put")
    func pickingPlaylistOrder() {
        let sort = MusicPlaylistSort(field: .duration, ascending: false).picking(.playlistOrder)
        #expect(sort == .playlistOrder)
        #expect(sort.picking(.playlistOrder) == .playlistOrder)
        #expect(MusicPlaylistSort.dateAddedNewestFirst.picking(.playlistOrder) == .playlistOrder)
        #expect(MusicPlaylistSort.dateAddedNewestFirst.picking(.playlistOrder) != .dateAddedNewestFirst)
    }

    // MARK: - Needing a reorder

    @Test("Playlist order never reorders, whichever way the source runs")
    func playlistOrderNeverReorders() {
        #expect(!MusicPlaylistSort.playlistOrder.reorders(newestFirst: false))
        #expect(!MusicPlaylistSort.playlistOrder.reorders(newestFirst: true))
    }

    @Test("Date added newest first reorders a list that runs oldest first and leaves one that runs newest first")
    func dateAddedDescendingReorders() {
        #expect(MusicPlaylistSort.dateAddedNewestFirst.reorders(newestFirst: false))
        #expect(!MusicPlaylistSort.dateAddedNewestFirst.reorders(newestFirst: true))
    }

    @Test("Date added oldest first is the other way round")
    func dateAddedAscendingReorders() {
        let oldestFirst = MusicPlaylistSort(field: .dateAdded, ascending: true)
        #expect(!oldestFirst.reorders(newestFirst: false))
        #expect(oldestFirst.reorders(newestFirst: true))
    }

    @Test("every other option reorders whichever way the source runs")
    func fieldsAlwaysReorder() {
        for field in [MusicSortField.title, .artist, .album, .duration] {
            for ascending in [true, false] {
                let sort = MusicPlaylistSort(field: field, ascending: ascending)
                #expect(sort.reorders(newestFirst: false))
                #expect(sort.reorders(newestFirst: true))
            }
        }
    }

    // MARK: - Ordering

    @Test("Playlist order returns the songs untouched, even when the direction says descending")
    func playlistOrder() {
        let list = [track("a", title: "Zed"), track("b", title: "Alpha"), track("c", title: "Mid")]
        #expect(sorted(.playlistOrder, list) == ["a", "b", "c"])
        #expect(sorted(.playlistOrder, ascending: false, list) == ["a", "b", "c"])
    }

    @Test("Date added newest first reverses a playlist that lists the oldest first")
    func dateAddedDescendingReverses() {
        let list = [track("a"), track("b"), track("c"), track("d")]
        #expect(sorted(.dateAdded, ascending: false, list) == ["d", "c", "b", "a"])
    }

    @Test("Date added oldest first keeps a playlist that lists the oldest first")
    func dateAddedAscendingKeeps() {
        let list = [track("a"), track("b"), track("c"), track("d")]
        #expect(sorted(.dateAdded, ascending: true, list) == ["a", "b", "c", "d"])
    }

    @Test("a list that already runs newest first (Liked music) keeps its order for newest first and reverses for oldest first")
    func dateAddedOnNewestFirstSource() {
        let list = [track("a"), track("b"), track("c"), track("d")]
        let newest = MusicPlaylistSort(field: .dateAdded, ascending: false).sorted(list, newestFirst: true)
        let oldest = MusicPlaylistSort(field: .dateAdded, ascending: true).sorted(list, newestFirst: true)
        #expect(ids(newest) == ["a", "b", "c", "d"])
        #expect(ids(oldest) == ["d", "c", "b", "a"])
    }

    @Test("the newest-first flag changes nothing for the other options, including Playlist order")
    func newestFirstFlagIgnoredByOtherFields() {
        let list = [track("a", title: "Charlie"), track("b", title: "Alpha"), track("c", title: "Bravo")]
        for field in [MusicSortField.playlistOrder, .title, .artist, .album, .duration] {
            let sort = MusicPlaylistSort(field: field, ascending: false)
            #expect(sort.sorted(list, newestFirst: true) == sort.sorted(list, newestFirst: false))
        }
    }

    @Test("Date added reads the position only: titles, lengths and missing values do not move a song")
    func dateAddedIgnoresEverythingButPosition() {
        let list = [
            track("a", title: "Zed", seconds: nil),
            track("b", title: "Alpha", seconds: 10),
            track("c", title: "", artist: "", seconds: 999),
            track("d", title: "Mid", album: "X", seconds: 5)
        ]
        #expect(sorted(.dateAdded, ascending: false, list) == ["d", "c", "b", "a"])
        #expect(sorted(.dateAdded, ascending: true, list) == ["a", "b", "c", "d"])
    }

    @Test("Date added keeps a song that is in the playlist twice in both places")
    func dateAddedKeepsRepeats() {
        let list = [track("a"), track("b"), track("a")]
        #expect(sorted(.dateAdded, ascending: false, list) == ["a", "b", "a"])
        let list2 = [track("a"), track("b"), track("c"), track("a")]
        #expect(sorted(.dateAdded, ascending: false, list2) == ["a", "c", "b", "a"])
    }

    @Test("Date added on an empty list and on a single song comes back as it is, either direction")
    func dateAddedTiny() {
        #expect(sorted(.dateAdded, ascending: false, []).isEmpty)
        #expect(sorted(.dateAdded, ascending: false, [track("a")]) == ["a"])
        #expect(MusicPlaylistSort.dateAddedNewestFirst.sorted([], newestFirst: true).isEmpty)
    }

    @Test("Date added reverses ten thousand songs exactly")
    func dateAddedLarge() {
        let list = (0..<10_000).map { track("id\($0)") }
        let result = MusicPlaylistSort.dateAddedNewestFirst.sorted(list)
        #expect(result.count == 10_000)
        #expect(result.first?.videoId == "id9999")
        #expect(result.last?.videoId == "id0")
        #expect(ids(result) == ids(list).reversed())
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

    // MARK: - Plays

    @Test("Plays runs from the most played song down by default, and the other way ascending")
    func playsOrder() {
        let list = [track("a", plays: 5_000), track("b", plays: 2_000_000_000), track("c", plays: 271_000_000), track("d", plays: 12)]
        #expect(sorted(.plays, ascending: false, list) == ["b", "c", "a", "d"])
        #expect(sorted(.plays, ascending: true, list) == ["d", "a", "c", "b"])
    }

    @Test("songs with no play count go last in both directions, in the order they had")
    func playsMissingLast() {
        let list = [track("a", plays: nil), track("b", plays: 100), track("c", plays: nil), track("d", plays: 900), track("e", plays: 0)]
        #expect(sorted(.plays, ascending: false, list) == ["d", "b", "e", "a", "c"])
        #expect(sorted(.plays, ascending: true, list) == ["e", "b", "d", "a", "c"])
    }

    @Test("songs with the same play count keep the order they had, in both directions")
    func playsTiesKeepOrder() {
        let list = [track("a", plays: 7), track("b", plays: 9), track("c", plays: 7), track("d", plays: 9)]
        #expect(sorted(.plays, ascending: false, list) == ["b", "d", "a", "c"])
        #expect(sorted(.plays, ascending: true, list) == ["a", "c", "b", "d"])
    }

    @Test("Plays reorders the songs in any list, so a playlist has to be whole before it shows")
    func playsReorders() {
        #expect(MusicPlaylistSort(field: .plays, ascending: false).reorders(newestFirst: false))
        #expect(MusicPlaylistSort(field: .plays, ascending: true).reorders(newestFirst: true))
    }

    @Test("a list where no song has a play count stays in its order")
    func playsAllMissing() {
        let list = [track("a"), track("b"), track("c")]
        #expect(sorted(.plays, ascending: false, list) == ["a", "b", "c"])
        #expect(sorted(.plays, ascending: true, list) == ["a", "b", "c"])
    }

    // MARK: - Release date

    @Test("Release date runs from the newest song down by default, and the other way ascending")
    func releaseDateOrder() {
        let years = albumYears(("MPREa", "A", 2013), ("MPREb", "B", 2020), ("MPREc", "C", 1999))
        let list = [track("a", albumId: "MPREa"), track("b", albumId: "MPREb"), track("c", albumId: "MPREc")]
        #expect(sortedByYear(ascending: false, years, list) == ["b", "a", "c"])
        #expect(sortedByYear(ascending: true, years, list) == ["c", "a", "b"])
    }

    @Test("songs with no known year go last in both directions, in the order they had")
    func releaseDateMissingLast() {
        let years = albumYears(("MPREa", "A", 2013), ("MPREb", "B", 2020))
        let list = [track("x"), track("a", albumId: "MPREa"), track("y", album: "Unknown"), track("b", albumId: "MPREb"), track("z", albumId: "MPREgone")]
        #expect(sortedByYear(ascending: false, years, list) == ["b", "a", "x", "y", "z"])
        #expect(sortedByYear(ascending: true, years, list) == ["a", "b", "x", "y", "z"])
    }

    @Test("songs of the same year keep the order they had, in both directions")
    func releaseDateTiesKeepOrder() {
        let years = albumYears(("MPREa", "A", 2013), ("MPREb", "B", 2020))
        let list = [track("p", albumId: "MPREa"), track("q", albumId: "MPREb"), track("r", albumId: "MPREa"), track("s", albumId: "MPREb")]
        #expect(sortedByYear(ascending: false, years, list) == ["q", "s", "p", "r"])
        #expect(sortedByYear(ascending: true, years, list) == ["p", "r", "q", "s"])
    }

    @Test("a list with no years at all stays in its order, whatever the direction")
    func releaseDateNoYears() {
        let list = [track("a", album: "One"), track("b"), track("c", albumId: "MPREc")]
        #expect(sortedByYear(ascending: false, .empty, list) == ["a", "b", "c"])
        #expect(sortedByYear(ascending: true, .empty, list) == ["a", "b", "c"])
        #expect(ids(MusicPlaylistSort(field: .releaseDate, ascending: false).sorted(list)) == ["a", "b", "c"])
    }

    @Test("Release date reorders the songs in any list, so the songs have to be all here before it shows")
    func releaseDateReorders() {
        #expect(MusicPlaylistSort(field: .releaseDate, ascending: false).reorders(newestFirst: false))
        #expect(MusicPlaylistSort(field: .releaseDate, ascending: true).reorders(newestFirst: true))
    }

    @Test("the years change no other sort")
    func yearsAreIgnoredByOtherFields() {
        let years = albumYears(("MPREa", "A", 2013), ("MPREb", "B", 2020))
        let list = [track("a", title: "Zed", albumId: "MPREa"), track("b", title: "Alpha", albumId: "MPREb")]
        for field in [MusicSortField.title, .album, .plays, .duration, .dateAdded, .playlistOrder] {
            let sort = MusicPlaylistSort(field: field, ascending: true)
            #expect(sort.sorted(list, releaseYears: years) == sort.sorted(list))
        }
    }

    @Test("a song's year is its album page's, then its album title's, ignoring case, accents and padding")
    func yearLookup() {
        let years = albumYears(("MPRE1", "Éclair", 2010), ("MPRE2", "Other", 2000))
        #expect(years.year(of: track("a", albumId: "MPRE1")) == 2010)
        // The album page wins over a title that says another year.
        #expect(years.year(of: track("b", album: "Other", albumId: "MPRE1")) == 2010)
        // An album page the years do not know falls back to the title.
        #expect(years.year(of: track("c", album: "Other", albumId: "MPREunknown")) == 2000)
        #expect(years.year(of: track("d", album: "  eclair ")) == 2010)
        #expect(years.year(of: track("e", album: "ECLAIR")) == 2010)
        #expect(years.year(of: track("f", album: "Nothing")) == nil)
        #expect(years.year(of: track("g", album: "")) == nil)
        #expect(years.year(of: track("h")) == nil)
    }

    @Test("an album title with two years keeps the earliest, and each album page keeps its own")
    func yearsKeepTheEarliestPerTitle() {
        let years = albumYears(("MPRE1", "Greatest Hits", 2015), ("MPRE2", "greatest hits", 2005))
        #expect(years.year(of: track("a", album: "GREATEST HITS")) == 2005)
        #expect(years.year(of: track("b", albumId: "MPRE1")) == 2015)
        #expect(years.year(of: track("c", albumId: "MPRE2")) == 2005)
    }

    @Test("adding albums again lets the later year win for a page, and an album with no year in its line adds nothing")
    func addingYears() {
        var years = albumYears(("MPRE1", "One", 2015))
        years.add([
            MusicSamples.collection("MPRE1", kind: .album, title: "One", subtitle: "Album \u{2022} 2013"),
            MusicSamples.collection("MPRE2", kind: .album, title: "Two", subtitle: "Playlist \u{2022} 50 songs"),
        ])
        #expect(years.byAlbumId == ["MPRE1": 2013])
        #expect(years.byAlbumTitle == ["one": 2013])
        #expect(MusicReleaseYears.empty.byAlbumId.isEmpty)
    }

    @Test("a year is the last bullet-separated part of a subtitle that is exactly four digits in 1900 to 2100",
          arguments: [
              ("Album \u{2022} 2013", 2013 as Int?),
              ("2013", 2013),
              ("Single \u{2022} Artist \u{2022} 2020", 2020),
              ("Album \u{2022} 2013 \u{2022} 13 songs", 2013),
              ("Album\u{2022}2013", 2013),
              ("  2013  ", 2013),
              ("Album \u{2022} 1900", 1900),
              ("Album \u{2022} 2100", 2100),
              ("Album \u{2022} 1899", nil),
              ("Album \u{2022} 2101", nil),
              ("Album \u{2022} 20133", nil),
              ("Album \u{2022} 201", nil),
              ("Album \u{2022} 20x3", nil),
              ("Album \u{2022} Artist 2013", nil),
              ("Playlist \u{2022} 50 songs", nil),
              ("Auto playlist", nil),
              ("", nil),
          ])
    func releaseYearFromSubtitle(subtitle: String, expected: Int?) {
        let album = MusicSamples.collection("MPRE1", kind: .album, subtitle: subtitle)
        #expect(album.releaseYear == expected)
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
