// DeciTests/Music/MusicTrackActionsStoreTests.swift
// The state behind the song actions: the save to playlist menu (load, save, errors, late answers), saving a whole album
// or playlist through the same menu (a ticked row there says Already in), which playlists already hold it (read locally,
// because YouTube Music sends no such flag), removing a row from a playlist page, the short notice line, and a session
// that ends. Tapping a ticked row of a song's menu, which takes the song out, is in MusicTrackActionsStoreUnsaveTests.swift.

import Foundation
import Testing
@testable import Deci

@MainActor
final class ActionProbe {
    var expired = 0
}

@MainActor
struct ActionsHarness {
    let backend = FakeMusicBackend()
    let browse: MusicBrowseStore
    let store: MusicTrackActionsStore
    let probe = ActionProbe()
    let song = MusicSamples.track("vid-1", title: "Song")

    init(noticeDuration: Duration = .seconds(60)) {
        browse = MusicBrowseStore(backend: backend)
        store = MusicTrackActionsStore(backend: backend, browse: browse, noticeDuration: noticeDuration)
        let probe = self.probe
        store.onSessionExpired = { probe.expired += 1 }
    }

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

    var options: [MusicPlaylistOption]? {
        if case .loaded(let options)? = store.picker?.load { options } else { nil }
    }

    /// Opens the picker for `track` over the scripted `options` and waits for the list.
    func openPicker(
        for track: Deci.MusicTrack? = nil,
        options: [MusicPlaylistOption] = [
            MusicSamples.playlistOption("PLone", title: "Road Trip"),
            MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true),
        ]
    ) async {
        let track = track ?? song
        await backend.setPlaylistOptions(videoId: track.videoId, options)
        store.openPicker(for: track)
        _ = await until { if case .loaded? = store.picker?.load { true } else { false } }
    }

    /// An editable playlist page open and loaded, as the user would have it under a row.
    func openPage(_ tracks: [Deci.MusicTrack], id: String = "VLPLfixtureMine") async -> MusicTrackContext {
        await backend.setPage(MusicSamples.page(id, tracks: tracks, title: "Mine", isEditable: true))
        browse.open(MusicSamples.collection(id, title: "Mine"))
        _ = await until { if case .loaded = browse.pageState(id) { true } else { false } }
        return MusicTrackContext(pageBrowseId: id, pageTitle: "Mine", pageIsEditable: true)
    }

    /// An album tile with the playlist id of its songs, and a playlist tile.
    let albumTile = MusicSamples.collection(
        "MPREbTile", kind: .album, title: "Tile Album", subtitle: "Album", audioPlaylistId: "OLAK5uy_tile"
    )
    let playlistTile = MusicSamples.collection("VLPLtile", kind: .playlist, title: "Tile Playlist")

    /// Opens the picker for a whole album or playlist over the options scripted for `sourceId`, and waits for the list.
    func openCollectionPicker(
        for collection: MusicCollection,
        sourceId: String,
        options: [MusicPlaylistOption] = [
            MusicSamples.playlistOption("PLone", title: "Road Trip"),
            MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true),
        ]
    ) async {
        await backend.setSourceOptions(sourceId: sourceId, options)
        store.openPicker(for: collection)
        _ = await until { if case .loaded? = store.picker?.load { true } else { false } }
    }

    func pageIds(_ id: String = "VLPLfixtureMine") -> [String] {
        if case .loaded(let page) = browse.pageState(id) { page.tracks.map(\.videoId) } else { [] }
    }

    /// The playlists whose row is ticked in the open picker.
    var ticked: Set<String> {
        Set(options?.filter(\.containsVideo).map(\.playlistId) ?? [])
    }

    /// A playlist's first page as the membership pass reads it: its songs by video id, and the token of the page behind it.
    func setPlaylistSongs(_ playlistId: String, _ ids: [String], continuation: String? = nil) async {
        let tracks = ids.map { MusicSamples.track($0) }
        await backend.setPage(MusicSamples.page("VL" + playlistId, tracks: tracks, continuation: continuation))
    }

    /// A playlist of `pages` pages with two songs each, reached through the tokens "c1", "c2" and so on. `songOnPage`
    /// (1 is the first page) also holds "vid-1". The last page has no token.
    func setLongPlaylist(_ playlistId: String, pages: Int, songOnPage: Int? = nil) async {
        let browseId = "VL" + playlistId
        for page in 1...pages {
            var ids = ["\(playlistId)-\(page)a", "\(playlistId)-\(page)b"]
            if page == songOnPage { ids.append("vid-1") }
            let tracks = ids.map { MusicSamples.track($0) }
            let next = page < pages ? "c\(page)" : nil
            if page == 1 {
                await backend.setPage(MusicSamples.page(browseId, tracks: tracks, continuation: next))
            } else {
                await backend.setMoreTracks(browseId: browseId, continuation: "c\(page - 1)", tracks: tracks, next: next)
            }
        }
    }
}

@MainActor
@Suite("MusicTrackActionsStore")
struct MusicTrackActionsStoreTests {

    // MARK: - Picker: loading

    @Test("Opening the picker shows it loading, then the playlists in YouTube's order")
    func pickerLoads() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setPlaylistOptionsGate(videoId: "vid-1", gate)
        await h.backend.setPlaylistOptions(videoId: "vid-1", [MusicSamples.playlistOption("PLone"), MusicSamples.playlistOption("PLtwo")])

        #expect(h.store.picker == nil)
        h.store.openPicker(for: h.song)
        #expect(h.store.picker?.track == h.song)
        #expect(h.store.picker?.load == .loading)
        await gate.open()

        #expect(await h.until { h.options?.map(\.playlistId) == ["PLone", "PLtwo"] })
        #expect(await h.backend.playlistOptionsCalls == ["vid-1"])
    }

    @Test("A user with no playlists gets a loaded, empty list")
    func pickerEmpty() async {
        let h = ActionsHarness()
        await h.openPicker(options: [])
        #expect(h.options == [])
    }

    @Test("A failed list shows a message, and opening it again tries again")
    func pickerFailureThenRetry() async {
        let h = ActionsHarness()
        await h.backend.setPlaylistOptionsError(videoId: "vid-1", MusicError.http(500))
        h.store.openPicker(for: h.song)
        let message = MusicService.message(for: MusicError.http(500))
        #expect(await h.until { h.store.picker?.load == .failed(message) })
        #expect(h.probe.expired == 0)

        await h.backend.setPlaylistOptionsError(videoId: "vid-1", nil)
        await h.backend.setPlaylistOptions(videoId: "vid-1", [MusicSamples.playlistOption("PLone")])
        h.store.openPicker(for: h.song)
        #expect(h.store.picker?.load == .loading)
        #expect(await h.until { h.options?.map(\.playlistId) == ["PLone"] })
    }

    @Test("Closing the picker drops it, and a list that arrives afterwards does not bring it back")
    func closeDropsLateList() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setPlaylistOptionsGate(videoId: "vid-1", gate)
        await h.backend.setPlaylistOptions(videoId: "vid-1", [MusicSamples.playlistOption("PLone")])
        h.store.openPicker(for: h.song)
        h.store.closePicker()
        #expect(h.store.picker == nil)
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.picker == nil)
    }

    @Test("A slow list for an earlier song never overwrites the list of the song opened since")
    func slowEarlierListDropped() async {
        let h = ActionsHarness()
        let slow = MusicTestGate()
        await h.backend.setPlaylistOptionsGate(videoId: "vid-1", slow)
        await h.backend.setPlaylistOptions(videoId: "vid-1", [MusicSamples.playlistOption("PLold")])
        await h.backend.setPlaylistOptions(videoId: "vid-2", [MusicSamples.playlistOption("PLnew")])

        h.store.openPicker(for: h.song)
        let second = MusicSamples.track("vid-2", title: "Other")
        h.store.openPicker(for: second)
        #expect(await h.until { h.options?.map(\.playlistId) == ["PLnew"] })
        await slow.open()
        await h.letLateWorkLand()
        #expect(h.options?.map(\.playlistId) == ["PLnew"])
        #expect(h.store.picker?.track == second)
    }

    @Test("A long list of playlists loads whole")
    func pickerLargeList() async {
        let h = ActionsHarness()
        let many = (0..<10_000).map { MusicSamples.playlistOption("PL\($0)") }
        await h.openPicker(options: many)
        #expect(h.options?.count == 10_000)
    }

    // MARK: - Picker: saving

    @Test("Choosing a playlist adds the song, ticks its row in the menu that stays open, and says it saved")
    func chooseSaves() async {
        let h = ActionsHarness()
        await h.openPicker()
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")
        h.store.choose(road)

        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(await h.backend.addToPlaylistCalls == [FakeMusicBackend.AddToPlaylistCall(videoId: "vid-1", playlistId: "PLone")])
        #expect(h.store.notice?.isError == false)
        #expect(h.store.picker != nil)
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.options?.first { $0.playlistId == "PLone" }?.containsVideo == true)
        #expect(h.options?.map(\.playlistId) == ["PLone", "PLtwo"])
    }

    @Test("A row shows saving while its call is out, and a second tap on it does not send a second call")
    func chooseOnlyOnce() async {
        let h = ActionsHarness()
        await h.openPicker()
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")

        h.store.choose(road)
        #expect(h.store.picker?.saving == ["PLone"])
        h.store.choose(road)
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        await h.letLateWorkLand()
        #expect(await h.backend.addToPlaylistCalls.count == 1)
    }

    @Test("Saves to two playlists go out together, and each row is ticked when its own call lands")
    func chooseSeveral() async {
        let h = ActionsHarness()
        await h.openPicker(options: [
            MusicSamples.playlistOption("PLone", title: "Road Trip"),
            MusicSamples.playlistOption("PLtwo", title: "Workout"),
        ])
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)

        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "Workout"))
        #expect(h.store.picker?.saving == ["PLone", "PLtwo"])
        await gate.open()

        #expect(await h.until { h.options?.allSatisfy(\.containsVideo) == true })
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(await h.backend.addToPlaylistCalls.count == 2)
    }

    @Test("A save still out shows saving in a picker closed and opened again, is not sent again, and ticks the row there")
    func reopenedPickerDoesNotResend() async {
        let h = ActionsHarness()
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")
        await h.openPicker(options: [road])
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        h.store.choose(road)
        h.store.closePicker()
        await h.openPicker(options: [road])
        #expect(h.store.picker?.saving == ["PLone"])
        h.store.choose(road)
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(await h.until { h.options?.first?.containsVideo == true })
        #expect(h.store.picker?.saving.isEmpty == true)
        await h.letLateWorkLand()
        #expect(await h.backend.addToPlaylistCalls.count == 1)
    }

    @Test("A save out for one song never shows saving in the picker of another song")
    func savingStaysWithItsSong() async {
        let h = ActionsHarness()
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")
        await h.openPicker(options: [road])
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        h.store.choose(road)
        await h.openPicker(for: MusicSamples.track("vid-2", title: "Other"), options: [road])
        #expect(h.store.picker?.saving.isEmpty == true)
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(h.options?.first?.containsVideo == false)
    }

    @Test("A failed save leaves the row unticked for another try, with an error line")
    func chooseFailureKeepsPicker() async {
        let h = ActionsHarness()
        await h.openPicker()
        await h.backend.setAddToPlaylistError(MusicError.rejected)
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))

        #expect(await h.until { h.store.notice != nil })
        // No dedupe option goes out, so a refusal most likely means the song is already there.
        #expect(h.store.notice?.text == "Not added. Road Trip may already have it.")
        #expect(h.store.notice?.isError == true)
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.options?.count == 2)
        #expect(h.options?.first { $0.playlistId == "PLone" }?.containsVideo == false)

        await h.backend.setAddToPlaylistError(nil)
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(h.options?.first { $0.playlistId == "PLone" }?.containsVideo == true)
    }

    @Test("A network failure while saving shows the network line, and does not sign out")
    func chooseNetworkFailure() async {
        let h = ActionsHarness()
        await h.openPicker()
        await h.backend.setAddToPlaylistError(URLError(.notConnectedToInternet))
        h.store.choose(MusicSamples.playlistOption("PLone"))
        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == "Network problem. Check your connection.")
        #expect(h.probe.expired == 0)
    }

    @Test("Choosing with no picker open, or while the list is still loading, does nothing")
    func chooseNeedsLoadedPicker() async {
        let h = ActionsHarness()
        h.store.choose(MusicSamples.playlistOption("PLone"))
        let gate = MusicTestGate()
        await h.backend.setPlaylistOptionsGate(videoId: "vid-1", gate)
        h.store.openPicker(for: h.song)
        h.store.choose(MusicSamples.playlistOption("PLone"))
        await h.letLateWorkLand()
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
        #expect(h.store.notice == nil)
        await gate.open()
    }

    @Test("A save that finishes after the picker was closed still says it saved")
    func saveFinishesAfterClose() async {
        let h = ActionsHarness()
        await h.openPicker()
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        h.store.closePicker()
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(h.store.picker == nil)
    }

    @Test("A save that finds the session gone tells the service and shows no error line")
    func saveSignedOut() async {
        let h = ActionsHarness()
        await h.openPicker()
        await h.backend.setAddToPlaylistError(MusicError.signedOut)
        h.store.choose(MusicSamples.playlistOption("PLone"))
        #expect(await h.until { h.probe.expired == 1 })
        #expect(h.store.notice == nil)
    }

    @Test("A list that finds the session gone tells the service once")
    func listSignedOut() async {
        let h = ActionsHarness()
        await h.backend.setPlaylistOptionsError(videoId: "vid-1", MusicError.signedOut)
        h.store.openPicker(for: h.song)
        #expect(await h.until { h.probe.expired == 1 })
    }

    @Test("Playlist names with Unicode, emoji and markup go into the notice as they are")
    func unicodeTitles() async {
        let h = ActionsHarness()
        let title = "Caf\u{E9} \u{1F3B5} <b>&amp;</b> 'quoted' \"too\""
        await h.openPicker(options: [MusicSamples.playlistOption("PLone", title: title)])
        h.store.choose(MusicSamples.playlistOption("PLone", title: title))
        #expect(await h.until { h.store.notice?.text == "Saved to \(title)" })
    }

    // MARK: - Save a whole album or playlist

    @Test("Opening the picker for an album asks for the playlists it can go to by the album's playlist id, not by a song")
    func collectionPickerLoads() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setSourceOptionsGate(sourceId: "OLAK5uy_tile", gate)
        await h.backend.setSourceOptions(sourceId: "OLAK5uy_tile", [MusicSamples.playlistOption("PLone"), MusicSamples.playlistOption("PLtwo")])

        h.store.openPicker(for: h.albumTile)
        #expect(h.store.picker?.collection == h.albumTile)
        #expect(h.store.picker?.track == nil)
        #expect(h.store.picker?.load == .loading)
        await gate.open()

        #expect(await h.until { h.options?.map(\.playlistId) == ["PLone", "PLtwo"] })
        #expect(await h.backend.sourceOptionsCalls == ["OLAK5uy_tile"])
        #expect(await h.backend.playlistOptionsCalls.isEmpty)
    }

    @Test("A playlist tile asks by its playlist id without the VL, a mix by its RD id")
    func collectionPickerSourceIds() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.playlistTile, sourceId: "PLtile")
        h.store.closePicker()
        await h.openCollectionPicker(for: MusicSamples.collection("VLRDAMPLmixone"), sourceId: "RDAMPLmixone")
        #expect(await h.backend.sourceOptionsCalls == ["PLtile", "RDAMPLmixone"])
    }

    @Test("Nothing opens for what has no playlist to save: an album with no album playlist id, an artist, Liked music")
    func collectionPickerNeedsSource() async {
        let h = ActionsHarness()
        for tile in [
            MusicSamples.collection("MPREbBare", kind: .album),
            MusicSamples.collection("UCa", kind: .artist, audioPlaylistId: "OLAK5uy_x"),
            MusicBrowseStore.likedMusic,
            MusicSamples.collection("VL"),
        ] {
            h.store.openPicker(for: tile)
            #expect(h.store.picker == nil, "tile \(tile.browseId)")
        }
        await h.letLateWorkLand()
        #expect(await h.backend.sourceOptionsCalls.isEmpty)
    }

    @Test("Choosing a playlist adds the whole album to it, ticks the row and says it saved, as a song does")
    func collectionChooseSaves() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile")
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))

        #expect(h.store.picker?.saving == ["PLone"])
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(await h.backend.addPlaylistCalls == [FakeMusicBackend.AddPlaylistCall(sourceId: "OLAK5uy_tile", playlistId: "PLone")])
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
        #expect(h.store.notice?.isError == false)
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.options?.first { $0.playlistId == "PLone" }?.containsVideo == true)
    }

    @Test("Choosing a playlist for a playlist tile adds the source playlist, named without its VL")
    func collectionChooseSavesPlaylist() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.playlistTile, sourceId: "PLtile")
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(await h.backend.addPlaylistCalls == [FakeMusicBackend.AddPlaylistCall(sourceId: "PLtile", playlistId: "PLone")])
    }

    @Test("A playlist that already holds the whole album sends nothing and says so")
    func collectionChooseAlreadyIn() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile")
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true))
        #expect(h.store.notice?.text == "Already in Workout")
        #expect(h.store.notice?.isError == false)
        await h.letLateWorkLand()
        #expect(await h.backend.addPlaylistCalls.isEmpty)
    }

    @Test("A second tap while the album is going to a playlist sends nothing more")
    func collectionChooseOnlyOnce() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile")
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")
        h.store.choose(road)
        h.store.choose(road)
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        await h.letLateWorkLand()
        #expect(await h.backend.addPlaylistCalls.count == 1)
    }

    @Test("A refused album save leaves the row unticked with the same line as a song, and a retry can go through")
    func collectionChooseFailure() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile")
        await h.backend.setAddToPlaylistError(MusicError.rejected)
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == "Not added. Road Trip may already have it.")
        #expect(h.store.notice?.isError == true)
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.options?.first { $0.playlistId == "PLone" }?.containsVideo == false)

        await h.backend.setAddToPlaylistError(nil)
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(h.options?.first { $0.playlistId == "PLone" }?.containsVideo == true)
    }

    @Test("A network failure while saving an album shows the network line, and a gone session tells the service")
    func collectionChooseErrors() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile")
        await h.backend.setAddToPlaylistError(URLError(.notConnectedToInternet))
        h.store.choose(MusicSamples.playlistOption("PLone"))
        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == "Network problem. Check your connection.")
        #expect(h.probe.expired == 0)

        await h.backend.setAddToPlaylistError(MusicError.signedOut)
        h.store.choose(MusicSamples.playlistOption("PLone"))
        #expect(await h.until { h.probe.expired == 1 })
    }

    @Test("A list that fails shows a message, and Try again asks for the same album's playlists again")
    func collectionListFailureThenRetry() async {
        let h = ActionsHarness()
        await h.backend.setSourceOptionsError(sourceId: "OLAK5uy_tile", MusicError.http(500))
        h.store.openPicker(for: h.albumTile)
        #expect(await h.until { h.store.picker?.load == .failed(MusicService.message(for: MusicError.http(500))) })

        await h.backend.setSourceOptionsError(sourceId: "OLAK5uy_tile", nil)
        await h.backend.setSourceOptions(sourceId: "OLAK5uy_tile", [MusicSamples.playlistOption("PLone")])
        h.store.retryPicker()
        #expect(h.store.picker?.load == .loading)
        #expect(h.store.picker?.collection == h.albumTile)
        #expect(await h.until { h.options?.map(\.playlistId) == ["PLone"] })
        #expect(await h.backend.sourceOptionsCalls == ["OLAK5uy_tile", "OLAK5uy_tile"])
    }

    @Test("Try again on a song's picker asks for the song's playlists again, and with no picker open does nothing")
    func songRetry() async {
        let h = ActionsHarness()
        h.store.retryPicker()
        #expect(h.store.picker == nil)
        await h.backend.setPlaylistOptionsError(videoId: "vid-1", MusicError.http(500))
        h.store.openPicker(for: h.song)
        #expect(await h.until { if case .failed? = h.store.picker?.load { true } else { false } })
        await h.backend.setPlaylistOptionsError(videoId: "vid-1", nil)
        h.store.retryPicker()
        #expect(h.store.picker?.track == h.song)
        #expect(await h.until { if case .loaded? = h.store.picker?.load { true } else { false } })
        #expect(await h.backend.playlistOptionsCalls == ["vid-1", "vid-1"])
    }

    @Test("A slow list for a closed album picker never brings it back, nor overwrites the song opened since")
    func collectionSlowListDropped() async {
        let h = ActionsHarness()
        let slow = MusicTestGate()
        await h.backend.setSourceOptionsGate(sourceId: "OLAK5uy_tile", slow)
        await h.backend.setSourceOptions(sourceId: "OLAK5uy_tile", [MusicSamples.playlistOption("PLold")])
        h.store.openPicker(for: h.albumTile)
        await h.openPicker(options: [MusicSamples.playlistOption("PLnew")])
        await slow.open()
        await h.letLateWorkLand()
        #expect(h.options?.map(\.playlistId) == ["PLnew"])
        #expect(h.store.picker?.track == h.song)
    }

    @Test("A save out for an album never shows saving in a song's picker, though they share a playlist id")
    func collectionSavingStaysWithItsTarget() async {
        let h = ActionsHarness()
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile", options: [road])
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        h.store.choose(road)
        #expect(h.store.picker?.saving == ["PLone"])

        await h.openPicker(options: [road])
        #expect(h.store.picker?.saving.isEmpty == true)
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(h.options?.first?.containsVideo == false)
    }

    @Test("An album picker closed and opened again while its save is out shows saving, and sends nothing twice")
    func collectionReopenedPickerDoesNotResend() async {
        let h = ActionsHarness()
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile", options: [road])
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        h.store.choose(road)
        h.store.closePicker()
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile", options: [road])
        #expect(h.store.picker?.saving == ["PLone"])
        h.store.choose(road)
        await gate.open()
        #expect(await h.until { h.options?.first?.containsVideo == true })
        await h.letLateWorkLand()
        #expect(await h.backend.addPlaylistCalls.count == 1)
    }

    @Test("A save that finishes after the album picker was closed still says it saved; a reset drops it")
    func collectionSaveAfterCloseAndReset() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile")
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        h.store.closePicker()
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(h.store.picker == nil)

        let again = ActionsHarness()
        await again.openCollectionPicker(for: again.albumTile, sourceId: "OLAK5uy_tile")
        let held = MusicTestGate()
        await again.backend.setAddToPlaylistGate(held)
        again.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        again.store.reset()
        await held.open()
        await again.letLateWorkLand()
        #expect(again.store.notice == nil)
        #expect(again.store.picker == nil)
    }

    // MARK: - Which playlists already hold it

    @Test("A playlist that holds the song on its first page gets its row ticked, and one without it stays unticked")
    func membershipTicksFirstPage() async {
        let h = ActionsHarness()
        await h.setPlaylistSongs("PLone", ["x", "vid-1", "y"])
        await h.setPlaylistSongs("PLtwo", ["x", "y"])
        await h.openPicker(options: [MusicSamples.playlistOption("PLone"), MusicSamples.playlistOption("PLtwo")])

        #expect(await h.until { h.ticked == ["PLone"] })
        #expect(await h.until { await h.backend.pageCalls.count == 2 })
        await h.letLateWorkLand()
        #expect(h.ticked == ["PLone"])
        #expect(await h.backend.pageCalls.sorted() == ["VLPLone", "VLPLtwo"])
        #expect(await h.backend.moreTracksCalls.isEmpty)
        #expect(h.store.notice == nil)
        #expect(h.options?.map(\.playlistId) == ["PLone", "PLtwo"])
    }

    @Test("A song that is only on a later page ticks the row, and paging stops as soon as it is found")
    func membershipFindsSongOnLaterPage() async {
        let h = ActionsHarness()
        await h.setPlaylistSongs("PLone", ["a", "b"], continuation: "c1")
        await h.backend.setMoreTracks(browseId: "VLPLone", continuation: "c1", tracks: MusicSamples.tracks("c", "vid-1"), next: "c2")
        await h.backend.setMoreTracks(browseId: "VLPLone", continuation: "c2", tracks: MusicSamples.tracks("d"))
        await h.openPicker(options: [MusicSamples.playlistOption("PLone")])

        #expect(await h.until { h.ticked == ["PLone"] })
        await h.letLateWorkLand()
        #expect(await h.backend.pageCalls == ["VLPLone"])
        #expect(await h.backend.moreTracksCalls == [FakeMusicBackend.MoreTracksCall(browseId: "VLPLone", continuation: "c1")])
    }

    @Test("A playlist is read to its end when the song is not in it, and stays unticked")
    func membershipReadsToTheEnd() async {
        let h = ActionsHarness()
        await h.setPlaylistSongs("PLone", ["a"], continuation: "c1")
        await h.backend.setMoreTracks(browseId: "VLPLone", continuation: "c1", tracks: MusicSamples.tracks("b"), next: "c2")
        await h.backend.setMoreTracks(browseId: "VLPLone", continuation: "c2", tracks: MusicSamples.tracks("c"))
        await h.openPicker(options: [MusicSamples.playlistOption("PLone")])

        #expect(await h.until { await h.backend.moreTracksCalls.count == 2 })
        await h.letLateWorkLand()
        #expect(h.ticked.isEmpty)
        #expect(h.options?.count == 1)
    }

    @Test("Saving a whole album ticks the playlists that hold every one of its songs, and not one that holds only some")
    func membershipCollection() async {
        let h = ActionsHarness()
        // The album's songs are on two pages, and the full playlist holds them across two pages as well.
        await h.setPlaylistSongs("OLAK5uy_tile", ["s1", "s2"], continuation: "sc")
        await h.backend.setMoreTracks(browseId: "VLOLAK5uy_tile", continuation: "sc", tracks: MusicSamples.tracks("s3"))
        await h.setPlaylistSongs("PLfull", ["x", "s3", "s1"], continuation: "fc")
        await h.backend.setMoreTracks(browseId: "VLPLfull", continuation: "fc", tracks: MusicSamples.tracks("s2"))
        await h.setPlaylistSongs("PLpartial", ["s1", "s2"])
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile", options: [
            MusicSamples.playlistOption("PLfull"), MusicSamples.playlistOption("PLpartial"),
        ])

        #expect(await h.until { h.ticked == ["PLfull"] })
        #expect(await h.until { await h.backend.pageCalls.count == 3 })
        await h.letLateWorkLand()
        #expect(h.ticked == ["PLfull"])
        #expect(await h.backend.pageCalls.first == "VLOLAK5uy_tile")
        #expect(await h.backend.pageCalls.sorted() == ["VLOLAK5uy_tile", "VLPLfull", "VLPLpartial"])
    }

    @Test("A playlist tile is read by its playlist id with the VL, and a playlist that holds all of it is ticked")
    func membershipPlaylistTile() async {
        let h = ActionsHarness()
        await h.setPlaylistSongs("PLtile", ["s1", "s2"])
        await h.setPlaylistSongs("PLone", ["s2", "s1", "z"])
        await h.openCollectionPicker(for: h.playlistTile, sourceId: "PLtile", options: [MusicSamples.playlistOption("PLone")])
        #expect(await h.until { h.ticked == ["PLone"] })
        #expect(await h.backend.pageCalls.first == "VLPLtile")
    }

    @Test("When the source of a whole album cannot be read nothing is ticked, no playlist is read, and no notice shows")
    func membershipSourceFailure() async {
        let h = ActionsHarness()
        await h.setPlaylistSongs("PLone", ["s1"])
        await h.backend.setPageError("VLOLAK5uy_tile", MusicError.http(500))
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile", options: [MusicSamples.playlistOption("PLone")])

        #expect(await h.until { await h.backend.pageCalls.count == 1 })
        await h.letLateWorkLand()
        #expect(h.ticked.isEmpty)
        #expect(await h.backend.pageCalls == ["VLOLAK5uy_tile"])
        #expect(h.store.notice == nil)
        #expect(h.probe.expired == 0)
        #expect(h.store.picker != nil)
    }

    @Test("A source that comes back empty ticks nothing: no playlist holds all of no songs")
    func membershipEmptySource() async {
        let h = ActionsHarness()
        await h.setPlaylistSongs("PLone", ["s1"])
        // Nothing is scripted for the album's page, so it answers with no songs.
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile", options: [MusicSamples.playlistOption("PLone")])

        #expect(await h.until { await h.backend.pageCalls.count == 1 })
        await h.letLateWorkLand()
        #expect(h.ticked.isEmpty)
        #expect(await h.backend.pageCalls == ["VLOLAK5uy_tile"])
        #expect(h.store.notice == nil)
    }

    @Test("A source longer than the page limit is not trusted: ticking against part of it would be wrong")
    func membershipSourceTooLong() async {
        let h = ActionsHarness()
        await h.setLongPlaylist("OLAK5uy_tile", pages: MusicTrackActionsStore.membershipPageLimit + 5)
        // This playlist holds every song of the pages that were read, but the album goes on past them.
        let readSongs = (1...MusicTrackActionsStore.membershipPageLimit).flatMap { ["OLAK5uy_tile-\($0)a", "OLAK5uy_tile-\($0)b"] }
        await h.setPlaylistSongs("PLone", readSongs)
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile", options: [MusicSamples.playlistOption("PLone")])

        #expect(await h.until { await h.backend.moreTracksCalls.count == MusicTrackActionsStore.membershipPageLimit - 1 })
        await h.letLateWorkLand()
        #expect(h.ticked.isEmpty)
        #expect(await h.backend.pageCalls == ["VLOLAK5uy_tile"])
    }

    @Test("A playlist whose pages fail stays unticked with no notice, and the others are still read and ticked")
    func membershipFailureIsolated() async {
        let errors: [any Error] = [MusicError.http(500), MusicError.signedOut, MusicError.parse("x"), URLError(.notConnectedToInternet)]
        for error in errors {
            let h = ActionsHarness()
            await h.setPlaylistSongs("PLone", ["vid-1"])
            await h.setPlaylistSongs("PLtwo", ["vid-1"])
            await h.setPlaylistSongs("PLthree", ["vid-1"])
            await h.backend.setPageError("VLPLtwo", error)
            await h.openPicker(options: [
                MusicSamples.playlistOption("PLone"), MusicSamples.playlistOption("PLtwo"), MusicSamples.playlistOption("PLthree"),
            ])

            #expect(await h.until { h.ticked == ["PLone", "PLthree"] }, "\(error)")
            await h.letLateWorkLand()
            #expect(h.ticked == ["PLone", "PLthree"], "\(error)")
            #expect(await h.backend.pageCalls.count == 3, "\(error)")
            #expect(h.store.notice == nil, "\(error)")
            #expect(h.probe.expired == 0, "\(error)")
            #expect(h.store.picker != nil)
        }
    }

    @Test("A later page that fails leaves the row unticked even if the song was on the pages after it")
    func membershipContinuationFailure() async {
        let h = ActionsHarness()
        await h.setPlaylistSongs("PLone", ["a"], continuation: "c1")
        await h.backend.setMoreTracksError(browseId: "VLPLone", continuation: "c1", MusicError.http(503))
        await h.setPlaylistSongs("PLtwo", ["vid-1"])
        await h.openPicker(options: [MusicSamples.playlistOption("PLone"), MusicSamples.playlistOption("PLtwo")])

        #expect(await h.until { h.ticked == ["PLtwo"] })
        #expect(await h.until { await h.backend.moreTracksCalls.count == 1 })
        await h.letLateWorkLand()
        #expect(h.ticked == ["PLtwo"])
        #expect(h.store.notice == nil)
    }

    @Test("An option YouTube already flagged is not read, and a list with nothing left to read makes no call at all")
    func membershipSkipsFlagged() async {
        let h = ActionsHarness()
        await h.openPicker(options: [MusicSamples.playlistOption("PLtwo", contains: true)])
        await h.letLateWorkLand()
        #expect(await h.backend.pageCalls.isEmpty)
        #expect(h.ticked == ["PLtwo"])

        await h.setPlaylistSongs("PLone", ["vid-1"])
        await h.openPicker(options: [MusicSamples.playlistOption("PLtwo", contains: true), MusicSamples.playlistOption("PLone")])
        #expect(await h.until { h.ticked == ["PLone", "PLtwo"] })
        await h.letLateWorkLand()
        #expect(await h.backend.pageCalls == ["VLPLone"])

        let album = ActionsHarness()
        await album.openCollectionPicker(
            for: album.albumTile, sourceId: "OLAK5uy_tile", options: [MusicSamples.playlistOption("PLtwo", contains: true)])
        await album.letLateWorkLand()
        #expect(await album.backend.pageCalls.isEmpty)
    }

    @Test("Closing the picker before a page comes back drops the answer and reads nothing more")
    func membershipDroppedOnClose() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLone", gate)
        await h.setPlaylistSongs("PLone", ["a"], continuation: "c1")
        await h.backend.setMoreTracks(browseId: "VLPLone", continuation: "c1", tracks: MusicSamples.tracks("vid-1"))
        await h.openPicker(options: [MusicSamples.playlistOption("PLone")])
        #expect(await h.until { await h.backend.pageCalls.count == 1 })

        h.store.closePicker()
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.picker == nil)
        #expect(await h.backend.moreTracksCalls.isEmpty)
        #expect(h.store.notice == nil)
    }

    @Test("Opening the picker for another song before a page comes back never ticks a row in the new picker")
    func membershipDroppedForAnotherSong() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLone", gate)
        await h.setPlaylistSongs("PLone", ["vid-1"])
        await h.openPicker(options: [MusicSamples.playlistOption("PLone")])
        #expect(await h.until { await h.backend.pageCalls.count == 1 })

        let other = MusicSamples.track("vid-2", title: "Other")
        await h.openPicker(for: other, options: [MusicSamples.playlistOption("PLone")])
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.picker?.track == other)
        #expect(h.ticked.isEmpty)
        #expect(h.options?.map(\.playlistId) == ["PLone"])
    }

    @Test("A late answer for a song whose picker was closed ticks nothing when the same song is opened again and is not in it")
    func membershipDroppedOnReopen() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLone", gate)
        await h.setPlaylistSongs("PLone", ["vid-1"])
        await h.openPicker(options: [MusicSamples.playlistOption("PLone")])
        #expect(await h.until { await h.backend.pageCalls.count == 1 })
        h.store.closePicker()

        // The playlist has lost the song by the time the picker is opened again.
        await h.setPlaylistSongs("PLone", ["other"])
        await h.openPicker(options: [MusicSamples.playlistOption("PLone")])
        #expect(await h.until { await h.backend.pageCalls.count == 2 })
        await gate.open()
        await h.letLateWorkLand()
        // Both reads were held at the gate; the first one carried the old page and must not tick the new picker.
        #expect(h.ticked.isEmpty)
    }

    @Test("A reset drops a pass that is still out")
    func membershipDroppedOnReset() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLone", gate)
        await h.setPlaylistSongs("PLone", ["vid-1"])
        await h.openPicker(options: [MusicSamples.playlistOption("PLone")])
        #expect(await h.until { await h.backend.pageCalls.count == 1 })

        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.picker == nil)
        #expect(h.store.notice == nil)
    }

    @Test("A playlist is read for at most the page limit, the first page counting as page one")
    func membershipPageLimit() async {
        #expect(MusicTrackActionsStore.membershipPageLimit == 20)
        let h = ActionsHarness()
        await h.setLongPlaylist("PLlong", pages: 30)
        await h.openPicker(options: [MusicSamples.playlistOption("PLlong")])

        #expect(await h.until { await h.backend.moreTracksCalls.count == MusicTrackActionsStore.membershipPageLimit - 1 })
        await h.letLateWorkLand()
        let calls = await h.backend.moreTracksCalls
        #expect(calls.count == 19)
        #expect(calls.last == FakeMusicBackend.MoreTracksCall(browseId: "VLPLlong", continuation: "c19"))
        #expect(await h.backend.pageCalls == ["VLPLlong"])
        #expect(h.ticked.isEmpty)
    }

    @Test("A song on the last page the limit allows ticks the row; one a page further is not looked for")
    func membershipPageLimitBoundary() async {
        let h = ActionsHarness()
        await h.setLongPlaylist("PLlast", pages: 30, songOnPage: 20)
        await h.setLongPlaylist("PLpast", pages: 30, songOnPage: 21)
        await h.openPicker(options: [MusicSamples.playlistOption("PLlast"), MusicSamples.playlistOption("PLpast")])

        #expect(await h.until { h.ticked == ["PLlast"] })
        #expect(await h.until { await h.backend.moreTracksCalls.filter { $0.browseId == "VLPLpast" }.count == 19 })
        await h.letLateWorkLand()
        let calls = await h.backend.moreTracksCalls
        #expect(calls.filter { $0.browseId == "VLPLpast" }.count == 19)
        #expect(!calls.contains(FakeMusicBackend.MoreTracksCall(browseId: "VLPLpast", continuation: "c20")))
        #expect(calls.filter { $0.browseId == "VLPLlast" }.count == 19)
        #expect(h.ticked == ["PLlast"])
    }

    @Test("At most four playlists are read at once, and the next one starts as soon as one is done")
    func membershipFourAtOnce() async {
        let h = ActionsHarness()
        let ids = (0..<6).map { "PL\($0)" }
        var gates: [MusicTestGate] = []
        for id in ids {
            let gate = MusicTestGate()
            gates.append(gate)
            await h.backend.setPageGate("VL" + id, gate)
        }
        await h.openPicker(options: ids.map { MusicSamples.playlistOption($0) })

        #expect(await h.until { await h.backend.pageCalls.count == 4 })
        await h.letLateWorkLand()
        #expect(await h.backend.pageCalls.count == 4)

        await gates[0].open()
        #expect(await h.until { await h.backend.pageCalls.count == 5 })
        await h.letLateWorkLand()
        #expect(await h.backend.pageCalls.count == 5)

        for gate in gates { await gate.open() }
        #expect(await h.until { await h.backend.pageCalls.count == 6 })
        #expect(await h.backend.pageCalls.sorted() == ids.map { "VL" + $0 })
    }

    @Test("Rows tick one by one as their own playlists are read, not all together at the end")
    func membershipTicksOneByOne() async {
        let h = ActionsHarness()
        let gates = [MusicTestGate(), MusicTestGate()]
        await h.setPlaylistSongs("PLone", ["vid-1"])
        await h.setPlaylistSongs("PLtwo", ["vid-1"])
        await h.backend.setPageGate("VLPLone", gates[0])
        await h.backend.setPageGate("VLPLtwo", gates[1])
        await h.openPicker(options: [MusicSamples.playlistOption("PLone"), MusicSamples.playlistOption("PLtwo")])
        #expect(await h.until { await h.backend.pageCalls.count == 2 })
        #expect(h.ticked.isEmpty)

        await gates[1].open()
        #expect(await h.until { h.ticked == ["PLtwo"] })
        await h.letLateWorkLand()
        #expect(h.ticked == ["PLtwo"])
        await gates[0].open()
        #expect(await h.until { h.ticked == ["PLone", "PLtwo"] })
    }

    @Test("A row a save ticked while its playlist was being read stays ticked, whatever the read finds")
    func membershipNeverUnticks() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLone", gate)
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")
        await h.openPicker(options: [road])
        #expect(await h.until { await h.backend.pageCalls.count == 1 })

        h.store.choose(road)
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(h.ticked == ["PLone"])
        // The playlist's page does not list the song (the read began before the save), and the row must keep its tick.
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.ticked == ["PLone"])
    }

    @Test("A playlist a save ticked before its turn came is not read")
    func membershipSkipsRowTickedBySave() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        let ids = (0..<5).map { "PL\($0)" }
        for id in ids.prefix(4) { await h.backend.setPageGate("VL" + id, gate) }
        await h.openPicker(options: ids.map { MusicSamples.playlistOption($0, title: "Name \($0)") })
        #expect(await h.until { await h.backend.pageCalls.count == 4 })

        h.store.choose(MusicSamples.playlistOption("PL4", title: "Name PL4"))
        #expect(await h.until { h.store.notice?.text == "Saved to Name PL4" })
        await gate.open()
        await h.letLateWorkLand()
        #expect(await h.backend.pageCalls.sorted() == ["VLPL0", "VLPL1", "VLPL2", "VLPL3"])
        #expect(h.ticked == ["PL4"])
    }

    @Test("A long list of playlists is read through whole, and a song in a few of them ticks only those")
    func membershipLargeList() async {
        let h = ActionsHarness()
        let many = (0..<300).map { "PL\($0)" }
        for id in [many[3], many[150], many[299]] { await h.setPlaylistSongs(id, ["vid-1"]) }
        await h.openPicker(options: many.map { MusicSamples.playlistOption($0) })

        #expect(await h.until { h.ticked == ["PL3", "PL150", "PL299"] })
        #expect(await h.until { await h.backend.pageCalls.count == 300 })
    }

    // MARK: - Remove from playlist

    @Test("Removing a row calls the backend with its ids, takes it off the page and says so")
    func removeRow() async {
        let h = ActionsHarness()
        let first = MusicSamples.track("a", setVideoId: "s1"), second = MusicSamples.track("b", setVideoId: "s2")
        let context = await h.openPage([first, second])

        h.store.remove(first, in: context)

        #expect(await h.until { h.pageIds() == ["b"] })
        #expect(await h.backend.removeFromPlaylistCalls
            == [FakeMusicBackend.RemoveFromPlaylistCall(videoId: "a", setVideoId: "s1", playlistId: "VLPLfixtureMine")])
        #expect(h.store.notice?.text == "Removed from Mine")
        #expect(h.store.notice?.isError == false)
    }

    @Test("The row stays on the page until the call has gone through")
    func removeWaitsForTheCall() async {
        let h = ActionsHarness()
        let row = MusicSamples.track("a", setVideoId: "s1")
        let context = await h.openPage([row])
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)

        h.store.remove(row, in: context)
        #expect(await h.until { await h.backend.removeFromPlaylistCalls.count == 1 })
        #expect(h.pageIds() == ["a"])
        await gate.open()
        #expect(await h.until { h.pageIds().isEmpty })
    }

    @Test("A failed removal keeps the row, shows an error line and removes nothing")
    func removeFailure() async {
        let h = ActionsHarness()
        let row = MusicSamples.track("a", setVideoId: "s1")
        let context = await h.openPage([row])
        await h.backend.setRemoveFromPlaylistError(MusicError.rejected)

        h.store.remove(row, in: context)

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == MusicService.message(for: MusicError.rejected))
        #expect(h.store.notice?.isError == true)
        #expect(h.pageIds() == ["a"])
    }

    @Test("A second tap while the removal is out sends nothing more")
    func removeOnlyOnce() async {
        let h = ActionsHarness()
        let row = MusicSamples.track("a", setVideoId: "s1")
        let context = await h.openPage([row])
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)

        h.store.remove(row, in: context)
        h.store.remove(row, in: context)
        await gate.open()
        #expect(await h.until { h.pageIds().isEmpty })
        #expect(await h.backend.removeFromPlaylistCalls.count == 1)
    }

    @Test("Removal is refused where the rules say no: read-only page, Liked Music, no setVideoId, no page")
    func removeRefused() async {
        let h = ActionsHarness()
        let row = MusicSamples.track("a", setVideoId: "s1")
        let bare = MusicSamples.track("b")
        let readOnly = MusicTrackContext(pageBrowseId: "VLPLtheirs", pageTitle: "Theirs", pageIsEditable: false)
        let liked = MusicTrackContext(pageBrowseId: "VLLM", pageTitle: "Liked music", pageIsEditable: true)
        let own = MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true)

        h.store.remove(row, in: readOnly)
        h.store.remove(row, in: liked)
        h.store.remove(row, in: .none)
        h.store.remove(bare, in: own)
        await h.letLateWorkLand()
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        #expect(h.store.notice == nil)
    }

    @Test("A removal that finds the session gone tells the service and leaves the row")
    func removeSignedOut() async {
        let h = ActionsHarness()
        let row = MusicSamples.track("a", setVideoId: "s1")
        let context = await h.openPage([row])
        await h.backend.setRemoveFromPlaylistError(MusicError.signedOut)
        h.store.remove(row, in: context)
        #expect(await h.until { h.probe.expired == 1 })
        #expect(h.pageIds() == ["a"])
        #expect(h.store.notice == nil)
    }

    @Test("A removal that lands after the page was closed still says it removed")
    func removeAfterPageClosed() async {
        let h = ActionsHarness()
        let row = MusicSamples.track("a", setVideoId: "s1")
        let context = await h.openPage([row])
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)
        h.store.remove(row, in: context)
        h.browse.back()
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Removed from Mine" })
    }

    // MARK: - The notice line

    @Test("A notice clears itself after its time")
    func noticeClears() async {
        let h = ActionsHarness(noticeDuration: .milliseconds(40))
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile")
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true))
        #expect(h.store.notice != nil)
        #expect(await h.until { h.store.notice == nil })
    }

    @Test("The notice stays about 2 seconds unless told otherwise")
    func noticeDefaultTime() {
        #expect(MusicTrackActionsStore.defaultNoticeDuration == .seconds(2))
    }

    @Test("An older notice's timer never clears a newer notice early")
    func newerNoticeSurvives() async {
        let h = ActionsHarness(noticeDuration: .milliseconds(150))
        let first = MusicSamples.playlistOption("PLtwo", title: "First", contains: true)
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile", options: [first])
        h.store.choose(first)
        try? await Task.sleep(for: .milliseconds(100))
        let second = MusicSamples.playlistOption("PLtwo", title: "Second", contains: true)
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile", options: [second])
        h.store.choose(second)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.store.notice?.text == "Already in Second")
        #expect(await h.until { h.store.notice == nil })
    }

    @Test("Dismissing the notice clears it")
    func dismissNotice() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile")
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true))
        #expect(h.store.notice != nil)
        h.store.dismissNotice()
        #expect(h.store.notice == nil)
    }

    // MARK: - Reset

    @Test("Reset drops the picker and the notice, and late answers after it land nowhere")
    func resetDropsEverything() async {
        let h = ActionsHarness()
        await h.openPicker()
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.store.notice != nil })

        let gate = MusicTestGate()
        await h.backend.setPlaylistOptionsGate(videoId: "vid-1", gate)
        await h.backend.setPlaylistOptions(videoId: "vid-1", [MusicSamples.playlistOption("PLone")])
        h.store.openPicker(for: h.song)
        #expect(h.store.picker != nil)

        h.store.reset()
        #expect(h.store.picker == nil)
        #expect(h.store.notice == nil)
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.picker == nil)
    }

    @Test("A save that finishes after a reset shows no notice from the old session")
    func resetDropsLateSave() async {
        let h = ActionsHarness()
        await h.openPicker()
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.notice == nil)
        #expect(h.store.picker == nil)
    }

    // MARK: - Errors

    @Test("A rejected write has its own short line and a log word with no detail")
    func rejectedWords() {
        #expect(MusicService.message(for: MusicError.rejected) == "YouTube Music didn't accept that. Try again.")
        #expect(MusicService.logDescription(of: MusicError.rejected) == "rejected")
        #expect(!MusicService.message(for: MusicError.rejected).contains("\u{2014}"))
    }

    // MARK: - Rating outcomes

    @Test("A refusal or a failed call shows in the notice line in the hotkey's words, as an error", arguments: [
        (MusicActionOutcome.nothingPlaying, "Nothing is playing"),
        (.signedOut, "Sign in to YouTube Music"),
        (.failed, "Couldn't reach YouTube Music"),
        (.musicHidden, "Show Music in the menu bar"),
    ])
    func postsAnOutcome(outcome: MusicActionOutcome, text: String) {
        let h = ActionsHarness()

        h.store.post(outcome)

        #expect(h.store.notice?.text == text)
        #expect(h.store.notice?.isError == true)
    }

    @Test("A rating that went through posts no line, and leaves one already showing", arguments: [
        MusicActionOutcome.liked, .likeRemoved, .disliked, .dislikeRemoved,
    ])
    func successfulRatingPostsNothing(outcome: MusicActionOutcome) {
        let h = ActionsHarness()
        h.store.post(outcome)
        #expect(h.store.notice == nil)

        h.store.post("Saved to Road Trip")
        h.store.post(outcome)
        #expect(h.store.notice?.text == "Saved to Road Trip")
    }

    @Test("A quiet outcome posts nothing, and leaves a line already showing")
    func quietOutcomePostsNothing() {
        let h = ActionsHarness()
        h.store.post(.quiet)
        #expect(h.store.notice == nil)

        h.store.post("Saved to Road Trip")
        h.store.post(.quiet)
        #expect(h.store.notice?.text == "Saved to Road Trip")
    }

    @Test("Posting only a failure shows a failed call and a gone session, and nothing for a call that went through", arguments:
        MusicActionOutcome.allCases)
    func postsOnlyFailures(outcome: MusicActionOutcome) {
        let h = ActionsHarness()

        h.store.postIfFailed(outcome)

        if outcome == .failed || outcome == .signedOut {
            #expect(h.store.notice?.text == outcome.noticeText)
            #expect(h.store.notice?.isError == true)
        } else {
            #expect(h.store.notice == nil)
        }
    }

    @Test("A newer outcome replaces the older line, and the older line's timer does not clear it")
    func outcomesReplaceEachOther() async {
        let h = ActionsHarness(noticeDuration: .milliseconds(80))
        h.store.post(.failed)
        try? await Task.sleep(for: .milliseconds(50))
        h.store.post(.nothingPlaying)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(h.store.notice?.text == "Nothing is playing")
        #expect(await h.until { h.store.notice == nil })
    }
}
