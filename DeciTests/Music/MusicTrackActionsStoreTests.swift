// DeciTests/Music/MusicTrackActionsStoreTests.swift
// The state behind the song actions: the save to playlist menu (load, save, already in, errors, late answers),
// removing a row from a playlist page, the short notice line, and a session that ends.

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
}
