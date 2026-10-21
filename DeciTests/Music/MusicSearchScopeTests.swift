// DeciTests/Music/MusicSearchScopeTests.swift
// What the right column's search field searches on each screen, and the words the filtered screens say: the count
// line, the other matches, the hint and the no-results block. Nothing here draws a view.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicSearchScope")
struct MusicSearchScopeTests {
    @Test("Home searches YouTube Music, and so does an artist page, from any tab")
    func global() {
        #expect(MusicSearchScope.resolve(column: .browse, tab: .home, page: nil) == .global)
        #expect(MusicSearchScope.resolve(column: .browse, tab: .home, page: .artist) == .global)
        #expect(MusicSearchScope.resolve(column: .browse, tab: .library, page: .artist) == .global)
        #expect(MusicSearchScope.resolve(column: .browse, tab: .history, page: .artist) == .global)
    }

    @Test("History searches YouTube Music, not the loaded days")
    func history() {
        #expect(MusicSearchScope.resolve(column: .browse, tab: .history, page: nil) == .global)
        #expect(MusicSearchScope.resolve(column: .queue, tab: .history, page: nil) == .queue)
        #expect(MusicSearchScope.resolve(column: .lyrics, tab: .history, page: nil) == .none)
    }

    @Test("Library filters what is loaded, whichever segment it shows")
    func library() {
        #expect(MusicSearchScope.resolve(column: .browse, tab: .library, page: nil) == .library)
    }

    @Test("a playlist page and Liked music filter their songs, an album its tracks, whichever tab opened them")
    func pages() {
        for tab in [MusicBrowseStore.Tab.home, .library, .history] {
            #expect(MusicSearchScope.resolve(column: .browse, tab: tab, page: .playlist) == .playlist)
            #expect(MusicSearchScope.resolve(column: .browse, tab: tab, page: .liked) == .playlist)
            #expect(MusicSearchScope.resolve(column: .browse, tab: tab, page: .album) == .album)
        }
    }

    @Test("Up next searches the queue, over any tab and any page")
    func queue() {
        #expect(MusicSearchScope.resolve(column: .queue, tab: .home, page: nil) == .queue)
        #expect(MusicSearchScope.resolve(column: .queue, tab: .library, page: .artist) == .queue)
    }

    @Test("Lyrics has no search")
    func none() {
        for page in [MusicPageKind?.none, .album, .artist, .playlist, .liked] {
            #expect(MusicSearchScope.resolve(column: .lyrics, tab: .home, page: page) == .none)
        }
    }

    @Test("the placeholder of each scope says what it searches, and Lyrics has none")
    func placeholders() {
        #expect(MusicSearchScope.global.placeholder == "Search YouTube Music")
        #expect(MusicSearchScope.library.placeholder == "Search your library")
        #expect(MusicSearchScope.playlist.placeholder == "Search in this playlist")
        #expect(MusicSearchScope.album.placeholder == "Search in this album")
        #expect(MusicSearchScope.queue.placeholder == "Search the queue")
        #expect(MusicSearchScope.none.placeholder == nil)
    }

    @Test("every scope but none shows the magnifier")
    func magnifier() {
        #expect(MusicSearchScope.global.showsMagnifier)
        #expect(MusicSearchScope.library.showsMagnifier)
        #expect(MusicSearchScope.playlist.showsMagnifier)
        #expect(MusicSearchScope.album.showsMagnifier)
        #expect(MusicSearchScope.queue.showsMagnifier)
        #expect(MusicSearchScope.none.showsMagnifier == false)
    }

    @Test("only the YouTube Music scope waits for Return, the rest filter live")
    func locality() {
        #expect(MusicSearchScope.global.isLocal == false)
        #expect(MusicSearchScope.none.isLocal == false)
        #expect(MusicSearchScope.library.isLocal)
        #expect(MusicSearchScope.playlist.isLocal)
        #expect(MusicSearchScope.album.isLocal)
        #expect(MusicSearchScope.queue.isLocal)
    }

    @Test("Liked music's browse id resolves to the playlist scope through its page kind")
    func likedPageKind() {
        let kind = MusicPageKind.resolve(kind: .playlist, browseId: MusicBrowseStore.likedMusic.browseId)
        #expect(MusicSearchScope.resolve(column: .browse, tab: .library, page: kind) == .playlist)
    }
}

@Suite("MusicSearchNoun")
struct MusicSearchNounTests {
    @Test("a noun is plural for every count but one")
    func words() {
        #expect(MusicSearchNoun.song.word(count: 1) == "song")
        #expect(MusicSearchNoun.song.word(count: 0) == "songs")
        #expect(MusicSearchNoun.song.word(count: 42) == "songs")
        #expect(MusicSearchNoun.playlist.word(count: 1) == "playlist")
        #expect(MusicSearchNoun.playlist.word(count: 2) == "playlists")
        #expect(MusicSearchNoun.album.word(count: 1) == "album")
        #expect(MusicSearchNoun.album.word(count: 3) == "albums")
        #expect(MusicSearchNoun.artist.word(count: 1) == "artist")
        #expect(MusicSearchNoun.artist.word(count: 0) == "artists")
    }
}

@Suite("MusicSearchCopy")
struct MusicSearchCopyTests {
    @Test("the count line is matched of total, in capitals, with the noun of the total")
    func countLine() {
        #expect(MusicSearchCopy.countLine(matched: 3, total: 42, noun: .playlist, isPartial: false) == "3 OF 42 PLAYLISTS")
        #expect(MusicSearchCopy.countLine(matched: 1, total: 1, noun: .artist, isPartial: false) == "1 OF 1 ARTIST")
        #expect(MusicSearchCopy.countLine(matched: 0, total: 12, noun: .song, isPartial: false) == "0 OF 12 SONGS")
    }

    @Test("a count of a list still loading says LOADED")
    func countLinePartial() {
        #expect(MusicSearchCopy.countLine(matched: 2, total: 50, noun: .album, isPartial: true) == "2 OF 50 ALBUMS LOADED")
    }

    @Test("a count never goes below zero")
    func countLineClamps() {
        #expect(MusicSearchCopy.countLine(matched: -1, total: -5, noun: .song, isPartial: false) == "0 OF 0 SONGS")
    }

    @Test("the hint under a filtered queue counts the songs it would show")
    func clearHint() {
        #expect(MusicSearchCopy.clearHint(total: 4, noun: .song) == "Clear or press esc to show all 4 songs")
        #expect(MusicSearchCopy.clearHint(total: 1, noun: .song) == "Clear or press esc to show all 1 song")
        #expect(MusicSearchCopy.clearHint(total: -2, noun: .song) == "Clear or press esc to show all 0 songs")
    }

    @Test("the no-results block names the noun, the words in curly quotes, where it looked and what to look past")
    func noResults() {
        let copy = MusicSearchCopy.noResults(noun: .song, query: "zzz", place: "this playlist", beyond: "Late Night Drive")
        #expect(copy.title == "No songs match \u{201C}zzz\u{201D} in this playlist")
        #expect(copy.detail == "Try another word, or look beyond Late Night Drive.")

        let library = MusicSearchCopy.noResults(noun: .playlist, query: "q", place: "your library", beyond: "your library")
        #expect(library.title == "No playlists match \u{201C}q\u{201D} in your library")
        #expect(library.detail == "Try another word, or look beyond your library.")
    }

    @Test("the quoted words are trimmed, and a long query is cut at 30 characters with dots")
    func quoted() {
        #expect(MusicSearchCopy.quoted("  late night \n") == "late night")
        let exact = String(repeating: "a", count: 30)
        #expect(MusicSearchCopy.quoted(exact) == exact)
        let long = String(repeating: "a", count: 31)
        #expect(MusicSearchCopy.quoted(long) == exact + "...")
        #expect(MusicSearchCopy.quoted("") == "")
    }

    @Test("a cut that lands on a space does not leave a space before the dots")
    func quotedCutAtSpace() {
        let query = String(repeating: "a", count: 29) + " " + "bbbb"
        #expect(MusicSearchCopy.quoted(query) == String(repeating: "a", count: 29) + "...")
    }

    @Test("the link and the clear action have their fixed words")
    func fixedWords() {
        #expect(MusicSearchCopy.searchYouTubeInstead == "Search YouTube Music instead")
        #expect(MusicSearchCopy.clearFilter == "Clear filter")
    }
}

@Suite("MusicOtherMatches")
struct MusicOtherMatchesTests {
    @Test("nothing in the other segments means no line")
    func none() {
        #expect(MusicOtherMatches.resolve(current: .playlist, counts: [:]) == nil)
        #expect(MusicOtherMatches.resolve(current: .playlist, counts: [.album: 0, .artist: 0]) == nil)
    }

    @Test("one other segment with one match reads \"matches\" and is the link's target")
    func singleMatch() {
        let match = MusicOtherMatches.resolve(current: .playlist, counts: [.album: 1])
        #expect(match?.text == "Also 1 album matches")
        #expect(match?.target == .album)
    }

    @Test("one other segment with several matches reads \"match\"")
    func singlePlural() {
        let match = MusicOtherMatches.resolve(current: .album, counts: [.artist: 3])
        #expect(match?.text == "Also 3 artists match")
        #expect(match?.target == .artist)
    }

    @Test("two other segments are joined with \"and\", in the segments' order")
    func two() {
        let match = MusicOtherMatches.resolve(current: .playlist, counts: [.artist: 1, .album: 2])
        #expect(match?.text == "Also 2 albums and 1 artist match")
        #expect(match?.target == .album)
    }

    @Test("two segments with one match each read \"match\", not \"matches\"")
    func twoSingles() {
        let match = MusicOtherMatches.resolve(current: .playlist, counts: [.album: 1, .artist: 1])
        #expect(match?.text == "Also 1 album and 1 artist match")
    }

    @Test("the target is the segment with the most matches, the first of them on a tie")
    func target() {
        #expect(MusicOtherMatches.resolve(current: .playlist, counts: [.album: 1, .artist: 5])?.target == .artist)
        #expect(MusicOtherMatches.resolve(current: .playlist, counts: [.album: 4, .artist: 4])?.target == .album)
        #expect(MusicOtherMatches.resolve(current: .artist, counts: [.playlist: 2, .album: 2])?.target == .playlist)
    }

    @Test("the segment being filtered and songs are never counted")
    func ignoresCurrentAndSongs() {
        let match = MusicOtherMatches.resolve(current: .album, counts: [.album: 9, .song: 9, .artist: 1])
        #expect(match?.text == "Also 1 artist matches")
        #expect(match?.target == .artist)
        #expect(MusicOtherMatches.resolve(current: .album, counts: [.album: 9, .song: 9]) == nil)
    }
}

@MainActor
@Suite("MusicLibraryFilter")
struct MusicLibraryFilterTests {
    private func playlist(_ id: String, _ title: String, owner: String = "Sam") -> MusicCollection {
        MusicSamples.collection(id, kind: .playlist, title: title, subtitle: "Playlist \u{2022} \(owner)")
    }

    private func album(_ id: String, _ title: String, artist: String = "Kim") -> MusicCollection {
        MusicSamples.collection(id, kind: .album, title: title, subtitle: "Album \u{2022} \(artist)")
    }

    private func artist(_ id: String, _ name: String) -> MusicCollection {
        MusicSamples.collection(id, kind: .artist, title: name, subtitle: "12 songs")
    }

    private var loaded: [MusicLibrarySection: [MusicCollection]] {
        [
            .playlists: [playlist("p1", "Late Night Drive"), playlist("p2", "Focus"), playlist("p3", "Late Show")],
            .albums: [album("a1", "Hurry Up"), album("a2", "Late Registration"), album("a3", "Blue")],
            .artists: [artist("r1", "Late Owner"), artist("r2", "M83")],
        ]
    }

    @Test("Playlists keeps the matching rows in order and counts Liked music in the total")
    func playlists() {
        let filter = MusicLibraryFilter.resolve(section: .playlists, loaded: loaded, hasMore: [], terms: ["late"])
        #expect(filter.items.map(\.browseId) == ["p1", "p3"])
        #expect(filter.showsLiked == false)
        #expect(filter.matched == 2)
        #expect(filter.total == 4)
        #expect(filter.isPartial == false)
        #expect(filter.countLine == "2 OF 4 PLAYLISTS")
        #expect(filter.isEmpty == false)
        #expect(filter.section == .playlists)
    }

    @Test("Liked music, the first row of Playlists, shows and counts when it matches")
    func likedMatches() {
        let filter = MusicLibraryFilter.resolve(section: .playlists, loaded: loaded, hasMore: [], terms: ["liked"])
        #expect(filter.items.isEmpty)
        #expect(filter.showsLiked)
        #expect(filter.matched == 1)
        #expect(filter.isEmpty == false)
        #expect(filter.countLine == "1 OF 4 PLAYLISTS")
    }

    @Test("Liked music is not a row of Albums and Artists, and is not in their totals")
    func likedOnlyInPlaylists() {
        let albums = MusicLibraryFilter.resolve(section: .albums, loaded: loaded, hasMore: [], terms: ["liked"])
        #expect(albums.showsLiked == false)
        #expect(albums.total == 3)
        #expect(albums.isEmpty)

        let artists = MusicLibraryFilter.resolve(section: .artists, loaded: loaded, hasMore: [], terms: ["blue"])
        #expect(artists.showsLiked == false)
        #expect(artists.total == 2)
    }

    @Test("a list with more pages to load counts what is loaded and says so")
    func partial() {
        let filter = MusicLibraryFilter.resolve(section: .albums, loaded: loaded, hasMore: [.albums], terms: ["late"])
        #expect(filter.isPartial)
        #expect(filter.countLine == "1 OF 3 ALBUMS LOADED")
    }

    @Test("more pages in another segment do not make this one partial")
    func partialIsPerSegment() {
        let filter = MusicLibraryFilter.resolve(section: .albums, loaded: loaded, hasMore: [.playlists], terms: ["late"])
        #expect(filter.isPartial == false)
        #expect(filter.countLine == "1 OF 3 ALBUMS")
    }

    @Test("a word nothing matches leaves the segment empty and the other segments with nothing to offer")
    func empty() {
        let filter = MusicLibraryFilter.resolve(section: .albums, loaded: loaded, hasMore: [], terms: ["zzz"])
        #expect(filter.isEmpty)
        #expect(filter.items.isEmpty)
        #expect(filter.matched == 0)
        #expect(filter.other == nil)
        #expect(filter.countLine == "0 OF 3 ALBUMS")
    }

    @Test("the other segments' matches are counted and named, the most of them the link's target")
    func otherMatches() {
        let filter = MusicLibraryFilter.resolve(section: .playlists, loaded: loaded, hasMore: [], terms: ["late"])
        #expect(filter.other?.text == "Also 1 album and 1 artist match")
        #expect(filter.other?.target == .album)

        let fromArtists = MusicLibraryFilter.resolve(section: .artists, loaded: loaded, hasMore: [], terms: ["late"])
        #expect(fromArtists.other?.text == "Also 2 playlists and 1 album match")
        #expect(fromArtists.other?.target == .playlist)
    }

    @Test("a segment that is not loaded is left out of the other matches")
    func unloadedSegments() {
        var partial = loaded
        partial[.albums] = nil
        let filter = MusicLibraryFilter.resolve(section: .playlists, loaded: partial, hasMore: [], terms: ["late"])
        #expect(filter.other?.text == "Also 1 artist matches")
        #expect(filter.other?.target == .artist)
    }

    @Test("Liked music counts toward the Playlists segment in the other matches")
    func likedInOtherMatches() {
        let filter = MusicLibraryFilter.resolve(section: .albums, loaded: loaded, hasMore: [], terms: ["liked"])
        #expect(filter.other?.text == "Also 1 playlist matches")
        #expect(filter.other?.target == .playlist)
    }

    @Test("a segment that is not loaded has no rows, and Playlists still has Liked music")
    func nothingLoaded() {
        let albums = MusicLibraryFilter.resolve(section: .albums, loaded: [:], hasMore: [], terms: ["a"])
        #expect(albums.total == 0)
        #expect(albums.isEmpty)
        #expect(albums.other == nil)

        let playlists = MusicLibraryFilter.resolve(section: .playlists, loaded: [:], hasMore: [], terms: ["liked"])
        #expect(playlists.total == 1)
        #expect(playlists.showsLiked)
    }

    @Test("every word has to match one row, and the kind word is not searched")
    func termsAndKind() {
        let both = MusicLibraryFilter.resolve(section: .playlists, loaded: loaded, hasMore: [], terms: ["late", "show"])
        #expect(both.items.map(\.browseId) == ["p3"])

        let kind = MusicLibraryFilter.resolve(section: .playlists, loaded: loaded, hasMore: [], terms: ["playlist"])
        #expect(kind.items.isEmpty)
        // Not Liked music's "Auto playlist" line either.
        #expect(kind.showsLiked == false)
        #expect(kind.isEmpty)
    }

    @Test("with no words every row matches and the counts are the totals")
    func noTerms() {
        let filter = MusicLibraryFilter.resolve(section: .playlists, loaded: loaded, hasMore: [], terms: [])
        #expect(filter.items.count == 3)
        #expect(filter.showsLiked)
        #expect(filter.matched == filter.total)
    }

    @Test("the segments and the nouns map to each other")
    func segmentNouns() {
        #expect(MusicLibrarySection.playlists.noun == .playlist)
        #expect(MusicLibrarySection.albums.noun == .album)
        #expect(MusicLibrarySection.artists.noun == .artist)
        #expect(MusicLibrarySection(noun: .playlist) == .playlists)
        #expect(MusicLibrarySection(noun: .album) == .albums)
        #expect(MusicLibrarySection(noun: .artist) == .artists)
        #expect(MusicLibrarySection(noun: .song) == .playlists)
    }
}
