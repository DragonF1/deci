// DeciTests/Music/MusicBrowseStoreSortTests.swift
// Sorting a playlist page: the choice is remembered per playlist for the session, a sort that reorders first loads
// every remaining page of songs (up to a cap), and the page the list shows and Play queues is the sorted one. A
// playlist the user made, and Liked music, rest on Date added newest first; any other playlist rests on its own order.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct SortHarness {
    let backend = FakeMusicBackend()
    let store: MusicBrowseStore

    init() {
        store = MusicBrowseStore(backend: backend)
    }

    /// Polls until `condition` holds, for at most two seconds.
    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Gives a response that should be dropped time to arrive, so a missing drop would show.
    func letLateWorkLand() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// A playlist of four songs over three pages: "a" first, then "b" and "c", then "d". `isEditable` makes it one the
    /// user made.
    func openLongPlaylist(_ browseId: String = "VLPL1", isEditable: Bool = false) async {
        await backend.setPage(MusicSamples.page(
            browseId,
            tracks: [MusicSamples.track("a", title: "Delta", seconds: 100)],
            continuation: "t1",
            isEditable: isEditable
        ))
        await backend.setMoreTracks(
            browseId: browseId, continuation: "t1",
            tracks: [MusicSamples.track("b", title: "alpha", seconds: 300), MusicSamples.track("c", title: "Charlie", seconds: 200)],
            next: "t2"
        )
        await backend.setMoreTracks(
            browseId: browseId, continuation: "t2",
            tracks: [MusicSamples.track("d", title: "Bravo", seconds: 50)],
            next: nil
        )
        store.open(MusicSamples.collection(browseId))
        _ = await until { loadedPage(browseId) != nil }
    }

    /// An artist's songs list of four songs over two pages, opened as `isArtistSongs` says: "a" (100 plays, album
    /// "Zeta") first, then "b" (no plays, album "alpha"), "c" (5,000 plays, no album) and "d" (100 plays, album "Beta").
    func openSongsList(_ browseId: String = "VLOLAK5uy_songs", isArtistSongs: Bool = true) async {
        await backend.setPage(MusicSamples.page(
            browseId,
            tracks: [MusicSamples.track("a", title: "Delta", album: "Zeta", plays: 100)],
            continuation: "t1"
        ))
        await backend.setMoreTracks(
            browseId: browseId, continuation: "t1",
            tracks: [
                MusicSamples.track("b", title: "alpha", album: "alpha", plays: nil),
                MusicSamples.track("c", title: "Charlie", album: nil, plays: 5_000),
                MusicSamples.track("d", title: "Bravo", album: "Beta", plays: 100)
            ],
            next: nil
        )
        store.open(MusicSamples.collection(browseId, isArtistSongs: isArtistSongs))
        _ = await until { loadedPage(browseId) != nil }
    }

    /// An artist's page "UCartist" whose Top songs link opens "VLOLAK5uy_songs", then that songs list (see `openSongsList`).
    /// The artist's Albums shelf holds "Zeta" (2015) and "Beta" (2010); `links` are its discography pages.
    func openArtistThenSongs(links: [MusicDiscographyLink], shelfAlbums: Bool = true) async {
        let albums = [
            MusicSamples.collection("MPREzeta", kind: .album, title: "Zeta", subtitle: "Album \u{2022} 2015"),
            MusicSamples.collection("MPREbeta", kind: .album, title: "Beta", subtitle: "Album \u{2022} 2010"),
        ]
        await backend.setPage(MusicSamples.page(
            "UCartist",
            title: "Artist",
            shelves: shelfAlbums ? [MusicShelf(title: "Albums", items: albums.map { .collection($0) })] : [],
            allSongsBrowseId: "VLOLAK5uy_songs",
            discographyLinks: links
        ))
        store.open(MusicSamples.collection("UCartist", kind: .artist))
        _ = await until { loadedPage("UCartist") != nil }
        await openSongsList()
    }

    /// The discography page "alpha" (2020) lives on, as a link and as what it answers.
    static let albumsLink = MusicDiscographyLink(browseId: "MPADartist", params: "P1")
    static let alpha = MusicSamples.collection("MPREalpha", kind: .album, title: "Alpha", subtitle: "Album \u{2022} 2020")

    /// Waits until Release date has read the years of the songs list.
    func yearsRead(_ browseId: String = "VLOLAK5uy_songs") async -> Bool {
        await until { store.releaseYears[browseId] != nil && store.loadingReleaseYears.isEmpty }
    }

    func loadedPage(_ browseId: String) -> MusicBrowsePage? {
        if case .loaded(let page)? = store.pages[browseId] { page } else { nil }
    }

    func shownIds(_ browseId: String) -> [String]? {
        store.displayedPage(browseId)?.tracks.map(\.videoId)
    }

    /// Waits until the loading is over and the page shows `count` songs.
    func settled(_ browseId: String, count: Int) async -> Bool {
        await until { store.loadingAllTracks.isEmpty && shownIds(browseId)?.count == count }
    }
}

@MainActor
@Suite("MusicBrowseStore sorting")
struct MusicBrowseStoreSortTests {
    @Test("only playlist pages can be sorted: VL ids, Liked music included, not albums or artists")
    func playlistsOnly() {
        #expect(MusicBrowseStore.canSort("VLPL1"))
        #expect(MusicBrowseStore.canSort(MusicBrowseStore.likedMusic.browseId))
        #expect(MusicBrowseStore.canSort("MPREb_album") == false)
        #expect(MusicBrowseStore.canSort("UCartist") == false)
        #expect(MusicBrowseStore.canSort("") == false)
    }

    @Test("a playlist the user did not make rests on Playlist order, shows the page as loaded and loads nothing extra")
    func startsInPlaylistOrder() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(!h.store.needsReorder("VLPL1"))
        #expect(!h.store.isOrderPending("VLPL1"))
        #expect(h.store.displayedPage("VLPL1") == h.loadedPage("VLPL1"))
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(h.store.sortedSongLimit("VLPL1") == nil)
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.isEmpty)
    }

    @Test("a page that is not loaded has nothing to show")
    func nothingToShow() {
        let h = SortHarness()
        #expect(h.store.displayedPage("VLnope") == nil)
    }

    @Test("picking a sort loads every remaining page first, then shows the sorted songs with no more to load")
    func sortLoadsAll() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)

        h.store.pickSort(.title, for: "VLPL1")
        #expect(h.store.sort(for: "VLPL1") == MusicPlaylistSort(field: .title, ascending: true))
        #expect(h.store.loadingAllTracks == ["VLPL1"])
        // Until everything is here the list keeps the order it has.
        #expect(h.shownIds("VLPL1") == ["a"])
        #expect(h.store.displayedPage("VLPL1")?.continuation == "t1")

        await gate.open()
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        #expect(h.shownIds("VLPL1") == ["b", "d", "c", "a"])
        #expect(h.store.displayedPage("VLPL1")?.continuation == nil)
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
    }

    @Test("the sorted page keeps the header and the stored page stays in its own order")
    func sortedPageKeepsHeader() async {
        let h = SortHarness()
        await h.backend.setPage(MusicBrowsePage(
            browseId: "VLPL1", title: "Mix", subtitle: "Playlist • 2 songs", thumbnailURL: nil,
            tracks: [MusicSamples.track("a", title: "Zed"), MusicSamples.track("b", title: "Ace")],
            continuation: nil, shelves: []
        ))
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })

        h.store.pickSort(.title, for: "VLPL1")
        let shown = h.store.displayedPage("VLPL1")
        #expect(shown?.tracks.map(\.videoId) == ["b", "a"])
        #expect(shown?.title == "Mix")
        #expect(shown?.subtitle == "Playlist • 2 songs")
        #expect(shown?.browseId == "VLPL1")
        #expect(h.loadedPage("VLPL1")?.tracks.map(\.videoId) == ["a", "b"])
    }

    @Test("a playlist with nothing more to load sorts at once and fetches nothing")
    func shortPlaylist() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page(
            "VLPL1", tracks: [MusicSamples.track("a", title: "B"), MusicSamples.track("b", title: "A")]
        ))
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })

        h.store.pickSort(.title, for: "VLPL1")
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(h.shownIds("VLPL1") == ["b", "a"])
        h.store.pickSort(.title, for: "VLPL1")
        #expect(h.shownIds("VLPL1") == ["a", "b"])
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.isEmpty)
    }

    @Test("picking the same option again flips the direction and does not load again")
    func flips() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        h.store.pickSort(.duration, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.store.displayedPage("VLPL1")?.continuation == nil })
        #expect(h.shownIds("VLPL1") == ["d", "a", "c", "b"])

        h.store.pickSort(.duration, for: "VLPL1")
        #expect(h.store.sort(for: "VLPL1") == MusicPlaylistSort(field: .duration, ascending: false))
        #expect(h.shownIds("VLPL1") == ["b", "c", "a", "d"])
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.count == 2)
    }

    @Test("Playlist order puts the page order back and keeps the songs that were loaded")
    func backToPlaylistOrder() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 4 })

        h.store.pickSort(.playlistOrder, for: "VLPL1")
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.shownIds("VLPL1") == ["a", "b", "c", "d"])
    }

    @Test("a different option while the pages are loading changes the order they land in, not the number of requests")
    func changeWhileLoading() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)

        h.store.pickSort(.title, for: "VLPL1")
        h.store.pickSort(.artist, for: "VLPL1")
        h.store.pickSort(.duration, for: "VLPL1")
        await gate.open()

        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        #expect(h.store.sort(for: "VLPL1") == MusicPlaylistSort(field: .duration, ascending: true))
        #expect(h.shownIds("VLPL1") == ["d", "a", "c", "b"])
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
    }

    @Test("picking Playlist order while the songs load stops after the page in flight and keeps the page order")
    func playlistOrderWhileLoading() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)

        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { await h.backend.moreTracksCalls.count == 1 })
        h.store.pickSort(.playlistOrder, for: "VLPL1")
        await gate.open()

        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1"])
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.shownIds("VLPL1") == ["a", "b", "c"])
    }

    @Test("the choice is remembered per playlist and does not touch another one")
    func perPlaylist() async {
        let h = SortHarness()
        await h.openLongPlaylist("VLPL1")
        await h.backend.setPage(MusicSamples.page("VLPL2", tracks: [MusicSamples.track("x", title: "Y"), MusicSamples.track("z", title: "X")]))
        h.store.open(MusicSamples.collection("VLPL2"))
        #expect(await h.until { h.loadedPage("VLPL2") != nil })

        h.store.pickSort(.title, for: "VLPL1")
        #expect(h.store.sort(for: "VLPL2") == .playlistOrder)
        #expect(h.shownIds("VLPL2") == ["x", "z"])
        #expect(h.store.sort(for: "VLPL1").field == .title)
    }

    @Test("a closed and reopened playlist keeps its sort and sorts again once its songs are loaded")
    func rememberedAcrossReopen() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 4 })

        h.store.back()
        #expect(h.store.displayedPage("VLPL1") == nil)
        #expect(h.store.sort(for: "VLPL1").field == .title)

        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 4 })
        #expect(h.shownIds("VLPL1") == ["b", "d", "c", "a"])
        #expect(await h.backend.moreTracksCalls.count == 4)
    }

    @Test("a reload of a sorted playlist loads all of its songs again")
    func reloadKeepsSort() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 4 })

        h.store.reloadPage("VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 4 })
        #expect(h.shownIds("VLPL1") == ["b", "d", "c", "a"])
    }

    @Test("loading stops at the cap and the loaded songs are sorted")
    func cap() async {
        let h = SortHarness()
        let first = (0..<700).map { MusicSamples.track("p\($0)", title: "T\(1000 - $0)") }
        await h.backend.setPage(MusicSamples.page("VLBIG", tracks: first, continuation: "t1"))
        for (index, token) in ["t1", "t2", "t3", "t4"].enumerated() {
            let page = (0..<700).map { MusicSamples.track("q\(index)_\($0)", title: "U\($0)") }
            await h.backend.setMoreTracks(browseId: "VLBIG", continuation: token, tracks: page, next: "t\(index + 2)")
        }
        h.store.open(MusicSamples.collection("VLBIG"))
        #expect(await h.until { h.loadedPage("VLBIG") != nil })

        h.store.pickSort(.title, for: "VLBIG")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })

        // 700, 1400, 2100: the third page takes it over 2000, so nothing is asked after it.
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
        let loaded = h.loadedPage("VLBIG")?.tracks.count ?? 0
        #expect(loaded >= MusicBrowseStore.sortTrackCap - 700)
        #expect(loaded < MusicBrowseStore.sortTrackCap + 700)
        // The sorted list is exactly the first 2000 songs of the playlist, so the note beside the sort is exact.
        let shown = h.store.displayedPage("VLBIG")
        #expect(shown?.continuation == nil)
        #expect(shown?.tracks.count == MusicBrowseStore.sortTrackCap)
        #expect(shown?.tracks.first?.title.hasPrefix("T") == true)
        let shownIDs: Set<String> = Set((shown?.tracks ?? []).map { $0.videoId })
        let firstIDs: Set<String> = Set((h.loadedPage("VLBIG")?.tracks ?? []).prefix(MusicBrowseStore.sortTrackCap).map { $0.videoId })
        #expect(shownIDs.isSubset(of: firstIDs))
        #expect(h.store.sortedSongLimit("VLBIG") == MusicBrowseStore.sortTrackCap)
    }

    @Test("a playlist the user made that stops at the cap goes back to Playlist order, so its newest songs stay reachable")
    func ownedCapFallsBackToPlaylistOrder() async {
        let h = SortHarness()
        let first = (0..<700).map { MusicSamples.track("p\($0)", title: "T\($0)") }
        await h.backend.setPage(MusicSamples.page("VLBIG", tracks: first, continuation: "t1", isEditable: true))
        for (index, token) in ["t1", "t2", "t3", "t4"].enumerated() {
            let page = (0..<700).map { MusicSamples.track("q\(index)_\($0)", title: "U\($0)") }
            await h.backend.setMoreTracks(browseId: "VLBIG", continuation: token, tracks: page, next: "t\(index + 2)")
        }
        h.store.open(MusicSamples.collection("VLBIG"))
        #expect(await h.until { h.loadedPage("VLBIG") != nil && h.store.loadingAllTracks.isEmpty })

        #expect(h.store.sort(for: "VLBIG") == .playlistOrder)
        #expect(!h.store.needsReorder("VLBIG"))
        #expect(!h.store.isOrderPending("VLBIG"))
        let shown = h.store.displayedPage("VLBIG")
        #expect(shown?.tracks.first?.videoId == "p0")
        #expect(shown?.continuation != nil)
        #expect(h.store.sortedSongLimit("VLBIG") == nil)
    }

    @Test("Date added picked on a playlist the user made keeps its sort at the cap, with the limit note")
    func ownedPickedDateAddedKeepsSortAtCap() async {
        let h = SortHarness()
        let first = (0..<700).map { MusicSamples.track("p\($0)", title: "T\($0)") }
        await h.backend.setPage(MusicSamples.page("VLBIG", tracks: first, continuation: "t1", isEditable: true))
        for (index, token) in ["t1", "t2", "t3", "t4"].enumerated() {
            let page = (0..<700).map { MusicSamples.track("q\(index)_\($0)", title: "U\($0)") }
            await h.backend.setMoreTracks(browseId: "VLBIG", continuation: token, tracks: page, next: "t\(index + 2)")
        }
        h.store.open(MusicSamples.collection("VLBIG"))
        #expect(await h.until { h.loadedPage("VLBIG") != nil && h.store.loadingAllTracks.isEmpty })

        // Back at Playlist order after the cap; Date added picked twice is newest first again, as the user asked.
        h.store.pickSort(.dateAdded, for: "VLBIG")
        if h.store.sort(for: "VLBIG") != .dateAddedNewestFirst { h.store.pickSort(.dateAdded, for: "VLBIG") }
        #expect(h.store.sort(for: "VLBIG") == .dateAddedNewestFirst)
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        #expect(h.store.sort(for: "VLBIG") == .dateAddedNewestFirst)
        #expect(h.store.sortedSongLimit("VLBIG") == MusicBrowseStore.sortTrackCap)
    }

    @Test("the cap is 2000 songs")
    func capValue() {
        #expect(MusicBrowseStore.sortTrackCap == 2000)
    }

    @Test("a playlist already at the cap sorts without asking for more")
    func capAlreadyReached() async {
        let h = SortHarness()
        let full = (0..<MusicBrowseStore.sortTrackCap).map { MusicSamples.track("p\($0)", title: "T\($0)") }
        await h.backend.setPage(MusicSamples.page("VLBIG", tracks: full, continuation: "t1"))
        h.store.open(MusicSamples.collection("VLBIG"))
        #expect(await h.until { h.loadedPage("VLBIG") != nil })

        h.store.pickSort(.title, for: "VLBIG")
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(h.store.displayedPage("VLBIG")?.continuation == nil)
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.isEmpty)
        #expect(h.store.sortedSongLimit("VLBIG") == MusicBrowseStore.sortTrackCap)
    }

    @Test("a failed page ends the sort: the songs so far stay in page order and the sort goes back to Playlist order")
    func failure() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t2", MusicError.http(500))

        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.shownIds("VLPL1") == ["a", "b", "c"])
        #expect(h.store.displayedPage("VLPL1")?.continuation == "t2")

        // Picking it again retries from where it stopped.
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t2", nil)
        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 4 })
        #expect(h.shownIds("VLPL1") == ["b", "d", "c", "a"])
    }

    @Test("the page footer does not load more while a sort is loading everything")
    func footerBlocked() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)

        h.store.pickSort(.title, for: "VLPL1")
        h.store.loadMoreTracks("VLPL1")
        #expect(h.store.loadingMoreTracks.isEmpty)
        await gate.open()
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
    }

    @Test("a sort chosen while the footer is loading waits for it and still ends with every song")
    func sortDuringFooterLoad() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)

        h.store.loadMoreTracks("VLPL1")
        h.store.pickSort(.title, for: "VLPL1")
        await gate.open()

        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 4 })
        #expect(h.shownIds("VLPL1") == ["b", "d", "c", "a"])
    }

    @Test("pages that arrive after a reload are dropped and never mixed into the new page")
    func staleLoadAll() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        let slow = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", slow)
        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { await h.backend.moreTracksCalls.count == 1 })

        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: [MusicSamples.track("fresh", title: "Fresh")]))
        h.store.reloadPage("VLPL1")
        #expect(await h.until { h.loadedPage("VLPL1")?.tracks.map(\.videoId) == ["fresh"] })

        await slow.open()
        await h.letLateWorkLand()
        #expect(h.loadedPage("VLPL1")?.tracks.map(\.videoId) == ["fresh"])
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(h.shownIds("VLPL1") == ["fresh"])
    }

    @Test("a sort picked for a page that is not a playlist does nothing")
    func notAPlaylist() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page("MPREb_x", tracks: [MusicSamples.track("a", title: "Z"), MusicSamples.track("b", title: "A")]))
        h.store.open(MusicSamples.collection("MPREb_x", kind: .album))
        #expect(await h.until { h.loadedPage("MPREb_x") != nil })

        h.store.pickSort(.title, for: "MPREb_x")
        #expect(h.store.sort(for: "MPREb_x") == .playlistOrder)
        #expect(h.shownIds("MPREb_x") == ["a", "b"])
    }

    @Test("a sort picked before the page has loaded is applied when it lands")
    func pickedEarly() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page(
            "VLPL1", tracks: [MusicSamples.track("a", title: "B")], continuation: "t1"
        ))
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: [MusicSamples.track("b", title: "A")])
        h.store.pickSort(.title, for: "VLPL1")
        h.store.open(MusicSamples.collection("VLPL1"))

        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 2 })
        #expect(h.shownIds("VLPL1") == ["b", "a"])
    }

    @Test("reset forgets every remembered sort")
    func resetForgets() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })

        h.store.reset()
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.store.loadingAllTracks.isEmpty)
    }

    @Test("a reset while the songs are loading drops them and clears the loading state")
    func resetWhileLoading() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { await h.backend.moreTracksCalls.count == 1 })

        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(h.store.displayedPage("VLPL1") == nil)
    }

    @Test("a playlist at the size cap sorts to the right first song and reads the same every time")
    func largePlaylist() async {
        let h = SortHarness()
        let many = (0..<MusicBrowseStore.sortTrackCap).map { MusicSamples.track("v\($0)", title: "Song \(2000 - $0)") }
        await h.backend.setPage(MusicSamples.page("VLBIG", tracks: many))
        h.store.open(MusicSamples.collection("VLBIG"))
        #expect(await h.until { h.loadedPage("VLBIG") != nil })

        h.store.pickSort(.title, for: "VLBIG")
        let first = h.store.displayedPage("VLBIG")
        #expect(first?.tracks.first?.videoId == "v1999")
        #expect(first?.tracks.count == MusicBrowseStore.sortTrackCap)
        #expect(h.store.displayedPage("VLBIG") == first)
        // Exactly 2000 songs and nothing more to load: nothing was left out.
        #expect(h.store.sortedSongLimit("VLBIG") == nil)
    }

    // MARK: - Guards on the load-all loop

    @Test("pages that bring no new songs three times in a row end the loading, and the songs so far are sorted")
    func stopsAfterThreeEmptyPages() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: [MusicSamples.track("a", title: "B")], continuation: "t1"))
        for index in 1...10 {
            await h.backend.setMoreTracks(
                browseId: "VLPL1", continuation: "t\(index)",
                tracks: [MusicSamples.track("a", title: "B")], next: "t\(index + 1)"
            )
        }
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })

        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        await h.letLateWorkLand()

        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2", "t3"])
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(h.shownIds("VLPL1") == ["a"])
        #expect(h.store.sort(for: "VLPL1").field == .title)
        #expect(h.store.sortedSongLimit("VLPL1") == 1)
    }

    @Test("a page with new songs resets the count of empty pages")
    func freshPageResetsTheCount() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: [MusicSamples.track("a", title: "Delta")], continuation: "t1"))
        let dupe = [MusicSamples.track("a", title: "Delta")]
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: dupe, next: "t2")
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t2", tracks: dupe, next: "t3")
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t3", tracks: [MusicSamples.track("b", title: "Alpha")], next: "t4")
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t4", tracks: dupe, next: "t5")
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t5", tracks: dupe, next: "t6")
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t6", tracks: [MusicSamples.track("c", title: "Charlie")], next: nil)
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })

        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 3 })

        #expect(await h.backend.moreTracksCalls.count == 6)
        #expect(h.shownIds("VLPL1") == ["b", "c", "a"])
        #expect(h.store.sortedSongLimit("VLPL1") == nil)
    }

    @Test("a chain of continuations that comes back to one already used ends the loading")
    func cyclingTokens() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: [MusicSamples.track("a", title: "Delta")], continuation: "t1"))
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: [MusicSamples.track("b", title: "Bravo")], next: "t2")
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t2", tracks: [MusicSamples.track("c", title: "Charlie")], next: "t3")
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t3", tracks: [MusicSamples.track("d", title: "Alpha")], next: "t1")
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })

        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        await h.letLateWorkLand()
        h.store.reset()

        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2", "t3"])
    }

    @Test("the loading stops at a hard ceiling of pages even when every page has new songs and no token repeats")
    func pageCeiling() async {
        let h = SortHarness()
        let ceiling = MusicBrowseStore.sortPageCeiling
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: [MusicSamples.track("a", title: "A")], continuation: "t1"))
        for index in 1...(ceiling + 20) {
            await h.backend.setMoreTracks(
                browseId: "VLPL1", continuation: "t\(index)",
                tracks: [MusicSamples.track("s\(index)", title: "S\(index)")], next: "t\(index + 1)"
            )
        }
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })

        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        await h.letLateWorkLand()
        h.store.reset()

        #expect(ceiling >= 50)
        #expect(await h.backend.moreTracksCalls.count == ceiling)
    }

    @Test("a playlist whose pages run out before any guard fires is not marked as cut short")
    func completePlaylistHasNoLimit() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 4 })
        #expect(h.store.sortedSongLimit("VLPL1") == nil)
    }

    // MARK: - The "first N songs" note

    @Test("with the playlist in its own order there is no limit note, and none while a sort is still loading the songs")
    func noLimitWithoutSortOrWhileLoading() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        #expect(h.store.sortedSongLimit("VLPL1") == nil)

        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        h.store.pickSort(.title, for: "VLPL1")
        #expect(h.store.sortedSongLimit("VLPL1") == nil)
        await gate.open()
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
    }

    @Test("the note reads First 2000 songs, and First song for a single one")
    func limitText() {
        #expect(MusicSortNote.limitText(MusicBrowseStore.sortTrackCap) == "First 2000 songs")
        #expect(MusicSortNote.limitText(1) == "First song")
    }

    @Test("going back to Playlist order drops the limit note")
    func playlistOrderDropsTheLimit() async {
        let h = SortHarness()
        let first = (0..<700).map { MusicSamples.track("p\($0)", title: "T\(1000 - $0)") }
        await h.backend.setPage(MusicSamples.page("VLBIG", tracks: first, continuation: "t1"))
        for (index, token) in ["t1", "t2", "t3"].enumerated() {
            let page = (0..<700).map { MusicSamples.track("q\(index)_\($0)", title: "U\($0)") }
            await h.backend.setMoreTracks(browseId: "VLBIG", continuation: token, tracks: page, next: "t\(index + 2)")
        }
        h.store.open(MusicSamples.collection("VLBIG"))
        #expect(await h.until { h.loadedPage("VLBIG") != nil })
        h.store.pickSort(.title, for: "VLBIG")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        #expect(h.store.sortedSongLimit("VLBIG") == MusicBrowseStore.sortTrackCap)

        h.store.pickSort(.playlistOrder, for: "VLBIG")
        #expect(h.store.sortedSongLimit("VLBIG") == nil)
    }

    // MARK: - Date added at rest

    @Test("a playlist the user made lands on Date added newest first, loads the rest and shows the whole list reversed")
    func ownedPlaylistRestsOnDateAdded() async {
        let h = SortHarness()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        await h.openLongPlaylist(isEditable: true)

        #expect(h.store.sort(for: "VLPL1") == .dateAddedNewestFirst)
        #expect(h.store.needsReorder("VLPL1"))
        // The load starts the moment the page lands, with nobody having picked anything.
        #expect(h.store.loadingAllTracks == ["VLPL1"])
        #expect(h.store.isOrderPending("VLPL1"))
        #expect(h.store.sorts["VLPL1"] == nil)

        await gate.open()
        #expect(await h.settled("VLPL1", count: 4))
        #expect(h.shownIds("VLPL1") == ["d", "c", "b", "a"])
        #expect(h.store.displayedPage("VLPL1")?.continuation == nil)
        #expect(!h.store.isOrderPending("VLPL1"))
        #expect(h.store.sortedSongLimit("VLPL1") == nil)
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
        // The stored page stays in YouTube's order.
        #expect(h.loadedPage("VLPL1")?.tracks.map(\.videoId) == ["a", "b", "c", "d"])
    }

    @Test("a short playlist the user made shows reversed at once and fetches nothing")
    func ownedShortPlaylistReversesAtOnce() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page(
            "VLPL1", tracks: [MusicSamples.track("a"), MusicSamples.track("b"), MusicSamples.track("c")], isEditable: true
        ))
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })

        #expect(h.store.needsReorder("VLPL1"))
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(!h.store.isOrderPending("VLPL1"))
        #expect(h.shownIds("VLPL1") == ["c", "b", "a"])
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.isEmpty)
    }

    @Test("an empty playlist the user made has nothing to reorder and nothing to load")
    func ownedEmptyPlaylist() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page("VLPL1", isEditable: true))
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })
        #expect(h.shownIds("VLPL1") == [])
        #expect(h.store.loadingAllTracks.isEmpty)
    }

    @Test("the page the list shows and Play queues stays in YouTube's order while the rest is loading, and the list waits")
    func ownedPlaylistPendingWhileLoading() async {
        let h = SortHarness()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        await h.openLongPlaylist(isEditable: true)

        #expect(h.store.isOrderPending("VLPL1"))
        #expect(h.shownIds("VLPL1") == ["a"])
        #expect(h.store.displayedPage("VLPL1")?.continuation == "t1")
        await gate.open()
        #expect(await h.settled("VLPL1", count: 4))
        #expect(!h.store.isOrderPending("VLPL1"))
    }

    @Test("a playlist in its own order is not pending, and a picked sort is pending until its songs are in")
    func pendingOnlyWhileReordering() async {
        let h = SortHarness()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        await h.openLongPlaylist()
        #expect(!h.store.isOrderPending("VLPL1"))

        h.store.pickSort(.title, for: "VLPL1")
        #expect(h.store.isOrderPending("VLPL1"))
        await gate.open()
        #expect(await h.settled("VLPL1", count: 4))
        #expect(!h.store.isOrderPending("VLPL1"))
    }

    @Test("picking Playlist order while the songs load ends the wait at once, before the page in flight lands")
    func playlistOrderEndsThePendingWait() async {
        let h = SortHarness()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        await h.openLongPlaylist(isEditable: true)
        #expect(h.store.isOrderPending("VLPL1"))
        #expect(await h.until { await h.backend.moreTracksCalls.count == 1 })

        h.store.pickSort(.playlistOrder, for: "VLPL1")
        #expect(!h.store.isOrderPending("VLPL1"))
        await gate.open()
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1"])
        #expect(h.shownIds("VLPL1") == ["a", "b", "c"])
    }

    @Test("a playlist the user made is not touched by a playlist that is not theirs, and the other way round")
    func restIsPerPlaylist() async {
        let h = SortHarness()
        await h.openLongPlaylist("VLPLmine", isEditable: true)
        await h.openLongPlaylist("VLPLtheirs")
        #expect(await h.settled("VLPLmine", count: 4))

        #expect(h.store.sort(for: "VLPLmine") == .dateAddedNewestFirst)
        #expect(h.store.sort(for: "VLPLtheirs") == .playlistOrder)
        #expect(h.shownIds("VLPLmine") == ["d", "c", "b", "a"])
        #expect(h.shownIds("VLPLtheirs") == ["a"])
        #expect(await h.backend.moreTracksCalls.allSatisfy { $0.browseId == "VLPLmine" })
    }

    @Test("before a page has loaded only Liked music is known to rest on Date added")
    func restBeforeLanding() {
        let h = SortHarness()
        #expect(h.store.sort(for: "VLLM") == .dateAddedNewestFirst)
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.store.sort(for: "MPREb_x") == .playlistOrder)
        #expect(h.store.sort(for: "") == .playlistOrder)
    }

    @Test("an album never rests on Date added, whatever the page says")
    func albumsKeepTheirOrder() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page(
            "MPREb_x", tracks: [MusicSamples.track("a"), MusicSamples.track("b")], isEditable: true
        ))
        h.store.open(MusicSamples.collection("MPREb_x", kind: .album))
        #expect(await h.until { h.loadedPage("MPREb_x") != nil })
        #expect(h.store.sort(for: "MPREb_x") == .playlistOrder)
        #expect(h.shownIds("MPREb_x") == ["a", "b"])
    }

    // MARK: - Liked music

    /// Liked music as YouTube lists it: the newest like first. Like a real one, it is not marked editable.
    private func openLiked(_ h: SortHarness, continuation: String? = "t1") async {
        await h.backend.setPage(MusicSamples.page(
            "VLLM", tracks: [MusicSamples.track("n1", title: "Newest")], continuation: continuation, title: "Liked music"
        ))
        await h.backend.setMoreTracks(
            browseId: "VLLM", continuation: "t1",
            tracks: [MusicSamples.track("n2", title: "Middle"), MusicSamples.track("n3", title: "Older")], next: "t2"
        )
        await h.backend.setMoreTracks(
            browseId: "VLLM", continuation: "t2",
            tracks: [MusicSamples.track("n4", title: "Oldest")], next: nil
        )
        h.store.open(MusicBrowseStore.likedMusic)
        _ = await h.until { h.loadedPage("VLLM") != nil }
    }

    @Test("Liked music rests on Date added newest first and shows YouTube's order with nothing extra loaded")
    func likedRestsInstantly() async {
        let h = SortHarness()
        await openLiked(h)

        #expect(h.store.sort(for: "VLLM") == .dateAddedNewestFirst)
        #expect(!h.store.needsReorder("VLLM"))
        #expect(!h.store.isOrderPending("VLLM"))
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(h.shownIds("VLLM") == ["n1"])
        #expect(h.store.displayedPage("VLLM") == h.loadedPage("VLLM"))
        #expect(h.store.displayedPage("VLLM")?.continuation == "t1")
        #expect(h.store.sortedSongLimit("VLLM") == nil)
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.isEmpty)
    }

    @Test("Liked music still pages in on scroll at rest")
    func likedStillPagesOnScroll() async {
        let h = SortHarness()
        await openLiked(h)
        h.store.loadMoreTracks("VLLM")
        #expect(await h.until { h.shownIds("VLLM") == ["n1", "n2", "n3"] })
    }

    @Test("Date added on Liked music flips to oldest first: it loads everything and reverses YouTube's order")
    func likedOldestFirst() async {
        let h = SortHarness()
        await openLiked(h)

        h.store.pickSort(.dateAdded, for: "VLLM")
        #expect(h.store.sort(for: "VLLM") == MusicPlaylistSort(field: .dateAdded, ascending: true))
        #expect(h.store.needsReorder("VLLM"))
        #expect(await h.settled("VLLM", count: 4))
        #expect(h.shownIds("VLLM") == ["n4", "n3", "n2", "n1"])
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])

        // And back to newest first: YouTube's order, with nothing to reorder or load again.
        h.store.pickSort(.dateAdded, for: "VLLM")
        #expect(h.store.sort(for: "VLLM") == .dateAddedNewestFirst)
        #expect(!h.store.needsReorder("VLLM"))
        #expect(h.shownIds("VLLM") == ["n1", "n2", "n3", "n4"])
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.count == 2)
    }

    @Test("Playlist order on Liked music is YouTube's order too, and needs no reorder")
    func likedPlaylistOrder() async {
        let h = SortHarness()
        await openLiked(h)
        h.store.pickSort(.playlistOrder, for: "VLLM")
        #expect(h.store.sort(for: "VLLM") == .playlistOrder)
        #expect(!h.store.needsReorder("VLLM"))
        #expect(h.shownIds("VLLM") == ["n1"])
        #expect(h.store.loadingAllTracks.isEmpty)
    }

    @Test("a title sort on Liked music loads everything first, as on any playlist")
    func likedByTitle() async {
        let h = SortHarness()
        await openLiked(h)
        h.store.pickSort(.title, for: "VLLM")
        #expect(h.store.isOrderPending("VLLM"))
        #expect(await h.settled("VLLM", count: 4))
        #expect(h.shownIds("VLLM") == ["n2", "n1", "n3", "n4"])
    }

    @Test("a failed load on Liked music falls back to Playlist order, which is YouTube's order, and does not loop")
    func likedFailure() async {
        let h = SortHarness()
        await openLiked(h)
        await h.backend.setMoreTracksError(browseId: "VLLM", continuation: "t2", MusicError.http(500))
        h.store.pickSort(.dateAdded, for: "VLLM")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        await h.letLateWorkLand()
        #expect(h.store.sort(for: "VLLM") == .playlistOrder)
        #expect(h.shownIds("VLLM") == ["n1", "n2", "n3"])
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
    }

    // MARK: - Picking on top of the rest

    @Test("Date added on a playlist the user made flips the rest to oldest first, which is YouTube's order")
    func ownedDateAddedFlips() async {
        let h = SortHarness()
        await h.openLongPlaylist(isEditable: true)
        #expect(await h.settled("VLPL1", count: 4))

        h.store.pickSort(.dateAdded, for: "VLPL1")
        #expect(h.store.sort(for: "VLPL1") == MusicPlaylistSort(field: .dateAdded, ascending: true))
        #expect(!h.store.needsReorder("VLPL1"))
        #expect(h.shownIds("VLPL1") == ["a", "b", "c", "d"])

        h.store.pickSort(.dateAdded, for: "VLPL1")
        #expect(h.store.sort(for: "VLPL1") == .dateAddedNewestFirst)
        #expect(h.shownIds("VLPL1") == ["d", "c", "b", "a"])
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.count == 2)
    }

    @Test("Date added on a playlist that is not the user's starts newest first and loads everything")
    func notOwnedDateAdded() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        h.store.pickSort(.dateAdded, for: "VLPL1")
        #expect(h.store.sort(for: "VLPL1") == .dateAddedNewestFirst)
        #expect(h.store.isOrderPending("VLPL1"))
        #expect(await h.settled("VLPL1", count: 4))
        #expect(h.shownIds("VLPL1") == ["d", "c", "b", "a"])

        h.store.pickSort(.dateAdded, for: "VLPL1")
        #expect(h.shownIds("VLPL1") == ["a", "b", "c", "d"])
    }

    @Test("picking Playlist order on a playlist the user made shows YouTube's order and stores it as picked")
    func ownedPlaylistOrderPicked() async {
        let h = SortHarness()
        await h.openLongPlaylist(isEditable: true)
        #expect(await h.settled("VLPL1", count: 4))
        #expect(h.shownIds("VLPL1") == ["d", "c", "b", "a"])

        h.store.pickSort(.playlistOrder, for: "VLPL1")
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.store.sorts["VLPL1"] == .playlistOrder)
        #expect(!h.store.needsReorder("VLPL1"))
        #expect(h.shownIds("VLPL1") == ["a", "b", "c", "d"])
    }

    @Test("Playlist order picked on a playlist the user made survives closing and reopening it, and loads nothing")
    func ownedPlaylistOrderSurvivesReopen() async {
        let h = SortHarness()
        await h.openLongPlaylist(isEditable: true)
        #expect(await h.settled("VLPL1", count: 4))
        h.store.pickSort(.playlistOrder, for: "VLPL1")
        let callsBefore = await h.backend.moreTracksCalls.count

        h.store.back()
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })
        await h.letLateWorkLand()
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(h.shownIds("VLPL1") == ["a"])
        #expect(await h.backend.moreTracksCalls.count == callsBefore)
    }

    @Test("a closed and reopened playlist the user made rests on Date added again and loads everything again")
    func ownedReopenLoadsAgain() async {
        let h = SortHarness()
        await h.openLongPlaylist(isEditable: true)
        #expect(await h.settled("VLPL1", count: 4))
        h.store.back()
        #expect(h.store.displayedPage("VLPL1") == nil)

        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.settled("VLPL1", count: 4))
        #expect(h.shownIds("VLPL1") == ["d", "c", "b", "a"])
        #expect(await h.backend.moreTracksCalls.count == 4)
    }

    @Test("a reload of a playlist the user made loads all of its songs again and lands reversed")
    func ownedReload() async {
        let h = SortHarness()
        await h.openLongPlaylist(isEditable: true)
        #expect(await h.settled("VLPL1", count: 4))

        h.store.reloadPage("VLPL1")
        #expect(await h.settled("VLPL1", count: 4))
        #expect(h.shownIds("VLPL1") == ["d", "c", "b", "a"])
    }

    @Test("reset forgets a picked Playlist order, so the playlist rests on Date added again")
    func resetRestoresTheRest() async {
        let h = SortHarness()
        await h.openLongPlaylist(isEditable: true)
        #expect(await h.settled("VLPL1", count: 4))
        h.store.pickSort(.playlistOrder, for: "VLPL1")
        h.store.reset()
        #expect(h.store.sorts.isEmpty)

        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.settled("VLPL1", count: 4))
        #expect(h.store.sort(for: "VLPL1") == .dateAddedNewestFirst)
        #expect(h.shownIds("VLPL1") == ["d", "c", "b", "a"])
    }

    // MARK: - Failure at rest

    @Test("a failed page at rest falls back to Playlist order, shows what loaded in YouTube's order and does not loop")
    func ownedFailureFallsBack() async {
        let h = SortHarness()
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t2", MusicError.http(500))
        await h.openLongPlaylist(isEditable: true)

        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        await h.letLateWorkLand()
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.store.sorts["VLPL1"] == .playlistOrder)
        #expect(!h.store.needsReorder("VLPL1"))
        #expect(!h.store.isOrderPending("VLPL1"))
        #expect(h.shownIds("VLPL1") == ["a", "b", "c"])
        #expect(h.store.displayedPage("VLPL1")?.continuation == "t2")
        // Each page was asked for once: the fallback does not start the load again.
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])

        // Picking Date added again retries from where it stopped.
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t2", nil)
        h.store.pickSort(.dateAdded, for: "VLPL1")
        #expect(h.store.sort(for: "VLPL1") == .dateAddedNewestFirst)
        #expect(await h.settled("VLPL1", count: 4))
        #expect(h.shownIds("VLPL1") == ["d", "c", "b", "a"])
    }

    @Test("a failed first page at rest leaves the page in YouTube's order and the footer free to load more")
    func ownedFirstPageFailure() async {
        let h = SortHarness()
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t1", MusicError.http(500))
        await h.openLongPlaylist(isEditable: true)
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.shownIds("VLPL1") == ["a"])

        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t1", nil)
        h.store.loadMoreTracks("VLPL1")
        #expect(await h.until { h.shownIds("VLPL1") == ["a", "b", "c"] })
    }

    // MARK: - Guards at rest

    @Test("the page footer does not load more while a playlist the user made is loading everything at rest")
    func ownedFooterBlocked() async {
        let h = SortHarness()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        await h.openLongPlaylist(isEditable: true)

        h.store.loadMoreTracks("VLPL1")
        #expect(h.store.loadingMoreTracks.isEmpty)
        await gate.open()
        #expect(await h.settled("VLPL1", count: 4))
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
    }

    @Test("pages that arrive after a reload are dropped, and the reloaded playlist loads itself at rest")
    func ownedStaleLoad() async {
        let h = SortHarness()
        let slow = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", slow)
        await h.openLongPlaylist(isEditable: true)
        #expect(await h.until { await h.backend.moreTracksCalls.count == 1 })

        await h.backend.setPage(MusicSamples.page(
            "VLPL1", tracks: [MusicSamples.track("fresh", title: "Fresh")], isEditable: true
        ))
        h.store.reloadPage("VLPL1")
        #expect(await h.until { h.loadedPage("VLPL1")?.tracks.map(\.videoId) == ["fresh"] })

        await slow.open()
        await h.letLateWorkLand()
        #expect(h.loadedPage("VLPL1")?.tracks.map(\.videoId) == ["fresh"])
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(h.shownIds("VLPL1") == ["fresh"])
    }

    @Test("a reset while a playlist the user made is loading at rest clears the loading state")
    func ownedResetWhileLoading() async {
        let h = SortHarness()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        await h.openLongPlaylist(isEditable: true)
        #expect(await h.until { await h.backend.moreTracksCalls.count == 1 })

        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.loadingAllTracks.isEmpty)
        #expect(!h.store.isOrderPending("VLPL1"))
        #expect(h.store.displayedPage("VLPL1") == nil)
    }

    @Test("removing a song from a playlist the user made updates the reversed list")
    func ownedRemoval() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page(
            "VLPL1",
            tracks: [
                MusicSamples.track("a", setVideoId: "s1"),
                MusicSamples.track("b", setVideoId: "s2"),
                MusicSamples.track("c", setVideoId: "s3")
            ],
            isEditable: true
        ))
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })
        #expect(h.shownIds("VLPL1") == ["c", "b", "a"])

        #expect(h.store.removeTrack(setVideoId: "s2", from: "VLPL1"))
        #expect(h.shownIds("VLPL1") == ["c", "a"])
    }

    // MARK: - An artist's songs list

    @Test("a normal playlist, a playlist the user made and Liked music offer exactly the options they always did")
    func normalPlaylistOptions() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        await h.openLongPlaylist("VLPL2", isEditable: true)

        let expected: [MusicSortField] = [.dateAdded, .playlistOrder, .title, .artist, .album, .duration]
        #expect(h.store.sortOptions(for: "VLPL1") == expected)
        #expect(h.store.sortOptions(for: "VLPL2") == expected)
        #expect(h.store.sortOptions(for: MusicBrowseStore.likedMusic.browseId) == expected)
        #expect(!h.store.isArtistSongs("VLPL1"))
        #expect(!h.store.isArtistSongs("VLPL2"))
        #expect(!h.store.isArtistSongs(MusicBrowseStore.likedMusic.browseId))
    }

    @Test("an artist's songs list offers Popular, Album, Release date and Plays, and nothing else")
    func artistSongsOptions() async {
        let h = SortHarness()
        await h.openSongsList()
        #expect(h.store.isArtistSongs("VLOLAK5uy_songs"))
        #expect(h.store.sortOptions(for: "VLOLAK5uy_songs") == [.playlistOrder, .album, .releaseDate, .plays])
        #expect(MusicBrowseStore.canSort("VLOLAK5uy_songs"))
    }

    @Test("the marker travels with the opened collection: the same OLAK5uy_ id opened as a plain playlist is not one")
    func markerIsNotGuessedFromTheId() async {
        let h = SortHarness()
        await h.openSongsList(isArtistSongs: false)
        #expect(!h.store.isArtistSongs("VLOLAK5uy_songs"))
        #expect(h.store.sortOptions(for: "VLOLAK5uy_songs") == MusicSortField.playlistOptions)
    }

    @Test("a page that is not on the path is not an artist's songs list, nor is one after back or reset")
    func markerFollowsThePath() async {
        let h = SortHarness()
        #expect(!h.store.isArtistSongs("VLOLAK5uy_songs"))
        #expect(h.store.sortOptions(for: "VLOLAK5uy_songs") == MusicSortField.playlistOptions)

        await h.openSongsList()
        #expect(h.store.isArtistSongs("VLOLAK5uy_songs"))
        h.store.back()
        #expect(!h.store.isArtistSongs("VLOLAK5uy_songs"))

        h.store.open(MusicSamples.collection("VLOLAK5uy_songs", isArtistSongs: true))
        #expect(h.store.isArtistSongs("VLOLAK5uy_songs"))
        h.store.reset()
        #expect(!h.store.isArtistSongs("VLOLAK5uy_songs"))
    }

    @Test("an artist's songs list rests on Popular, which is YouTube's order: it loads nothing and shows the page as it is")
    func artistSongsRestOnPopular() async {
        let h = SortHarness()
        await h.openSongsList()
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == .playlistOrder)
        #expect(!h.store.needsReorder("VLOLAK5uy_songs"))
        #expect(h.store.displayedPage("VLOLAK5uy_songs") == h.loadedPage("VLOLAK5uy_songs"))
        #expect(h.store.loadingAllTracks.isEmpty)
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.isEmpty)
    }

    @Test("Plays loads every page first, then lists the most played first with the songs that have no count last")
    func artistSongsPlays() async {
        let h = SortHarness()
        await h.openSongsList()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLOLAK5uy_songs", continuation: "t1", gate)

        h.store.pickSort(.plays, for: "VLOLAK5uy_songs")
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == MusicPlaylistSort(field: .plays, ascending: false))
        #expect(h.store.loadingAllTracks == ["VLOLAK5uy_songs"])
        #expect(h.store.isOrderPending("VLOLAK5uy_songs"))
        // Until everything is here the list keeps the order it has.
        #expect(h.shownIds("VLOLAK5uy_songs") == ["a"])

        await gate.open()
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["c", "a", "d", "b"])
        #expect(h.store.displayedPage("VLOLAK5uy_songs")?.continuation == nil)
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1"])
    }

    @Test("picking Plays again flips it, so the least played come first and the songs with no count stay last")
    func artistSongsPlaysFlip() async {
        let h = SortHarness()
        await h.openSongsList()
        h.store.pickSort(.plays, for: "VLOLAK5uy_songs")
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))

        h.store.pickSort(.plays, for: "VLOLAK5uy_songs")
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == MusicPlaylistSort(field: .plays, ascending: true))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["a", "d", "c", "b"])
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.count == 1)
    }

    @Test("Album sorts A to Z with the songs that have none last, and Popular puts YouTube's order back")
    func artistSongsAlbumThenPopular() async {
        let h = SortHarness()
        await h.openSongsList()
        h.store.pickSort(.album, for: "VLOLAK5uy_songs")
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["b", "d", "a", "c"])

        h.store.pickSort(.playlistOrder, for: "VLOLAK5uy_songs")
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == .playlistOrder)
        #expect(!h.store.needsReorder("VLOLAK5uy_songs"))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["a", "b", "c", "d"])
    }

    @Test("an artist's songs list ignores the options it does not offer: nothing changes and nothing loads")
    func artistSongsRefusesOtherOptions() async {
        let h = SortHarness()
        await h.openSongsList()
        for field in [MusicSortField.dateAdded, .title, .artist, .duration] {
            h.store.pickSort(field, for: "VLOLAK5uy_songs")
        }
        #expect(h.store.sorts["VLOLAK5uy_songs"] == nil)
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == .playlistOrder)
        #expect(h.store.loadingAllTracks.isEmpty)
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.isEmpty)
        #expect(h.shownIds("VLOLAK5uy_songs") == ["a"])
    }

    @Test("Plays is not an option of a normal playlist: picking it changes nothing and loads nothing")
    func plainPlaylistRefusesPlays() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        h.store.pickSort(.plays, for: "VLPL1")
        #expect(h.store.sorts["VLPL1"] == nil)
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.store.loadingAllTracks.isEmpty)
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.isEmpty)

        // The options it has still work as they did.
        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.settled("VLPL1", count: 4))
        #expect(h.shownIds("VLPL1") == ["b", "d", "c", "a"])
    }

    @Test("a pick made on an artist's songs list is kept when the page is closed and opened again, and reset forgets it")
    func artistSongsPickIsRemembered() async {
        let h = SortHarness()
        await h.openSongsList()
        h.store.pickSort(.plays, for: "VLOLAK5uy_songs")
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))

        h.store.back()
        h.store.open(MusicSamples.collection("VLOLAK5uy_songs", isArtistSongs: true))
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == MusicPlaylistSort(field: .plays, ascending: false))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["c", "a", "d", "b"])

        h.store.reset()
        #expect(h.store.sorts.isEmpty)
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == .playlistOrder)
    }

    @Test("a Plays pick on an artist's songs does not follow the id opened as a plain playlist")
    func artistSongsPickStaysOnItsPage() async {
        let h = SortHarness()
        await h.openSongsList()
        h.store.pickSort(.plays, for: "VLOLAK5uy_songs")
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))

        // Back drops the page, so it opens fresh: its first page only, since Playlist order loads nothing extra.
        h.store.back()
        h.store.open(MusicSamples.collection("VLOLAK5uy_songs"))
        #expect(await h.settled("VLOLAK5uy_songs", count: 1))
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == .playlistOrder)
    }

    @Test("the all songs id survives loading more songs, taking a song out and sorting")
    func allSongsIdSurvivesRebuilds() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page(
            "VLPL1",
            tracks: [MusicSamples.track("a", title: "B", setVideoId: "s1", plays: 1)],
            continuation: "t1",
            allSongsBrowseId: "VLOLAK5uy_all"
        ))
        await h.backend.setMoreTracks(
            browseId: "VLPL1", continuation: "t1",
            tracks: [MusicSamples.track("b", title: "A", setVideoId: "s2", plays: 2), MusicSamples.track("c", title: "C", setVideoId: "s3")],
            next: nil
        )
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })
        #expect(h.loadedPage("VLPL1")?.allSongsBrowseId == "VLOLAK5uy_all")

        h.store.loadMoreTracks("VLPL1")
        #expect(await h.until { h.loadedPage("VLPL1")?.tracks.count == 3 })
        #expect(h.loadedPage("VLPL1")?.allSongsBrowseId == "VLOLAK5uy_all")

        #expect(h.store.removeTrack(setVideoId: "s3", from: "VLPL1"))
        #expect(h.loadedPage("VLPL1")?.allSongsBrowseId == "VLOLAK5uy_all")

        h.store.pickSort(.title, for: "VLPL1")
        #expect(h.shownIds("VLPL1") == ["b", "a"])
        #expect(h.store.displayedPage("VLPL1")?.allSongsBrowseId == "VLOLAK5uy_all")
    }

    // MARK: - Release date

    @Test("Release date reads the discography pages, then lists the newest release first with the year-less songs last")
    func releaseDateSortsNewestFirst() async {
        let h = SortHarness()
        await h.backend.setDiscography(browseId: "MPADartist", params: "P1", [SortHarness.alpha])
        await h.openArtistThenSongs(links: [SortHarness.albumsLink])

        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == MusicPlaylistSort(field: .releaseDate, ascending: false))
        #expect(await h.yearsRead())
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        // b: Alpha 2020 (discography), a: Zeta 2015 and d: Beta 2010 (artist page shelf), c: no album.
        #expect(h.shownIds("VLOLAK5uy_songs") == ["b", "a", "d", "c"])
        #expect(h.store.displayedPage("VLOLAK5uy_songs")?.continuation == nil)
        #expect(!h.store.isOrderPending("VLOLAK5uy_songs"))
        #expect(await h.backend.discographyCalls == [FakeMusicBackend.DiscographyCall(browseId: "MPADartist", params: "P1")])
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1"])
    }

    @Test("every discography link is asked for with its own params, and a title keeps its earliest year across the answers")
    func releaseDateAsksEveryLink() async {
        let h = SortHarness()
        let singles = MusicDiscographyLink(browseId: "MPADartist", params: "P2")
        // The albums page lists a 2022 re-release of Beta (2010 on the artist page), the singles page brings Alpha in 2012.
        await h.backend.setDiscography(
            browseId: "MPADartist", params: "P1",
            [MusicSamples.collection("MPREbeta2", kind: .album, title: "Beta", subtitle: "Album \u{2022} 2022")]
        )
        await h.backend.setDiscography(
            browseId: "MPADartist", params: "P2",
            [MusicSamples.collection("MPREalpha", kind: .album, title: "Alpha", subtitle: "Single \u{2022} 2012")]
        )
        await h.openArtistThenSongs(links: [SortHarness.albumsLink, singles])

        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(await h.yearsRead())
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        // a: Zeta 2015, b: Alpha 2012, d: Beta 2010 (the earlier of its two years), c: no album.
        #expect(h.shownIds("VLOLAK5uy_songs") == ["a", "b", "d", "c"])
        let calls = Set(await h.backend.discographyCalls)
        #expect(calls == [
            FakeMusicBackend.DiscographyCall(browseId: "MPADartist", params: "P1"),
            FakeMusicBackend.DiscographyCall(browseId: "MPADartist", params: "P2"),
        ])
    }

    @Test("the list waits while the years load, then shows the order, and a flip neither asks again nor loads again")
    func releaseDateWaitsThenFlips() async {
        let h = SortHarness()
        await h.backend.setDiscography(browseId: "MPADartist", params: "P1", [SortHarness.alpha])
        let gate = MusicTestGate()
        await h.backend.setDiscographyGate(browseId: "MPADartist", params: "P1", gate)
        await h.openArtistThenSongs(links: [SortHarness.albumsLink])

        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(h.store.loadingReleaseYears == ["VLOLAK5uy_songs"])
        #expect(h.store.isOrderPending("VLOLAK5uy_songs"))
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        // Every song is here, but the years are not: the list still waits, and shows the page as it came.
        #expect(h.store.isOrderPending("VLOLAK5uy_songs"))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["a", "b", "c", "d"])

        await gate.open()
        #expect(await h.yearsRead())
        #expect(!h.store.isOrderPending("VLOLAK5uy_songs"))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["b", "a", "d", "c"])

        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == MusicPlaylistSort(field: .releaseDate, ascending: true))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["d", "a", "b", "c"])
        #expect(!h.store.isOrderPending("VLOLAK5uy_songs"))
        await h.letLateWorkLand()
        #expect(await h.backend.discographyCalls.count == 1)
        #expect(await h.backend.moreTracksCalls.count == 1)
    }

    @Test("a discography page that fails leaves the artist page's albums to sort by, with no banner and no second try")
    func releaseDateFailureKeepsTheSeed() async {
        let h = SortHarness()
        await h.backend.setDiscographyError(browseId: "MPADartist", params: "P1", MusicError.http(503))
        await h.openArtistThenSongs(links: [SortHarness.albumsLink])

        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(await h.yearsRead())
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        // a: Zeta 2015 and d: Beta 2010 from the shelf; b has no year now, so it goes last with c, in their order.
        #expect(h.shownIds("VLOLAK5uy_songs") == ["a", "d", "b", "c"])
        #expect(h.loadedPage("VLOLAK5uy_songs") != nil)
        if case .failed = h.store.pageState("VLOLAK5uy_songs") { Issue.record("a failed discography page must not fail the songs list") }
        await h.letLateWorkLand()
        #expect(await h.backend.discographyCalls.count == 1)
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == MusicPlaylistSort(field: .releaseDate, ascending: false))
    }

    @Test("after a failed discography page, picking Release date again asks once more and sorts by the answer")
    func releaseDateRetriesAfterAFailure() async {
        let h = SortHarness()
        await h.backend.setDiscographyError(browseId: "MPADartist", params: "P1", MusicError.http(503))
        await h.openArtistThenSongs(links: [SortHarness.albumsLink])
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(await h.yearsRead())
        #expect(h.store.releaseYears["VLOLAK5uy_songs"]?.isComplete == false)

        await h.backend.setDiscographyError(browseId: "MPADartist", params: "P1", nil)
        await h.backend.setDiscography(browseId: "MPADartist", params: "P1", [SortHarness.alpha])
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(await h.until { await h.backend.discographyCalls.count == 2 })
        #expect(await h.yearsRead())
        #expect(h.store.releaseYears["VLOLAK5uy_songs"]?.isComplete == true)
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        // Oldest first now: d Beta 2010, a Zeta 2015, b alpha 2020, then c with no album.
        #expect(h.shownIds("VLOLAK5uy_songs") == ["d", "a", "b", "c"])

        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        await h.letLateWorkLand()
        #expect(await h.backend.discographyCalls.count == 2)
    }

    @Test("two discography pages that both sign out end the session once, after the years are written")
    func releaseDateSignsOutOnce() async {
        let h = SortHarness()
        let singles = MusicDiscographyLink(browseId: "MPADartist", params: "P2")
        await h.backend.setDiscographyError(browseId: "MPADartist", params: "P1", MusicError.signedOut)
        await h.backend.setDiscographyError(browseId: "MPADartist", params: "P2", MusicError.signedOut)
        await h.openArtistThenSongs(links: [SortHarness.albumsLink, singles])
        var expired = 0
        h.store.onSessionExpired = { expired += 1 }
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(await h.yearsRead())
        await h.letLateWorkLand()
        #expect(expired == 1)
    }

    @Test("with no artist page behind the songs list, Release date sorts by nothing and asks for nothing")
    func releaseDateWithoutAnArtistPage() async {
        let h = SortHarness()
        await h.openSongsList()
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(await h.yearsRead())
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["a", "b", "c", "d"])
        #expect(!h.store.isOrderPending("VLOLAK5uy_songs"))
        await h.letLateWorkLand()
        #expect(await h.backend.discographyCalls.isEmpty)
    }

    @Test("an artist page with no discography links sorts by the albums on its shelves alone")
    func releaseDateWithoutLinks() async {
        let h = SortHarness()
        await h.openArtistThenSongs(links: [])
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(await h.yearsRead())
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["a", "d", "b", "c"])
        #expect(await h.backend.discographyCalls.isEmpty)
    }

    @Test("an artist page the songs list does not belong to gives no years")
    func releaseDateIgnoresOtherArtistPages() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page(
            "UCother",
            shelves: [MusicSamples.shelf("Albums", "MPREx")],
            allSongsBrowseId: "VLOLAK5uy_other",
            discographyLinks: [SortHarness.albumsLink]
        ))
        h.store.open(MusicSamples.collection("UCother", kind: .artist))
        #expect(await h.until { h.loadedPage("UCother") != nil })
        await h.openSongsList()

        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(await h.yearsRead())
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["a", "b", "c", "d"])
        await h.letLateWorkLand()
        #expect(await h.backend.discographyCalls.isEmpty)
    }

    @Test("Release date is no option of a plain playlist: picking it changes nothing and reads nothing")
    func plainPlaylistRefusesReleaseDate() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        h.store.pickSort(.releaseDate, for: "VLPL1")
        #expect(h.store.sorts["VLPL1"] == nil)
        #expect(h.store.sort(for: "VLPL1") == .playlistOrder)
        #expect(h.store.releaseYears.isEmpty)
        #expect(h.store.loadingReleaseYears.isEmpty)
        #expect(h.store.loadingAllTracks.isEmpty)
        await h.letLateWorkLand()
        #expect(await h.backend.discographyCalls.isEmpty)
        #expect(await h.backend.moreTracksCalls.isEmpty)

        // The id of an artist's songs list opened as a plain playlist refuses it as well.
        await h.openSongsList(isArtistSongs: false)
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(h.store.sorts["VLOLAK5uy_songs"] == nil)
        #expect(h.store.loadingReleaseYears.isEmpty)
        await h.letLateWorkLand()
        #expect(await h.backend.discographyCalls.isEmpty)
    }

    @Test("closing the songs list while the years load drops the late answer for good")
    func releaseDateBackDropsLateAnswer() async {
        let h = SortHarness()
        await h.backend.setDiscography(browseId: "MPADartist", params: "P1", [SortHarness.alpha])
        let gate = MusicTestGate()
        await h.backend.setDiscographyGate(browseId: "MPADartist", params: "P1", gate)
        await h.openArtistThenSongs(links: [SortHarness.albumsLink])
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(h.store.loadingReleaseYears == ["VLOLAK5uy_songs"])

        h.store.back()
        #expect(h.store.loadingReleaseYears.isEmpty)
        #expect(h.store.releaseYears["VLOLAK5uy_songs"] == nil)
        #expect(!h.store.isOrderPending("VLOLAK5uy_songs"))

        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.releaseYears["VLOLAK5uy_songs"] == nil)
        #expect(h.store.loadingReleaseYears.isEmpty)
        #expect(h.store.pageState("VLOLAK5uy_songs") == .idle)
    }

    @Test("reset forgets the years and drops an answer still on its way")
    func releaseDateResetClearsYears() async {
        let h = SortHarness()
        await h.backend.setDiscography(browseId: "MPADartist", params: "P1", [SortHarness.alpha])
        await h.openArtistThenSongs(links: [SortHarness.albumsLink])
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(await h.yearsRead())
        #expect(!h.store.releaseYears.isEmpty)
        h.store.reset()
        #expect(h.store.releaseYears.isEmpty)
        #expect(h.store.loadingReleaseYears.isEmpty)

        // And one cut off while it was loading.
        let gate = MusicTestGate()
        await h.backend.setDiscographyGate(browseId: "MPADartist", params: "P1", gate)
        await h.openArtistThenSongs(links: [SortHarness.albumsLink])
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(h.store.loadingReleaseYears == ["VLOLAK5uy_songs"])
        h.store.reset()
        #expect(h.store.loadingReleaseYears.isEmpty)
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.releaseYears.isEmpty)
        #expect(h.store.loadingReleaseYears.isEmpty)
    }

    @Test("opening the songs list again reads the years again, and a pick made before is still Release date")
    func releaseDateReopenReadsAgain() async {
        let h = SortHarness()
        await h.backend.setDiscography(browseId: "MPADartist", params: "P1", [SortHarness.alpha])
        await h.openArtistThenSongs(links: [SortHarness.albumsLink])
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        #expect(await h.yearsRead())
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))

        h.store.back()
        h.store.open(MusicSamples.collection("VLOLAK5uy_songs", isArtistSongs: true))
        #expect(await h.yearsRead())
        #expect(await h.settled("VLOLAK5uy_songs", count: 4))
        #expect(h.shownIds("VLOLAK5uy_songs") == ["b", "a", "d", "c"])
        #expect(await h.backend.discographyCalls.count == 2)
    }

    @Test("picking another sort while the years load shows that sort at once, with nothing pending")
    func releaseDateAbandonedWhileLoading() async {
        let h = SortHarness()
        let gate = MusicTestGate()
        await h.backend.setDiscographyGate(browseId: "MPADartist", params: "P1", gate)
        await h.openArtistThenSongs(links: [SortHarness.albumsLink])
        h.store.pickSort(.releaseDate, for: "VLOLAK5uy_songs")
        h.store.pickSort(.playlistOrder, for: "VLOLAK5uy_songs")
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == .playlistOrder)
        #expect(!h.store.isOrderPending("VLOLAK5uy_songs"))
        await gate.open()
        #expect(await h.yearsRead())
        #expect(h.store.sort(for: "VLOLAK5uy_songs") == .playlistOrder)
        #expect(!h.store.isOrderPending("VLOLAK5uy_songs"))
    }

    @Test("the discography links survive loading more songs, taking a song out and sorting")
    func discographyLinksSurviveRebuilds() async {
        let h = SortHarness()
        await h.backend.setPage(MusicSamples.page(
            "VLPL1",
            tracks: [MusicSamples.track("a", title: "B", setVideoId: "s1")],
            continuation: "t1",
            discographyLinks: [SortHarness.albumsLink]
        ))
        await h.backend.setMoreTracks(
            browseId: "VLPL1", continuation: "t1",
            tracks: [MusicSamples.track("b", title: "A", setVideoId: "s2"), MusicSamples.track("c", title: "C", setVideoId: "s3")],
            next: nil
        )
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.loadedPage("VLPL1") != nil })
        h.store.loadMoreTracks("VLPL1")
        #expect(await h.until { h.loadedPage("VLPL1")?.tracks.count == 3 })
        #expect(h.loadedPage("VLPL1")?.discographyLinks == [SortHarness.albumsLink])
        #expect(h.store.removeTrack(setVideoId: "s3", from: "VLPL1"))
        #expect(h.loadedPage("VLPL1")?.discographyLinks == [SortHarness.albumsLink])
        h.store.pickSort(.title, for: "VLPL1")
        #expect(h.store.displayedPage("VLPL1")?.discographyLinks == [SortHarness.albumsLink])
    }
}
