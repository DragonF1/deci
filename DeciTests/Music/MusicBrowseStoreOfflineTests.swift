// DeciTests/Music/MusicBrowseStoreOfflineTests.swift
// The browse store with downloads and without a network: the Library tabs (Playlists, Albums, Downloads, and Downloads
// alone offline), the Downloaded songs page behind a reserved id that never reaches the backend, a downloaded
// collection's page built from the index, the notes that stand in for pages that need the network, the dimming of songs
// that cannot play, and the loads that wait for the network and run when it returns. Two fake backends: the store's own,
// whose recorded calls are the point of most tests here, and the one the download service reads collection pages from.

import Foundation
import Observation
import Testing
@testable import Deci

@MainActor
private struct OfflineStoreRig {
    let backend = FakeMusicBackend()
    let downloadsBackend = FakeMusicBackend()
    let connectivity: MusicConnectivity
    let downloadRig: DownloadServiceRig
    let store: MusicBrowseStore

    var downloads: MusicDownloadService { downloadRig.service }

    /// `pathReported` false is a launch the system has not reported the network for yet (the flag starts online).
    init(pathReported: Bool = true) {
        let clock = MutableClock()
        let downloadsBackend = self.downloadsBackend
        let connectivity = MusicConnectivity(isOnline: true, reported: pathReported)
        self.connectivity = connectivity
        downloadRig = DownloadServiceRig(
            clock: clock, storeNow: { clock.now }, backend: downloadsBackend, covers: FakeCoverFetcher(),
            connectivity: connectivity
        )
        store = MusicBrowseStore(backend: backend, connectivity: connectivity, downloads: downloadRig.service)
    }

    func cleanUp() { downloadRig.cleanUp() }

    func goOffline() { connectivity.update(isOnline: false) }

    func goOnline() { connectivity.update(isOnline: true) }

    /// Downloads songs one after the other, ten seconds apart, so each has its own time.
    func download(_ ids: String...) async {
        for id in ids {
            downloads.download(DownloadSamples.track(id, title: "Title \(id.prefix(1))"))
            await downloads.waitUntilIdle()
            downloadRig.clock.advance(by: 10)
        }
    }

    /// Downloads a collection of `tracks` whole, with the cover a header would have.
    func downloadCollection(
        _ browseId: String, tracks: [MusicTrack], title: String, kind: MusicDownloadStore.Collection.Kind = .playlist
    ) async {
        await downloadRig.script(browseId, tracks: tracks, title: title, cover: "https://lh3.googleusercontent.com/\(browseId)=w544-h544")
        downloads.downloadCollection(downloadRig.request(
            browseId, title: title, kind: kind, cover: "https://lh3.googleusercontent.com/\(browseId)=w544-h544"
        ))
        await downloads.waitUntilIdle()
        downloadRig.clock.advance(by: 10)
    }

    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Gives a call that should not be made time to show.
    func letLateWorkLand() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    func loadedPage(_ browseId: String) -> MusicBrowsePage? {
        if case .loaded(let page) = store.pageState(browseId) { page } else { nil }
    }

    func collection(_ browseId: String, title: String = "Page") -> MusicCollection {
        MusicCollection(browseId: browseId, kind: .playlist, title: title, subtitle: "Playlist", thumbnailURL: nil)
    }
}

@MainActor
@Suite("MusicBrowseStore offline")
struct MusicBrowseStoreOfflineTests {
    private let one = "VLPLone"
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB
    private let idC = DownloadSamples.idC

    private func id(_ number: Int) -> String { DownloadSamples.id(number) }

    // MARK: - Library tabs

    @Test("Library has three tabs, and opens on Playlists")
    func tabsStart() {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }

        #expect(MusicLibraryTab.allCases == [.playlists, .albums, .downloads])
        #expect(MusicLibraryTab.allCases.map(\.title) == ["Playlists", "Albums", "Downloads"])
        #expect(rig.store.libraryTab == .playlists)
        #expect(MusicLibraryTab.downloads.section == nil)
        #expect(MusicLibraryTab.albums.section == .albums)
        #expect(MusicLibraryTab(.playlists) == .playlists)
    }

    @Test("picking a tab shows it, and Playlists and Albums keep the section the lists load for")
    func pickingTabs() {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }

        rig.store.selectLibraryTab(.albums)
        #expect(rig.store.libraryTab == .albums)
        #expect(rig.store.librarySection == .albums)

        rig.store.selectLibraryTab(.downloads)
        #expect(rig.store.libraryTab == .downloads)
        #expect(rig.store.librarySection == .albums)

        rig.store.selectLibraryTab(.playlists)
        #expect(rig.store.libraryTab == .playlists)
        #expect(rig.store.librarySection == .playlists)
    }

    @Test("the section set directly, as the other-matches row does, shows its tab")
    func sectionSetDirectly() {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        rig.store.selectLibraryTab(.downloads)

        rig.store.librarySection = .albums

        #expect(rig.store.libraryTab == .albums)
    }

    @Test("offline, Library is on Downloads, and the Playlists and Albums pills are disabled")
    func offlineTabs() {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        rig.store.selectLibraryTab(.albums)

        rig.goOffline()

        #expect(rig.store.libraryTab == .downloads)
        #expect(!rig.store.isLibraryTabEnabled(.playlists))
        #expect(!rig.store.isLibraryTabEnabled(.albums))
        #expect(rig.store.isLibraryTabEnabled(.downloads))
    }

    @Test("every tab is enabled online")
    func onlineTabs() {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }

        #expect(MusicLibraryTab.allCases.allSatisfy { rig.store.isLibraryTabEnabled($0) })
    }

    @Test("a pick of Playlists or Albums offline changes nothing")
    func offlinePicksIgnored() {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        rig.store.selectLibraryTab(.albums)
        rig.goOffline()

        rig.store.selectLibraryTab(.playlists)

        #expect(rig.store.libraryTab == .downloads)
        #expect(rig.store.librarySection == .albums)
    }

    @Test("back online the tab picked last returns")
    func tabReturns() {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        rig.store.selectLibraryTab(.albums)
        rig.goOffline()
        rig.store.selectLibraryTab(.downloads)

        rig.goOnline()

        #expect(rig.store.libraryTab == .albums)
    }

    @Test("a Downloads pick made online stays on Downloads when the network returns")
    func downloadsPickStays() {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        rig.store.selectLibraryTab(.downloads)
        rig.goOffline()

        rig.goOnline()

        #expect(rig.store.libraryTab == .downloads)
    }

    @Test("the tab is observable, so the pills redraw when the network goes")
    func tabObservable() {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        let fired = OfflineFlag()
        withObservationTracking { _ = rig.store.libraryTab } onChange: { fired.set() }

        rig.goOffline()

        #expect(fired.value)
    }

    // MARK: - The Downloaded songs row and page

    @Test("the pinned row is a collection with the reserved id, titled Downloaded songs")
    func pinnedRow() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.download(idA, idB)

        #expect(MusicBrowseStore.downloadedSongs.browseId == "DECI_DOWNLOADS")
        #expect(MusicBrowseStore.downloadedSongs.title == "Downloaded songs")
        #expect(rig.store.downloadedSongsRow.browseId == MusicDownloadService.songsBrowseId)
        #expect(rig.store.downloadedSongsRow.title == "Downloaded songs")
        #expect(rig.store.downloadedSongsRow.subtitle == "2 songs")
    }

    @Test("the row's subtitle is the song count, and follows it")
    func pinnedRowCount() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloads.waitUntilLoaded()
        #expect(rig.store.downloadedSongsRow.subtitle == "No songs")

        await rig.download(idA)

        #expect(rig.store.downloadedSongsRow.subtitle == "1 song")
    }

    @Test("opening the Downloaded songs page asks the backend for nothing, online or offline")
    func reservedIdNeverReachesTheBackend() async {
        for offline in [false, true] {
            let rig = OfflineStoreRig()
            defer { rig.cleanUp() }
            await rig.download(idA, idB)
            if offline { rig.goOffline() }

            rig.store.open(MusicBrowseStore.downloadedSongs)
            rig.store.reloadPage(MusicDownloadService.songsBrowseId)
            rig.store.loadMoreTracks(MusicDownloadService.songsBrowseId)
            rig.store.reloadPage(MusicDownloadService.songsBrowseId)
            await rig.letLateWorkLand()

            #expect(await rig.backend.pageCalls.isEmpty)
            #expect(await rig.backend.moreTracksCalls.isEmpty)
            #expect(rig.store.path.map(\.browseId) == [MusicDownloadService.songsBrowseId])
        }
    }

    @Test("the reserved id never reaches the backend when the store has no download service either")
    func reservedIdWithoutDownloads() async {
        let backend = FakeMusicBackend()
        let store = MusicBrowseStore(backend: backend)

        store.open(MusicBrowseStore.downloadedSongs)
        store.reloadPage(MusicDownloadService.songsBrowseId)
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))

        #expect(await backend.pageCalls.isEmpty)
        #expect(store.pageState(MusicDownloadService.songsBrowseId) != .loading)
    }

    @Test("the Downloaded songs page is loaded at once, from the index, newest song first")
    func songsPage() async throws {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.download(idA, idB, idC)

        rig.store.open(MusicBrowseStore.downloadedSongs)

        let page = try #require(rig.loadedPage(MusicDownloadService.songsBrowseId))
        #expect(page.title == "Downloaded songs")
        #expect(page.tracks.map(\.videoId) == [idC, idB, idA])
        #expect(rig.store.displayedPage(MusicDownloadService.songsBrowseId)?.tracks.map(\.videoId) == [idC, idB, idA])
        #expect(!rig.store.needsReorder(MusicDownloadService.songsBrowseId))
    }

    @Test("the page grows as another song finishes downloading")
    func songsPageIsLive() async throws {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.download(idA)
        rig.store.open(MusicBrowseStore.downloadedSongs)
        #expect(rig.loadedPage(MusicDownloadService.songsBrowseId)?.tracks.count == 1)

        await rig.download(idB)

        #expect(rig.loadedPage(MusicDownloadService.songsBrowseId)?.tracks.map(\.videoId) == [idB, idA])
    }

    @Test("closing the Downloaded songs page and opening it again shows it again")
    func songsPageReopens() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.download(idA)

        rig.store.open(MusicBrowseStore.downloadedSongs)
        rig.store.back()
        #expect(rig.store.path.isEmpty)
        rig.store.open(MusicBrowseStore.downloadedSongs)

        #expect(rig.loadedPage(MusicDownloadService.songsBrowseId)?.tracks.count == 1)
    }

    // MARK: - A downloaded collection's page

    @Test("offline, a downloaded collection opens from the index: title, cover from disk, songs in the stored order")
    func storedPageOffline() async throws {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        let tracks = [3, 1, 2].map { DownloadSamples.track(id($0), title: "Song \($0)") }
        await rig.downloadCollection(one, tracks: tracks, title: "Road trip")
        rig.goOffline()

        rig.store.open(rig.collection(one, title: "Road trip"))

        let page = try #require(rig.loadedPage(one))
        #expect(page.title == "Road trip")
        #expect(page.tracks.map(\.videoId) == [id(3), id(1), id(2)])
        #expect(page.thumbnailURL?.isFileURL == true)
        #expect(await rig.backend.pageCalls.isEmpty)
        #expect(rig.store.offlineNote(for: .page(one)) == nil)
    }

    @Test("online, the same collection opens from the network as ever")
    func storedPageOnline() async throws {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        await rig.script(one, title: "Live title")

        rig.store.open(rig.collection(one))

        #expect(await rig.until { rig.loadedPage(one)?.title == "Live title" })
        #expect(await rig.backend.pageCalls == [one])
    }

    @Test("a stored page shown offline is replaced by the network page when the network returns")
    func storedPageReplacedOnReconnect() async throws {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        await rig.script(one, title: "Live title")
        rig.goOffline()
        rig.store.open(rig.collection(one))
        #expect(rig.loadedPage(one)?.title == "Road trip")

        rig.goOnline()

        #expect(await rig.until { rig.loadedPage(one)?.title == "Live title" })
        #expect(await rig.backend.pageCalls == [one])
    }

    @Test("a page that is not downloaded shows the offline note, makes no request and is not an error")
    func unreachablePage() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        rig.goOffline()

        rig.store.open(rig.collection("VLPLother"))
        await rig.letLateWorkLand()

        #expect(await rig.backend.pageCalls.isEmpty)
        #expect(rig.store.pageState("VLPLother") == .idle)
        #expect(rig.store.offlineNote(for: .page("VLPLother")) == MusicOfflineCopy.note)
    }

    @Test("a page opened offline loads once the network returns, and the note goes")
    func unreachablePageLoadsOnReconnect() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.script("VLPLother", title: "Other")
        rig.goOffline()
        rig.store.open(rig.collection("VLPLother"))

        rig.goOnline()

        #expect(await rig.until { rig.loadedPage("VLPLother")?.title == "Other" })
        #expect(rig.store.offlineNote(for: .page("VLPLother")) == nil)
        #expect(await rig.backend.pageCalls == ["VLPLother"])
    }

    @Test("a collection that has not finished its first read has no stored page, so it shows the note")
    func pendingCollectionHasNoStoredPage() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        let gate = MusicTestGate()
        await rig.downloadsBackend.setPageGate(one, gate)
        await rig.downloadRig.script(one, tracks: DownloadSamples.tracks(1...2))
        rig.downloads.downloadCollection(rig.downloadRig.request(one))
        rig.goOffline()

        rig.store.open(rig.collection(one))

        #expect(rig.store.offlineNote(for: .page(one)) == MusicOfflineCopy.note)
        #expect(await rig.backend.pageCalls.isEmpty)
        await gate.open()
    }

    @Test("a page loaded online stays on screen when the network goes, with no note")
    func loadedPageStays() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.script("VLPLother", title: "Other")
        rig.store.open(rig.collection("VLPLother"))
        #expect(await rig.until { rig.loadedPage("VLPLother") != nil })

        rig.goOffline()

        #expect(rig.loadedPage("VLPLother")?.title == "Other")
        #expect(rig.store.offlineNote(for: .page("VLPLother")) == nil)
    }

    @Test("more songs of a loaded page are not asked for offline")
    func noMoreTracksOffline() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.script("VLPLlong", title: "Long", continuation: "next")
        rig.store.open(rig.collection("VLPLlong"))
        #expect(await rig.until { rig.loadedPage("VLPLlong") != nil })
        rig.goOffline()

        rig.store.loadMoreTracks("VLPLlong")
        await rig.letLateWorkLand()

        #expect(await rig.backend.moreTracksCalls.isEmpty)
    }

    // MARK: - Notes and dimming

    @Test("the words offline are the owner's")
    func copy() {
        #expect(MusicOfflineCopy.banner == "Offline. Playing downloads only.")
        #expect(MusicOfflineCopy.note == "You're offline. Your downloads are in Library.")
        #expect(MusicOfflineCopy.noDownloadsTitle == "No downloads yet")
        #expect(!MusicOfflineCopy.noDownloadsDetail.isEmpty)
        let words = [
            MusicOfflineCopy.banner, MusicOfflineCopy.note, MusicOfflineCopy.noDownloadsTitle, MusicOfflineCopy.noDownloadsDetail,
        ]
        #expect(words.allSatisfy { !$0.contains("\u{2014}") })
    }

    @Test("Home and History show the note in place of their feed while offline, whatever they hold, and nothing online")
    func homeNote() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "a")])
        rig.store.loadHomeIfNeeded()
        #expect(await rig.until { rig.store.home != .loading })
        #expect(rig.store.offlineNote(for: .home) == nil)
        #expect(rig.store.offlineNote(for: .history) == nil)

        rig.goOffline()

        #expect(rig.store.offlineNote(for: .home) == "You're offline. Your downloads are in Library.")
        #expect(rig.store.offlineNote(for: .history) == MusicOfflineCopy.note)
        // What was loaded is still there for when the network returns.
        if case .loaded(let shelves) = rig.store.home { #expect(shelves.count == 1) } else { Issue.record("Home was wiped") }
    }

    @Test("a song that is not downloaded is dimmed offline; a downloaded one is not; online nothing is")
    func dimming() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.download(idA)
        #expect(!rig.store.isDimmed(idA))
        #expect(!rig.store.isDimmed(idB))

        rig.goOffline()

        #expect(!rig.store.isDimmed(idA))
        #expect(rig.store.isDimmed(idB))
        rig.goOnline()
        #expect(!rig.store.isDimmed(idB))
    }

    @Test("a store with no download service dims every song offline")
    func dimmingWithoutDownloads() {
        let connectivity = MusicConnectivity(isOnline: false)
        let store = MusicBrowseStore(backend: FakeMusicBackend(), connectivity: connectivity)

        #expect(store.isDimmed(idA))
        #expect(store.isOffline)
    }

    // MARK: - Loads that wait for the network

    @Test("Home asked for offline makes no request, stays idle, and loads when the network returns")
    func homeWaits() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "a")])
        rig.goOffline()

        rig.store.loadHomeIfNeeded()
        rig.store.reloadHome()
        await rig.letLateWorkLand()

        #expect(await rig.backend.homeCallCount == 0)
        #expect(rig.store.home == .idle)

        rig.goOnline()

        #expect(await rig.until { rig.store.home != .idle && rig.store.home != .loading })
        #expect(await rig.backend.homeCallCount == 1)
    }

    @Test("History and the Library lists wait the same way")
    func historyAndLibraryWait() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.backend.setHistory(shelves: [MusicSamples.shelf("Today", "a")])
        await rig.backend.setLibrary(.playlists, items: [rig.collection("VLPLmine", title: "Mine")])
        rig.goOffline()

        rig.store.loadHistoryIfNeeded()
        rig.store.loadLibraryIfNeeded(.playlists)
        await rig.letLateWorkLand()

        #expect(await rig.backend.historyCallCount == 0)
        #expect(await rig.backend.libraryCalls.isEmpty)
        #expect(rig.store.libraryState(.playlists) == .idle)

        rig.goOnline()

        #expect(await rig.until { rig.store.loadedLibrary(.playlists)?.map(\.browseId) == ["VLPLmine"] })
        #expect(await rig.until { rig.store.history != .idle && rig.store.history != .loading })
        #expect(await rig.backend.historyCallCount == 1)
        #expect(await rig.backend.libraryCalls == [.playlists])
    }

    @Test("a list that loaded before the network went is neither wiped nor asked for again when it returns")
    func loadedStateKept() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "a")])
        await rig.backend.setLibrary(.albums, items: [rig.collection("MPREx", title: "Album")])
        rig.store.loadHomeIfNeeded()
        rig.store.loadLibraryIfNeeded(.albums)
        #expect(await rig.until { rig.store.loadedLibrary(.albums) != nil })
        #expect(await rig.until { rig.store.home != .loading })

        rig.goOffline()
        #expect(rig.store.loadedLibrary(.albums)?.map(\.browseId) == ["MPREx"])
        rig.goOnline()
        await rig.letLateWorkLand()

        #expect(await rig.backend.homeCallCount == 1)
        #expect(await rig.backend.libraryCalls == [.albums])
        #expect(rig.store.loadedLibrary(.albums)?.map(\.browseId) == ["MPREx"])
    }

    @Test("refreshing and paging do nothing offline")
    func refreshingAndPagingOffline() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "a")], continuation: "more")
        await rig.backend.setHistory(shelves: [MusicSamples.shelf("Today", "a")], continuation: "more")
        await rig.backend.setLibrary(.playlists, items: [rig.collection("VLPLmine")], continuation: "more")
        rig.store.loadHomeIfNeeded()
        rig.store.loadHistoryIfNeeded()
        rig.store.loadLibraryIfNeeded(.playlists)
        #expect(await rig.until { rig.store.loadedLibrary(.playlists) != nil })
        #expect(await rig.until { rig.store.home != .loading && rig.store.history != .loading })
        rig.goOffline()

        rig.store.refreshHome()
        rig.store.refreshHistory()
        rig.store.loadMoreHome()
        rig.store.loadMoreHistory()
        rig.store.loadMoreLibrary(.playlists)
        await rig.letLateWorkLand()

        #expect(await rig.backend.homeCallCount == 1)
        #expect(await rig.backend.historyCallCount == 1)
        #expect(await rig.backend.moreHomeCalls.isEmpty)
        #expect(await rig.backend.libraryCalls == [.playlists])
        #expect(rig.store.home != .loading)
    }

    @Test("a load that the network cut mid-flight is asked for again when it returns")
    func cutLoadRetried() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        let gate = MusicTestGate()
        await rig.backend.setHomeGate(gate)
        await rig.backend.setHomeError(URLError(.networkConnectionLost))
        rig.store.reloadHome()
        rig.goOffline()
        await gate.open()
        #expect(await rig.until { if case .failed = rig.store.home { true } else { false } })

        await rig.backend.setHomeError(nil)
        await rig.backend.setHomeGate(nil)
        await rig.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "a")])
        rig.goOnline()

        #expect(await rig.until { if case .loaded = rig.store.home { true } else { false } })
        #expect(await rig.backend.homeCallCount == 2)
    }

    @Test("a failure with the network up is left for Retry, as before")
    func failureOnlineStaysFailed() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.backend.setHomeError(URLError(.badServerResponse))
        rig.store.reloadHome()
        #expect(await rig.until { if case .failed = rig.store.home { true } else { false } })

        rig.goOffline()
        rig.goOnline()
        await rig.letLateWorkLand()

        #expect(await rig.backend.homeCallCount == 1)
    }

    @Test("several flips load a waiting list once")
    func flapLoadsOnce() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "a")])
        rig.goOffline()
        rig.store.loadHomeIfNeeded()

        rig.goOnline()
        #expect(await rig.until { rig.store.home != .idle && rig.store.home != .loading })
        rig.goOffline()
        rig.goOnline()
        await rig.letLateWorkLand()

        #expect(await rig.backend.homeCallCount == 1)
    }

    @Test("a reset while offline forgets what was waiting, so a signed-out store loads nothing on return")
    func resetForgetsWaiting() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        rig.goOffline()
        rig.store.loadHomeIfNeeded()
        rig.store.loadLibraryIfNeeded(.albums)
        rig.store.open(rig.collection("VLPLother"))

        rig.store.reset()
        rig.goOnline()
        await rig.letLateWorkLand()

        #expect(await rig.backend.homeCallCount == 0)
        #expect(await rig.backend.libraryCalls.isEmpty)
        #expect(await rig.backend.pageCalls.isEmpty)
    }

    @Test("the Downloaded songs page reads the same after a reset, since nothing of it is stored")
    func songsPageAfterReset() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.download(idA)

        rig.store.reset()

        // Nothing is stored for it: it is read from the index each time.
        #expect(rig.loadedPage(MusicDownloadService.songsBrowseId)?.tracks.map(\.videoId) == [idA])
    }

    // MARK: - Signed out

    @Test("with the account gone the store is downloads only: Library shows Downloads, with Playlists and Albums disabled")
    func accountGoneIsDownloadsOnly() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        let gone = AccountFlag(false)
        rig.store.accountGone = { gone.value }
        #expect(!rig.store.isOffline)
        #expect(rig.store.libraryTab == .playlists)

        gone.value = true

        #expect(rig.store.isOffline)
        #expect(!rig.store.isNetworkDown)
        #expect(rig.store.libraryTab == .downloads)
        #expect(rig.store.isLibraryTabEnabled(.downloads))
        #expect(!rig.store.isLibraryTabEnabled(.playlists))
        #expect(!rig.store.isLibraryTabEnabled(.albums))
        rig.store.selectLibraryTab(.albums)
        #expect(rig.store.libraryTab == .downloads)
    }

    @Test("with the account gone nothing is asked of the backend, and a downloaded collection opens from the index")
    func accountGoneAsksNothing() async throws {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        let gone = AccountFlag(true)
        rig.store.accountGone = { gone.value }

        rig.store.loadHomeIfNeeded()
        rig.store.loadLibraryIfNeeded(.playlists)
        rig.store.open(rig.collection(one, title: "Road trip"))
        rig.store.open(MusicBrowseStore.downloadedSongs)
        await rig.letLateWorkLand()

        let page = try #require(rig.loadedPage(one))
        #expect(page.tracks.count == 2)
        #expect(await rig.backend.homeCallCount == 0)
        #expect(await rig.backend.libraryCalls.isEmpty)
        #expect(await rig.backend.pageCalls.isEmpty)
        // Songs that are not downloaded do not play from here.
        #expect(rig.store.isDimmed("NOTDOWNLOADED"))
    }

    @Test("the account coming back loads what was held back and replaces the pages built from the index")
    func accountReturned() async throws {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        await rig.script(one, title: "Live title")
        let gone = AccountFlag(true)
        rig.store.accountGone = { gone.value }
        rig.store.open(rig.collection(one))
        #expect(rig.loadedPage(one)?.title == "Road trip")
        #expect(await rig.backend.pageCalls.isEmpty)

        gone.value = false
        rig.store.accountReturned()

        #expect(await rig.until { rig.loadedPage(one)?.title == "Live title" })
        #expect(await rig.backend.pageCalls == [one])
    }

    @Test("the account coming back while the network is down changes nothing yet")
    func accountReturnedOffline() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        let gone = AccountFlag(true)
        rig.store.accountGone = { gone.value }
        rig.goOffline()
        rig.store.open(rig.collection(one))

        gone.value = false
        rig.store.accountReturned()
        await rig.letLateWorkLand()

        #expect(rig.store.isOffline)
        #expect(await rig.backend.pageCalls.isEmpty)
    }

    // MARK: - The Downloads list

    @Test("there are downloads once a song or a collection is there, and not before")
    func hasDownloads() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloads.waitUntilLoaded()
        #expect(!rig.store.hasDownloads)

        await rig.download(idA)

        #expect(rig.store.hasDownloads)
    }

    @Test("a collection on its way counts as a download, though no song of it is here yet")
    func collectionCountsAsDownload() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        let gate = MusicTestGate()
        await rig.downloadsBackend.setPageGate(one, gate)
        await rig.downloadRig.script(one, tracks: DownloadSamples.tracks(1...2))

        rig.downloads.downloadCollection(rig.downloadRig.request(one))
        #expect(await rig.downloadRig.eventually { await rig.downloadsBackend.pageCalls.contains(one) })

        #expect(rig.store.hasDownloads)
        await gate.open()
    }
}

/// A flag a change handler sets, readable from the test.
nonisolated private final class OfflineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }

    func set() { lock.withLock { flag = true } }
}

/// Whether the account is gone, as the service would answer it; a test flips it.
nonisolated private final class AccountFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    init(_ flag: Bool) { self.flag = flag }

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

private extension OfflineStoreRig {
    func script(_ browseId: String, title: String, continuation: String? = nil) async {
        await backend.setPage(MusicBrowsePage(
            browseId: browseId, title: title, subtitle: "Playlist", thumbnailURL: nil,
            tracks: [MusicSamples.track("x1", title: "One"), MusicSamples.track("x2", title: "Two")],
            continuation: continuation, shelves: []
        ))
    }
}

@MainActor
@Suite("MusicDownloadsFilter")
struct MusicDownloadsFilterTests {
    private func collection(_ browseId: String, _ title: String) -> MusicCollection {
        MusicCollection(browseId: browseId, kind: .playlist, title: title, subtitle: "Playlist", thumbnailURL: nil)
    }

    private let collections = [
        MusicCollection(browseId: "VLPL1", kind: .playlist, title: "Road trip", subtitle: "Playlist", thumbnailURL: nil),
        MusicCollection(browseId: "MPRE2", kind: .album, title: "Night drive", subtitle: "Album", thumbnailURL: nil),
        MusicCollection(browseId: "VLPL3", kind: .playlist, title: "Focus", subtitle: "Playlist", thumbnailURL: nil),
    ]

    @Test("words that match some of the rows keep those rows, in order")
    func someMatch() {
        let filter = MusicDownloadsFilter.resolve(collections: collections, terms: ["dr"])

        #expect(filter.items.map(\.browseId) == ["MPRE2"])
        #expect(!filter.showsSongsRow)
        #expect(filter.matched == 1)
        #expect(filter.total == 4)
        #expect(filter.countLine == "1 OF 4 DOWNLOADS")
    }

    @Test("the Downloaded songs row matches by its title")
    func songsRowMatches() {
        let filter = MusicDownloadsFilter.resolve(collections: collections, terms: ["songs"])

        #expect(filter.showsSongsRow)
        #expect(filter.items.isEmpty)
        #expect(filter.matched == 1)
        #expect(!filter.isEmpty)
    }

    @Test("words that match nothing leave nothing")
    func noneMatch() {
        let filter = MusicDownloadsFilter.resolve(collections: collections, terms: ["zzz"])

        #expect(filter.isEmpty)
        #expect(filter.matched == 0)
        #expect(filter.countLine == "0 OF 4 DOWNLOADS")
    }

    @Test("no words keep every row")
    func noTerms() {
        let filter = MusicDownloadsFilter.resolve(collections: collections, terms: [])

        #expect(filter.items.count == 3)
        #expect(filter.showsSongsRow)
        #expect(filter.matched == 4)
    }

    @Test("one download counts in the singular")
    func singular() {
        let filter = MusicDownloadsFilter.resolve(collections: [], terms: ["songs"])

        #expect(filter.total == 1)
        #expect(filter.countLine == "1 OF 1 DOWNLOAD")
    }
}

// MARK: - The review of phase 3

@MainActor
@Suite("MusicBrowseStore offline review")
struct MusicBrowseStoreOfflineReviewTests {
    private let one = "VLPLone"

    private func failed<Value: Equatable>(_ load: MusicBrowseStore.Load<Value>) -> Bool {
        if case .failed = load { true } else { false }
    }

    private func loaded<Value: Equatable>(_ load: MusicBrowseStore.Load<Value>) -> Bool {
        if case .loaded = load { true } else { false }
    }

    // MARK: - A reconnect refreshes a stored page in place

    @Test("a reconnect keeps the stored page on screen while the network's page loads, then swaps it in")
    func reconnectRefreshesInPlace() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        await rig.script(one, title: "Live title")
        let gate = MusicTestGate()
        await rig.backend.setPageGate(one, gate)
        rig.goOffline()
        rig.store.open(rig.collection(one))
        #expect(rig.loadedPage(one)?.title == "Road trip")

        rig.goOnline()
        #expect(await rig.until { await rig.backend.pageCalls == [one] })

        // The request is out, and the page on screen is still the stored one: no spinner, no empty state.
        #expect(rig.loadedPage(one)?.title == "Road trip")
        await gate.open()
        #expect(await rig.until { rig.loadedPage(one)?.title == "Live title" })
        #expect(await rig.backend.pageCalls == [one])
    }

    @Test("nothing a view reads changes while the refresh is out, so the list keeps its scroll position")
    func reconnectChangesNothingWhileLoading() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        await rig.script(one, title: "Live title")
        let gate = MusicTestGate()
        await rig.backend.setPageGate(one, gate)
        rig.goOffline()
        rig.store.open(rig.collection(one))
        let fired = OfflineFlag()
        withObservationTracking { _ = rig.store.pageState(one) } onChange: { fired.set() }

        rig.goOnline()
        #expect(await rig.until { await rig.backend.pageCalls == [one] })
        await rig.letLateWorkLand()
        #expect(!fired.value)

        await gate.open()
        #expect(await rig.until { rig.loadedPage(one)?.title == "Live title" })
        #expect(fired.value)
    }

    @Test("a refresh that fails leaves the stored page up, and the next reconnect tries it again")
    func reconnectFailureKeepsStoredPage() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        await rig.script(one, title: "Live title")
        await rig.backend.setPageError(one, URLError(.networkConnectionLost))
        rig.goOffline()
        rig.store.open(rig.collection(one))

        rig.goOnline()
        #expect(await rig.until { await rig.backend.pageCalls == [one] })
        await rig.letLateWorkLand()

        // Neither failed nor loading: the stored page.
        #expect(rig.loadedPage(one)?.title == "Road trip")
        #expect(rig.store.offlineNote(for: .page(one)) == nil)

        await rig.backend.setPageError(one, nil)
        rig.goOffline()
        rig.goOnline()

        #expect(await rig.until { rig.loadedPage(one)?.title == "Live title" })
        #expect(await rig.backend.pageCalls == [one, one])
    }

    @Test("a refresh that finds the session gone tells the service, and still keeps the stored page up")
    func reconnectSignedOutTellsService() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        await rig.backend.setPageError(one, MusicError.signedOut)
        let expired = OfflineFlag()
        rig.store.onSessionExpired = { expired.set() }
        rig.goOffline()
        rig.store.open(rig.collection(one))

        rig.goOnline()

        #expect(await rig.until { expired.value })
        #expect(rig.loadedPage(one)?.title == "Road trip")
    }

    @Test("closing the page while its refresh is out lets the late answer land nowhere")
    func closedPageIgnoresLateRefresh() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        await rig.script(one, title: "Live title")
        let gate = MusicTestGate()
        await rig.backend.setPageGate(one, gate)
        rig.goOffline()
        rig.store.open(rig.collection(one))
        rig.goOnline()
        #expect(await rig.until { await rig.backend.pageCalls == [one] })

        rig.store.back()
        await gate.open()
        await rig.letLateWorkLand()

        #expect(rig.store.pageState(one) == .idle)
    }

    // MARK: - A flap while signed out

    @Test("a flap of the network while signed out keeps the stored page for the sign-in to replace")
    func flapWhileSignedOut() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        await rig.script(one, title: "Live title")
        let gone = AccountFlag(true)
        rig.store.accountGone = { gone.value }
        rig.store.open(rig.collection(one))
        #expect(rig.loadedPage(one)?.title == "Road trip")

        rig.goOffline()
        rig.goOnline()
        await rig.letLateWorkLand()

        // Online again, but the account is gone: nothing is asked, and the page is still waiting to be replaced.
        #expect(await rig.backend.pageCalls.isEmpty)
        #expect(rig.loadedPage(one)?.title == "Road trip")

        gone.value = false
        rig.store.accountReturned()

        #expect(await rig.until { rig.loadedPage(one)?.title == "Live title" })
        #expect(await rig.backend.pageCalls == [one])
    }

    @Test("a flap while signed out keeps the loads that were waiting too")
    func flapWhileSignedOutKeepsWaiting() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "a")])
        let gone = AccountFlag(true)
        rig.store.accountGone = { gone.value }
        rig.store.loadHomeIfNeeded()

        rig.goOffline()
        rig.goOnline()
        await rig.letLateWorkLand()
        #expect(await rig.backend.homeCallCount == 0)

        gone.value = false
        rig.store.accountReturned()

        #expect(await rig.until { loaded(rig.store.home) })
        #expect(await rig.backend.homeCallCount == 1)
    }

    // MARK: - The first path report

    private let cut = URLError(.notConnectedToInternet)

    @Test("before the system has reported the network, a feed that fails for the network waits instead of failing")
    func unreportedHomeWaits() async {
        let rig = OfflineStoreRig(pathReported: false)
        defer { rig.cleanUp() }
        await rig.backend.setHomeError(cut)

        rig.store.loadHomeIfNeeded()
        #expect(await rig.until { await rig.backend.homeCallCount == 1 })
        await rig.letLateWorkLand()

        #expect(rig.store.home == .idle)
    }

    @Test("History, the Library lists and a page wait the same way")
    func unreportedOthersWait() async {
        let rig = OfflineStoreRig(pathReported: false)
        defer { rig.cleanUp() }
        await rig.backend.setHistoryError(cut)
        await rig.backend.setLibraryError(.playlists, cut)
        await rig.backend.setPageError("VLPLother", cut)

        rig.store.loadHistoryIfNeeded()
        rig.store.loadLibraryIfNeeded(.playlists)
        rig.store.open(rig.collection("VLPLother"))
        #expect(await rig.until {
            let history = await rig.backend.historyCallCount
            let library = await rig.backend.libraryCalls.count
            let pages = await rig.backend.pageCalls.count
            return history == 1 && library == 1 && pages == 1
        })
        await rig.letLateWorkLand()

        #expect(rig.store.history == .idle)
        #expect(rig.store.libraryState(.playlists) == .idle)
        #expect(rig.store.pageState("VLPLother") == .idle)
    }

    @Test("a view that asks again as the feed lands idle does not start a loop of requests")
    func unreportedNoLoop() async {
        let rig = OfflineStoreRig(pathReported: false)
        defer { rig.cleanUp() }
        await rig.backend.setHomeError(cut)
        rig.store.loadHomeIfNeeded()
        #expect(await rig.until { await rig.backend.homeCallCount == 1 })
        await rig.letLateWorkLand()

        // What Home's view does when the feed goes back to idle.
        rig.store.loadHomeIfNeeded()
        rig.store.loadHomeIfNeeded()
        rig.store.reloadHome()
        await rig.letLateWorkLand()

        #expect(await rig.backend.homeCallCount == 1)
    }

    @Test("a first report of an online network asks again, once, and a failure now is a failure")
    func unreportedThenOnline() async {
        let rig = OfflineStoreRig(pathReported: false)
        defer { rig.cleanUp() }
        await rig.backend.setHomeError(cut)
        rig.store.loadHomeIfNeeded()
        #expect(await rig.until { await rig.backend.homeCallCount == 1 })
        await rig.letLateWorkLand()

        rig.connectivity.report(isOnline: true)

        #expect(await rig.until { await rig.backend.homeCallCount == 2 })
        #expect(await rig.until { failed(rig.store.home) })
        await rig.letLateWorkLand()
        #expect(await rig.backend.homeCallCount == 2)
    }

    @Test("a first report of no network keeps the feed waiting, shows the offline note, and loads when it returns")
    func unreportedThenOffline() async {
        let rig = OfflineStoreRig(pathReported: false)
        defer { rig.cleanUp() }
        await rig.backend.setHomeError(cut)
        rig.store.loadHomeIfNeeded()
        #expect(await rig.until { await rig.backend.homeCallCount == 1 })
        await rig.letLateWorkLand()

        rig.connectivity.report(isOnline: false)
        await rig.letLateWorkLand()

        #expect(rig.store.home == .idle)
        #expect(rig.store.offlineNote(for: .home) == MusicOfflineCopy.note)
        #expect(await rig.backend.homeCallCount == 1)

        await rig.backend.setHomeError(nil)
        await rig.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "a")])
        rig.goOnline()

        #expect(await rig.until { loaded(rig.store.home) })
        #expect(await rig.backend.homeCallCount == 2)
    }

    @Test("a failure that is not the network is a failure at once, reported or not")
    func unreportedOtherFailure() async {
        let rig = OfflineStoreRig(pathReported: false)
        defer { rig.cleanUp() }
        await rig.backend.setHomeError(URLError(.badServerResponse))

        rig.store.loadHomeIfNeeded()

        #expect(await rig.until { failed(rig.store.home) })
    }

    @Test("a feed that loads before the first report is not touched by it")
    func unreportedSuccess() async {
        let rig = OfflineStoreRig(pathReported: false)
        defer { rig.cleanUp() }
        await rig.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "a")])
        rig.store.loadHomeIfNeeded()
        #expect(await rig.until { loaded(rig.store.home) })

        rig.connectivity.report(isOnline: true)
        await rig.letLateWorkLand()

        #expect(await rig.backend.homeCallCount == 1)
    }

    // MARK: - Signed out is not offline

    @Test("the network down says offline; the account gone with the network up says signed out")
    func notesSplit() {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        let gone = AccountFlag(false)
        rig.store.accountGone = { gone.value }
        #expect(rig.store.offlineNote(for: .home) == nil)
        #expect(!rig.store.offersSignIn)

        gone.value = true
        #expect(rig.store.offlineNote(for: .home) == MusicOfflineCopy.signedOutNote)
        #expect(rig.store.offlineNote(for: .history) == MusicOfflineCopy.signedOutNote)
        #expect(rig.store.offersSignIn)

        rig.goOffline()
        #expect(rig.store.offlineNote(for: .home) == MusicOfflineCopy.note)
        #expect(rig.store.offlineNote(for: .history) == MusicOfflineCopy.note)
        // No sign-in window can load with no network.
        #expect(!rig.store.offersSignIn)

        gone.value = false
        #expect(rig.store.offlineNote(for: .home) == MusicOfflineCopy.note)
        #expect(!rig.store.offersSignIn)
    }

    @Test("a page that cannot load signed out says signed out, and one that is shown says nothing")
    func signedOutPageNote() async {
        let rig = OfflineStoreRig()
        defer { rig.cleanUp() }
        await rig.downloadCollection(one, tracks: DownloadSamples.tracks(1...2), title: "Road trip")
        let gone = AccountFlag(true)
        rig.store.accountGone = { gone.value }

        rig.store.open(rig.collection("VLPLother"))
        rig.store.open(rig.collection(one))

        #expect(rig.store.offlineNote(for: .page("VLPLother")) == MusicOfflineCopy.signedOutNote)
        #expect(rig.store.offlineNote(for: .page(one)) == nil)
        #expect(await rig.backend.pageCalls.isEmpty)
    }

    @Test("the signed-out line is the owner's kind of copy: short, plain, and pointing at Library")
    func signedOutCopy() {
        #expect(MusicOfflineCopy.signedOutNote == "You're signed out. Your downloads are in Library.")
        #expect(MusicOfflineCopy.signInButton == "Sign in")
        #expect(!MusicOfflineCopy.signedOutNote.contains("\u{2014}"))
        #expect(MusicOfflineCopy.signedOutNote != MusicOfflineCopy.note)
    }
}

