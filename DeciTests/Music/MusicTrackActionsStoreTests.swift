// DeciTests/Music/MusicTrackActionsStoreTests.swift
// The state behind the song actions: the add-to-playlist picker (load, save, already in, errors, late answers),
// removing a row from a playlist page, the Pin / Unpin toggle, the short notice line, and a session that ends.

import Foundation
import Testing
@testable import Deci

@MainActor
private final class ActionProbe {
    var expired = 0
}

@MainActor
private struct ActionsHarness {
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

    func pageIds(_ id: String = "VLPLfixtureMine") -> [String] {
        if case .loaded(let page) = browse.pageState(id) { page.tracks.map(\.videoId) } else { [] }
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

    @Test("Choosing a playlist adds the song, closes the picker and says it saved")
    func chooseSaves() async {
        let h = ActionsHarness()
        await h.openPicker()
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")
        h.store.choose(road)

        #expect(await h.until { h.store.picker == nil })
        #expect(await h.backend.addToPlaylistCalls == [FakeMusicBackend.AddToPlaylistCall(videoId: "vid-1", playlistId: "PLone")])
        #expect(h.store.notice?.text == "Saved to Road Trip")
        #expect(h.store.notice?.isError == false)
    }

    @Test("The picker shows saving while the call is out, and a second tap does not send a second call")
    func chooseOnlyOnce() async {
        let h = ActionsHarness()
        await h.openPicker()
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")

        h.store.choose(road)
        #expect(h.store.picker?.isSaving == true)
        h.store.choose(road)
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "Workout"))
        await gate.open()
        #expect(await h.until { h.store.picker == nil })
        #expect(await h.backend.addToPlaylistCalls.count == 1)
    }

    @Test("A save still out is not sent again from a picker closed and opened again")
    func reopenedPickerDoesNotResend() async {
        let h = ActionsHarness()
        await h.openPicker()
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        let road = MusicSamples.playlistOption("PLone", title: "Road Trip")
        h.store.choose(road)
        h.store.closePicker()
        await h.openPicker()
        h.store.choose(road)
        #expect(h.store.picker?.isSaving == false)
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        await h.letLateWorkLand()
        #expect(await h.backend.addToPlaylistCalls.count == 1)
    }

    @Test("A playlist that already holds the song sends nothing and says so")
    func chooseAlreadyIn() async {
        let h = ActionsHarness()
        await h.openPicker()
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true))

        #expect(h.store.picker == nil)
        #expect(h.store.notice?.text == "Already in Workout")
        #expect(h.store.notice?.isError == false)
        await h.letLateWorkLand()
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
    }

    @Test("A failed save keeps the picker open for another try, with an error line")
    func chooseFailureKeepsPicker() async {
        let h = ActionsHarness()
        await h.openPicker()
        await h.backend.setAddToPlaylistError(MusicError.rejected)
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))

        #expect(await h.until { h.store.notice != nil })
        // No dedupe option goes out, so a refusal most likely means the song is already there.
        #expect(h.store.notice?.text == "Not added. Road Trip may already have it.")
        #expect(h.store.notice?.isError == true)
        #expect(h.store.picker?.isSaving == false)
        #expect(h.options?.count == 2)

        await h.backend.setAddToPlaylistError(nil)
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.store.picker == nil })
        #expect(h.store.notice?.text == "Saved to Road Trip")
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

    // MARK: - Pin to Listen again

    @Test("Pin sends the pin token, then the row offers Unpin, and the next tap sends the unpin token")
    func pinToggles() async {
        let h = ActionsHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        #expect(h.store.actions(for: track, in: .none) == [.saveToPlaylist, .pinToListenAgain])

        h.store.togglePin(track)
        #expect(await h.until { h.store.actions(for: track, in: .none).contains(.unpinFromListenAgain) })
        #expect(await h.backend.feedbackTokens == ["pin-token"])
        #expect(h.store.notice?.text == "Pinned to Listen again")
        #expect(h.store.notice?.isError == false)

        h.store.togglePin(track)
        #expect(await h.until { h.store.actions(for: track, in: .none).contains(.pinToListenAgain) })
        #expect(await h.backend.feedbackTokens == ["pin-token", "unpin-token"])
        #expect(h.store.notice?.text == "Unpinned from Listen again")
    }

    @Test("A song that starts pinned offers Unpin and sends the unpin token first")
    func pinnedStartsWithUnpin() async {
        let h = ActionsHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle(isPinned: true))
        #expect(h.store.actions(for: track, in: .none).contains(.unpinFromListenAgain))
        h.store.togglePin(track)
        #expect(await h.until { h.store.actions(for: track, in: .none).contains(.pinToListenAgain) })
        #expect(await h.backend.feedbackTokens == ["unpin-token"])
    }

    @Test("A failed pin leaves the row as it was and shows an error line")
    func pinFailure() async {
        let h = ActionsHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        await h.backend.setFeedbackError(MusicError.rejected)
        h.store.togglePin(track)
        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.isError == true)
        #expect(h.store.actions(for: track, in: .none).contains(.pinToListenAgain))
    }

    @Test("A second tap while the pin is out sends nothing more")
    func pinOnlyOnce() async {
        let h = ActionsHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        let gate = MusicTestGate()
        await h.backend.setFeedbackGate(gate)
        h.store.togglePin(track)
        h.store.togglePin(track)
        await gate.open()
        #expect(await h.until { h.store.actions(for: track, in: .none).contains(.unpinFromListenAgain) })
        #expect(await h.backend.feedbackTokens.count == 1)
    }

    @Test("A song with no toggle, or none for its next move, sends nothing")
    func pinNeedsToggle() async {
        let h = ActionsHarness()
        h.store.togglePin(MusicSamples.track("v1"))
        h.store.togglePin(MusicSamples.track("v2", pin: MusicSamples.pinToggle(isPinned: false, pin: nil, unpin: "u")))
        await h.letLateWorkLand()
        #expect(await h.backend.feedbackTokens.isEmpty)
        #expect(h.store.notice == nil)
    }

    @Test("A pinned song is pinned wherever the same song shows a toggle, and other songs are not touched")
    func pinFollowsTheSong() async {
        let h = ActionsHarness()
        let here = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        let elsewhere = MusicSamples.track("v1", title: "Same song, other row", pin: MusicSamples.pinToggle())
        let other = MusicSamples.track("v2", pin: MusicSamples.pinToggle())
        h.store.togglePin(here)
        #expect(await h.until { h.store.actions(for: here, in: .none).contains(.unpinFromListenAgain) })
        #expect(h.store.actions(for: elsewhere, in: .none).contains(.unpinFromListenAgain))
        #expect(h.store.actions(for: other, in: .none).contains(.pinToListenAgain))
    }

    @Test("A row loaded since the pin, with its own state and tokens, shows its own and sends its own token")
    func reloadedRowShowsItsOwn() async {
        let h = ActionsHarness()
        let here = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        h.store.togglePin(here)
        #expect(await h.until { h.store.actions(for: here, in: .none).contains(.unpinFromListenAgain) })

        // Unpinned on the web since: the fresh row says Pin again, with new tokens.
        let reloaded = MusicSamples.track("v1", pin: MusicSamples.pinToggle(isPinned: false, pin: "pin-2", unpin: "unpin-2"))
        #expect(h.store.actions(for: reloaded, in: .none).contains(.pinToListenAgain))
        h.store.togglePin(reloaded)
        #expect(await h.until { await h.backend.feedbackTokens.count == 2 })
        #expect(await h.backend.feedbackTokens == ["pin-token", "pin-2"])
        #expect(h.store.actions(for: reloaded, in: .none).contains(.unpinFromListenAgain))
    }

    @Test("A row with no toggle never gains one from another row's pin")
    func pinDoesNotInvent() async {
        let h = ActionsHarness()
        let withToggle = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        let without = MusicSamples.track("v1")
        h.store.togglePin(withToggle)
        #expect(await h.until { h.store.actions(for: withToggle, in: .none).contains(.unpinFromListenAgain) })
        #expect(h.store.actions(for: without, in: .none) == [.saveToPlaylist])
    }

    @Test("A pin that finds the session gone tells the service")
    func pinSignedOut() async {
        let h = ActionsHarness()
        await h.backend.setFeedbackError(MusicError.signedOut)
        h.store.togglePin(MusicSamples.track("v1", pin: MusicSamples.pinToggle()))
        #expect(await h.until { h.probe.expired == 1 })
        #expect(h.store.notice == nil)
    }

    // MARK: - The action list

    @Test("Pin on a playlist sends its pin token, then it offers Unpin, and the next tap sends the unpin token")
    func collectionPinToggles() async {
        let h = ActionsHarness()
        var playlist = MusicSamples.collection("VLPLmine")
        playlist.listenAgainPin = MusicSamples.pinToggle()
        #expect(h.store.listenAgainPin(for: playlist)?.isPinned == false)

        h.store.togglePin(playlist)
        #expect(await h.until { h.store.listenAgainPin(for: playlist)?.isPinned == true })
        #expect(await h.backend.feedbackTokens == ["pin-token"])
        #expect(h.store.notice?.text == "Pinned to Listen again")

        h.store.togglePin(playlist)
        #expect(await h.until { h.store.listenAgainPin(for: playlist)?.isPinned == false })
        #expect(await h.backend.feedbackTokens == ["pin-token", "unpin-token"])
        #expect(h.store.notice?.text == "Unpinned from Listen again")
    }

    @Test("A pin from a playlist's page shows on its tiles too, and other playlists are not touched")
    func pagePinSharesCollectionState() async {
        let h = ActionsHarness()
        var page = MusicSamples.page("VLPLmine")
        page.listenAgainPin = MusicSamples.pinToggle()
        var tile = MusicSamples.collection("VLPLmine")
        tile.listenAgainPin = MusicSamples.pinToggle()
        var other = MusicSamples.collection("VLPLother")
        other.listenAgainPin = MusicSamples.pinToggle()

        h.store.togglePin(page)
        #expect(await h.until { h.store.listenAgainPin(for: page)?.isPinned == true })
        #expect(h.store.listenAgainPin(for: tile)?.isPinned == true)
        #expect(h.store.listenAgainPin(for: other)?.isPinned == false)
        #expect(await h.backend.feedbackTokens == ["pin-token"])
    }

    @Test("A playlist or page with no toggle, or no token for its next step, offers no pin and sends nothing")
    func collectionWithoutPin() async {
        let h = ActionsHarness()
        let bare = MusicSamples.collection("VLPLbare")
        var half = MusicSamples.collection("VLPLhalf")
        half.listenAgainPin = MusicSamples.pinToggle(pin: nil)
        let page = MusicSamples.page("VLPLbare")
        #expect(h.store.listenAgainPin(for: bare) == nil)
        #expect(h.store.listenAgainPin(for: half) == nil)
        #expect(h.store.listenAgainPin(for: page) == nil)

        h.store.togglePin(bare)
        h.store.togglePin(half)
        h.store.togglePin(page)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await h.backend.feedbackTokens.isEmpty)
    }

    @Test("The store's list is the model's list, with the pin state it knows about")
    func actionsMatchTheModel() async {
        let h = ActionsHarness()
        let track = MusicSamples.track("v1", albumBrowseId: "MPREbFixture", setVideoId: "s1", pin: MusicSamples.pinToggle())
        let context = MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true)
        #expect(h.store.actions(for: track, in: context) == MusicTrackActions.available(for: track, in: context))
    }

    // MARK: - The notice line

    @Test("A notice clears itself after its time")
    func noticeClears() async {
        let h = ActionsHarness(noticeDuration: .milliseconds(40))
        await h.openPicker()
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true))
        #expect(h.store.notice != nil)
        #expect(await h.until { h.store.notice == nil })
    }

    @Test("An older notice's timer never clears a newer notice early")
    func newerNoticeSurvives() async {
        let h = ActionsHarness(noticeDuration: .milliseconds(150))
        await h.openPicker()
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "First", contains: true))
        try? await Task.sleep(for: .milliseconds(100))
        await h.openPicker()
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "Second", contains: true))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.store.notice?.text == "Already in Second")
        #expect(await h.until { h.store.notice == nil })
    }

    @Test("Dismissing the notice clears it")
    func dismissNotice() async {
        let h = ActionsHarness()
        await h.openPicker()
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true))
        h.store.dismissNotice()
        #expect(h.store.notice == nil)
    }

    // MARK: - Reset

    @Test("Reset drops the picker, the notice and the pin state, and late answers after it land nowhere")
    func resetDropsEverything() async {
        let h = ActionsHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        h.store.togglePin(track)
        #expect(await h.until { h.store.actions(for: track, in: .none).contains(.unpinFromListenAgain) })

        let gate = MusicTestGate()
        await h.backend.setPlaylistOptionsGate(videoId: "vid-1", gate)
        await h.backend.setPlaylistOptions(videoId: "vid-1", [MusicSamples.playlistOption("PLone")])
        h.store.openPicker(for: h.song)
        #expect(h.store.notice != nil)

        h.store.reset()
        #expect(h.store.picker == nil)
        #expect(h.store.notice == nil)
        #expect(h.store.actions(for: track, in: .none).contains(.pinToListenAgain))
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
}
