// DeciTests/Music/MusicServiceAlbumsTests.swift
// The albums of a global search: asked for with the songs, artists and Top result, landing together under the same
// grace, never failing the search, and joined with the owner's own matching albums and playlists from the library.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct AlbumRig {
    let backend = FakeMusicBackend(signedIn: true)
    let service: MusicService

    /// `artistGrace` is long by default, so a search waits for a held call; a test of the grace passes a short one.
    init(grace: Duration = .seconds(60)) {
        service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: FakePlaybackEngine()),
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            artistGrace: grace,
            refreshOnCreate: false
        )
    }

    func search(_ query: String) async {
        service.query = query
        service.search()
        await service.searchTask?.value
    }

    /// Polls until `condition` holds; for work that is held at a gate and cannot be awaited.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Loads a library section into the browse store, as opening Library does.
    func loadLibrary(_ section: MusicLibrarySection, _ items: [MusicCollection]) async {
        await backend.setLibrary(section, items: items)
        service.browse.loadLibraryIfNeeded(section)
        _ = await eventually {
            if case .loaded = service.browse.libraryState(section) { return true }
            return false
        }
    }

    var ids: [String] { service.albumResults.map(\.browseId) }

    static func album(_ id: String, title: String? = nil, subtitle: String = "Album \u{2022} Someone \u{2022} 2019") -> MusicCollection {
        MusicSamples.collection(id, kind: .album, title: title ?? "Album \(id)", subtitle: subtitle)
    }
}

@MainActor
@Suite("MusicService search albums")
struct MusicServiceAlbumsTests {

    // MARK: - Public albums

    @Test("albums are searched with the songs, with the same trimmed query, and fill albumResults")
    func albumsFill() async {
        let r = AlbumRig()
        let found = [AlbumRig.album("MPREa"), AlbumRig.album("MPREb")]
        await r.backend.setSearch("some band", results: MusicSamples.tracks("s1"))
        await r.backend.setAlbums("some band", results: found)

        await r.search("  some band \n")

        #expect(r.service.albumResults == found)
        #expect(r.service.results.map(\.videoId) == ["s1"])
        #expect(await r.backend.searchedAlbumsQueries == ["some band"])
        #expect(await r.backend.searchedQueries == ["some band"])
        #expect(r.service.isSearching == false)
    }

    @Test("no albums found leaves an empty list and the songs as they are")
    func noAlbums() async {
        let r = AlbumRig()
        await r.backend.setSearch("q", results: MusicSamples.tracks("s1"))

        await r.search("q")

        #expect(r.service.albumResults.isEmpty)
        #expect(r.service.results.count == 1)
    }

    @Test("at most six public albums are kept, in the order the backend gave them")
    func albumsCappedAtSix() async {
        let r = AlbumRig()
        let ids = (1...9).map { "MPRE\($0)" }
        await r.backend.setAlbums("q", results: ids.map { AlbumRig.album($0) })

        await r.search("q")

        #expect(MusicService.maxAlbumResults == 6)
        #expect(r.ids == Array(ids.prefix(6)))
    }

    @Test("albums land with the artists and the Top result")
    func albumsLandWithTheRest() async {
        let r = AlbumRig()
        await r.backend.setSearch("q", results: MusicSamples.tracks("s1"))
        await r.backend.setTopResult("q", track: MusicSamples.track("top"))
        await r.backend.setArtistSearch("q", results: [MusicSamples.collection("UCa", kind: .artist, subtitle: "Artist")])
        await r.backend.setAlbums("q", results: [AlbumRig.album("MPREa")])

        await r.search("q")

        #expect(r.service.results.map(\.videoId) == ["top", "s1"])
        #expect(r.service.artistResults.map(\.browseId) == ["UCa"])
        #expect(r.ids == ["MPREa"])
    }

    @Test("a blank query clears the albums and asks for none")
    func blankQuery() async {
        let r = AlbumRig()
        await r.backend.setAlbums("q", results: [AlbumRig.album("MPREa")])
        await r.search("q")
        #expect(r.ids == ["MPREa"])

        r.service.query = "   "
        r.service.search()

        #expect(r.service.albumResults.isEmpty)
        #expect(await r.backend.searchedAlbumsQueries == ["q"])
    }

    @Test("signing out drops the albums")
    func signOutDropsAlbums() async {
        let r = AlbumRig()
        await r.backend.setAlbums("q", results: [AlbumRig.album("MPREa")])
        await r.search("q")
        #expect(r.ids == ["MPREa"])

        r.service.signOut()

        #expect(r.service.albumResults.isEmpty)
    }

    // MARK: - Failures and slow answers

    @Test("a failing albums request leaves the songs showing and no error")
    func albumsFailureIsQuiet() async {
        let r = AlbumRig()
        await r.backend.setSearch("q", results: MusicSamples.tracks("s1", "s2"))
        await r.backend.setAlbumsError("q", MusicError.http(503))

        await r.search("q")

        #expect(r.service.results.map(\.videoId) == ["s1", "s2"])
        #expect(r.service.albumResults.isEmpty)
        #expect(r.service.lastError == nil)
        #expect(r.service.isSearching == false)
    }

    @Test("a failing albums request does not cost the artists or the Top result")
    func albumsFailureKeepsTheRest() async {
        let r = AlbumRig()
        await r.backend.setSearch("q", results: MusicSamples.tracks("s1"))
        await r.backend.setTopResult("q", track: MusicSamples.track("top"))
        await r.backend.setArtistSearch("q", results: [MusicSamples.collection("UCa", kind: .artist, subtitle: "Artist")])
        await r.backend.setAlbumsError("q", MusicError.parse("bad"))

        await r.search("q")

        #expect(r.service.results.map(\.videoId) == ["top", "s1"])
        #expect(r.service.artistResults.map(\.browseId) == ["UCa"])
        #expect(r.service.lastError == nil)
    }

    @Test("a failing songs request fails the search even when albums are found")
    func songsFailureFails() async {
        let r = AlbumRig()
        await r.backend.setSearchError("q", MusicError.http(503))
        await r.backend.setAlbums("q", results: [AlbumRig.album("MPREa")])

        await r.search("q")

        #expect(r.service.results.isEmpty)
        #expect(r.service.albumResults.isEmpty)
        #expect(r.service.lastError != nil)
        #expect(r.service.isSearching == false)
    }

    @Test("albums slower than the grace are dropped and the songs show without them")
    func slowAlbumsAreDropped() async {
        let r = AlbumRig(grace: .milliseconds(20))
        let gate = MusicTestGate()
        await r.backend.setSearch("q", results: MusicSamples.tracks("s1"))
        await r.backend.setAlbums("q", results: [AlbumRig.album("MPREa")])
        await r.backend.setAlbumsGate("q", gate)

        r.service.query = "q"
        r.service.search()

        // The albums call never returns, and the search still ends. Polled, so a search that waits for it fails here
        // instead of hanging the run.
        #expect(await r.eventually { r.service.isSearching == false })
        #expect(r.service.results.map(\.videoId) == ["s1"])
        #expect(r.service.albumResults.isEmpty)
        #expect(r.service.lastError == nil)

        // A reply that comes after the grace changes nothing.
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        #expect(r.service.albumResults.isEmpty)
        #expect(r.service.results.map(\.videoId) == ["s1"])
    }

    @Test("the songs wait for albums that land inside the grace")
    func albumsInsideTheGrace() async {
        let r = AlbumRig()
        let gate = MusicTestGate()
        await r.backend.setSearch("q", results: MusicSamples.tracks("s1"))
        await r.backend.setAlbums("q", results: [AlbumRig.album("MPREa")])
        await r.backend.setAlbumsGate("q", gate)

        r.service.query = "q"
        r.service.search()
        let task = r.service.searchTask
        #expect(await r.eventually { await r.backend.searchedAlbumsQueries == ["q"] })
        for _ in 0..<20 { await Task.yield() }
        #expect(r.service.results.isEmpty)
        #expect(r.service.isSearching)

        await gate.open()
        await task?.value
        #expect(r.service.results.map(\.videoId) == ["s1"])
        #expect(r.ids == ["MPREa"])
        #expect(r.service.isSearching == false)
    }

    @Test("a newer search drops the albums of one still in flight")
    func staleAlbumsAreDropped() async {
        let r = AlbumRig()
        let gate = MusicTestGate()
        await r.backend.setSearch("one", results: MusicSamples.tracks("slow"))
        await r.backend.setAlbums("one", results: [AlbumRig.album("MPREold")])
        await r.backend.setAlbumsGate("one", gate)
        await r.backend.setSearch("two", results: MusicSamples.tracks("fast"))
        await r.backend.setAlbums("two", results: [AlbumRig.album("MPREnew")])

        r.service.query = "one"
        r.service.search()
        let first = r.service.searchTask
        r.service.query = "two"
        r.service.search()
        await r.service.searchTask?.value
        #expect(r.ids == ["MPREnew"])

        await gate.open()
        await first?.value
        #expect(r.ids == ["MPREnew"])
        #expect(r.service.results.map(\.videoId) == ["fast"])
        #expect(r.service.isSearching == false)
    }

    // MARK: - The owner's library

    @Test("the owner's matching albums come first, then the public ones")
    func libraryFirst() async {
        let r = AlbumRig()
        await r.loadLibrary(.albums, [
            AlbumRig.album("MPREmine1", title: "Alpha Saved"),
            AlbumRig.album("MPREother", title: "Something Else"),
        ])
        await r.backend.setAlbums("alpha", results: [AlbumRig.album("MPREpub1", title: "Alpha Public")])

        await r.search("alpha")

        #expect(r.ids == ["MPREmine1", "MPREpub1"])
    }

    @Test("a public album the library already holds is dropped, and the library's copy stays first")
    func duplicateDropped() async {
        let r = AlbumRig()
        await r.loadLibrary(.albums, [AlbumRig.album("MPREsame", title: "Alpha Saved")])
        await r.backend.setAlbums("alpha", results: [
            AlbumRig.album("MPREpub1", title: "Alpha One"),
            AlbumRig.album("MPREsame", title: "Alpha Saved"),
        ])

        await r.search("alpha")

        #expect(r.ids == ["MPREsame", "MPREpub1"])
    }

    @Test("a library that is not loaded yet gives the public albums only, and no request is made for it")
    func libraryNotLoaded() async {
        let r = AlbumRig()
        await r.backend.setLibrary(.albums, items: [AlbumRig.album("MPREmine1", title: "Alpha Saved")])
        await r.backend.setAlbums("alpha", results: [AlbumRig.album("MPREpub1", title: "Alpha Public")])

        await r.search("alpha")

        #expect(r.ids == ["MPREpub1"])
        #expect(await r.backend.libraryCalls.isEmpty)
        #expect(r.service.browse.libraryState(.albums) == .idle)
    }

    @Test("a library that failed to load gives the public albums only")
    func libraryFailed() async {
        let r = AlbumRig()
        await r.backend.setLibraryError(.albums, MusicError.http(500))
        r.service.browse.loadLibraryIfNeeded(.albums)
        #expect(await r.eventually { r.service.browse.libraryState(.albums) != .loading })
        await r.backend.setAlbums("alpha", results: [AlbumRig.album("MPREpub1", title: "Alpha Public")])

        await r.search("alpha")

        #expect(r.ids == ["MPREpub1"])
    }

    @Test("the library is matched by every word of the query, in the title or the second line")
    func libraryMatchesEveryWord() async {
        let r = AlbumRig()
        await r.loadLibrary(.albums, [
            AlbumRig.album("MPRE19", title: "Alpha", subtitle: "Album \u{2022} Band \u{2022} 2019"),
            AlbumRig.album("MPRE20", title: "Alpha Two", subtitle: "Album \u{2022} Band \u{2022} 2020"),
        ])

        await r.search("alpha 2019")

        #expect(r.ids == ["MPRE19"])
    }

    @Test("saved playlists match too, after the saved albums")
    func libraryPlaylists() async {
        let r = AlbumRig()
        await r.loadLibrary(.playlists, [MusicSamples.collection("VLPLmine", title: "Alpha Mix", subtitle: "Playlist \u{2022} 12 songs")])
        await r.loadLibrary(.albums, [AlbumRig.album("MPREmine", title: "Alpha Saved")])
        await r.backend.setAlbums("alpha", results: [AlbumRig.album("MPREpub1", title: "Alpha Public")])

        await r.search("alpha")

        #expect(r.ids == ["MPREmine", "VLPLmine", "MPREpub1"])
    }

    @Test("library matches reach their own cap, so they never push the public albums out")
    func libraryDoesNotCrowdOutPublic() async {
        let r = AlbumRig()
        await r.loadLibrary(.albums, (1...9).map { AlbumRig.album("MPREmine\($0)", title: "Alpha \($0)") })
        await r.backend.setAlbums("alpha", results: [AlbumRig.album("MPREpub1", title: "Alpha Public")])

        await r.search("alpha")

        #expect(r.ids == (1...6).map { "MPREmine\($0)" } + ["MPREpub1"])
    }

    @Test("the library is matched against the trimmed query")
    func libraryTrimmedQuery() async {
        let r = AlbumRig()
        await r.loadLibrary(.albums, [AlbumRig.album("MPREmine", title: "Alpha Saved")])

        await r.search("  alpha \n")

        #expect(r.ids == ["MPREmine"])
    }

    @Test("a library match shows even when the YouTube Music albums request fails")
    func libraryShowsWhenPublicFails() async {
        let r = AlbumRig()
        await r.loadLibrary(.albums, [AlbumRig.album("MPREmine", title: "Alpha Saved")])
        await r.backend.setAlbumsError("alpha", MusicError.http(503))

        await r.search("alpha")

        #expect(r.ids == ["MPREmine"])
        #expect(r.service.lastError == nil)
    }
}
