// DeciTests/Music/MusicSearchNavigationAlbumsTests.swift
// The Albums section of the global results: the sections in their order with the empty ones left out, the owner's
// matches ahead of the public albums, a duplicate dropped, and an unloaded library leaving the public albums alone.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct AlbumNavHarness {
    let backend = FakeMusicBackend()
    let service: MusicService
    let nav: MusicSearchNavigation

    init() {
        service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: FakePlaybackEngine()),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            refreshOnCreate: false
        )
        nav = MusicSearchNavigation(service: service)
    }

    /// Types `query`, presses Return and waits for the search to land.
    func search(
        _ query: String,
        songs: [MusicTrack] = [],
        albums: [MusicCollection] = [],
        artists: [MusicCollection] = []
    ) async {
        await backend.setSearch(query, results: songs)
        await backend.setAlbums(query, results: albums)
        await backend.setArtistSearch(query, results: artists)
        service.query = query
        nav.submit()
        await service.searchTask?.value
    }

    static func album(_ id: String, title: String? = nil) -> MusicCollection {
        MusicSamples.collection(id, kind: .album, title: title ?? "Album \(id)", subtitle: "Album \u{2022} Someone \u{2022} 2019")
    }

    static let artist = MusicSamples.collection("UCa", kind: .artist, title: "Artist", subtitle: "Artist")
}

@MainActor
@Suite("MusicSearchNavigation albums")
struct MusicSearchNavigationAlbumsTests {

    // MARK: - Sections

    @Test("the sections are Songs, Albums, Artists, in that order")
    func sectionOrder() async {
        let h = AlbumNavHarness()
        await h.search("q", songs: MusicSamples.tracks("s1"), albums: [AlbumNavHarness.album("MPREa")], artists: [AlbumNavHarness.artist])
        #expect(h.nav.sections == [.songs, .albums, .artists])
    }

    @Test("a section with nothing in it is left out")
    func emptySectionsHidden() async {
        let h = AlbumNavHarness()
        await h.search("q", songs: MusicSamples.tracks("s1"), artists: [AlbumNavHarness.artist])
        #expect(h.nav.sections == [.songs, .artists])

        await h.search("r", albums: [AlbumNavHarness.album("MPREa")])
        #expect(h.nav.sections == [.albums])

        await h.search("s", songs: MusicSamples.tracks("s1"), albums: [AlbumNavHarness.album("MPREa")])
        #expect(h.nav.sections == [.songs, .albums])
    }

    @Test("a search that found nothing has no sections and says so")
    func noSections() async {
        let h = AlbumNavHarness()
        await h.search("nothing")
        #expect(h.nav.sections.isEmpty)
        #expect(h.nav.hasResults == false)
        #expect(h.nav.panel == .noResults)
    }

    @Test("a search that found only albums shows the results")
    func albumsOnlyShows() async {
        let h = AlbumNavHarness()
        await h.search("q", albums: [AlbumNavHarness.album("MPREa")])
        #expect(h.nav.hasResults)
        #expect(h.nav.showsResults)
        #expect(h.nav.panel == .results)
    }

    @Test("emptying the field drops the albums and the sections")
    func emptiedQueryDropsAlbums() async {
        let h = AlbumNavHarness()
        await h.search("q", albums: [AlbumNavHarness.album("MPREa")])

        h.service.query = ""
        h.nav.queryChanged()

        #expect(h.service.albumResults.isEmpty)
        #expect(h.nav.sections.isEmpty)
        #expect(h.nav.showsResults == false)
    }

    @Test("the no-results and invite lines name albums too")
    func panelCopyNamesAlbums() {
        #expect(MusicSearchPanel.noResults.message == "No songs, albums or artists found.")
        #expect(MusicSearchPanel.invite.message == "Search YouTube Music for songs, albums and artists.")
    }

    // MARK: - Opening an album

    @Test("an album from the results opens its page on top, hides the results and keeps the query")
    func openAlbumFromResults() async {
        let h = AlbumNavHarness()
        let album = AlbumNavHarness.album("MPREa", title: "Alpha")
        await h.search("alpha", albums: [album])

        h.nav.openCollection(album)

        #expect(h.service.browse.path == [album])
        #expect(h.nav.hidesResults)
        #expect(h.nav.showsResults == false)
        #expect(h.service.query == "alpha")
        #expect(h.service.albumResults == [album])
    }

    // MARK: - Joining the library with the public albums

    private static func mine(_ ids: String...) -> [MusicCollection] {
        ids.map { AlbumNavHarness.album($0, title: "Alpha \($0)") }
    }

    @Test("the owner's matches come first, then the public albums")
    func libraryFirst() {
        let found = MusicSearchAlbums.resolve(
            query: "alpha",
            library: [.albums: Self.mine("MPREmine1", "MPREmine2")],
            found: [AlbumNavHarness.album("MPREpub1", title: "Alpha Public")]
        )
        #expect(found.map(\.browseId) == ["MPREmine1", "MPREmine2", "MPREpub1"])
    }

    @Test("a public album with the same id as a library match is dropped")
    func duplicateDropped() {
        let found = MusicSearchAlbums.resolve(
            query: "alpha",
            library: [.albums: Self.mine("MPREsame")],
            found: [AlbumNavHarness.album("MPREpub1", title: "Alpha Public"), AlbumNavHarness.album("MPREsame", title: "Alpha Public Copy")]
        )
        #expect(found.map(\.browseId) == ["MPREsame", "MPREpub1"])
        #expect(found.first?.title == "Alpha MPREsame")
    }

    @Test("a library that is not loaded gives the public albums only")
    func libraryNotLoaded() {
        let pub = [AlbumNavHarness.album("MPREpub1", title: "Alpha Public")]
        #expect(MusicSearchAlbums.resolve(query: "alpha", library: [:], found: pub) == pub)
    }

    @Test("a library that is loaded but empty, or matches nothing, adds nothing")
    func libraryWithoutMatches() {
        let pub = [AlbumNavHarness.album("MPREpub1", title: "Alpha Public")]
        #expect(MusicSearchAlbums.resolve(query: "alpha", library: [.albums: [], .playlists: []], found: pub) == pub)
        #expect(MusicSearchAlbums.resolve(query: "zzz", library: [.albums: Self.mine("MPREmine1")], found: pub) == pub)
    }

    @Test("with no public albums the library matches show alone")
    func libraryAlone() {
        let found = MusicSearchAlbums.resolve(query: "alpha", library: [.albums: Self.mine("MPREmine1")], found: [])
        #expect(found.map(\.browseId) == ["MPREmine1"])
    }

    @Test("a blank query matches nothing in the library, rather than everything")
    func blankQueryMatchesNothing() {
        let library: [MusicLibrarySection: [MusicCollection]] = [.albums: Self.mine("MPREmine1")]
        #expect(MusicSearchAlbums.resolve(query: "", library: library, found: []).isEmpty)
        #expect(MusicSearchAlbums.resolve(query: "  \n ", library: library, found: []).isEmpty)
    }

    @Test("saved albums come before saved playlists, and one id in both lists shows once")
    func albumsBeforePlaylists() {
        let playlist = MusicSamples.collection("VLPLmine", title: "Alpha Mix")
        let found = MusicSearchAlbums.resolve(
            query: "alpha",
            library: [.playlists: [playlist, AlbumNavHarness.album("MPREmine1", title: "Alpha Again")], .albums: Self.mine("MPREmine1")],
            found: []
        )
        #expect(found.map(\.browseId) == ["MPREmine1", "VLPLmine"])
        #expect(found.first?.title == "Alpha MPREmine1")
    }

    @Test("each half has its own cap of six, and duplicates go before the public cap is applied")
    func caps() {
        let library = (1...9).map { AlbumNavHarness.album("MPREmine\($0)", title: "Alpha \($0)") }
        let pub = (1...9).map { AlbumNavHarness.album("MPREpub\($0)", title: "Alpha Public \($0)") }
            + [AlbumNavHarness.album("MPREmine1", title: "Alpha 1")]
        let found = MusicSearchAlbums.resolve(query: "alpha", library: [.albums: library], found: pub)
        #expect(found.map(\.browseId) == (1...6).map { "MPREmine\($0)" } + (1...6).map { "MPREpub\($0)" })

        let crowded = MusicSearchAlbums.resolve(
            query: "alpha",
            library: [.albums: library],
            found: [AlbumNavHarness.album("MPREmine1")] + pub.prefix(6)
        )
        #expect(crowded.suffix(6).map(\.browseId) == (1...6).map { "MPREpub\($0)" })
    }

    @Test("accents and case do not matter when the library is matched")
    func accentsAndCase() {
        let library: [MusicLibrarySection: [MusicCollection]] = [.albums: [AlbumNavHarness.album("MPREcafe", title: "Caf\u{00E9} Del Mar")]]
        #expect(MusicSearchAlbums.resolve(query: "CAFE", library: library, found: []).map(\.browseId) == ["MPREcafe"])
    }
}
