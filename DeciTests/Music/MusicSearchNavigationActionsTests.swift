// DeciTests/Music/MusicSearchNavigationActionsTests.swift
// The song actions through the Music tab's navigation: Go to album and Go to artist open a page the way an artist
// opens (with Back returning to the results), the save menu floats over whatever shows, and the other actions
// reach the actions store. The same menu for an album, playlist or artist tile.

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
        #expect(h.nav.actions(for: track, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin), .goToAlbum, .goToArtist])
    }

    @Test("Pin to Home adds the song to Home, and the menu then offers Unpin from Home")
    func pinHomeAndUnpin() {
        let h = ActionNavHarness()
        let track = MusicSamples.track("v1")
        #expect(h.nav.actions(for: track, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin)])

        h.nav.perform(.pinHome(.canPin), for: track, in: .none)

        #expect(h.service.pinnedItems.items.map(\.id) == ["v1"])
        #expect(h.service.pinnedItems.items.first?.kind == .song)
        #expect(h.nav.actions(for: track, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.pinned)])

        h.nav.perform(.pinHome(.pinned), for: track, in: .none)

        #expect(h.service.pinnedItems.isEmpty)
        #expect(h.nav.actions(for: track, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin)])
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
        #expect(h.nav.actions(for: fresh, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.full)])
        #expect(h.nav.actions(for: pinned, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.pinned)])

        h.nav.perform(.pinHome(.full), for: fresh, in: .none)
        #expect(h.service.pinnedItems.items.count == MusicPinnedItems.limit)
        #expect(!h.service.pinnedItems.isPinned(fresh))

        h.nav.perform(.pinHome(.pinned), for: pinned, in: .none)
        #expect(!h.service.pinnedItems.isPinned(pinned))
        #expect(h.nav.actions(for: fresh, in: .none) == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin)])
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

    // MARK: - Collection tiles

    @Test("An album tile's menu is save, the Home pin, go to album and go to artist; a playlist's is save and the pin; an artist's is the pin and go to artist")
    func collectionActionsLists() {
        let h = ActionNavHarness()
        #expect(h.nav.actions(for: h.albumTile, in: .none) == [.saveToPlaylist, .pinHome(.canPin), .goToAlbum, .goToArtist])
        #expect(h.nav.actions(for: h.playlistTile, in: .none) == [.saveToPlaylist, .pinHome(.canPin)])
        #expect(h.nav.actions(for: h.artistTile, in: .none) == [.pinHome(.canPin), .goToArtist])
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
