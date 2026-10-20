// DeciTests/Music/MusicBrowseStoreTests.swift
// Home, Library and page state for the Music tab: load states, paging, repeats, a response that
// arrives after a newer load or a reset, the Liked music filter and the session-expired callback.

import Foundation
import Testing
@testable import Deci

@MainActor
private final class ExpiryProbe {
    var count = 0
}

@MainActor
private struct StoreHarness {
    let backend = FakeMusicBackend()
    let store: MusicBrowseStore
    let probe = ExpiryProbe()

    init() {
        store = MusicBrowseStore(backend: backend)
        let probe = self.probe
        store.onSessionExpired = { probe.count += 1 }
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
}

@MainActor
@Suite("MusicBrowseStore")
struct MusicBrowseStoreTests {

    private func ids(_ collections: [MusicCollection]) -> [String] { collections.map(\.browseId) }

    private func loadedShelves(_ store: MusicBrowseStore) -> [MusicShelf] {
        if case .loaded(let shelves) = store.home { shelves } else { [] }
    }

    private func loadedCollections(_ store: MusicBrowseStore, _ section: MusicLibrarySection) -> [MusicCollection] {
        if case .loaded(let items) = store.libraryState(section) { items } else { [] }
    }

    private func loadedPage(_ store: MusicBrowseStore, _ browseId: String) -> MusicBrowsePage? {
        if case .loaded(let page) = store.pageState(browseId) { page } else { nil }
    }

    // MARK: - Home

    @Test("Everything starts idle, on Home, with Playlists selected")
    func startsIdle() {
        let h = StoreHarness()
        #expect(h.store.home == .idle)
        #expect(h.store.libraryState(.playlists) == .idle)
        #expect(h.store.pageState("VLx") == .idle)
        #expect(h.store.path.isEmpty)
        #expect(h.store.tab == .home)
        #expect(h.store.librarySection == .playlists)
        #expect(h.store.canLoadMoreHome == false)
    }

    @Test("loadHomeIfNeeded goes loading, then loaded with the shelves and the more-flag")
    func homeLoads() async {
        let h = StoreHarness()
        let shelves = [MusicSamples.shelf("Quick picks", "a", "b")]
        await h.backend.setHome(shelves: shelves, continuation: "c1")
        let gate = MusicTestGate()
        await h.backend.setHomeGate(gate)

        h.store.loadHomeIfNeeded()
        #expect(h.store.home == .loading)
        await gate.open()

        #expect(await h.until { h.store.home == .loaded(shelves) })
        #expect(h.store.canLoadMoreHome)
        #expect(await h.backend.homeCallCount == 1)
    }

    @Test("loadHomeIfNeeded does nothing while loading or once loaded")
    func homeLoadsOnce() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")])
        h.store.loadHomeIfNeeded()
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })
        h.store.loadHomeIfNeeded()
        await h.letLateWorkLand()
        #expect(await h.backend.homeCallCount == 1)
    }

    @Test("A failed home shows a message and loadHomeIfNeeded tries again")
    func homeFailureThenRetry() async {
        let h = StoreHarness()
        await h.backend.setHomeError(MusicError.http(500))
        h.store.loadHomeIfNeeded()
        let message = MusicService.message(for: MusicError.http(500))
        #expect(await h.until { h.store.home == .failed(message) })
        #expect(h.probe.count == 0)

        await h.backend.setHomeError(nil)
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")])
        h.store.loadHomeIfNeeded()
        #expect(h.store.home == .loading)
        #expect(await h.until { h.store.home == .loaded([MusicSamples.shelf("A", "a")]) })
    }

    @Test("A home with no shelves is loaded and empty, not an error")
    func homeEmpty() async {
        let h = StoreHarness()
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home == .loaded([]) })
        #expect(h.store.canLoadMoreHome == false)
    }

    @Test("loadMoreHome appends new shelves, drops repeats and follows the next token to the end")
    func homePaging() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a1")], continuation: "t1")
        await h.backend.setMoreHome(continuation: "t1", shelves: [MusicSamples.shelf("A", "a1"), MusicSamples.shelf("B", "b1")], next: "t2")
        await h.backend.setMoreHome(continuation: "t2", shelves: [MusicSamples.shelf("C", "c1")], next: nil)
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })

        h.store.loadMoreHome()
        #expect(h.store.isLoadingMoreHome)
        #expect(await h.until { loadedShelves(h.store).count == 2 })
        #expect(loadedShelves(h.store).map(\.title) == ["A", "B"])
        #expect(h.store.isLoadingMoreHome == false)
        #expect(h.store.canLoadMoreHome)

        h.store.loadMoreHome()
        #expect(await h.until { loadedShelves(h.store).count == 3 })
        #expect(loadedShelves(h.store).map(\.title) == ["A", "B", "C"])
        #expect(h.store.canLoadMoreHome == false)

        h.store.loadMoreHome()
        await h.letLateWorkLand()
        #expect(await h.backend.moreHomeCalls == ["t1", "t2"])
    }

    @Test("loadMoreHome does nothing before Home has loaded or without a token")
    func homeMoreGuards() async {
        let h = StoreHarness()
        h.store.loadMoreHome()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: nil)
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })
        h.store.loadMoreHome()
        await h.letLateWorkLand()
        #expect(await h.backend.moreHomeCalls.isEmpty)
    }

    @Test("loadMoreHome while a page is already coming asks only once")
    func homeMoreInFlight() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: "t1")
        await h.backend.setMoreHome(continuation: "t1", shelves: [MusicSamples.shelf("B", "b")])
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })

        let gate = MusicTestGate()
        await h.backend.setMoreHomeGate(continuation: "t1", gate)
        h.store.loadMoreHome()
        h.store.loadMoreHome()
        h.store.loadMoreHome()
        await gate.open()
        #expect(await h.until { loadedShelves(h.store).count == 2 })
        #expect(await h.backend.moreHomeCalls == ["t1"])
    }

    @Test("Home drops the hidden shelves in any case, on the first page and on more pages")
    func homeHidesShelves() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [
            MusicSamples.shelf("Quick picks", "q"), MusicSamples.shelf("From the community", "fc"),
            MusicSamples.shelf("Mixed for you", "m"), MusicSamples.shelf(" LONG LISTENS ", "l"),
        ], continuation: "t1")
        await h.backend.setMoreHome(continuation: "t1", shelves: [
            MusicSamples.shelf("Live performances", "lp"), MusicSamples.shelf("Mixes for you", "mx"),
            MusicSamples.shelf("Listen again", "a"),
        ])
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })
        #expect(loadedShelves(h.store).map(\.title) == ["Quick picks"])
        h.store.loadMoreHome()
        #expect(await h.until { loadedShelves(h.store).count == 2 })
        #expect(loadedShelves(h.store).map(\.title) == ["Quick picks", "Listen again"])
    }

    @Test("refreshHome keeps the shelves up while it loads, then swaps in the new ones")
    func homeRefreshInPlace() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: "t1")
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })

        let gate = MusicTestGate()
        await h.backend.setHomeGate(gate)
        await h.backend.setHome(shelves: [MusicSamples.shelf("B", "b")], continuation: "t2")
        h.store.refreshHome()
        #expect(h.store.isRefreshingHome)
        #expect(loadedShelves(h.store).map(\.title) == ["A"])
        #expect(h.store.canLoadMoreHome == false)
        h.store.refreshHome()
        await gate.open()
        #expect(await h.until { h.store.isRefreshingHome == false })
        #expect(loadedShelves(h.store).map(\.title) == ["B"])
        #expect(h.store.canLoadMoreHome)
        #expect(await h.backend.homeCallCount == 2)
    }

    @Test("A failed refresh keeps the old shelves and their next token")
    func homeRefreshFailure() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: "t1")
        await h.backend.setMoreHome(continuation: "t1", shelves: [MusicSamples.shelf("B", "b")])
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })

        await h.backend.setHomeError(MusicError.http(503))
        h.store.refreshHome()
        #expect(await h.until { h.store.isRefreshingHome == false })
        #expect(loadedShelves(h.store).map(\.title) == ["A"])
        #expect(h.store.canLoadMoreHome)
        h.store.loadMoreHome()
        #expect(await h.until { loadedShelves(h.store).count == 2 })
    }

    @Test("refreshHome before Home has loaded loads it from the top")
    func homeRefreshBeforeLoad() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")])
        h.store.refreshHome()
        #expect(h.store.home == .loading)
        #expect(h.store.isRefreshingHome == false)
        #expect(await h.until { h.store.home == .loaded([MusicSamples.shelf("A", "a")]) })
    }

    @Test("A token the server hands back unchanged ends paging instead of looping")
    func homeRepeatedToken() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: "t1")
        await h.backend.setMoreHome(continuation: "t1", shelves: [MusicSamples.shelf("B", "b")], next: "t1")
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })
        h.store.loadMoreHome()
        #expect(await h.until { loadedShelves(h.store).count == 2 })
        #expect(h.store.canLoadMoreHome == false)
    }

    @Test("A failed extra page keeps the shelves, clears the loading flag and can be retried")
    func homeMoreFailure() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: "t1")
        await h.backend.setMoreHomeError(continuation: "t1", MusicError.http(503))
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })

        h.store.loadMoreHome()
        #expect(await h.until { h.store.isLoadingMoreHome == false })
        #expect(loadedShelves(h.store).map(\.title) == ["A"])
        #expect(h.store.canLoadMoreHome)

        await h.backend.setMoreHomeError(continuation: "t1", nil)
        await h.backend.setMoreHome(continuation: "t1", shelves: [MusicSamples.shelf("B", "b")])
        h.store.loadMoreHome()
        #expect(await h.until { loadedShelves(h.store).count == 2 })
    }

    @Test("reloadHome starts again from the top and forgets the old token")
    func homeReload() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: "t1")
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })

        await h.backend.setHome(shelves: [MusicSamples.shelf("Z", "z")], continuation: nil)
        h.store.reloadHome()
        #expect(h.store.home == .loading)
        #expect(h.store.canLoadMoreHome == false)
        #expect(await h.until { loadedShelves(h.store).map(\.title) == ["Z"] })
        #expect(h.store.canLoadMoreHome == false)
    }

    @Test("A slow home answer that arrives after a reload is dropped")
    func homeStaleResponse() async {
        let h = StoreHarness()
        let slow = MusicTestGate()
        await h.backend.setHome(shelves: [MusicSamples.shelf("Old", "o")])
        await h.backend.setHomeGate(slow)
        h.store.loadHomeIfNeeded()
        #expect(await h.until { await h.backend.homeCallCount == 1 })

        await h.backend.setHomeGate(nil)
        await h.backend.setHome(shelves: [MusicSamples.shelf("New", "n")])
        h.store.reloadHome()
        #expect(await h.until { loadedShelves(h.store).map(\.title) == ["New"] })

        await slow.open()
        await h.letLateWorkLand()
        #expect(loadedShelves(h.store).map(\.title) == ["New"])
    }

    @Test("A slow home failure that arrives after a reload does not replace the newer shelves")
    func homeStaleFailure() async {
        let h = StoreHarness()
        let slow = MusicTestGate()
        await h.backend.setHomeError(MusicError.signedOut)
        await h.backend.setHomeGate(slow)
        h.store.loadHomeIfNeeded()
        #expect(await h.until { await h.backend.homeCallCount == 1 })

        await h.backend.setHomeError(nil)
        await h.backend.setHomeGate(nil)
        await h.backend.setHome(shelves: [MusicSamples.shelf("New", "n")])
        h.store.reloadHome()
        #expect(await h.until { loadedShelves(h.store).count == 1 })

        await slow.open()
        await h.letLateWorkLand()
        #expect(loadedShelves(h.store).map(\.title) == ["New"])
        #expect(h.probe.count == 0)
    }

    // MARK: - Library

    @Test("A library list loads on its own and leaves the other sections idle")
    func libraryLoads() async {
        let h = StoreHarness()
        await h.backend.setLibrary(.albums, items: MusicSamples.collections("MPREb1", "MPREb2"), continuation: "t1")
        h.store.loadLibraryIfNeeded(.albums)
        #expect(h.store.libraryState(.albums) == .loading)
        #expect(await h.until { h.store.libraryState(.albums) != .loading })
        #expect(ids(loadedCollections(h.store, .albums)) == ["MPREb1", "MPREb2"])
        #expect(h.store.libraryHasMore == [.albums])
        #expect(h.store.libraryState(.playlists) == .idle)
        #expect(h.store.libraryState(.artists) == .idle)
        #expect(await h.backend.libraryCalls == [.albums])
    }

    @Test("Liked music is left out of the playlists list, on the first page and on later ones")
    func libraryFiltersLikedMusic() async {
        let h = StoreHarness()
        await h.backend.setLibrary(.playlists, items: MusicSamples.collections("VLLM", "VLPL1"), continuation: "t1")
        await h.backend.setMoreLibrary(.playlists, continuation: "t1", items: MusicSamples.collections("VLPL2", "VLLM"))
        h.store.loadLibraryIfNeeded(.playlists)
        #expect(await h.until { h.store.libraryState(.playlists) != .loading })
        #expect(ids(loadedCollections(h.store, .playlists)) == ["VLPL1"])

        h.store.loadMoreLibrary(.playlists)
        #expect(await h.until { loadedCollections(h.store, .playlists).count == 2 })
        #expect(ids(loadedCollections(h.store, .playlists)) == ["VLPL1", "VLPL2"])
        #expect(MusicBrowseStore.likedMusic.browseId == "VLLM")
    }

    @Test("loadLibraryIfNeeded does nothing while loading or once loaded, and retries after a failure")
    func libraryLoadsOnceAndRetries() async {
        let h = StoreHarness()
        await h.backend.setLibraryError(.artists, MusicError.http(500))
        h.store.loadLibraryIfNeeded(.artists)
        h.store.loadLibraryIfNeeded(.artists)
        let message = MusicService.message(for: MusicError.http(500))
        #expect(await h.until { h.store.libraryState(.artists) == .failed(message) })
        #expect(await h.backend.libraryCalls.count == 1)

        await h.backend.setLibraryError(.artists, nil)
        await h.backend.setLibrary(.artists, items: MusicSamples.collections("UC1"))
        h.store.loadLibraryIfNeeded(.artists)
        #expect(await h.until { loadedCollections(h.store, .artists).count == 1 })
        h.store.loadLibraryIfNeeded(.artists)
        await h.letLateWorkLand()
        #expect(await h.backend.libraryCalls.count == 2)
    }

    @Test("loadMoreLibrary appends without repeats and stops at the last page")
    func libraryPaging() async {
        let h = StoreHarness()
        await h.backend.setLibrary(.albums, items: MusicSamples.collections("A", "B"), continuation: "t1")
        await h.backend.setMoreLibrary(.albums, continuation: "t1", items: MusicSamples.collections("B", "C"), next: "t2")
        await h.backend.setMoreLibrary(.albums, continuation: "t2", items: MusicSamples.collections("D"), next: nil)
        h.store.loadLibraryIfNeeded(.albums)
        #expect(await h.until { h.store.libraryState(.albums) != .loading })

        h.store.loadMoreLibrary(.albums)
        #expect(h.store.loadingMoreLibrary == [.albums])
        #expect(await h.until { loadedCollections(h.store, .albums).count == 3 })
        #expect(ids(loadedCollections(h.store, .albums)) == ["A", "B", "C"])
        #expect(h.store.libraryHasMore == [.albums])

        h.store.loadMoreLibrary(.albums)
        #expect(await h.until { loadedCollections(h.store, .albums).count == 4 })
        #expect(h.store.libraryHasMore.isEmpty)
        #expect(h.store.loadingMoreLibrary.isEmpty)

        h.store.loadMoreLibrary(.albums)
        await h.letLateWorkLand()
        #expect(await h.backend.moreLibraryCalls.map(\.continuation) == ["t1", "t2"])
    }

    @Test("loadMoreLibrary guards: not loaded, no token, already loading more")
    func libraryMoreGuards() async {
        let h = StoreHarness()
        h.store.loadMoreLibrary(.albums)
        await h.backend.setLibrary(.albums, items: MusicSamples.collections("A"), continuation: "t1")
        await h.backend.setMoreLibrary(.albums, continuation: "t1", items: MusicSamples.collections("B"))
        let gate = MusicTestGate()
        await h.backend.setMoreLibraryGate(.albums, continuation: "t1", gate)
        h.store.loadLibraryIfNeeded(.albums)
        #expect(await h.until { h.store.libraryState(.albums) != .loading })

        h.store.loadMoreLibrary(.albums)
        h.store.loadMoreLibrary(.albums)
        await gate.open()
        #expect(await h.until { loadedCollections(h.store, .albums).count == 2 })
        #expect(await h.backend.moreLibraryCalls.count == 1)

        h.store.loadMoreLibrary(.albums)
        await h.letLateWorkLand()
        #expect(await h.backend.moreLibraryCalls.count == 1)
    }

    @Test("A repeated library token and a failed extra page both leave the list as it is")
    func libraryMoreRepeatAndFailure() async {
        let h = StoreHarness()
        await h.backend.setLibrary(.albums, items: MusicSamples.collections("A"), continuation: "t1")
        await h.backend.setMoreLibrary(.albums, continuation: "t1", items: MusicSamples.collections("B"), next: "t1")
        h.store.loadLibraryIfNeeded(.albums)
        #expect(await h.until { h.store.libraryState(.albums) != .loading })
        h.store.loadMoreLibrary(.albums)
        #expect(await h.until { loadedCollections(h.store, .albums).count == 2 })
        #expect(h.store.libraryHasMore.isEmpty)

        await h.backend.setLibrary(.playlists, items: MusicSamples.collections("VLPL1"), continuation: "p1")
        await h.backend.setMoreLibraryError(.playlists, continuation: "p1", MusicError.http(500))
        h.store.loadLibraryIfNeeded(.playlists)
        #expect(await h.until { h.store.libraryState(.playlists) != .loading })
        h.store.loadMoreLibrary(.playlists)
        #expect(await h.until { h.store.loadingMoreLibrary.isEmpty })
        #expect(ids(loadedCollections(h.store, .playlists)) == ["VLPL1"])
        #expect(h.store.libraryHasMore == [.playlists])
    }

    @Test("reloadLibrary starts the section over")
    func libraryReload() async {
        let h = StoreHarness()
        await h.backend.setLibrary(.albums, items: MusicSamples.collections("A"), continuation: "t1")
        h.store.loadLibraryIfNeeded(.albums)
        #expect(await h.until { h.store.libraryState(.albums) != .loading })

        await h.backend.setLibrary(.albums, items: MusicSamples.collections("Z"))
        h.store.reloadLibrary(.albums)
        #expect(h.store.libraryState(.albums) == .loading)
        #expect(h.store.libraryHasMore.isEmpty)
        #expect(await h.until { ids(loadedCollections(h.store, .albums)) == ["Z"] })
    }

    @Test("A slow library answer that arrives after a reload is dropped")
    func libraryStaleResponse() async {
        let h = StoreHarness()
        let slow = MusicTestGate()
        await h.backend.setLibrary(.albums, items: MusicSamples.collections("Old"))
        await h.backend.setLibraryGate(.albums, slow)
        h.store.loadLibraryIfNeeded(.albums)
        #expect(await h.until { await h.backend.libraryCalls.count == 1 })

        await h.backend.setLibraryGate(.albums, nil)
        await h.backend.setLibrary(.albums, items: MusicSamples.collections("New"))
        h.store.reloadLibrary(.albums)
        #expect(await h.until { ids(loadedCollections(h.store, .albums)) == ["New"] })

        await slow.open()
        await h.letLateWorkLand()
        #expect(ids(loadedCollections(h.store, .albums)) == ["New"])
    }

    // MARK: - Pages

    @Test("open pushes the page, loads it, and a double tap pushes it once")
    func openPushesAndLoads() async {
        let h = StoreHarness()
        let album = MusicSamples.collection("MPREb1", kind: .album)
        await h.backend.setPage(MusicSamples.page("MPREb1", tracks: MusicSamples.tracks("a", "b"), title: "Album"))
        let gate = MusicTestGate()
        await h.backend.setPageGate("MPREb1", gate)

        h.store.open(album)
        h.store.open(album)
        #expect(h.store.path == [album])
        #expect(h.store.pageState("MPREb1") == .loading)
        await gate.open()

        #expect(await h.until { h.store.pageState("MPREb1") != .loading })
        #expect(loadedPage(h.store, "MPREb1")?.tracks.map(\.videoId) == ["a", "b"])
        #expect(await h.backend.pageCalls == ["MPREb1"])
    }

    @Test("Pages stack, back pops one, popToRoot clears, and a closed page is fetched fresh when opened again")
    func pageNavigation() async {
        let h = StoreHarness()
        let first = MusicSamples.collection("VLPL1")
        let second = MusicSamples.collection("MPREb2", kind: .album)
        h.store.open(first)
        h.store.open(second)
        #expect(h.store.path == [first, second])
        #expect(await h.until { h.store.pageState("MPREb2") != .loading && h.store.pageState("VLPL1") != .loading })

        h.store.back()
        #expect(h.store.path == [first])
        #expect(h.store.pageState("MPREb2") == .idle)
        #expect(loadedPage(h.store, "VLPL1") != nil)
        h.store.open(second)
        #expect(h.store.path == [first, second])
        #expect(await h.until { h.store.pageState("MPREb2") != .loading })
        h.store.popToRoot()
        #expect(h.store.path.isEmpty)
        #expect(h.store.pages.isEmpty)
        h.store.back()
        #expect(h.store.path.isEmpty)

        await h.letLateWorkLand()
        #expect(await h.backend.pageCalls.sorted() == ["MPREb2", "MPREb2", "VLPL1"])
    }

    @Test("A failed page shows a message, and opening it again reloads it without pushing it twice")
    func pageFailureThenReopen() async {
        let h = StoreHarness()
        let playlist = MusicSamples.collection("VLPL1")
        await h.backend.setPageError("VLPL1", MusicError.parse("bad"))
        h.store.open(playlist)
        let message = MusicService.message(for: MusicError.parse("bad"))
        #expect(await h.until { h.store.pageState("VLPL1") == .failed(message) })

        await h.backend.setPageError("VLPL1", nil)
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a")))
        h.store.open(playlist)
        #expect(h.store.path == [playlist])
        #expect(await h.until { loadedPage(h.store, "VLPL1")?.tracks.count == 1 })
    }

    @Test("reloadPage shows loading again and replaces the page")
    func pageReload() async {
        let h = StoreHarness()
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a"), title: "Old"))
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { loadedPage(h.store, "VLPL1") != nil })

        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a", "b"), title: "New"))
        h.store.reloadPage("VLPL1")
        #expect(h.store.pageState("VLPL1") == .loading)
        #expect(await h.until { loadedPage(h.store, "VLPL1")?.title == "New" })
    }

    @Test("A slow page answer that arrives after a reload is dropped")
    func pageStaleResponse() async {
        let h = StoreHarness()
        let slow = MusicTestGate()
        await h.backend.setPage(MusicSamples.page("VLPL1", title: "Old"))
        await h.backend.setPageGate("VLPL1", slow)
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { await h.backend.pageCalls.count == 1 })

        await h.backend.setPageGate("VLPL1", nil)
        await h.backend.setPage(MusicSamples.page("VLPL1", title: "New"))
        h.store.reloadPage("VLPL1")
        #expect(await h.until { loadedPage(h.store, "VLPL1")?.title == "New" })

        await slow.open()
        await h.letLateWorkLand()
        #expect(loadedPage(h.store, "VLPL1")?.title == "New")
    }

    @Test("loadMoreTracks appends new tracks, drops repeats, keeps the header and moves the token")
    func tracksPaging() async {
        let h = StoreHarness()
        await h.backend.setPage(MusicBrowsePage(
            browseId: "VLPL1", title: "Long", subtitle: "Playlist • 3 songs", thumbnailURL: nil,
            tracks: MusicSamples.tracks("a", "b"), continuation: "t1", shelves: [MusicSamples.shelf("More", "x")]
        ))
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: MusicSamples.tracks("b", "c"), next: "t2")
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t2", tracks: MusicSamples.tracks("d"), next: nil)
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { loadedPage(h.store, "VLPL1") != nil })

        h.store.loadMoreTracks("VLPL1")
        #expect(h.store.loadingMoreTracks == ["VLPL1"])
        #expect(await h.until { loadedPage(h.store, "VLPL1")?.tracks.count == 3 })
        var page = loadedPage(h.store, "VLPL1")
        #expect(page?.tracks.map(\.videoId) == ["a", "b", "c"])
        #expect(page?.continuation == "t2")
        #expect(page?.title == "Long")
        #expect(page?.subtitle == "Playlist • 3 songs")
        #expect(page?.shelves.map(\.title) == ["More"])
        #expect(h.store.loadingMoreTracks.isEmpty)

        h.store.loadMoreTracks("VLPL1")
        #expect(await h.until { loadedPage(h.store, "VLPL1")?.tracks.count == 4 })
        page = loadedPage(h.store, "VLPL1")
        #expect(page?.continuation == nil)

        h.store.loadMoreTracks("VLPL1")
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
    }

    @Test("loadMoreTracks guards: not loaded, no token, already loading more")
    func tracksMoreGuards() async {
        let h = StoreHarness()
        h.store.loadMoreTracks("VLPL1")
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a"), continuation: "t1"))
        await h.backend.setPage(MusicSamples.page("VLPL2", tracks: MusicSamples.tracks("z"), continuation: nil))
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: MusicSamples.tracks("b"))
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        h.store.open(MusicSamples.collection("VLPL1"))
        h.store.open(MusicSamples.collection("VLPL2"))
        #expect(await h.until { loadedPage(h.store, "VLPL1") != nil && loadedPage(h.store, "VLPL2") != nil })

        h.store.loadMoreTracks("VLPL2")
        h.store.loadMoreTracks("VLPL1")
        h.store.loadMoreTracks("VLPL1")
        await gate.open()
        #expect(await h.until { loadedPage(h.store, "VLPL1")?.tracks.count == 2 })
        await h.letLateWorkLand()
        #expect(await h.backend.moreTracksCalls.count == 1)
    }

    @Test("A repeated track token ends paging, and a failed extra page keeps the tracks and can be retried")
    func tracksRepeatAndFailure() async {
        let h = StoreHarness()
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a"), continuation: "t1"))
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: MusicSamples.tracks("b"), next: "t1")
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { loadedPage(h.store, "VLPL1") != nil })
        h.store.loadMoreTracks("VLPL1")
        #expect(await h.until { loadedPage(h.store, "VLPL1")?.tracks.count == 2 })
        #expect(loadedPage(h.store, "VLPL1")?.continuation == nil)

        await h.backend.setPage(MusicSamples.page("VLPL2", tracks: MusicSamples.tracks("x"), continuation: "u1"))
        await h.backend.setMoreTracksError(browseId: "VLPL2", continuation: "u1", MusicError.http(500))
        h.store.open(MusicSamples.collection("VLPL2"))
        #expect(await h.until { loadedPage(h.store, "VLPL2") != nil })
        h.store.loadMoreTracks("VLPL2")
        #expect(await h.until { h.store.loadingMoreTracks.isEmpty })
        #expect(loadedPage(h.store, "VLPL2")?.tracks.map(\.videoId) == ["x"])
        #expect(loadedPage(h.store, "VLPL2")?.continuation == "u1")

        await h.backend.setMoreTracksError(browseId: "VLPL2", continuation: "u1", nil)
        await h.backend.setMoreTracks(browseId: "VLPL2", continuation: "u1", tracks: MusicSamples.tracks("y"))
        h.store.loadMoreTracks("VLPL2")
        #expect(await h.until { loadedPage(h.store, "VLPL2")?.tracks.count == 2 })
    }

    @Test("A page extra answer that arrives after a reload is dropped")
    func tracksStaleResponse() async {
        let h = StoreHarness()
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a"), continuation: "t1"))
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: MusicSamples.tracks("late"))
        let slow = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", slow)
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { loadedPage(h.store, "VLPL1") != nil })
        h.store.loadMoreTracks("VLPL1")
        #expect(await h.until { await h.backend.moreTracksCalls.count == 1 })

        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("fresh")))
        h.store.reloadPage("VLPL1")
        #expect(await h.until { loadedPage(h.store, "VLPL1")?.tracks.map(\.videoId) == ["fresh"] })

        await slow.open()
        await h.letLateWorkLand()
        #expect(loadedPage(h.store, "VLPL1")?.tracks.map(\.videoId) == ["fresh"])
        #expect(h.store.loadingMoreTracks.isEmpty)
    }

    @Test("Ten thousand more tracks are all appended")
    func tracksLargePage() async {
        let h = StoreHarness()
        let more = (0..<10_000).map { MusicSamples.track("v\($0)") }
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a"), continuation: "t1"))
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: more)
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { loadedPage(h.store, "VLPL1") != nil })
        h.store.loadMoreTracks("VLPL1")
        #expect(await h.until { loadedPage(h.store, "VLPL1")?.tracks.count == 10_001 })
    }

    // MARK: - Reset

    @Test("reset drops everything loaded and keeps the selected tab and library section")
    func resetClearsAll() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: "t1")
        await h.backend.setLibrary(.albums, items: MusicSamples.collections("A"), continuation: "t1")
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a"), continuation: "t1"))
        h.store.tab = .library
        h.store.librarySection = .albums
        h.store.loadHomeIfNeeded()
        h.store.loadLibraryIfNeeded(.albums)
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until {
            h.store.home != .loading && h.store.libraryState(.albums) != .loading && h.store.pageState("VLPL1") != .loading
        })

        h.store.reset()
        #expect(h.store.home == .idle)
        #expect(h.store.canLoadMoreHome == false)
        #expect(h.store.libraryState(.albums) == .idle)
        #expect(h.store.libraryHasMore.isEmpty)
        #expect(h.store.pageState("VLPL1") == .idle)
        #expect(h.store.path.isEmpty)
        #expect(h.store.loadingMoreTracks.isEmpty)
        #expect(h.store.tab == .library)
        #expect(h.store.librarySection == .albums)

        h.store.loadHomeIfNeeded()
        #expect(h.store.home == .loading)
    }

    @Test("Answers that were in flight at reset are dropped and cannot bring old data back")
    func resetDropsInFlight() async {
        let h = StoreHarness()
        let slow = MusicTestGate()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: "t1")
        await h.backend.setHomeGate(slow)
        await h.backend.setLibrary(.albums, items: MusicSamples.collections("A"))
        await h.backend.setLibraryGate(.albums, slow)
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a")))
        await h.backend.setPageGate("VLPL1", slow)
        h.store.loadHomeIfNeeded()
        h.store.loadLibraryIfNeeded(.albums)
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until {
            let backend = h.backend
            let home = await backend.homeCallCount
            let library = await backend.libraryCalls.count
            let page = await backend.pageCalls.count
            return home == 1 && library == 1 && page == 1
        })

        h.store.reset()
        await slow.open()
        await h.letLateWorkLand()
        #expect(h.store.home == .idle)
        #expect(h.store.libraryState(.albums) == .idle)
        #expect(h.store.pageState("VLPL1") == .idle)
        #expect(h.store.canLoadMoreHome == false)
    }

    @Test("A more-page that was in flight at reset is dropped")
    func resetDropsInFlightMore() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: "t1")
        await h.backend.setMoreHome(continuation: "t1", shelves: [MusicSamples.shelf("B", "b")])
        let slow = MusicTestGate()
        await h.backend.setMoreHomeGate(continuation: "t1", slow)
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })
        h.store.loadMoreHome()
        #expect(await h.until { await h.backend.moreHomeCalls.count == 1 })

        h.store.reset()
        await slow.open()
        await h.letLateWorkLand()
        #expect(h.store.home == .idle)
        #expect(h.store.isLoadingMoreHome == false)
    }

    // MARK: - Session expired

    @Test("signedOut from any call tells the service once and shows the signed-out message")
    func sessionExpiredEverywhere() async {
        let h = StoreHarness()
        let message = MusicService.message(for: MusicError.signedOut)

        await h.backend.setHomeError(MusicError.signedOut)
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home == .failed(message) })
        #expect(h.probe.count == 1)

        await h.backend.setLibraryError(.albums, MusicError.signedOut)
        h.store.loadLibraryIfNeeded(.albums)
        #expect(await h.until { h.store.libraryState(.albums) == .failed(message) })
        #expect(h.probe.count == 2)

        await h.backend.setPageError("VLPL1", MusicError.signedOut)
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until { h.store.pageState("VLPL1") == .failed(message) })
        #expect(h.probe.count == 3)
    }

    @Test("signedOut from an extra page tells the service and keeps what was loaded")
    func sessionExpiredOnMore() async {
        let h = StoreHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("A", "a")], continuation: "h1")
        await h.backend.setMoreHomeError(continuation: "h1", MusicError.signedOut)
        await h.backend.setLibrary(.albums, items: MusicSamples.collections("A"), continuation: "l1")
        await h.backend.setMoreLibraryError(.albums, continuation: "l1", MusicError.signedOut)
        await h.backend.setPage(MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a"), continuation: "p1"))
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "p1", MusicError.signedOut)
        h.store.loadHomeIfNeeded()
        h.store.loadLibraryIfNeeded(.albums)
        h.store.open(MusicSamples.collection("VLPL1"))
        #expect(await h.until {
            h.store.home != .loading && h.store.libraryState(.albums) != .loading && h.store.pageState("VLPL1") != .loading
        })

        h.store.loadMoreHome()
        #expect(await h.until { h.probe.count == 1 })
        h.store.loadMoreLibrary(.albums)
        #expect(await h.until { h.probe.count == 2 })
        h.store.loadMoreTracks("VLPL1")
        #expect(await h.until { h.probe.count == 3 })
        #expect(loadedShelves(h.store).count == 1)
        #expect(loadedCollections(h.store, .albums).count == 1)
        #expect(loadedPage(h.store, "VLPL1")?.tracks.count == 1)
    }

    @Test("Other errors do not sign the session out")
    func otherErrorsKeepSession() async {
        let h = StoreHarness()
        let errors: [any Error] = [MusicError.http(500), MusicError.http(403), MusicError.parse("x"), URLError(.notConnectedToInternet)]
        for error in errors {
            await h.backend.setHomeError(error)
            h.store.reloadHome()
            #expect(await h.until { h.store.home != .loading })
        }
        #expect(h.store.home == .failed(MusicService.message(for: URLError(.notConnectedToInternet))))
        #expect(h.probe.count == 0)
    }

    @Test("A signedOut answer that arrives after a reset does not fire the callback")
    func sessionExpiredAfterResetIsIgnored() async {
        let h = StoreHarness()
        let slow = MusicTestGate()
        await h.backend.setHomeError(MusicError.signedOut)
        await h.backend.setHomeGate(slow)
        h.store.loadHomeIfNeeded()
        #expect(await h.until { await h.backend.homeCallCount == 1 })

        h.store.reset()
        await slow.open()
        await h.letLateWorkLand()
        #expect(h.probe.count == 0)
        #expect(h.store.home == .idle)
    }
}
