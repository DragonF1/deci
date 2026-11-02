// DeciTests/Music/MusicSelectionNavigationTests.swift
// The selection as the Music tab runs it: what the bar and the menu offer for it, what a pick does to the queue and to
// the selection, what Escape does first, and when the column moves on or the popup closes under it.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct SelectionNavHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let service: MusicService
    let nav: MusicSearchNavigation
    let host: MusicServiceHost

    init() {
        let service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: engine),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            savePreferences: { _ in },
            shuffleSeed: 1,
            queueRetryDelay: .seconds(60),
            refreshOnCreate: false
        )
        self.service = service
        host = MusicServiceHost(makeService: { service })
        host.loadIfNeeded()
        nav = host.navigation ?? MusicSearchNavigation(service: service)
    }

    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            await play?.value
            await radio?.value
            if service.playTask == play, service.radioTask == radio { break }
        }
    }

    func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    func startPage(_ ids: [String]) async {
        service.play(song(ids[0]), in: MusicSamples.page("VLPL1", tracks: ids.map { song($0) }))
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Selects `ids` of a list of `all` with Command clicks.
    func select(_ ids: [String], of all: [String], scope scopeId: String = "page:VLPL1", isUpNext: Bool = false) {
        let scope = MusicSelectionScope(id: scopeId, tracks: all.map { song($0) }, isUpNext: isUpNext)
        for id in ids { nav.selection.click(song(id), in: scope, modifiers: .command) }
    }

    var queuedIDs: [String] { service.queue.tracks.map(\.videoId) }
}

@MainActor
@Suite("Music selection through the navigation")
struct MusicSelectionNavigationTests {

    // MARK: - What is offered

    @Test("A selection offers Play next and Add to queue, and in Up next also Remove from queue")
    func offeredActions() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b", "c", "d"])
        h.select(["b", "c"], of: ["a", "b", "c", "d"])
        #expect(h.nav.queueActions == [.playNext, .addToQueue])

        h.nav.selection.clear()
        h.select(["b", "c"], of: ["b", "c", "d"], scope: "upNext", isUpNext: true)
        #expect(h.nav.queueActions == [.playNext, .addToQueue, .removeFromQueue])
    }

    @Test("The song that plays alone in a selection offers no queue entry")
    func currentSongAlone() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b"])
        h.select(["a"], of: ["a", "b"])
        #expect(h.nav.queueActions.isEmpty)
        h.select(["b"], of: ["a", "b"])
        #expect(h.nav.queueActions == [.playNext, .addToQueue])
    }

    @Test("Nothing selected offers nothing")
    func nothingSelected() {
        let h = SelectionNavHarness()
        #expect(h.nav.selectionActions.isEmpty)
    }

    // MARK: - What is offered, worked out once

    @Test("The actions are worked out once for a selection however many rows and the bar ask")
    func actionsAreKept() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b", "c", "d"])
        h.select(["b", "c"], of: ["a", "b", "c", "d"])

        let builds = h.nav.selectionActionsBuilds
        for _ in 0..<20 { _ = h.nav.selectionActions }
        #expect(h.nav.queueActions == [.playNext, .addToQueue])
        #expect(h.nav.selectionActionsBuilds - builds <= 1)

        let kept = h.nav.selectionActionsBuilds
        for _ in 0..<20 { _ = h.nav.selectionActions }
        #expect(h.nav.selectionActionsBuilds == kept)
    }

    @Test("The kept actions are worked out again when the selection changes")
    func actionsFollowSelection() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b", "c"])
        h.select(["a"], of: ["a", "b", "c"])
        #expect(h.nav.queueActions.isEmpty)
        let builds = h.nav.selectionActionsBuilds

        // "a" plays: alone it offers nothing, and with "b" it does.
        h.select(["b"], of: ["a", "b", "c"])
        #expect(h.nav.queueActions == [.playNext, .addToQueue])
        #expect(h.nav.selectionActionsBuilds == builds + 1)

        // The selection moving to Up next adds Remove from queue: same songs, other kind of list.
        h.nav.selection.clear()
        h.select(["b", "c"], of: ["b", "c"], scope: "upNext", isUpNext: true)
        #expect(h.nav.queueActions == [.playNext, .addToQueue, .removeFromQueue])
    }

    @Test("The kept actions are worked out again when the song in the player changes")
    func actionsFollowPlayingSong() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b", "c"])
        h.select(["b"], of: ["a", "b", "c"])
        #expect(h.nav.queueActions == [.playNext, .addToQueue])
        let builds = h.nav.selectionActionsBuilds

        // "b" starts to play: the one song picked is the song that plays, so nothing is on offer.
        h.service.play(h.song("b"), in: MusicSamples.page("VLPL1", tracks: ["a", "b", "c"].map { h.song($0) }))
        await h.settle()
        #expect(h.nav.queueActions.isEmpty)
        #expect(h.nav.selectionActionsBuilds > builds)
    }

    @Test("A sync that moves the selection's list into Up next gives it Remove from queue")
    func actionsFollowListKindOnSync() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b", "c"])
        h.select(["b", "c"], of: ["b", "c"], scope: "list")
        #expect(h.nav.queueActions == [.playNext, .addToQueue])

        h.nav.selection.sync(MusicSelectionScope(id: "list", tracks: ["b", "c"].map { h.song($0) }, isUpNext: true))
        #expect(h.nav.queueActions == [.playNext, .addToQueue, .removeFromQueue])
    }

    // MARK: - Picks

    @Test("Play next runs for the selected songs in list order, then the selection is gone")
    func playNextRuns() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        let all = ["x", "y", "z"]
        h.select(["z", "x"], of: all, scope: "search:q")
        h.nav.performSelection(.playNext)

        #expect(h.queuedIDs == ["a", "x", "z", "b", "c", "d", "e"])
        #expect(h.service.trackActions.notice?.text == "Playing 2 songs next")
        #expect(h.nav.selection.count == 0)
    }

    @Test("Add to queue runs for the selected songs and clears the selection")
    func addToQueueRuns() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b"])
        h.select(["x", "y"], of: ["x", "y", "z"], scope: "liked")
        h.nav.performSelection(.addToQueue)

        #expect(h.queuedIDs == ["a", "b", "x", "y"])
        #expect(h.service.trackActions.notice?.text == "Added 2 songs to queue")
        #expect(h.nav.selection.count == 0)
    }

    @Test("Remove from queue runs for the selected Up next songs and clears the selection")
    func removeFromQueueRuns() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.select(["b", "d"], of: ["b", "c", "d", "e"], scope: "upNext", isUpNext: true)
        h.nav.performSelection(.removeFromQueue)

        #expect(h.queuedIDs == ["a", "c", "e"])
        #expect(h.service.trackActions.notice?.text == "Removed 2 songs from queue")
        #expect(h.nav.selection.count == 0)
    }

    @Test("A pick the selection does not offer does nothing and leaves the selection")
    func unofferedPickIgnored() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b", "c"])
        h.select(["x", "y"], of: ["x", "y"], scope: "search:q")
        h.nav.performSelection(.removeFromQueue)

        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.nav.selection.count == 2)
    }

    @Test("A pick with nothing selected does nothing")
    func pickOnEmpty() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b"])
        h.nav.performSelection(.playNext)
        #expect(h.queuedIDs == ["a", "b"])
        #expect(h.service.trackActions.notice == nil)
    }

    // MARK: - Escape

    @Test("Escape clears a selection and says it did, and says no when there is none")
    func escapeClears() {
        let h = SelectionNavHarness()
        #expect(h.nav.escapeSelection() == false)
        h.select(["b"], of: ["a", "b"])
        #expect(h.nav.escapeSelection())
        #expect(h.nav.selection.count == 0)
        #expect(h.nav.escapeSelection() == false)
    }

    @Test("Escape clears the selection before it closes Up next, and the next Escape closes Up next")
    func escapeBeforePanel() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b", "c"])
        h.nav.toggleQueue()
        h.select(["b"], of: ["b", "c"], scope: "upNext", isUpNext: true)
        #expect(h.nav.showsQueue)

        // The popup asks the selection first, and only goes on to `escape()` when it had none.
        #expect(h.nav.escapeSelection())
        #expect(h.nav.showsQueue)
        #expect(h.nav.escapeSelection() == false)
        #expect(h.nav.escape())
        #expect(h.nav.showsQueue == false)
    }

    @Test("A tap on the song in the player at the top of Up next starts it over and clears the selection")
    func currentRowJumpClears() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b", "c", "d"])
        h.nav.toggleQueue()
        h.select(["c", "d"], of: ["b", "c", "d"], scope: "upNext", isUpNext: true)
        #expect(h.nav.selection.count == 2)
        let loads = h.engine.loads.count

        h.nav.jump(to: h.song("a"))
        await h.settle()
        #expect(h.nav.selection.count == 0)
        #expect(h.nav.selection.scopeId == nil)
        // The song still got started over.
        #expect(h.engine.loads.count == loads + 1)
        #expect(h.engine.loads.map(\.stream.videoId).last == "a")
    }

    // MARK: - Where it ends

    @Test("The selection's context moves when the column does, so a selection left behind can be dropped")
    func contextMoves() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b"])
        let start = h.nav.selectionContext

        h.nav.toggleQueue()
        let queue = h.nav.selectionContext
        #expect(queue != start)
        h.nav.toggleQueue()
        #expect(h.nav.selectionContext == start)

        h.service.browse.open(MusicSamples.collection("VLPLfixtureMine"))
        #expect(h.nav.selectionContext != start)
    }

    @Test("Search results showing or hiding moves the context")
    func contextFollowsResults() async {
        let h = SelectionNavHarness()
        let start = h.nav.selectionContext
        await h.backend.setSearch("q", results: [h.song("s1")])
        await h.backend.setArtistSearch("q", results: [])
        h.service.query = "q"
        h.nav.submit()
        await h.service.searchTask?.value
        #expect(h.nav.showsResults)
        #expect(h.nav.selectionContext != start)
    }

    @Test("The context moves with the tab and with the Library segment")
    func contextFollowsTabAndSegment() {
        let h = SelectionNavHarness()
        let home = h.nav.selectionContext
        h.service.browse.tab = .library
        let library = h.nav.selectionContext
        #expect(library != home)

        h.service.browse.librarySection = .albums
        #expect(h.nav.selectionContext != library)
        h.service.browse.librarySection = .playlists
        #expect(h.nav.selectionContext == library)
    }

    @Test("The context moves when the Lyrics and Related panels replace the column")
    func contextFollowsPanels() async {
        let h = SelectionNavHarness()
        await h.startPage(["a", "b"])
        let start = h.nav.selectionContext

        h.nav.toggleLyrics()
        let lyrics = h.nav.selectionContext
        #expect(lyrics != start)
        h.nav.toggleQueue()
        #expect(h.nav.selectionContext != lyrics)
        #expect(h.nav.selectionContext != start)
    }

    @Test("The context moves when a page is pushed and when it is popped")
    func contextFollowsPages() {
        let h = SelectionNavHarness()
        let start = h.nav.selectionContext
        h.service.browse.open(MusicSamples.collection("VLPLfixtureMine"))
        let pushed = h.nav.selectionContext
        #expect(pushed != start)
        h.service.browse.open(MusicSamples.collection("VLPLfixtureOther"))
        #expect(h.nav.selectionContext != pushed)
        h.service.browse.back()
        #expect(h.nav.selectionContext == pushed)
        h.service.browse.back()
        #expect(h.nav.selectionContext == start)
    }

    @Test("The results arriving after a search was asked, and Escape back out of them, each move the context")
    func contextFollowsSearchAndEscape() async {
        let h = SelectionNavHarness()
        let start = h.nav.selectionContext
        await h.backend.setSearch("q", results: [h.song("s1")])
        await h.backend.setArtistSearch("q", results: [])
        h.service.query = "q"
        h.nav.submit()
        let asking = h.nav.selectionContext
        #expect(asking != start)

        await h.service.searchTask?.value
        #expect(h.nav.showsResults)
        let results = h.nav.selectionContext
        #expect(results != asking)

        // Escape in the open field drops the words, and the results with them.
        h.nav.openField()
        #expect(h.nav.escape())
        #expect(h.nav.showsResults == false)
        #expect(h.nav.selectionContext != results)
    }

    @Test("The context moves when the account signs in, signs out or is being switched")
    func contextFollowsAccount() async {
        let h = SelectionNavHarness()
        let unknown = h.nav.selectionContext

        await h.service.refreshAuth()
        #expect(h.service.authState == .signedIn)
        let signedIn = h.nav.selectionContext
        #expect(signedIn != unknown)

        h.service.useAnotherAccount()
        #expect(h.service.isAddingAccount)
        let switching = h.nav.selectionContext
        #expect(switching != signedIn)

        await h.backend.setSignedIn(false)
        await h.service.refreshAuth()
        #expect(h.nav.selectionContext != switching)
    }

    @Test("Closing the popup clears the selection")
    func popupCloseClears() {
        let h = SelectionNavHarness()
        h.select(["a", "b"], of: ["a", "b", "c"])
        #expect(h.nav.selection.count == 2)

        h.host.isPopupVisible = true
        #expect(h.nav.selection.count == 2)
        h.host.isPopupVisible = false
        #expect(h.nav.selection.count == 0)
    }

    // MARK: - Offline

    @Test("Offline the queue entries need a downloaded song in the selection, and Remove from queue stays")
    func offlineOffered() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(DownloadSamples.idA))
        rig.goOffline()
        let nav = MusicSearchNavigation(service: rig.service)
        let downloaded = rig.song(DownloadSamples.idA)
        let other = rig.song("notDownloaded")

        let plain = MusicSelectionScope(id: "liked", tracks: [other, rig.song("alsoNot")], isUpNext: false)
        nav.selection.click(other, in: plain, modifiers: .command)
        #expect(nav.selectionActions.isEmpty)

        nav.selection.clear()
        let upNext = MusicSelectionScope(id: "upNext", tracks: [other, downloaded], isUpNext: true)
        nav.selection.click(other, in: upNext, modifiers: .command)
        #expect(nav.queueActions == [.removeFromQueue])

        nav.selection.click(downloaded, in: upNext, modifiers: .command)
        #expect(nav.queueActions == [.playNext, .addToQueue, .removeFromQueue])
    }
}
