// DeciTests/Music/MusicBrowseStoreSortTests.swift
// Sorting a playlist page: the choice is remembered per playlist for the session, a sort first loads every
// remaining page of songs (up to a cap), and the page the list shows and Play queues is the sorted one.

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

    /// A playlist of three songs over three pages: "a" first, then "b" and "c", then "d".
    func openLongPlaylist(_ browseId: String = "VLPL1") async {
        await backend.setPage(MusicSamples.page(
            browseId,
            tracks: [MusicSamples.track("a", title: "Delta", seconds: 100)],
            continuation: "t1"
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

    func loadedPage(_ browseId: String) -> MusicBrowsePage? {
        if case .loaded(let page)? = store.pages[browseId] { page } else { nil }
    }

    func shownIds(_ browseId: String) -> [String]? {
        store.displayedPage(browseId)?.tracks.map(\.videoId)
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

    @Test("a playlist starts in its default order and shows the page as loaded")
    func startsDefault() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        #expect(h.store.sort(for: "VLPL1") == .default)
        #expect(h.store.displayedPage("VLPL1") == h.loadedPage("VLPL1"))
        #expect(h.store.loadingAllTracks.isEmpty)
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

    @Test("Default order puts the page order back and keeps the songs that were loaded")
    func backToDefault() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty && h.shownIds("VLPL1")?.count == 4 })

        h.store.pickSort(.defaultOrder, for: "VLPL1")
        #expect(h.store.sort(for: "VLPL1") == .default)
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

    @Test("picking Default order while the songs load stops after the page in flight and keeps the page order")
    func defaultWhileLoading() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)

        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { await h.backend.moreTracksCalls.count == 1 })
        h.store.pickSort(.defaultOrder, for: "VLPL1")
        await gate.open()

        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1"])
        #expect(h.store.sort(for: "VLPL1") == .default)
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
        #expect(h.store.sort(for: "VLPL2") == .default)
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

    @Test("a failed page ends the sort: the songs so far stay in page order and the sort goes back to default")
    func failure() async {
        let h = SortHarness()
        await h.openLongPlaylist()
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t2", MusicError.http(500))

        h.store.pickSort(.title, for: "VLPL1")
        #expect(await h.until { h.store.loadingAllTracks.isEmpty })
        #expect(h.store.sort(for: "VLPL1") == .default)
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
        #expect(h.store.sort(for: "MPREb_x") == .default)
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
        #expect(h.store.sort(for: "VLPL1") == .default)
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

    @Test("with no sort picked there is no limit note, and none while the songs are still loading")
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
        #expect(MusicPageHeader.sortLimitText(MusicBrowseStore.sortTrackCap) == "First 2000 songs")
        #expect(MusicPageHeader.sortLimitText(1) == "First song")
    }

    @Test("going back to the default order drops the limit note")
    func defaultOrderDropsTheLimit() async {
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

        h.store.pickSort(.defaultOrder, for: "VLBIG")
        #expect(h.store.sortedSongLimit("VLBIG") == nil)
    }
}
