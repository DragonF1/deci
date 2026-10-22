// DeciTests/Music/MusicSearchNavigationActionsTests.swift
// The song actions through the Music tab's navigation: Go to album and Go to artist open a page the way an artist
// opens (with Back returning to the results), the save menu floats over whatever shows, and the other actions
// reach the actions store. The same menu for an album, playlist or artist tile.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct ActionNavHarness {
    let backend: FakeMusicBackend
    let service: MusicService
    let nav: MusicSearchNavigation

    init(signedIn: Bool = true) {
        backend = FakeMusicBackend(signedIn: signedIn)
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

    /// An album tile with its artist and the playlist id of its songs.
    var albumTile: MusicCollection {
        MusicSamples.collection(
            "MPREbTile", kind: .album, title: "Tile Album", subtitle: "Album",
            artistLinks: [MusicArtistLink(name: "Tile Artist", browseId: "UCtileArtist")], audioPlaylistId: "OLAK5uy_tile"
        )
    }

    var playlistTile: MusicCollection { MusicSamples.collection("VLPLtile", kind: .playlist, title: "Tile Playlist") }

    var artistTile: MusicCollection { MusicSamples.collection("UCtileArtist", kind: .artist, title: "Tile Artist", subtitle: "Artist") }
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

    // MARK: - Save menu

    @Test("Save to playlist opens the save menu over whatever shows, which stays as it was")
    func pickerOpens() async {
        let h = ActionNavHarness()
        #expect(h.nav.showsPicker == false)
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        #expect(h.nav.showsPicker)
        #expect(h.nav.isBrowsing)
        #expect(h.nav.rightColumn == .browse)
        #expect(h.service.trackActions.picker?.track == h.album)
        #expect(await h.until { await h.backend.playlistOptionsCalls == ["s1"] })
    }

    @Test("Closing the save menu leaves what was under it")
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

    @Test("Opening the save menu leaves Up next and Lyrics open under it")
    func pickerKeepsOtherPanels() {
        let h = ActionNavHarness()
        h.playSomething()
        h.nav.toggleQueue()
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        #expect(h.nav.showsQueue)
        #expect(h.nav.showsPicker)

        h.nav.closePicker()
        #expect(h.nav.showsQueue)
        h.loadLyricsTrack()
        h.nav.toggleLyrics()
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        #expect(h.nav.showsLyrics)
        #expect(h.nav.showsPicker)
    }

    @Test("Up next and Lyrics close the save menu when they are turned on")
    func panelsClosePicker() {
        let h = ActionNavHarness()
        h.playSomething()
        h.loadLyricsTrack()
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        h.nav.toggleQueue()
        #expect(h.nav.showsPicker == false)
        #expect(h.nav.showsQueue)

        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        h.nav.toggleLyrics()
        #expect(h.nav.showsPicker == false)
        #expect(h.nav.showsLyrics)
    }

    @Test("Home and Library, a new search and an edited query all close the save menu")
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

    @Test("Picking a playlist keeps the save menu open for another, and the saved line shows")
    func pickKeepsMenu() async {
        let h = ActionNavHarness()
        await h.backend.setPlaylistOptions(videoId: "s1", [MusicSamples.playlistOption("PLone", title: "Road Trip")])
        h.nav.perform(.saveToPlaylist, for: h.album, in: .none)
        #expect(await h.until { if case .loaded? = h.service.trackActions.picker?.load { true } else { false } })
        h.service.trackActions.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.service.trackActions.notice?.text == "Saved to Road Trip" })
        #expect(h.nav.showsPicker)
        #expect(h.nav.escape())
        #expect(h.nav.showsPicker == false)
    }

    // MARK: - Remove and Pin to Home

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

    @Test("The navigation's action list is the rules' list with the Home pin, so rows and the mini player agree")
    func actionsList() {
        let h = ActionNavHarness()
        var track = MusicSamples.track("v1", albumBrowseId: "MPREbFixture")
        track.artistLinks = [MusicArtistLink(name: "Fixture Artist", browseId: "UCfixtureArtist")]
        #expect(
            h.nav.actions(for: track, in: .none)
                == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin), .goToAlbum, .goToArtist, .related]
        )
    }

    @Test("Pin to Home adds the song to Home, and the menu then offers Unpin from Home")
    func pinHomeAndUnpin() {
        let h = ActionNavHarness()
        let track = MusicSamples.track("v1")
        #expect(h.nav.actions(for: track, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin), .related])

        h.nav.perform(.pinHome(.canPin), for: track, in: .none)

        #expect(h.service.pinnedItems.items.map(\.id) == ["v1"])
        #expect(h.service.pinnedItems.items.first?.kind == .song)
        #expect(h.nav.actions(for: track, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.pinned), .related])

        h.nav.perform(.pinHome(.pinned), for: track, in: .none)

        #expect(h.service.pinnedItems.isEmpty)
        #expect(h.nav.actions(for: track, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin), .related])
    }

    @Test("Pin to Home never reaches the account: nothing is sent to YouTube")
    func pinHomeSendsNothing() async {
        let h = ActionNavHarness()
        h.nav.perform(.pinHome(.canPin), for: MusicSamples.track("v1"), in: .none)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
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
        #expect(h.nav.actions(for: fresh, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.full), .related])
        #expect(h.nav.actions(for: pinned, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.pinned), .related])

        h.nav.perform(.pinHome(.full), for: fresh, in: .none)
        #expect(h.service.pinnedItems.items.count == MusicPinnedItems.limit)
        #expect(!h.service.pinnedItems.isPinned(fresh))

        h.nav.perform(.pinHome(.pinned), for: pinned, in: .none)
        #expect(!h.service.pinnedItems.isPinned(pinned))
        #expect(h.nav.actions(for: fresh, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin), .related])
    }

    // MARK: - Play next, Add to queue, Remove from queue

    @Test("Play next and Add to queue sit at the top of the menu of any song but the one in the player")
    func queueEntriesExceptCurrent() {
        let h = ActionNavHarness()
        let other = MusicSamples.track("other")
        #expect(Array(h.nav.actions(for: other, in: .none).prefix(2)) == [.playNext, .addToQueue])

        h.playSomething()
        #expect(Array(h.nav.actions(for: other, in: .none).prefix(2)) == [.playNext, .addToQueue])
        let current = h.nav.actions(for: MusicSamples.track("playing"), in: .none)
        #expect(current.first == .saveToPlaylist)
        #expect(!current.contains(.playNext) && !current.contains(.addToQueue))
    }

    @Test("Remove from queue shows only on a row of Up next, last, and never for the song in the player")
    func removeEntryOnlyInUpNext() {
        let h = ActionNavHarness()
        h.playSomething()
        let other = MusicSamples.track("other")
        #expect(!h.nav.actions(for: other, in: .none).contains(.removeFromQueue))
        #expect(h.nav.actions(for: other, in: .upNext).last == .removeFromQueue)
        #expect(!h.nav.actions(for: MusicSamples.track("playing"), in: .upNext).contains(.removeFromQueue))
    }

    @Test("The picks reach the queue: Play next, Add to queue and Remove from queue, each with its line")
    func queuePicks() {
        let h = ActionNavHarness()
        h.service.play(MusicSamples.track("a"), in: MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a", "b", "c", "d", "e")))
        let queued = { h.service.queue.tracks.map(\.videoId) }

        h.nav.perform(.addToQueue, for: MusicSamples.track("x"), in: .none)
        #expect(queued() == ["a", "b", "c", "d", "e", "x"])
        #expect(h.service.trackActions.notice?.text == "Added to queue")

        h.nav.perform(.playNext, for: MusicSamples.track("y"), in: .none)
        #expect(queued() == ["a", "y", "b", "c", "d", "e", "x"])
        #expect(h.service.trackActions.notice?.text == "Playing next")

        h.nav.perform(.removeFromQueue, for: MusicSamples.track("b"), in: .upNext)
        #expect(queued() == ["a", "y", "c", "d", "e", "x"])
        #expect(h.service.trackActions.notice?.text == "Removed from queue")
    }

    // MARK: - Like and Dislike

    private func hasRateEntry(_ actions: [MusicTrackAction]) -> Bool {
        actions.contains { $0.ratingStatus != nil }
    }

    @Test("A signed-in user's menu has Like and Dislike after save and the Home pin, worded by the cached state")
    func rateEntriesInTheMenu() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        let track = MusicSamples.track("v1")
        #expect(h.nav.actions(for: track, in: .none)
            == [
                .playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin), .like(removing: false), .dislike(removing: false),
                .related,
            ])

        _ = await h.service.setLike(.like, of: track)
        #expect(likeEntries(h.nav.actions(for: track, in: .none)) == [.like(removing: true), .dislike(removing: false)])

        _ = await h.service.setLike(.dislike, of: track)
        #expect(likeEntries(h.nav.actions(for: track, in: .none)) == [.like(removing: false), .dislike(removing: true)])
    }

    @Test("Signed out, or before the session check has answered, the menu has no Like or Dislike")
    func rateEntriesHiddenWhenNotSignedIn() async {
        let unknown = ActionNavHarness()
        #expect(!hasRateEntry(unknown.nav.actions(for: MusicSamples.track("v1"), in: .none)))

        let out = ActionNavHarness(signedIn: false)
        await out.service.refreshAuth()
        #expect(!hasRateEntry(out.nav.actions(for: MusicSamples.track("v1"), in: .none)))
    }

    @Test("A song with no id has no Like or Dislike")
    func rateEntriesHiddenWithoutId() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        #expect(!hasRateEntry(h.nav.actions(for: MusicSamples.track(""), in: .none)))
    }

    @Test("Rating is offered with nothing playing, and for the song in the player too")
    func rateEntriesWithAndWithoutAPlayer() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        #expect(hasRateEntry(h.nav.actions(for: MusicSamples.track("other"), in: .none)))
        h.playSomething()
        #expect(hasRateEntry(h.nav.actions(for: MusicSamples.track("other"), in: .none)))
        #expect(hasRateEntry(h.nav.actions(for: MusicSamples.track("playing"), in: .none)))
    }

    @Test("A pick sets its own rating and the notice line stays empty: the animation, or the plain switch, is the answer", arguments: [
        (MusicTrackAction.like(removing: false), MusicLikeStatus?.none, MusicLikeStatus.like),
        (.like(removing: true), .like, .indifferent),
        (.dislike(removing: false), .none, .dislike),
        (.dislike(removing: true), .dislike, .indifferent),
        (.like(removing: false), .dislike, .like),
        (.dislike(removing: false), .like, .dislike),
    ])
    func performRate(action: MusicTrackAction, start: MusicLikeStatus?, sent: MusicLikeStatus) async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        if let start {
            await h.backend.setLikeStatus(videoId: "v1", start)
            h.service.likes.load(videoId: "v1")
            #expect(await h.until { h.service.likes.status(of: "v1") == start })
        }

        h.nav.perform(action, for: MusicSamples.track("v1"), in: .none)

        #expect(await h.until { await h.backend.rateCalls.count == 1 })
        #expect(await h.backend.rateCalls == [.init(videoId: "v1", status: sent)])
        #expect(await h.until { h.service.likes.status(of: "v1") == sent })
        // Time for a notice, were one coming.
        try? await Task.sleep(for: .milliseconds(60))
        #expect(h.service.trackActions.notice == nil)
    }

    @Test("A rating YouTube Music does not take shows as an error line, and the state goes back")
    func performRateFails() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        await h.backend.setRateError(videoId: "v1", URLError(.notConnectedToInternet))

        h.nav.perform(.like(removing: false), for: MusicSamples.track("v1"), in: .none)

        #expect(await h.until { h.service.trackActions.notice?.text == "Couldn't reach YouTube Music" })
        #expect(h.service.trackActions.notice?.isError == true)
        #expect(h.service.likes.status(of: "v1") == nil)
    }

    @Test("Disliking a song that is not playing leaves the queue and the song in the player alone")
    func performDislikeOfAnotherSong() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        h.service.play(MusicSamples.track("a"), in: MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a", "b", "c")))
        let queued = h.service.queue.tracks.map(\.videoId)
        let current = h.service.queue.current?.videoId

        h.nav.perform(.dislike(removing: false), for: MusicSamples.track("b"), in: .upNext)

        #expect(await h.until { await h.backend.rateCalls.count == 1 })
        #expect(await h.backend.rateCalls == [.init(videoId: "b", status: .dislike)])
        #expect(h.service.trackActions.notice == nil)
        #expect(h.service.queue.tracks.map(\.videoId) == queued)
        #expect(h.service.queue.current?.videoId == current)
    }

    @Test("A tile has no Like or Dislike, signed in or not, and a pick on one sends nothing")
    func tilesHaveNoRateEntries() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        for tile in [h.albumTile, h.playlistTile, h.artistTile] {
            #expect(!hasRateEntry(h.nav.actions(for: tile, in: .none)))
            h.nav.perform(.like(removing: false), for: tile, in: .none)
            h.nav.perform(.dislike(removing: false), for: tile, in: .none)
        }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await h.backend.rateCalls.isEmpty)
        #expect(h.service.trackActions.notice == nil)
    }

    // MARK: - A song's state, read when the user shows interest

    private func likeEntries(_ actions: [MusicTrackAction]) -> [MusicTrackAction] {
        actions.filter { $0.ratingStatus != nil }
    }

    @Test("A song the pointer reached is read, and its menu then offers Remove like or Remove dislike", arguments: [
        (MusicLikeStatus.like, [MusicTrackAction.like(removing: true), .dislike(removing: false)]),
        (.dislike, [.like(removing: false), .dislike(removing: true)]),
    ])
    func menuFollowsALazyRead(status: MusicLikeStatus, expected: [MusicTrackAction]) async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        let track = MusicSamples.track("v1")
        await h.backend.setLikeStatus(videoId: "v1", status)
        #expect(likeEntries(h.nav.actions(for: track, in: .none)) == [.like(removing: false), .dislike(removing: false)])

        h.nav.revealLikeStatus(of: track, in: .none)

        #expect(await h.until { likeEntries(h.nav.actions(for: track, in: .none)) == expected })
    }

    @Test("Reaching the same song again, or on another row, asks once")
    func lazyReadAsksOnce() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        let track = MusicSamples.track("v1")

        for context in [MusicTrackContext.none, .upNext, .none] {
            h.nav.revealLikeStatus(of: track, in: context)
        }
        try? await Task.sleep(for: .milliseconds(60))

        #expect(await h.backend.likeStatusCalls == ["v1"])
    }

    @Test("Songs the pointer crosses are each read once, and a song it never reaches is not read")
    func lazyReadOnlyForSongsReached() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()

        for id in ["a", "b", "c", "a", "b"] {
            h.nav.revealLikeStatus(of: MusicSamples.track(id), in: .none)
        }
        try? await Task.sleep(for: .milliseconds(60))

        #expect(Set(await h.backend.likeStatusCalls) == ["a", "b", "c"])
        #expect(await h.backend.likeStatusCalls.count == 3)
    }

    @Test("Signed out, or before the session check has answered, reaching a song reads nothing")
    func lazyReadNeedsASession() async {
        let unknown = ActionNavHarness()
        unknown.nav.revealLikeStatus(of: MusicSamples.track("v1"), in: .none)
        let out = ActionNavHarness(signedIn: false)
        await out.service.refreshAuth()
        out.nav.revealLikeStatus(of: MusicSamples.track("v1"), in: .none)
        try? await Task.sleep(for: .milliseconds(60))

        #expect(await unknown.backend.likeStatusCalls.isEmpty)
        #expect(await out.backend.likeStatusCalls.isEmpty)
    }

    @Test("A row of the Liked music page is liked with no read: its menu offers Remove like, in any of the page's ids", arguments: ["VLLM", "FEmusic_liked_videos", "LM"])
    func likedMusicRowsAreSeeded(id: String) async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        let track = MusicSamples.track("v1")
        let liked = MusicTrackContext(pageBrowseId: id, pageTitle: "Liked music", pageIsEditable: false)

        #expect(likeEntries(h.nav.actions(for: track, in: liked)) == [.like(removing: true), .dislike(removing: false)])
        h.nav.revealLikeStatus(of: track, in: liked)
        try? await Task.sleep(for: .milliseconds(60))

        #expect(await h.backend.likeStatusCalls.isEmpty)
        #expect(h.service.likes.status(of: "v1") == nil)
    }

    @Test("The seed is for Liked music only: another playlist's row is unknown until it is read")
    func otherPlaylistsAreNotSeeded() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        let mine = MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true)

        #expect(likeEntries(h.nav.actions(for: MusicSamples.track("v1"), in: mine)) == [.like(removing: false), .dislike(removing: false)])
    }

    @Test("What the app knows beats the seed: a Liked music row whose like was taken back offers Like again")
    func knownStateBeatsTheSeed() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        let track = MusicSamples.track("v1")
        let liked = MusicTrackContext(pageBrowseId: "VLLM", pageTitle: "Liked music", pageIsEditable: false)

        _ = await h.service.setLike(.indifferent, of: track)

        #expect(likeEntries(h.nav.actions(for: track, in: liked)) == [.like(removing: false), .dislike(removing: false)])
    }

    @Test("Signed out, the Liked music seed does not bring Like and Dislike back")
    func seedNeedsASession() async {
        let out = ActionNavHarness(signedIn: false)
        await out.service.refreshAuth()
        let liked = MusicTrackContext(pageBrowseId: "VLLM", pageTitle: "Liked music", pageIsEditable: false)

        #expect(likeEntries(out.nav.actions(for: MusicSamples.track("v1"), in: liked)).isEmpty)
    }

    // MARK: - Where a menu pick's outcome shows

    @Test("A menu pick's outcome goes to the outcome reporter, the one the hotkeys use, and not straight to the notice line", arguments: [
        (MusicTrackAction.like(removing: false), MusicActionOutcome.liked),
        (.like(removing: true), .likeRemoved),
        (.dislike(removing: false), .disliked),
    ])
    func pickReportsThroughTheReporter(action: MusicTrackAction, outcome: MusicActionOutcome) async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        let reporter = RecordingOutcomeReporter()
        h.nav.outcomes = reporter

        h.nav.perform(action, for: MusicSamples.track("v1"), in: .none)

        #expect(await h.until { !reporter.outcomes.isEmpty })
        #expect(reporter.outcomes == [outcome])
        #expect(h.service.trackActions.notice == nil)
    }

    @Test("A failed rating is reported too, so a popup closed during the call still gets the HUD")
    func failedRateReportsThroughTheReporter() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        let reporter = RecordingOutcomeReporter()
        h.nav.outcomes = reporter
        await h.backend.setRateError(videoId: "v1", URLError(.notConnectedToInternet))

        await h.nav.rate(.like, MusicSamples.track("v1")).value

        #expect(reporter.outcomes == [.failed])
        #expect(h.service.trackActions.notice == nil)
    }

    @Test("A signed-out pick is reported as signed out")
    func signedOutRateReports() async {
        let h = ActionNavHarness(signedIn: false)
        await h.service.refreshAuth()
        let reporter = RecordingOutcomeReporter()
        h.nav.outcomes = reporter

        await h.nav.rate(.like, MusicSamples.track("v1")).value

        #expect(reporter.outcomes == [.signedOut])
    }

    @Test("A second pick on a song whose rating is still out reports as well, and its quiet outcome is the reporter's to drop")
    func foldedRateReportsEachCall() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        let reporter = RecordingOutcomeReporter()
        h.nav.outcomes = reporter
        let track = MusicSamples.track("v1")

        let first = h.nav.rate(.like, track)
        let second = h.nav.rate(.dislike, track)
        await first.value
        await second.value

        #expect(reporter.outcomes.count == 2)
        #expect(reporter.outcomes.contains(.quiet))
    }

    @Test("With no reporter set a failure still shows on the notice line, and a rating that went through does not")
    func rateFallsBackToTheNoticeLine() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()

        await h.nav.rate(.like, MusicSamples.track("v1")).value
        #expect(h.service.trackActions.notice == nil)

        await h.backend.setRateError(videoId: "v2", URLError(.notConnectedToInternet))
        await h.nav.rate(.like, MusicSamples.track("v2")).value
        #expect(h.service.trackActions.notice?.text == "Couldn't reach YouTube Music")
        #expect(h.service.trackActions.notice?.isError == true)
    }

    @Test("A reporter that is gone leaves the notice line to show a failure")
    func releasedReporterFallsBack() async {
        let h = ActionNavHarness()
        await h.service.refreshAuth()
        h.nav.outcomes = RecordingOutcomeReporter()
        await h.backend.setRateError(videoId: "v1", URLError(.notConnectedToInternet))

        await h.nav.rate(.like, MusicSamples.track("v1")).value

        #expect(h.nav.outcomes == nil)
        #expect(h.service.trackActions.notice?.text == "Couldn't reach YouTube Music")
    }

    // MARK: - Collection tiles

    @Test("An album tile's menu is save, the Home pin, go to album, go to artist and related songs; a playlist's is save, the pin and related songs; an artist's is the pin, go to artist and related songs")
    func collectionActionsLists() {
        let h = ActionNavHarness()
        #expect(
            h.nav.actions(for: h.albumTile, in: .none) == [.saveToPlaylist, .pinHome(.canPin), .goToAlbum, .goToArtist, .related]
        )
        #expect(h.nav.actions(for: h.playlistTile, in: .none) == [.saveToPlaylist, .pinHome(.canPin), .related])
        #expect(h.nav.actions(for: h.artistTile, in: .none) == [.pinHome(.canPin), .goToArtist, .related])
    }

    @Test("A tile's menu has no queue entries, whether or not a song is playing")
    func collectionActionsHaveNoQueue() {
        let h = ActionNavHarness()
        h.playSomething()
        for tile in [h.albumTile, h.playlistTile, h.artistTile] {
            let offered = h.nav.actions(for: tile, in: .upNext)
            #expect(!offered.contains(.playNext) && !offered.contains(.addToQueue) && !offered.contains(.removeFromQueue))
        }
    }

    @Test("Go to album on an album tile opens that album over the results, and Back returns to them")
    func collectionGoToAlbum() async {
        let h = ActionNavHarness()
        await h.search("q", songs: [h.album])
        h.nav.perform(.goToAlbum, for: h.albumTile, in: .none)
        #expect(h.path == ["MPREbTile"])
        #expect(h.service.browse.path.last?.kind == .album)
        #expect(h.service.browse.path.last?.title == "Tile Album")
        #expect(h.nav.hidesResults)
        h.service.browse.back()
        #expect(h.nav.showsResults)
    }

    @Test("Go to artist opens the artist the album tile links to, and an artist tile opens itself")
    func collectionGoToArtist() {
        let h = ActionNavHarness()
        h.nav.perform(.goToArtist, for: h.albumTile, in: .none)
        #expect(h.path == ["UCtileArtist"])
        #expect(h.service.browse.path.last?.kind == .artist)
        #expect(h.service.browse.path.last?.title == "Tile Artist")

        let other = ActionNavHarness()
        other.nav.perform(.goToArtist, for: other.artistTile, in: .none)
        #expect(other.path == ["UCtileArtist"])
    }

    @Test("Go to artist and Go to album do nothing where the tile has no such page")
    func collectionGoToWithoutPage() {
        let h = ActionNavHarness()
        h.nav.perform(.goToArtist, for: h.playlistTile, in: .none)
        h.nav.perform(.goToAlbum, for: h.playlistTile, in: .none)
        h.nav.perform(.goToAlbum, for: h.artistTile, in: .none)
        h.nav.perform(.goToArtist, for: MusicSamples.collection("MPREbBare", kind: .album), in: .none)
        #expect(h.path.isEmpty)
    }

    @Test("Save to playlist on an album tile opens the save menu for the whole album, asking for its playlists by the OLAK id")
    func collectionPickerForAlbum() async {
        let h = ActionNavHarness()
        h.nav.perform(.saveToPlaylist, for: h.albumTile, in: .none)
        #expect(h.nav.showsPicker)
        #expect(h.nav.rightColumn == .browse)
        #expect(h.service.trackActions.picker?.collection == h.albumTile)
        #expect(h.service.trackActions.picker?.track == nil)
        #expect(await h.until { await h.backend.sourceOptionsCalls == ["OLAK5uy_tile"] })
        #expect(await h.backend.playlistOptionsCalls.isEmpty)
    }

    @Test("Save to playlist on a playlist tile asks for its playlists by the playlist id without its VL")
    func collectionPickerForPlaylist() async {
        let h = ActionNavHarness()
        h.nav.perform(.saveToPlaylist, for: h.playlistTile, in: .none)
        #expect(await h.until { await h.backend.sourceOptionsCalls == ["PLtile"] })
    }

    @Test("Save to playlist does nothing for an album with no album playlist id, and for an artist")
    func collectionPickerNeedsSource() async {
        let h = ActionNavHarness()
        h.nav.perform(.saveToPlaylist, for: MusicSamples.collection("MPREbBare", kind: .album), in: .none)
        h.nav.perform(.saveToPlaylist, for: h.artistTile, in: .none)
        #expect(h.nav.showsPicker == false)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await h.backend.sourceOptionsCalls.isEmpty)
    }

    @Test("Picking a playlist for an album adds the whole album and keeps the menu open")
    func collectionPickKeepsMenu() async {
        let h = ActionNavHarness()
        await h.backend.setSourceOptions(sourceId: "OLAK5uy_tile", [MusicSamples.playlistOption("PLone", title: "Road Trip")])
        h.nav.perform(.saveToPlaylist, for: h.albumTile, in: .none)
        #expect(await h.until { if case .loaded? = h.service.trackActions.picker?.load { true } else { false } })
        h.service.trackActions.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.service.trackActions.notice?.text == "Saved to Road Trip" })
        #expect(await h.backend.addPlaylistCalls == [FakeMusicBackend.AddPlaylistCall(sourceId: "OLAK5uy_tile", playlistId: "PLone")])
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
        #expect(h.nav.showsPicker)
    }

    @Test("Pin to Home on a tile pins it with its kind, and the menu then offers Unpin from Home")
    func collectionPinAndUnpin() {
        let h = ActionNavHarness()
        h.nav.perform(.pinHome(.canPin), for: h.albumTile, in: .none)
        #expect(h.service.pinnedItems.items.map(\.key) == ["album:MPREbTile"])
        #expect(h.nav.actions(for: h.albumTile, in: .none).contains(.pinHome(.pinned)))

        h.nav.perform(.pinHome(.pinned), for: h.albumTile, in: .none)
        #expect(h.service.pinnedItems.isEmpty)

        h.nav.perform(.pinHome(.canPin), for: h.playlistTile, in: .none)
        h.nav.perform(.pinHome(.canPin), for: h.artistTile, in: .none)
        #expect(h.service.pinnedItems.items.map(\.key) == ["playlist:VLPLtile", "artist:UCtileArtist"])
    }

    @Test("A full Home offers the refusal on a new tile, and nothing is pinned by it")
    func collectionPinWhenFull() {
        let h = ActionNavHarness()
        for index in 0..<MusicPinnedItems.limit {
            h.service.pinnedItems.pin(MusicPinnedItem(kind: .artist, id: "UC\(index)", title: "Name \(index)"))
        }
        #expect(h.nav.actions(for: h.albumTile, in: .none).contains(.pinHome(.full)))
        h.nav.perform(.pinHome(.full), for: h.albumTile, in: .none)
        #expect(h.service.pinnedItems.items.count == MusicPinnedItems.limit)
        #expect(!h.service.pinnedItems.isPinned(h.albumTile))
    }

    @Test("Liked music offers no Home pin, since it cannot be pinned")
    func collectionLikedMusicNoPin() {
        let h = ActionNavHarness()
        let offered = h.nav.actions(for: MusicBrowseStore.likedMusic, in: .none)
        #expect(!offered.contains { if case .pinHome = $0 { true } else { false } })
    }

    @Test("The queue and remove picks do nothing on a tile")
    func collectionIgnoresSongOnlyPicks() async {
        let h = ActionNavHarness()
        h.service.play(MusicSamples.track("a"), in: MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a", "b")))
        let queued = h.service.queue.tracks.map(\.videoId)
        for action in [MusicTrackAction.playNext, .addToQueue, .removeFromQueue, .removeFromPlaylist] {
            h.nav.perform(action, for: h.albumTile, in: .none)
        }
        #expect(h.service.queue.tracks.map(\.videoId) == queued)
        #expect(h.service.trackActions.notice == nil)
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
    }

    // MARK: - Session

    @Test("Signing out closes the save menu and clears its line")
    func signOutResets() async {
        let h = ActionNavHarness()
        let track = MusicSamples.track("v1")
        await h.backend.setPlaylistOptions(videoId: "v1", [MusicSamples.playlistOption("PLone", title: "Road Trip")])
        h.nav.perform(.saveToPlaylist, for: track, in: .none)
        #expect(await h.until { if case .loaded? = h.service.trackActions.picker?.load { true } else { false } })
        h.service.trackActions.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.service.trackActions.notice?.text == "Saved to Road Trip" })
        #expect(h.nav.showsPicker)

        h.service.signOut()

        #expect(h.nav.showsPicker == false)
        #expect(h.service.trackActions.notice == nil)
    }

    @Test("A write that finds the session gone signs the service out")
    func expiredSignsOut() async {
        let h = ActionNavHarness()
        await h.backend.setRemoveFromPlaylistError(MusicError.signedOut)
        let row = MusicSamples.track("v1", setVideoId: "s1")
        h.nav.perform(.removeFromPlaylist, for: row, in: MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true))
        #expect(await h.until { h.service.authState == .signedOut })
        #expect(h.service.trackActions.picker == nil)
    }
}
