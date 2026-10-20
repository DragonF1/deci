// DeciTests/Music/MusicSearchNavigationActionsTests.swift
// The song actions through the Music tab's navigation: Go to album and Go to artist open a page the way an artist
// opens (with Back returning to the results), the picker is a panel like Up next and Lyrics, and the other actions
// reach the actions store.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct ActionNavHarness {
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

    var path: [String] { service.browse.path.map(\.browseId) }

    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func search(_ query: String, songs: [Deci.MusicTrack]) async {
        await backend.setSearch(query, results: songs)
        await backend.setArtistSearch(query, results: [])
        service.query = query
        nav.submit()
        await service.searchTask?.value
    }

    func playSomething() { service.play(MusicSamples.track("playing")) }

    func loadLyricsTrack() { service.lyrics.trackChanged(MusicSamples.track("playing"), duration: 200) }

    var album: Deci.MusicTrack {
        var track = Deci.MusicTrack(videoId: "s1", title: "Song", artist: "Artist", album: "Fixture Album", durationSeconds: 200, thumbnailURL: nil)
        track.albumBrowseId = "MPREbFixture"
        return track
    }

    /// A song that credits one artist with a page.
    var credited: Deci.MusicTrack {
        var track = album
        track.artistLinks = [MusicArtistLink(name: "Fixture Artist", browseId: "UCfixtureArtist")]
        return track
    }
}

@MainActor
@Suite("MusicSearchNavigation song actions")
struct MusicSearchNavigationActionsTests {

    // MARK: - Go to album

    @Test("Go to album from search results opens the album over them, and Back returns to the results")
    func albumFromResultsAndBack() async {
        let h = ActionNavHarness()
        await h.search("q", songs: [h.album])
        #expect(h.nav.showsResults)

        h.nav.perform(.goToAlbum, for: h.album, in: .none)

        #expect(h.path == ["MPREbFixture"])
        #expect(h.service.browse.path.last?.kind == .album)
        #expect(h.service.browse.path.last?.title == "Fixture Album")
        #expect(h.nav.showsResults == false)
        #expect(h.nav.hidesResults)
        #expect(h.nav.isBrowsing)

        h.service.browse.back()
        #expect(h.nav.showsResults)
        #expect(h.service.query == "q")
        #expect(h.path.isEmpty)
    }

    @Test("Go to album from a page opens on top of it, and Back is that page again")
    func albumFromPage() {
        let h = ActionNavHarness()
        h.service.browse.open(MusicSamples.collection("VLPLfixtureMine"))
        h.nav.perform(.goToAlbum, for: h.album, in: MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true))
        #expect(h.path == ["VLPLfixtureMine", "MPREbFixture"])
        h.service.browse.back()
        #expect(h.path == ["VLPLfixtureMine"])
    }

    @Test("Go to album from Up next closes the queue so the album is not hidden behind it")
    func albumFromQueue() {
        let h = ActionNavHarness()
        h.playSomething()
        h.nav.toggleQueue()
        #expect(h.nav.showsQueue)
        h.nav.perform(.goToAlbum, for: h.album, in: .none)
        #expect(h.nav.showsQueue == false)
        #expect(h.path == ["MPREbFixture"])
    }

    @Test("Go to album from Lyrics closes the lyrics panel")
    func albumFromLyrics() {
        let h = ActionNavHarness()
        h.loadLyricsTrack()
        h.nav.toggleLyrics()
        #expect(h.nav.showsLyrics)
        h.nav.perform(.goToAlbum, for: h.album, in: .none)
        #expect(h.nav.showsLyrics == false)
        #expect(h.path == ["MPREbFixture"])
    }

    @Test("Opening the same album twice does not push it twice")
    func albumTwice() {
        let h = ActionNavHarness()
        h.nav.perform(.goToAlbum, for: h.album, in: .none)
        h.nav.perform(.goToAlbum, for: h.album, in: .none)
        #expect(h.path == ["MPREbFixture"])
    }

    @Test("Go to album for a song with no album id does nothing")
    func albumWithoutId() {
        let h = ActionNavHarness()
        h.nav.perform(.goToAlbum, for: MusicSamples.track("s1"), in: .none)
        #expect(h.path.isEmpty)
    }

    // MARK: - Go to artist

    @Test("Go to artist from search results opens the artist over them, and Back returns to the results")
    func artistFromResultsAndBack() async {
        let h = ActionNavHarness()
        await h.search("q", songs: [h.credited])
        h.nav.perform(.goToArtist, for: h.credited, in: .none)

        #expect(h.path == ["UCfixtureArtist"])
        #expect(h.service.browse.path.last?.kind == .artist)
        #expect(h.service.browse.path.last?.title == "Fixture Artist")
        #expect(h.nav.showsResults == false)

        h.service.browse.back()
        #expect(h.nav.showsResults)
        #expect(h.path.isEmpty)
    }

    @Test("Go to artist from Up next closes the queue so the page is not hidden behind it")
    func artistFromQueue() {
        let h = ActionNavHarness()
        h.playSomething()
        h.nav.toggleQueue()
        h.nav.perform(.goToArtist, for: h.credited, in: .none)
        #expect(h.nav.showsQueue == false)
        #expect(h.path == ["UCfixtureArtist"])
    }

    @Test("Go to artist for a song with no artist link, or on that artist's own page, does nothing")
    func artistWithoutLinkOrOnOwnPage() {
        let h = ActionNavHarness()
        h.nav.perform(.goToArtist, for: h.album, in: .none)
        #expect(h.path.isEmpty)
        let own = MusicTrackContext(pageBrowseId: "UCfixtureArtist", pageTitle: "Fixture Artist", pageIsEditable: false)
        h.nav.perform(.goToArtist, for: h.credited, in: own)
        #expect(h.path.isEmpty)
    }

    @Test("openCollection opens any collection the way openArtist does, and openArtist still works")
    func openCollectionGeneral() async {
        let h = ActionNavHarness()
        await h.search("q", songs: [MusicSamples.track("s1")])
        h.nav.openCollection(MusicSamples.collection("MPREbOther", kind: .album, title: "Other"))
        #expect(h.path == ["MPREbOther"])
        #expect(h.nav.hidesResults)
        h.nav.openArtist(MusicSamples.collection("UCa", kind: .artist, title: "Artist"))
        #expect(h.path == ["MPREbOther", "UCa"])
        h.service.browse.back()
        #expect(h.nav.showsResults == false)
        h.service.browse.back()
        #expect(h.nav.showsResults)
    }

    @Test("An album opened from the results while a page is already open under them returns to the results")
    func albumFromResultsOverPage() async {
        let h = ActionNavHarness()
        h.service.browse.open(MusicSamples.collection("VLunder"))
        await h.search("q", songs: [h.album])
        h.nav.perform(.goToAlbum, for: h.album, in: .none)
        #expect(h.path == ["VLunder", "MPREbFixture"])
        h.service.browse.back()
        #expect(h.nav.showsResults)
        #expect(h.path == ["VLunder"])
    }

    // MARK: - Picker panel

    @Test("Save to playlist opens the picker over whatever shows, and it is not browsing then")
    func pickerOpens() async {
        let h = ActionNavHarness()
        #expect(h.nav.showsPicker == false)
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        #expect(h.nav.showsPicker)
        #expect(h.nav.isBrowsing == false)
        #expect(h.service.trackActions.picker?.track == h.album)
        #expect(await h.until { await h.backend.playlistOptionsCalls == ["s1"] })
    }

    @Test("Closing the picker goes back to what was under it")
    func pickerCloses() async {
        let h = ActionNavHarness()
        await h.search("q", songs: [h.album])
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        #expect(h.nav.showsPicker)
        h.nav.closePicker()
        #expect(h.nav.showsPicker == false)
        #expect(h.nav.showsResults)
        #expect(h.nav.isBrowsing == false)
    }

    @Test("Opening the picker closes Up next and Lyrics, which would sit on top of it")
    func pickerClosesOtherPanels() {
        let h = ActionNavHarness()
        h.playSomething()
        h.nav.toggleQueue()
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        #expect(h.nav.showsQueue == false)
        #expect(h.nav.showsPicker)

        h.nav.closePicker()
        h.loadLyricsTrack()
        h.nav.toggleLyrics()
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        #expect(h.nav.showsLyrics == false)
        #expect(h.nav.showsPicker)
    }

    @Test("Up next and Lyrics close the picker when they are turned on")
    func panelsClosePicker() {
        let h = ActionNavHarness()
        h.playSomething()
        h.loadLyricsTrack()
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        h.nav.toggleQueue()
        #expect(h.nav.showsPicker == false)
        #expect(h.nav.showsQueue)

        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        #expect(h.nav.showsQueue == false)
        h.nav.toggleLyrics()
        #expect(h.nav.showsPicker == false)
        #expect(h.nav.showsLyrics)
    }

    @Test("Home and Library, a new search and an edited query all close the picker")
    func browsingClosesPicker() async {
        let h = ActionNavHarness()
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        h.nav.select(.library)
        #expect(h.nav.showsPicker == false)

        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        h.service.query = "x"
        h.nav.queryChanged()
        #expect(h.nav.showsPicker == false)

        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        await h.search("q", songs: [h.album])
        #expect(h.nav.showsPicker == false)
    }

    @Test("Picking a playlist closes the picker, and the saved line stays for the view to show")
    func pickClosesPanel() async {
        let h = ActionNavHarness()
        await h.backend.setPlaylistOptions(videoId: "s1", [MusicSamples.playlistOption("PLone", title: "Road Trip")])
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        #expect(await h.until { if case .loaded? = h.service.trackActions.picker?.load { true } else { false } })
        h.service.trackActions.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.nav.showsPicker == false })
        #expect(h.service.trackActions.notice?.text == "Saved to Road Trip")
    }

    // MARK: - Remove and pin

    @Test("Remove from playlist reaches the store and takes the row off the page")
    func performRemove() async {
        let h = ActionNavHarness()
        let row = MusicSamples.track("a", setVideoId: "s1")
        await h.backend.setPage(MusicSamples.page("VLPLfixtureMine", tracks: [row, MusicSamples.track("b", setVideoId: "s2")], title: "Mine", isEditable: true))
        h.service.browse.open(MusicSamples.collection("VLPLfixtureMine", title: "Mine"))
        #expect(await h.until { if case .loaded = h.service.browse.pageState("VLPLfixtureMine") { true } else { false } })

        h.nav.perform(.removeFromPlaylist, for: row, in: MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true))

        #expect(await h.until {
            if case .loaded(let page) = h.service.browse.pageState("VLPLfixtureMine") { page.tracks.map(\.videoId) == ["b"] } else { false }
        })
        #expect(await h.backend.removeFromPlaylistCalls.count == 1)
    }

    @Test("Removing a row does not touch what is playing")
    func removeLeavesQueue() async {
        let h = ActionNavHarness()
        let row = MusicSamples.track("a", setVideoId: "s1")
        await h.backend.setPage(MusicSamples.page("VLPLfixtureMine", tracks: [row], title: "Mine", isEditable: true))
        h.service.browse.open(MusicSamples.collection("VLPLfixtureMine", title: "Mine"))
        #expect(await h.until { if case .loaded = h.service.browse.pageState("VLPLfixtureMine") { true } else { false } })
        h.service.play(row)
        let queued = h.service.queue.tracks.map(\.videoId)

        h.nav.perform(.removeFromPlaylist, for: row, in: MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true))
        #expect(await h.until { await h.backend.removeFromPlaylistCalls.count == 1 })
        #expect(h.service.queue.tracks.map(\.videoId) == queued)
    }

    @Test("Pin and Unpin reach the store")
    func performPin() async {
        let h = ActionNavHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        h.nav.perform(.pinToListenAgain, for: track, in: .none)
        #expect(await h.until { await h.backend.feedbackTokens == ["pin-token"] })
        #expect(await h.until { h.nav.actions(for: track, in: .none).contains(.unpinFromListenAgain) })
        h.nav.perform(.unpinFromListenAgain, for: track, in: .none)
        #expect(await h.until { await h.backend.feedbackTokens == ["pin-token", "unpin-token"] })
    }

    @Test("The navigation's action list is the store's, so rows and the mini player agree")
    func actionsList() {
        let h = ActionNavHarness()
        var track = MusicSamples.track("v1", albumBrowseId: "MPREbFixture", pin: MusicSamples.pinToggle())
        track.artistLinks = [MusicArtistLink(name: "Fixture Artist", browseId: "UCfixtureArtist")]
        #expect(h.nav.actions(for: track, in: .none) == [.saveToPlaylist, .pinToListenAgain, .pinHome(.canPin), .goToAlbum, .goToArtist])
    }

    @Test("Pin to Home works on a song YouTube gave no toggle for, and the menu then offers Unpin from Home")
    func pinHomeWithoutToken() {
        let h = ActionNavHarness()
        let track = MusicSamples.track("v1")
        #expect(h.nav.actions(for: track, in: .none) == [.saveToPlaylist, .pinHome(.canPin)])

        h.nav.perform(.pinHome(.canPin), for: track, in: .none)

        #expect(h.service.pinnedItems.items.map(\.id) == ["v1"])
        #expect(h.service.pinnedItems.items.first?.kind == .song)
        #expect(h.nav.actions(for: track, in: .none) == [.saveToPlaylist, .pinHome(.pinned)])

        h.nav.perform(.pinHome(.pinned), for: track, in: .none)

        #expect(h.service.pinnedItems.isEmpty)
        #expect(h.nav.actions(for: track, in: .none) == [.saveToPlaylist, .pinHome(.canPin)])
    }

    @Test("Pin to Home never reaches the account: nothing is sent to YouTube")
    func pinHomeSendsNothing() async {
        let h = ActionNavHarness()
        h.nav.perform(.pinHome(.canPin), for: MusicSamples.track("v1", pin: MusicSamples.pinToggle()), in: .none)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await h.backend.feedbackTokens.isEmpty)
        #expect(h.service.trackActions.notice == nil)
    }

    @Test("A full Home offers the refusal on a new song, and Unpin from Home on a pinned one")
    func pinHomeWhenFull() {
        let h = ActionNavHarness()
        let pinned = MusicSamples.track("kept")
        h.nav.perform(.pinHome(.canPin), for: pinned, in: .none)
        for index in 1..<MusicPinnedItems.limit {
            h.service.pinnedItems.pin(MusicPinnedItem(kind: .artist, id: "UC\(index)", title: "Name \(index)"))
        }
        #expect(h.service.pinnedItems.isFull)
        let fresh = MusicSamples.track("v1")
        #expect(h.nav.actions(for: fresh, in: .none) == [.saveToPlaylist, .pinHome(.full)])
        #expect(h.nav.actions(for: pinned, in: .none) == [.saveToPlaylist, .pinHome(.pinned)])

        h.nav.perform(.pinHome(.full), for: fresh, in: .none)
        #expect(h.service.pinnedItems.items.count == MusicPinnedItems.limit)
        #expect(!h.service.pinnedItems.isPinned(fresh))

        h.nav.perform(.pinHome(.pinned), for: pinned, in: .none)
        #expect(!h.service.pinnedItems.isPinned(pinned))
        #expect(h.nav.actions(for: fresh, in: .none) == [.saveToPlaylist, .pinHome(.canPin)])
    }

    @Test("A Home pin and a Listen again pin of the same song are independent")
    func pinHomeAndListenAgainIndependent() async {
        let h = ActionNavHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        h.nav.perform(.pinHome(.canPin), for: track, in: .none)
        #expect(h.nav.actions(for: track, in: .none) == [.saveToPlaylist, .pinToListenAgain, .pinHome(.pinned)])

        h.nav.perform(.pinToListenAgain, for: track, in: .none)
        #expect(await h.until { h.nav.actions(for: track, in: .none).contains(.unpinFromListenAgain) })
        #expect(h.service.pinnedItems.isPinned(track))
    }

    // MARK: - Session

    @Test("Signing out closes the picker and clears the pin state")
    func signOutResets() async {
        let h = ActionNavHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        h.nav.perform(.pinToListenAgain, for: track, in: .none)
        #expect(await h.until { h.nav.actions(for: track, in: .none).contains(.unpinFromListenAgain) })
        h.nav.perform(.saveToPlaylist, for: track, in: .none)
        #expect(h.nav.showsPicker)

        h.service.signOut()

        #expect(h.nav.showsPicker == false)
        #expect(h.service.trackActions.notice == nil)
        #expect(h.nav.actions(for: track, in: .none).contains(.pinToListenAgain))
    }

    @Test("A write that finds the session gone signs the service out")
    func expiredSignsOut() async {
        let h = ActionNavHarness()
        await h.backend.setFeedbackError(MusicError.signedOut)
        h.nav.perform(.pinToListenAgain, for: MusicSamples.track("v1", pin: MusicSamples.pinToggle()), in: .none)
        #expect(await h.until { h.service.authState == .signedOut })
        #expect(h.service.trackActions.picker == nil)
    }
}
