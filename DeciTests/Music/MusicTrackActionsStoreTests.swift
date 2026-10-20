// DeciTests/Music/MusicTrackActionsStoreTests.swift
// The state behind the song actions: the save to playlist menu (load, save, already in, errors, late answers),
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

    @Test("A row ticked by a save says Already in on the next click, whatever copy of it the click carried")
    func chooseAfterSaveSaysAlreadyIn() async {
        let h = ActionsHarness()
        await h.openPicker()
        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })

        h.store.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(h.store.notice?.text == "Already in Road Trip")
        await h.letLateWorkLand()
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
        #expect(h.store.picker?.saving.isEmpty == true)
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        await h.letLateWorkLand()
        #expect(await h.backend.addToPlaylistCalls.count == 1)
    }

    @Test("A playlist that already holds the song sends nothing, says so, and leaves the menu open")
    func chooseAlreadyIn() async {
        let h = ActionsHarness()
        await h.openPicker()
        h.store.choose(MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true))

        #expect(h.store.picker != nil)
        #expect(h.store.notice?.text == "Already in Workout")
        #expect(h.store.notice?.isError == false)
        await h.letLateWorkLand()
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
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

    // MARK: - Pin badge state

    @Test("A song, playlist or page reads pinned from its own toggle, and a row with no toggle never does")
    func pinnedReadsTheRowsOwnToggle() {
        let h = ActionsHarness()
        let pinnedSong = MusicSamples.track("v1", pin: MusicSamples.pinToggle(isPinned: true))
        let openSong = MusicSamples.track("v2", pin: MusicSamples.pinToggle(isPinned: false))
        var pinnedTile = MusicSamples.collection("VLPLpinned")
        pinnedTile.listenAgainPin = MusicSamples.pinToggle(isPinned: true)
        var openTile = MusicSamples.collection("VLPLopen")
        openTile.listenAgainPin = MusicSamples.pinToggle(isPinned: false)
        var pinnedPage = MusicSamples.page("VLPLpinned")
        pinnedPage.listenAgainPin = MusicSamples.pinToggle(isPinned: true)
        var openPage = MusicSamples.page("VLPLopen")
        openPage.listenAgainPin = MusicSamples.pinToggle(isPinned: false)

        #expect(h.store.isPinnedToListenAgain(pinnedSong))
        #expect(!h.store.isPinnedToListenAgain(openSong))
        #expect(!h.store.isPinnedToListenAgain(MusicSamples.track("v3")))
        #expect(h.store.isPinnedToListenAgain(pinnedTile))
        #expect(!h.store.isPinnedToListenAgain(openTile))
        #expect(!h.store.isPinnedToListenAgain(MusicSamples.collection("VLPLbare")))
        #expect(h.store.isPinnedToListenAgain(pinnedPage))
        #expect(!h.store.isPinnedToListenAgain(openPage))
        #expect(!h.store.isPinnedToListenAgain(MusicSamples.page("VLPLbare")))
    }

    @Test("A pinned song flips to not pinned after its unpin lands, and back after the next pin")
    func songBadgeFollowsToggle() async {
        let h = ActionsHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        #expect(!h.store.isPinnedToListenAgain(track))

        h.store.togglePin(track)
        #expect(await h.until { h.store.isPinnedToListenAgain(track) })
        h.store.togglePin(track)
        #expect(await h.until { !h.store.isPinnedToListenAgain(track) })
        #expect(await h.backend.feedbackTokens == ["pin-token", "unpin-token"])
    }

    @Test("The song stays unpinned until YouTube says the pin worked")
    func songBadgeWaitsForTheCall() async {
        let h = ActionsHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        let gate = MusicTestGate()
        await h.backend.setFeedbackGate(gate)

        h.store.togglePin(track)
        #expect(await h.until { await h.backend.feedbackTokens.count == 1 })
        #expect(!h.store.isPinnedToListenAgain(track))
        await gate.open()
        #expect(await h.until { h.store.isPinnedToListenAgain(track) })
    }

    @Test("A failed pin leaves the badge off")
    func failedPinKeepsBadgeOff() async {
        let h = ActionsHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        await h.backend.setFeedbackError(MusicError.rejected)
        h.store.togglePin(track)
        #expect(await h.until { h.store.notice != nil })
        #expect(!h.store.isPinnedToListenAgain(track))
    }

    @Test("A pin from a playlist's page flips its tile and the page, and an unpin flips them back")
    func collectionAndPageBadgeFollowToggle() async {
        let h = ActionsHarness()
        var tile = MusicSamples.collection("VLPLmine")
        tile.listenAgainPin = MusicSamples.pinToggle()
        var page = MusicSamples.page("VLPLmine")
        page.listenAgainPin = MusicSamples.pinToggle()
        #expect(!h.store.isPinnedToListenAgain(tile))
        #expect(!h.store.isPinnedToListenAgain(page))

        h.store.togglePin(page)
        #expect(await h.until { h.store.isPinnedToListenAgain(page) })
        #expect(h.store.isPinnedToListenAgain(tile))

        h.store.togglePin(tile)
        #expect(await h.until { !h.store.isPinnedToListenAgain(tile) })
        #expect(!h.store.isPinnedToListenAgain(page))
    }

    @Test("A pinned song, playlist or page with no unpin token still reads pinned, though no Unpin is offered")
    func pinnedWithoutUnpinTokenStillReadsPinned() {
        let h = ActionsHarness()
        let noWayBack = MusicSamples.pinToggle(isPinned: true, pin: "p", unpin: nil)
        let track = MusicSamples.track("v1", pin: noWayBack)
        var tile = MusicSamples.collection("VLPLmine")
        tile.listenAgainPin = noWayBack
        var page = MusicSamples.page("VLPLmine")
        page.listenAgainPin = noWayBack

        #expect(h.store.isPinnedToListenAgain(track))
        #expect(h.store.isPinnedToListenAgain(tile))
        #expect(h.store.isPinnedToListenAgain(page))
        #expect(h.store.listenAgainPin(for: tile) == nil)
        #expect(h.store.listenAgainPin(for: page) == nil)
        #expect(!h.store.actions(for: track, in: .none).contains(.unpinFromListenAgain))
    }

    @Test("A toggle with neither token reads from its own state, and an unpinned one reads not pinned")
    func tokenlessTogglesReadTheirState() {
        let h = ActionsHarness()
        let pinned = MusicSamples.track("v1", pin: MusicSamples.pinToggle(isPinned: true, pin: nil, unpin: nil))
        let open = MusicSamples.track("v2", pin: MusicSamples.pinToggle(isPinned: false, pin: nil, unpin: nil))
        #expect(h.store.isPinnedToListenAgain(pinned))
        #expect(!h.store.isPinnedToListenAgain(open))
    }

    @Test("A pinned song is pinned on every row that carries the toggle, and no other song or collection is")
    func badgeIsPerThing() async {
        let h = ActionsHarness()
        let here = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        let elsewhere = MusicSamples.track("v1", title: "Same song, other row", pin: MusicSamples.pinToggle())
        let without = MusicSamples.track("v1")
        let other = MusicSamples.track("v2", pin: MusicSamples.pinToggle())
        // A collection whose browse id equals the song's video id is a different thing.
        var sameId = MusicSamples.collection("v1")
        sameId.listenAgainPin = MusicSamples.pinToggle()

        h.store.togglePin(here)
        #expect(await h.until { h.store.isPinnedToListenAgain(here) })
        #expect(h.store.isPinnedToListenAgain(elsewhere))
        #expect(!h.store.isPinnedToListenAgain(without))
        #expect(!h.store.isPinnedToListenAgain(other))
        #expect(!h.store.isPinnedToListenAgain(sameId))
    }

    @Test("A row loaded since the pin reads its own state, the old row keeps reading the pin")
    func reloadedRowBadgeReadsItsOwn() async {
        let h = ActionsHarness()
        let here = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        h.store.togglePin(here)
        #expect(await h.until { h.store.isPinnedToListenAgain(here) })

        // Unpinned on the web since: the fresh row says not pinned, with new tokens.
        let reloaded = MusicSamples.track("v1", pin: MusicSamples.pinToggle(isPinned: false, pin: "pin-2", unpin: "unpin-2"))
        #expect(!h.store.isPinnedToListenAgain(reloaded))
        #expect(h.store.isPinnedToListenAgain(here))
    }

    @Test("Reset drops the pin state, so every row reads its own toggle again")
    func resetDropsBadgeState() async {
        let h = ActionsHarness()
        let track = MusicSamples.track("v1", pin: MusicSamples.pinToggle())
        h.store.togglePin(track)
        #expect(await h.until { h.store.isPinnedToListenAgain(track) })

        h.store.reset()
        #expect(!h.store.isPinnedToListenAgain(track))
    }

    @Test("An id with Unicode, emoji and markup reads pinned like any other")
    func unicodeIdsReadPinned() {
        let h = ActionsHarness()
        let id = "VL\u{E9}\u{1F3B5}<b>&amp;</b> 'q'"
        var tile = MusicSamples.collection(id)
        tile.listenAgainPin = MusicSamples.pinToggle(isPinned: true)
        #expect(h.store.isPinnedToListenAgain(tile))
        #expect(h.store.isPinnedToListenAgain(MusicSamples.track(id, pin: MusicSamples.pinToggle(isPinned: true))))
    }

    @Test("A tile wears the badge for a playlist or album pinned to Listen again, and for any collection pinned to Home")
    func tileBadgeCombinesBothPins() async {
        let h = ActionsHarness()
        let home = MusicPinnedItems(items: [
            MusicPinnedItem(kind: .artist, id: "UCpinned", title: "Pinned Artist"),
            MusicPinnedItem(kind: .playlist, id: "VLPLhome", title: "Pinned Playlist"),
            MusicPinnedItem(kind: .album, id: "MPREhome", title: "Pinned Album"),
        ])
        func wears(_ collection: MusicCollection) -> Bool {
            MusicCollectionPinHandler.wearsPinBadge(collection, actions: h.store, home: home)
        }

        var playlist = MusicSamples.collection("VLPLmine")
        playlist.listenAgainPin = MusicSamples.pinToggle()
        var album = MusicSamples.collection("MPREbFixture", kind: .album)
        album.listenAgainPin = MusicSamples.pinToggle(isPinned: true, pin: "p", unpin: nil)
        let homeArtist = MusicSamples.collection("UCpinned", kind: .artist)
        let homePlaylist = MusicSamples.collection("VLPLhome")
        let homeAlbum = MusicSamples.collection("MPREhome", kind: .album)
        let otherArtist = MusicSamples.collection("UCother", kind: .artist)
        // A playlist that shares an id with a pinned artist is not that artist.
        let lookalike = MusicSamples.collection("UCpinned")

        #expect(!wears(playlist))
        #expect(wears(album))
        #expect(wears(homeArtist))
        #expect(wears(homePlaylist))
        #expect(wears(homeAlbum))
        #expect(!wears(otherArtist))
        #expect(!wears(lookalike))

        h.store.togglePin(playlist)
        #expect(await h.until { wears(playlist) })

        home.unpin(MusicPinnedItem(kind: .artist, id: "UCpinned", title: ""))
        home.unpin(MusicPinnedItem(kind: .playlist, id: "VLPLhome", title: ""))
        #expect(!wears(homeArtist))
        #expect(!wears(homePlaylist))
        #expect(wears(homeAlbum))
    }

    @Test("A Home pin does not touch the Listen again state, and a Listen again pin does not touch Home")
    func homePinIsSeparateFromListenAgain() {
        let h = ActionsHarness()
        let home = MusicPinnedItems()
        var playlist = MusicSamples.collection("VLPLmine")
        playlist.listenAgainPin = MusicSamples.pinToggle()

        if let item = MusicPinnedItem(collection: playlist) { home.toggle(item) }

        #expect(home.isPinned(playlist))
        #expect(!h.store.isPinnedToListenAgain(playlist))
        #expect(h.store.listenAgainPin(for: playlist)?.isPinned == false)
        #expect(MusicCollectionPinHandler.wearsPinBadge(playlist, actions: h.store, home: home))
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

    @Test("A song's menu offers Pin to Home in the library block, whether or not YouTube has a Listen again toggle")
    func homeEntryInTheStoreList() {
        let h = ActionsHarness()
        let bare = MusicSamples.track("v1")
        let toggled = MusicSamples.track("v2", pin: MusicSamples.pinToggle())
        #expect(h.store.actions(for: bare, in: .none) == [.saveToPlaylist])
        #expect(h.store.actions(for: bare, in: .none, home: .canPin) == [.saveToPlaylist, .pinHome(.canPin)])
        #expect(h.store.actions(for: toggled, in: .none, home: .pinned) == [.saveToPlaylist, .pinToListenAgain, .pinHome(.pinned)])
        #expect(h.store.actions(for: bare, in: .none, home: .full) == [.saveToPlaylist, .pinHome(.full)])
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

    @Test("The notice stays about 2 seconds unless told otherwise")
    func noticeDefaultTime() {
        #expect(MusicTrackActionsStore.defaultNoticeDuration == .seconds(2))
    }

    @Test("An older notice's timer never clears a newer notice early")
    func newerNoticeSurvives() async {
        let h = ActionsHarness(noticeDuration: .milliseconds(150))
        let first = MusicSamples.playlistOption("PLtwo", title: "First", contains: true)
        await h.openPicker(options: [first])
        h.store.choose(first)
        try? await Task.sleep(for: .milliseconds(100))
        let second = MusicSamples.playlistOption("PLtwo", title: "Second", contains: true)
        await h.openPicker(options: [second])
        h.store.choose(second)
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
