// DeciTests/Music/MusicShelfMoreTests.swift
// What a shelf's "Show all" opens (MusicShelfMore) and how the store loads a full list of a shelf.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicShelfMore")
struct MusicShelfMoreTests {
    private func shelf(_ title: String, more: MusicDiscographyLink?, items: [MusicShelfItem]? = nil) -> MusicShelf {
        MusicShelf(title: title, items: items ?? [.collection(MusicSamples.collection("VLPL1")), .collection(MusicSamples.collection("VLPL2"))], more: more)
    }

    private let song = MusicShelfItem.track(MusicSamples.track("v1"))

    @Test("The link reads Show all, as the Top songs one does")
    func linkTitle() {
        #expect(MusicShelfMore.linkTitle == "Show all")
    }

    @Test("A shelf with no more link has no Show all")
    func noLink() {
        #expect(MusicShelfMore.opener(for: shelf("Featured on", more: nil)) == nil)
    }

    @Test("A playlist more link (Videos) opens that playlist as a page, whatever the shelf holds")
    func playlistLink() throws {
        let link = MusicDiscographyLink(browseId: "VLOLAK5uy_videos", params: "ggMCCAI%3D")
        let opener = try #require(MusicShelfMore.opener(for: shelf("Videos", more: link, items: [song])))
        #expect(opener.browseId == "VLOLAK5uy_videos")
        #expect(opener.kind == .playlist)
        #expect(opener.title == "Videos")
        #expect(opener.shelfList == nil)
    }

    @Test("A discography link on a shelf of albums opens the full list, carrying the link and the shelf title")
    func discographyLink() throws {
        let link = MusicDiscographyLink(browseId: "MPADUC1", params: "P1")
        let opener = try #require(MusicShelfMore.opener(for: shelf("Albums", more: link)))
        #expect(opener.shelfList == link)
        #expect(opener.title == "Albums")
    }

    @Test("A channel id with params on a shelf of playlists opens the full list")
    func channelLink() throws {
        let link = MusicDiscographyLink(browseId: "UC1", params: "6gPx")
        let opener = try #require(MusicShelfMore.opener(for: shelf("Playlists by Someone", more: link)))
        #expect(opener.shelfList == link)
    }

    @Test("A shelf of songs or videos behind a channel link (Live performances) has no Show all, and nor does a mixed one")
    func tracksHaveNoFullList() {
        let link = MusicDiscographyLink(browseId: "UC1", params: "6gPx")
        #expect(MusicShelfMore.opener(for: shelf("Live performances", more: link, items: [song, song])) == nil)
        #expect(MusicShelfMore.opener(for: shelf("Mixed", more: link, items: [song, .collection(MusicSamples.collection("VLPL1"))])) == nil)
    }

    @Test("An empty shelf has no Show all")
    func emptyShelf() {
        #expect(MusicShelfMore.opener(for: shelf("Albums", more: MusicDiscographyLink(browseId: "MPADUC1", params: "P"), items: [])) == nil)
    }

    @Test("Each list of one artist has its own id, so Albums and Singles never share a page or a double-tap guard")
    func listIdsAreDistinct() {
        let albums = MusicCollection.shelfList(title: "Albums", link: MusicDiscographyLink(browseId: "MPADUC1", params: "A"))
        let singles = MusicCollection.shelfList(title: "Singles", link: MusicDiscographyLink(browseId: "MPADUC1", params: "S"))
        let noParams = MusicCollection.shelfList(title: "Albums", link: MusicDiscographyLink(browseId: "MPADUC1", params: nil))
        #expect(albums.browseId != singles.browseId)
        #expect(albums.browseId != noParams.browseId)
        #expect(albums.browseId == MusicCollection.shelfList(title: "Albums", link: MusicDiscographyLink(browseId: "MPADUC1", params: "A")).browseId)
    }

    @Test("A list route is never mistaken for a downloadable or pinnable page id")
    func listIdIsNoPageId() {
        let list = MusicCollection.shelfList(title: "Albums", link: MusicDiscographyLink(browseId: "MPADUC1", params: "A"))
        #expect(!MusicDownloadPage.canDownload(browseId: list.browseId))
        #expect(!list.browseId.hasPrefix("VL") && !list.browseId.hasPrefix("MPRE") && !list.browseId.hasPrefix("UC"))
    }

    // MARK: - Fix round: page kind, scope, track context, titles

    @Test("A list route resolves to the shelf list page kind, whatever kind the route carries")
    func listPageKind() {
        let list = MusicCollection.shelfList(title: "Albums", link: MusicDiscographyLink(browseId: "MPADUC1", params: "A"))
        #expect(MusicPageKind.resolve(kind: list.kind, browseId: list.browseId) == .shelfList)
        #expect(MusicPageKind.resolve(kind: .playlist, browseId: "VLPL1") == .playlist)
    }

    @Test("The list page kind searches YouTube Music like Home, lays rows as a playlist and has a plain header")
    func listPageKindPlumbing() {
        #expect(MusicSearchScope.resolve(column: .browse, tab: .library, page: .shelfList) == .global)
        #expect(MusicSearchScope.global.placeholder == "Search YouTube Music")
        #expect(MusicPageKind.shelfList.rowLayout(at: 0) == MusicPageKind.playlist.rowLayout(at: 0))
        #expect(!MusicPageKind.shelfList.isRound)
        let text = MusicPageHeroText.resolve(
            kind: .shelfList, title: "Albums", subtitle: nil, firstArtist: nil, isEditable: false,
            songCount: nil, totalSeconds: nil, albumCount: nil
        )
        #expect(text.title == "Albums")
    }

    @Test("A list's tiles take the artist below it on the path as their page, so Go to artist on that artist's own list does not push it again")
    func listTrackContext() {
        let artist = MusicSamples.collection("UCartist", kind: .artist, title: "Artist")
        let list = MusicCollection.shelfList(title: "Albums", link: MusicDiscographyLink(browseId: "MPADUCartist", params: "A"))
        let context = MusicShelfMore.trackContext(for: list, path: [artist, list])
        #expect(context.pageBrowseId == "UCartist")
        #expect(context.pageTitle == "Artist")
        #expect(!context.pageIsEditable)
    }

    @Test("A list with no page below it, or only lists below it, has no page context")
    func listTrackContextWithoutParent() {
        let list = MusicCollection.shelfList(title: "Albums", link: MusicDiscographyLink(browseId: "MPADUC1", params: "A"))
        let other = MusicCollection.shelfList(title: "Singles", link: MusicDiscographyLink(browseId: "MPADUC1", params: "S"))
        #expect(MusicShelfMore.trackContext(for: list, path: [list]) == .none)
        #expect(MusicShelfMore.trackContext(for: list, path: [other, list]) == .none)
        #expect(MusicShelfMore.trackContext(for: list, path: []) == .none)
    }

    @Test("Through an album between two lists, the context is the album's parent below the list that is on top")
    func listTrackContextSkipsLists() {
        let artist = MusicSamples.collection("UCartist", kind: .artist, title: "Artist")
        let list = MusicCollection.shelfList(title: "Albums", link: MusicDiscographyLink(browseId: "MPADUCartist", params: "A"))
        #expect(MusicShelfMore.trackContext(for: list, path: [artist, list, list]).pageBrowseId == "UCartist")
    }

    @Test("A Videos opener only borrows the shelf title: the loaded page's own title is the Back label, and the shelf title stands until then")
    func videosBackLabel() throws {
        let opener = try #require(MusicShelfMore.opener(for: MusicShelf(
            title: "Videos", items: [.track(MusicSamples.track("v1"))], more: MusicDiscographyLink(browseId: "VLOLAK5uy_v", params: "ggMCCAI%3D")
        )))
        #expect(MusicPageBackLabel.title(of: opener, loaded: "Taylor Swift - Videos") == "Taylor Swift - Videos")
        #expect(MusicPageBackLabel.title(of: opener, loaded: nil) == "Videos")
        #expect(MusicPageBackLabel.title(of: opener, loaded: "  ") == "Videos")
        // The page header already shows the page's own title.
        #expect(MusicPageHeroText.shownTitle(pageTitle: "Taylor Swift - Videos", opener: opener) == "Taylor Swift - Videos")
    }

    @Test("Every other opener keeps its own title as the Back label")
    func otherBackLabels() {
        let album = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        #expect(MusicPageBackLabel.title(of: album, loaded: "Something else") == "Album")
        let list = MusicCollection.shelfList(title: "Albums", link: MusicDiscographyLink(browseId: "MPADUC1", params: "A"))
        #expect(MusicPageBackLabel.title(of: list, loaded: "Albums") == "Albums")
    }
}

@MainActor
@Suite("MusicBrowseStore shelf lists")
struct MusicBrowseStoreShelfListTests {
    private let backend = FakeMusicBackend()
    private let store: MusicBrowseStore
    private let probe = ExpiryCounter()
    private let link = MusicDiscographyLink(browseId: "UCartist", params: "6gPparams")

    init() {
        store = MusicBrowseStore(backend: backend)
        let probe = self.probe
        store.onSessionExpired = { probe.count += 1 }
    }

    private var route: MusicCollection { .shelfList(title: "Playlists by Artist", link: link) }

    private func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func loaded(_ browseId: String) -> MusicBrowsePage? {
        if case .loaded(let page) = store.pageState(browseId) { page } else { nil }
    }

    private func items(_ page: MusicBrowsePage?) -> [String] {
        (page?.shelves.first?.items ?? []).map { item in
            if case .collection(let collection) = item { collection.browseId } else { "?" }
        }
    }

    @Test("Opening a list pushes it, loads every item through the more link, and shows them in the shelf's order")
    func opensAndLoads() async {
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1", "VLPL2", "VLPL3"))
        let gate = MusicTestGate()
        await backend.setDiscographyGate(browseId: "UCartist", params: "6gPparams", gate)
        store.open(route)
        #expect(store.path == [route])
        #expect(await until { store.pageState(route.browseId) == .loading })
        await gate.open()
        #expect(await until { loaded(route.browseId) != nil })
        #expect(items(loaded(route.browseId)) == ["VLPL1", "VLPL2", "VLPL3"])
        #expect(loaded(route.browseId)?.title == "Playlists by Artist")
        #expect(loaded(route.browseId)?.shelves.first?.title == "Playlists by Artist")
        #expect(await backend.discographyCalls == [FakeMusicBackend.DiscographyCall(browseId: "UCartist", params: "6gPparams")])
        // It is a list, not a page of YouTube Music: no page request went out.
        #expect(await backend.pageCalls.isEmpty)
    }

    @Test("A double tap pushes the list once and asks once")
    func doubleOpen() async {
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1"))
        store.open(route)
        store.open(route)
        #expect(await until { loaded(route.browseId) != nil })
        #expect(store.path.count == 1)
        #expect(await backend.discographyCalls.count == 1)
    }

    @Test("A list that comes back empty is loaded and empty, so the page can say so")
    func emptyList() async {
        store.open(route)
        #expect(await until { loaded(route.browseId) != nil })
        #expect(items(loaded(route.browseId)).isEmpty)
    }

    @Test("A failed load shows failed, and a retry asks again and lands")
    func failureAndRetry() async {
        await backend.setDiscographyError(browseId: "UCartist", params: "6gPparams", MusicError.http(500))
        store.open(route)
        #expect(await until { if case .failed = store.pageState(route.browseId) { true } else { false } })
        await backend.setDiscographyError(browseId: "UCartist", params: "6gPparams", nil)
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL9"))
        store.reloadPage(route.browseId)
        #expect(await until { loaded(route.browseId) != nil })
        #expect(items(loaded(route.browseId)) == ["VLPL9"])
        #expect(await backend.discographyCalls.count == 2)
    }

    @Test("A signed-out answer tells the service the session is gone")
    func signedOut() async {
        await backend.setDiscographyError(browseId: "UCartist", params: "6gPparams", MusicError.signedOut)
        store.open(route)
        #expect(await until { probe.count == 1 })
    }

    @Test("Back drops the list, and opening it again loads it fresh")
    func backDrops() async {
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1"))
        store.open(route)
        #expect(await until { loaded(route.browseId) != nil })
        store.back()
        #expect(store.path.isEmpty)
        #expect(store.pageState(route.browseId) == .idle)
        store.open(route)
        #expect(await until { loaded(route.browseId) != nil })
        #expect(await backend.discographyCalls.count == 2)
    }

    @Test("A list opens a normal page on top of it, and Back lands on the list again with its items kept")
    func pageOnTopOfList() async {
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1"))
        await backend.setPage(MusicSamples.page("VLPL1", title: "One"))
        store.open(route)
        #expect(await until { loaded(route.browseId) != nil })
        store.open(MusicSamples.collection("VLPL1"))
        #expect(await until { loaded("VLPL1") != nil })
        #expect(store.path.map(\.browseId) == [route.browseId, "VLPL1"])
        store.back()
        #expect(store.path == [route])
        #expect(items(loaded(route.browseId)) == ["VLPL1"])
    }

    @Test("Two lists of one artist keep separate state")
    func separateLists() async {
        let other = MusicCollection.shelfList(title: "Singles", link: MusicDiscographyLink(browseId: "UCartist", params: "other"))
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1"))
        await backend.setDiscography(browseId: "UCartist", params: "other", MusicSamples.collections("VLPL2"))
        store.open(route)
        #expect(await until { loaded(route.browseId) != nil })
        store.open(other)
        #expect(await until { loaded(other.browseId) != nil })
        #expect(items(loaded(route.browseId)) == ["VLPL1"])
        #expect(items(loaded(other.browseId)) == ["VLPL2"])
    }

    @Test("Opening a playlist from a Videos link is the ordinary page load")
    func videosOpenAsPlaylist() async {
        let videos = MusicShelfMore.opener(for: MusicShelf(
            title: "Videos", items: [.track(MusicSamples.track("v1"))], more: MusicDiscographyLink(browseId: "VLOLAK5uy_v", params: "ggMCCAI%3D")
        ))
        await backend.setPage(MusicSamples.page("VLOLAK5uy_v", title: "Videos"))
        guard let videos else { Issue.record("no opener"); return }
        store.open(videos)
        #expect(await until { loaded("VLOLAK5uy_v") != nil })
        #expect(await backend.discographyCalls.isEmpty)
    }

    // MARK: - Fix round

    @Test("A repeated id across pages lands once, in the order it first appeared")
    func repeatedIdsLandOnce() async {
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1", "VLPL2", "VLPL1", "VLPL3", "VLPL2"))
        store.open(route)
        #expect(await until { loaded(route.browseId) != nil })
        #expect(items(loaded(route.browseId)) == ["VLPL1", "VLPL2", "VLPL3"])
    }

    @Test("A failed continuation shows the failed card, and Retry loads the whole list")
    func partialListFails() async {
        await backend.setDiscographyError(browseId: "UCartist", params: "6gPparams", MusicError.http(503))
        store.open(route)
        #expect(await until { if case .failed = store.pageState(route.browseId) { true } else { false } })
        #expect(loaded(route.browseId) == nil)
    }

    @Test("The route is registered on open, and cleared on Back, on pop to root and on reset")
    func registry() async {
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1"))
        store.open(route)
        #expect(store.shelfLists[route.browseId] == link)
        store.back()
        #expect(store.shelfLists[route.browseId] == nil)
        store.open(route)
        store.popToRoot()
        #expect(store.shelfLists.isEmpty)
        store.open(route)
        store.reset()
        #expect(store.shelfLists.isEmpty)
    }

    @Test("A list id is never sent to the page call, even when the route is gone from the path")
    func listIdNeverReachesPageCall() async {
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1"))
        store.open(route)
        #expect(await until { loaded(route.browseId) != nil })
        store.back()
        store.reloadPage(route.browseId)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await backend.pageCalls.isEmpty)
        #expect(await backend.discographyCalls.count == 1)
        #expect(store.pageState(route.browseId) == .idle)
    }

    @Test("Back while the load is gated, then opening the list again: the old load never lands")
    func staleLoadAfterBackAndReopen() async {
        let gate = MusicTestGate()
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLOLD"))
        await backend.setDiscographyGate(browseId: "UCartist", params: "6gPparams", gate)
        store.open(route)
        #expect(await until { await backend.discographyCalls.count == 1 })
        store.back()
        await backend.setDiscographyGate(browseId: "UCartist", params: "6gPparams", nil)
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLNEW"))
        store.open(route)
        #expect(await until { loaded(route.browseId) != nil })
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(items(loaded(route.browseId)) == ["VLNEW"])
    }

    @Test("A reload while the first load is in flight: the second result wins even when the first finishes last")
    func reloadWhileLoading() async {
        let gate = MusicTestGate()
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLFIRST"))
        await backend.setDiscographyGate(browseId: "UCartist", params: "6gPparams", gate)
        store.open(route)
        #expect(await until { await backend.discographyCalls.count == 1 })
        await backend.setDiscographyGate(browseId: "UCartist", params: "6gPparams", nil)
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLSECOND"))
        store.reloadPage(route.browseId)
        #expect(await until { loaded(route.browseId) != nil })
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(items(loaded(route.browseId)) == ["VLSECOND"])
    }

    @Test("Offline the list waits with no call, and loads when the network returns")
    func offlineWaitsAndReplays() async {
        let connectivity = MusicConnectivity(isOnline: true, reported: true)
        let store = MusicBrowseStore(backend: backend, connectivity: connectivity)
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1"))
        connectivity.update(isOnline: false)
        store.open(route)
        #expect(store.offlineNote(for: .page(route.browseId)) != nil)
        #expect(store.shelfLists[route.browseId] == link)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.discographyCalls.isEmpty)
        #expect(await backend.pageCalls.isEmpty)
        connectivity.update(isOnline: true)
        #expect(await until {
            if case .loaded = store.pageState(route.browseId) { true } else { false }
        })
        #expect(await backend.discographyCalls.count == 1)
        #expect(await backend.pageCalls.isEmpty)
    }

    @Test("The same list twice on the path, then Back once: the list under it keeps its state")
    func sameListTwice() async {
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1"))
        await backend.setPage(MusicSamples.page("VLPL1", title: "One"))
        store.open(route)
        #expect(await until { loaded(route.browseId) != nil })
        store.open(MusicSamples.collection("VLPL1"))
        #expect(await until { loaded("VLPL1") != nil })
        store.open(route)
        #expect(store.path.map(\.browseId) == [route.browseId, "VLPL1", route.browseId])
        store.back()
        #expect(store.path.map(\.browseId) == [route.browseId, "VLPL1"])
        #expect(items(loaded(route.browseId)) == ["VLPL1"])
        #expect(store.shelfLists[route.browseId] == link)
    }

    @Test("A reset during a load: the late result lands nowhere, and the list is idle with no route kept")
    func resetDuringLoad() async {
        let gate = MusicTestGate()
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1"))
        await backend.setDiscographyGate(browseId: "UCartist", params: "6gPparams", gate)
        store.open(route)
        #expect(await until { await backend.discographyCalls.count == 1 })
        store.reset()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(store.pageState(route.browseId) == .idle)
        #expect(store.path.isEmpty)
        #expect(store.shelfLists.isEmpty)
    }

    @Test("A double tap while the load is in flight pushes once and asks once, and a tap on a loaded list asks nothing")
    func doubleOpenInFlightAndLoaded() async {
        let gate = MusicTestGate()
        await backend.setDiscography(browseId: "UCartist", params: "6gPparams", MusicSamples.collections("VLPL1"))
        await backend.setDiscographyGate(browseId: "UCartist", params: "6gPparams", gate)
        store.open(route)
        #expect(await until { await backend.discographyCalls.count == 1 })
        store.open(route)
        #expect(store.path.count == 1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.discographyCalls.count == 1)
        await gate.open()
        #expect(await until { loaded(route.browseId) != nil })
        store.open(route)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(store.path.count == 1)
        #expect(await backend.discographyCalls.count == 1)
    }

    @Test("A creator channel opens as an artist page: no top songs, its shelves shown, and nothing artist-only breaks")
    func creatorChannelAsPage() async throws {
        let id = "UCOxqgCwgOqC2lMqC5PYz_Dg"
        let page = try InnerTubeParser.browsePage(from: MusicFixtures.data("browse-creator-channel.json"), browseId: id)
        await backend.setPage(page)
        let channel = MusicSamples.collection(id, kind: .artist, title: "Chillhop Music")
        store.open(channel)
        #expect(await until { loaded(id) != nil })
        let shown = try #require(loaded(id))
        #expect(MusicPageKind.resolve(kind: channel.kind, browseId: id) == .artist)
        #expect(shown.tracks.isEmpty)
        #expect(shown.allSongsBrowseId == nil)
        #expect(MusicTopSongsHeader.opener(for: shown, kind: .artist) == nil)
        #expect(shown.discographyLinks.isEmpty)
        #expect(shown.shelves.map(\.title) == ["Videos", "Playlists"])
        // Only the shelf of playlists has a full list; the videos shelf holds songs.
        let openers = shown.shelves.map { MusicShelfMore.opener(for: $0) }
        #expect(openers[0] == nil)
        #expect(openers[1]?.shelfList?.browseId == id)
        // No release years to read: nothing was asked of a discography page.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.discographyCalls.isEmpty)
    }
}

@MainActor
private final class ExpiryCounter {
    var count = 0
}
