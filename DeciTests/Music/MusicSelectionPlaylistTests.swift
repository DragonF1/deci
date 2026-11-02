// DeciTests/Music/MusicSelectionPlaylistTests.swift
// Phase 2 of the multi-select: the picked songs go to a playlist or out of one in a few calls. The rules of the two new
// actions, the save menu for a selection (tick, mixed mark, empty row; adds only what is missing; chunks of 50; a
// refused batch retried one song at a time), the removal from the playlist that is open, the selection that stays on
// cancel and goes after a write, and the InnerTube body with N actions. Fakes only; nothing here reaches the network.

import Foundation
import Observation
import Testing
@testable import Deci

/// Set by an observation callback, which is `@Sendable`, so a plain variable cannot be captured.
nonisolated private final class PlaylistChangeFlag: @unchecked Sendable {
    private(set) var raised = false
    func raise() { raised = true }
}

/// Counts what a `@MainActor` callback was told.
@MainActor
private final class PlaylistCallCounter {
    var count = 0
}

// MARK: - Rules of the actions

@MainActor
@Suite("MusicSelectionAction playlist rules")
struct MusicSelectionPlaylistActionTests {
    private let a = MusicSamples.track("a")
    private let b = MusicSamples.track("b")

    @Test("Words and blocks: Save sits with the library block, Remove from this playlist with the destructive one")
    func wordsAndGroups() {
        #expect(MusicSelectionAction.saveToPlaylist.title == "Save to playlist")
        #expect(MusicSelectionAction.removeFromPlaylist.title == "Remove from this playlist")
        #expect(MusicSelectionAction.saveToPlaylist.menuTitle(count: 4) == "Save to playlist (4)")
        #expect(MusicSelectionAction.removeFromPlaylist.menuTitle(count: 2) == "Remove from this playlist (2)")
        #expect(MusicSelectionAction.saveToPlaylist.group == .library)
        #expect(MusicSelectionAction.removeFromPlaylist.group == .remove)
    }

    @Test("Save is offered when the playlists can be reached, for any picked song, the one in the player too")
    func saveRules() {
        #expect(MusicSelectionAction.available(for: [a, b], isUpNext: false, playing: nil, savesToPlaylists: true)
            == [.playNext, .addToQueue, .saveToPlaylist])
        // Only the playing song picked: the queue entries go, Save stays.
        #expect(MusicSelectionAction.available(for: [a], isUpNext: false, playing: a, savesToPlaylists: true) == [.saveToPlaylist])
        // The caller does not offer it (offline or signed out): not in the list.
        #expect(MusicSelectionAction.available(for: [a, b], isUpNext: false, playing: nil, savesToPlaylists: false)
            == [.playNext, .addToQueue])
        #expect(MusicSelectionAction.available(for: [], isUpNext: false, playing: nil, savesToPlaylists: true).isEmpty)
    }

    @Test("Remove from this playlist needs rows that can come out, and hides at zero")
    func removeRules() {
        let both = MusicSelectionAction.available(
            for: [a, b], isUpNext: false, playing: nil, savesToPlaylists: true, removableFromPlaylist: 2
        )
        #expect(both == [.playNext, .addToQueue, .saveToPlaylist, .removeFromPlaylist])
        let none = MusicSelectionAction.available(
            for: [a, b], isUpNext: false, playing: nil, savesToPlaylists: true, removableFromPlaylist: 0
        )
        #expect(!none.contains(.removeFromPlaylist))
        // Not offered where the caller does not offer playlists at all, whatever the count.
        let offline = MusicSelectionAction.available(
            for: [a, b], isUpNext: false, playing: nil, savesToPlaylists: false, removableFromPlaylist: 2
        )
        #expect(!offline.contains(.removeFromPlaylist))
    }

    @Test("The blocks of a full menu: queue, library, then the two removals together")
    func fullMenuBlocks() {
        let all = MusicSelectionAction.available(
            for: [a, b], isUpNext: true, playing: nil, savesToPlaylists: true, removableFromPlaylist: 2
        )
        #expect(MusicSelectionAction.groups(of: all)
            == [[.playNext, .addToQueue], [.saveToPlaylist], [.removeFromPlaylist, .removeFromQueue]])
    }

    @Test("The queue rules are as they were when no playlist is on offer")
    func queueRulesUnchanged() {
        #expect(MusicSelectionAction.available(for: [a], isUpNext: false, playing: a).isEmpty)
        #expect(MusicSelectionAction.available(for: [a, b], isUpNext: true, playing: nil)
            == [.playNext, .addToQueue, .removeFromQueue])
    }
}

// MARK: - The save menu for a selection

private extension ActionsHarness {
    func songs(_ ids: [String]) -> [Deci.MusicTrack] {
        ids.map { MusicSamples.track($0, title: "Song \($0)") }
    }

    /// Opens the save menu for the picked `ids` and waits for the list. The options are scripted under the first id,
    /// which is the one the menu asks for.
    func openSelection(_ ids: [String], options: [MusicPlaylistOption] = [MusicSamples.playlistOption("PLone", title: "Road Trip")]) async {
        await backend.setPlaylistOptions(videoId: ids[0], options)
        store.openPicker(forSelection: songs(ids))
        _ = await until { if case .loaded? = store.picker?.load { true } else { false } }
    }

    /// A playlist's only page, its rows as (video id, setVideoId).
    func setRows(_ playlistId: String, _ rows: [(String, String?)]) async {
        let tracks = rows.map { MusicSamples.track($0.0, setVideoId: $0.1) }
        await backend.setPage(MusicSamples.page("VL" + playlistId, tracks: tracks))
    }

    func tapRow(_ playlistId: String) {
        store.choose(options?.first { $0.playlistId == playlistId } ?? MusicSamples.playlistOption(playlistId))
    }

    func held(_ playlistId: String) -> Set<String> {
        store.picker?.held[playlistId] ?? []
    }

    func addCalls() async -> [[String]] {
        await backend.addBatchCalls.map(\.videoIds)
    }
}

@MainActor
@Suite("MusicTrackActionsStore save a selection to a playlist")
struct MusicSelectionSaveToPlaylistTests {
    // MARK: - Opening

    @Test("Opening for a selection takes each song once in list order, names it N songs, and asks for the first id")
    func opens() async {
        let h = ActionsHarness()
        let picked = h.songs(["a", "b", "a", "c"])
        await h.backend.setPlaylistOptions(videoId: "a", [MusicSamples.playlistOption("PLone")])
        h.store.openPicker(forSelection: picked)
        _ = await h.until { if case .loaded? = h.store.picker?.load { true } else { false } }

        #expect(h.store.picker?.title == "3 songs")
        #expect(h.store.picker?.target.key.hasPrefix("tracks:") == true)
        #expect(h.store.picker?.track == nil)
        #expect(h.store.picker?.collection == nil)
        #expect(h.store.picker?.songs.map(\.videoId) == ["a", "b", "c"])
        #expect(await h.backend.playlistOptionsCalls == ["a"])
    }

    @Test("The key follows the songs: the same picks give the same key, other picks another")
    func key() {
        let h = ActionsHarness()
        func key(_ ids: [String]) -> String {
            MusicTrackActionsStore.Picker.Target.tracks(h.songs(ids)).key
        }
        #expect(key(["a", "b", "c"]) == key(["a", "b", "c"]))
        #expect(key(["a", "b", "c"]) != key(["a", "b"]))
        #expect(key(["a", "b", "c"]) != key(["c", "b", "a"]))
        #expect(key(["a", "b", "c"]) != MusicTrackActionsStore.Picker.Target.track(h.song).key)
    }

    @Test("A selection of nothing opens nothing, and one song opens the song's own menu")
    func degenerate() async {
        let h = ActionsHarness()
        h.store.openPicker(forSelection: [])
        #expect(h.store.picker == nil)

        await h.openSelection(["a"])
        #expect(h.store.picker?.track?.videoId == "a")
        #expect(h.store.picker?.title == "Song a")
    }

    @Test("A flag YouTube puts on a row for the first song says nothing about the others, so it is not a tick")
    func flagIsIgnored() async {
        let h = ActionsHarness()
        await h.setRows("PLone", [])
        await h.openSelection(["a", "b"], options: [MusicSamples.playlistOption("PLone", contains: true)])
        #expect(h.ticked.isEmpty)
    }

    // MARK: - What the playlists hold

    @Test("A playlist with every picked song is ticked, one with some is mixed, one with none is empty")
    func membershipStates() async {
        let h = ActionsHarness()
        await h.setRows("PLall", [("a", "s1"), ("b", "s2"), ("c", "s3"), ("z", "s4")])
        await h.setRows("PLsome", [("b", "s5")])
        await h.setRows("PLnone", [("z", "s6")])
        await h.openSelection(["a", "b", "c"], options: [
            MusicSamples.playlistOption("PLall"), MusicSamples.playlistOption("PLsome"), MusicSamples.playlistOption("PLnone"),
        ])

        #expect(await h.until { h.ticked == ["PLall"] && h.held("PLsome") == ["b"] })
        await h.letLateWorkLand()
        let rows = h.options ?? []
        let mixed = rows.filter { h.store.picker?.isMixed($0) == true }.map(\.playlistId)
        #expect(mixed == ["PLsome"])
        #expect(h.held("PLnone").isEmpty)
        #expect(h.store.picker?.isMixed(rows[0]) == false)
    }

    @Test("A playlist that cannot be read counts as holding none")
    func unreadableIsNone() async {
        let h = ActionsHarness()
        await h.backend.setPageError("VLPLone", MusicError.http(500))
        await h.openSelection(["a", "b"])
        await h.letLateWorkLand()
        #expect(h.ticked.isEmpty)
        #expect(h.held("PLone").isEmpty)
        #expect(h.store.picker?.isMixed(h.options![0]) == false)
    }

    // MARK: - Adding

    @Test("A tap on an empty row adds the picked songs in one call, ticks the row and says how many")
    func batchAdd() async {
        let h = ActionsHarness()
        await h.setRows("PLone", [("z", "s1")])
        await h.openSelection(["a", "b", "c"])
        await h.letLateWorkLand()

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Added 3 songs to Road Trip" })
        #expect(h.store.notice?.isError == false)
        #expect(await h.addCalls() == [["a", "b", "c"]])
        #expect(await h.backend.addBatchCalls.first?.playlistId == "PLone")
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
        #expect(h.ticked == ["PLone"])
        #expect(h.store.picker?.saving.isEmpty == true)
    }

    @Test("A second tap while the call is out sends nothing more, and the row shows it is saving")
    func busyRowIgnoresTaps() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        await h.openSelection(["a", "b"])
        await h.letLateWorkLand()

        h.tapRow("PLone")
        #expect(h.store.picker?.saving == ["PLone"])
        h.tapRow("PLone")
        await gate.open()

        #expect(await h.until { h.store.notice?.text == "Added 2 songs to Road Trip" })
        #expect(await h.backend.addBatchCalls.count == 1)
    }

    @Test("A long selection goes in chunks of 50 songs, in order")
    func chunksAtFifty() async {
        let h = ActionsHarness()
        let ids = (1...120).map { "v\($0)" }
        await h.openSelection(ids)
        await h.letLateWorkLand()

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Added 120 songs to Road Trip" })
        let calls = await h.addCalls()
        #expect(calls.map(\.count) == [50, 50, 20])
        #expect(calls.flatMap { $0 } == ids)
        #expect(h.ticked == ["PLone"])
    }

    @Test("A mixed row gets only the songs it lacks, and ends ticked")
    func mixedAddsOnlyMissing() async {
        let h = ActionsHarness()
        await h.setRows("PLone", [("b", "s1")])
        await h.openSelection(["a", "b", "c"])
        #expect(await h.until { h.held("PLone") == ["b"] })
        #expect(h.ticked.isEmpty)

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Added 2 songs to Road Trip" })
        #expect(await h.addCalls() == [["a", "c"]])
        #expect(h.ticked == ["PLone"])
        #expect(h.store.picker?.isMixed(h.options![0]) == false)
    }

    @Test("A tap before the pass has said anything adds every song")
    func unknownAddsAll() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.setRows("PLone", [("b", "s1")])
        await h.backend.setPageGate("VLPLone", gate)
        await h.openSelection(["a", "b", "c"])

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice != nil })
        #expect(await h.addCalls() == [["a", "b", "c"]])
        await gate.open()
    }

    @Test("A refused batch is tried again one song at a time, and the line counts what went in")
    func rejectionFallsBackToSingles() async {
        let h = ActionsHarness()
        await h.backend.setRejectedAdds(["b"])
        await h.openSelection(["a", "b", "c"])
        await h.letLateWorkLand()

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Added 2 of 3 songs to Road Trip" })
        #expect(h.store.notice?.isError == false)
        #expect(await h.addCalls() == [["a", "b", "c"]])
        #expect(await h.backend.addToPlaylistCalls.map(\.videoId) == ["a", "b", "c"])
        // Two of the three are in: the row is mixed, not ticked, and a tap on it tries only the one that is left.
        #expect(h.ticked.isEmpty)
        #expect(h.held("PLone") == ["a", "c"])
        #expect(h.store.picker?.isMixed(h.options![0]) == true)
        #expect(h.store.picker?.saving.isEmpty == true)

        h.tapRow("PLone")
        #expect(await h.until { h.store.notice?.text != "Added 2 of 3 songs to Road Trip" })
        #expect(await h.addCalls().last == ["b"])
    }

    @Test("Only the refused chunk is retried singly; the chunks before and after it go whole")
    func fallbackIsPerChunk() async {
        let h = ActionsHarness()
        let ids = (1...120).map { "v\($0)" }
        await h.backend.setRejectedAdds(["v60"])
        await h.openSelection(ids)
        await h.letLateWorkLand()

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Added 119 of 120 songs to Road Trip" })
        #expect(await h.addCalls().map(\.count) == [50, 50, 20])
        // The middle chunk (v51 to v100) went song by song.
        #expect(await h.backend.addToPlaylistCalls.map(\.videoId) == (51...100).map { "v\($0)" })
    }

    @Test("When every song is refused the line says the playlist may already have them, and nothing is ticked")
    func everythingRefused() async {
        let h = ActionsHarness()
        await h.backend.setAddToPlaylistError(MusicError.rejected)
        await h.openSelection(["a", "b"])
        await h.letLateWorkLand()

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Not added. Road Trip may already have them." })
        #expect(h.store.notice?.isError == true)
        #expect(await h.backend.addToPlaylistCalls.map(\.videoId) == ["a", "b"])
        #expect(h.ticked.isEmpty)
        #expect(h.store.picker?.saving.isEmpty == true)
    }

    @Test("One song refused alone is not retried: there is nothing smaller to try")
    func singleChunkOfOneIsNotRetried() async {
        let h = ActionsHarness()
        await h.backend.setRejectedAdds(["a"])
        await h.setRows("PLone", [("b", "s1")])
        await h.openSelection(["a", "b"])
        #expect(await h.until { h.held("PLone") == ["b"] })

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Not added. Road Trip may already have them." })
        #expect(await h.addCalls() == [["a"]])
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
    }

    @Test("Another kind of failure stops the add with its own line and tries nothing smaller")
    func otherFailureStops() async {
        let h = ActionsHarness()
        await h.backend.setAddToPlaylistError(MusicError.forbidden)
        await h.openSelection(["a", "b"])
        await h.letLateWorkLand()

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == MusicTrackActionsStore.playlistForbiddenText })
        #expect(h.store.notice?.isError == true)
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
        #expect(h.ticked.isEmpty)
    }

    @Test("A gone session signs out and says nothing else")
    func signedOutExpires() async {
        let h = ActionsHarness()
        await h.backend.setAddToPlaylistError(MusicError.signedOut)
        await h.openSelection(["a", "b"])
        await h.letLateWorkLand()

        h.tapRow("PLone")

        #expect(await h.until { h.probe.expired == 1 })
        #expect(h.store.notice == nil)
    }

    @Test("A session that ends while a chunk is out gets none of the chunks after it, and no line")
    func sessionEndsBetweenChunks() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        await h.openSelection((1...120).map { "v\($0)" })
        await h.letLateWorkLand()

        h.tapRow("PLone")
        _ = await h.until { await h.backend.addBatchCalls.count == 1 }
        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()

        #expect(await h.backend.addBatchCalls.count == 1)
        #expect(h.store.notice == nil)
    }

    // MARK: - Taking the songs out

    @Test("A tap on a ticked row reads the playlist once and removes every copy of every picked song in one call")
    func tickedRemovesAllCopies() async {
        let h = ActionsHarness()
        await h.setRows("PLone", [("a", "s1"), ("x", "sx"), ("b", "s2"), ("a", "s3"), ("c", "s4")])
        await h.openSelection(["a", "b", "c"])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.letLateWorkLand()
        // A copy that appeared since the pass read the playlist is found by the read of the tap.
        await h.setRows("PLone", [("a", "s1"), ("x", "sx"), ("b", "s2"), ("a", "s3"), ("c", "s4"), ("c", "s5")])

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Removed 3 songs from Road Trip" })
        #expect(h.store.notice?.isError == false)
        let expected = [("a", "s1"), ("b", "s2"), ("a", "s3"), ("c", "s4"), ("c", "s5")]
            .map { MusicPlaylistRemoval(videoId: $0.0, setVideoId: $0.1) }
        let calls = await h.backend.removeBatchCalls
        #expect(calls.map(\.removals) == [expected])
        #expect(calls.first?.playlistId == "PLone")
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        // One read for the pass, one for the tap.
        #expect(await h.backend.pageCalls == ["VLPLone", "VLPLone"])
        #expect(h.ticked.isEmpty)
        #expect(h.held("PLone").isEmpty)
        #expect(h.store.picker?.saving.isEmpty == true)
    }

    @Test("Removing from a playlist whose page is open takes each removed row off the page")
    func removalLandsOnTheOpenPage() async {
        let h = ActionsHarness()
        _ = await h.openPage([
            MusicSamples.track("a", setVideoId: "s1"), MusicSamples.track("x", setVideoId: "sx"),
            MusicSamples.track("b", setVideoId: "s2"), MusicSamples.track("a", setVideoId: "s3"),
        ], id: "VLPLone")
        await h.openSelection(["a", "b"])
        #expect(await h.until { h.ticked == ["PLone"] })

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Removed 2 songs from Road Trip" })
        #expect(h.pageIds("VLPLone") == ["x"])
    }

    @Test("A long removal goes in chunks of 50 rows")
    func removalChunks() async {
        let h = ActionsHarness()
        let ids = (1...60).map { "v\($0)" }
        await h.setRows("PLone", ids.map { ($0, "s-\($0)") })
        await h.openSelection(ids)
        #expect(await h.until { h.ticked == ["PLone"] })

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Removed 60 songs from Road Trip" })
        #expect(await h.backend.removeBatchCalls.map(\.removals.count) == [50, 10])
    }

    @Test("A refused removal leaves the row ticked, says so, and a tap on it tries again")
    func removalRefused() async {
        let h = ActionsHarness()
        await h.setRows("PLone", [("a", "s1"), ("b", "s2")])
        await h.openSelection(["a", "b"])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.backend.setRemoveFromPlaylistError(MusicError.rejected)

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Not removed from Road Trip." })
        #expect(h.store.notice?.isError == true)
        #expect(h.ticked == ["PLone"])
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.picker?.removing.isEmpty == true)

        await h.backend.setRemoveFromPlaylistError(nil)
        h.tapRow("PLone")
        #expect(await h.until { h.store.notice?.text == "Removed 2 songs from Road Trip" })
        #expect(h.ticked.isEmpty)
    }

    @Test("A playlist that no longer holds the songs says it could not find them, and sends nothing")
    func removalNotFound() async {
        let h = ActionsHarness()
        await h.setRows("PLone", [("a", "s1"), ("b", "s2")])
        await h.openSelection(["a", "b"])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.setRows("PLone", [("z", "sz")])

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Not removed. Couldn't find them in Road Trip." })
        #expect(await h.backend.removeBatchCalls.isEmpty)
    }

    @Test("A removal read that lands after the menu closed sends nothing")
    func removalDroppedWhenClosed() async {
        let h = ActionsHarness()
        await h.setRows("PLone", [("a", "s1"), ("b", "s2")])
        await h.openSelection(["a", "b"])
        #expect(await h.until { h.ticked == ["PLone"] })
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLone", gate)

        h.tapRow("PLone")
        h.store.closePicker()
        await gate.open()
        await h.letLateWorkLand()

        #expect(await h.backend.removeBatchCalls.isEmpty)
        #expect(h.store.notice == nil)
    }

    // MARK: - Whether a write landed

    @Test("Closing a selection's menu says whether a write landed, and a menu of one song never does")
    func closeReportsWrites() async {
        let h = ActionsHarness()
        await h.openSelection(["a", "b"])
        await h.letLateWorkLand()
        #expect(h.store.closePicker() == false)

        await h.openSelection(["a", "b"])
        await h.letLateWorkLand()
        h.tapRow("PLone")
        _ = await h.until { h.store.notice?.text == "Added 2 songs to Road Trip" }
        #expect(h.store.closePicker() == true)

        // The same write from the "..." menu of one song is not a selection's.
        await h.openPicker(options: [MusicSamples.playlistOption("PLone", title: "Road Trip")])
        h.tapRow("PLone")
        _ = await h.until { h.store.notice?.text == "Saved to Road Trip" }
        #expect(h.store.closePicker() == false)
    }

    @Test("Closing the menu while an add is still out counts as a write, so the selection ends with it")
    func closeWhileSavingCounts() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        await h.openSelection(["a", "b"])
        await h.letLateWorkLand()
        h.tapRow("PLone")
        #expect(h.store.picker?.saving == ["PLone"])

        #expect(h.store.closePicker() == true)
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Added 2 songs to Road Trip" })
    }

    @Test("A removal still out when the menu closes counts too")
    func closeWhileRemovingCounts() async {
        let h = ActionsHarness()
        await h.setRows("PLone", [("a", "s1"), ("b", "s2")])
        await h.openSelection(["a", "b"])
        #expect(await h.until { h.ticked == ["PLone"] })
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)
        h.tapRow("PLone")
        _ = await h.until { await h.backend.removeBatchCalls.count == 1 }

        #expect(h.store.closePicker() == true)
        await gate.open()
    }

    @Test("A single song's menu with a write out is still not a selection's")
    func closeWhileSavingOneSongOutsideSelection() async {
        let h = ActionsHarness()
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        await h.openPicker(options: [MusicSamples.playlistOption("PLone", title: "Road Trip")])
        h.tapRow("PLone")
        #expect(h.store.closePicker() == false)
        await gate.open()
    }

    @Test("When a later chunk fails the line says how many went in, and what went in is kept")
    func partialAddFailure() async {
        let h = ActionsHarness()
        let ids = (1...120).map { "v\($0)" }
        await h.backend.setAddError(videoId: "v60", MusicError.forbidden)
        await h.openSelection(ids)
        await h.letLateWorkLand()

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Added 50 of 120 songs to Road Trip" })
        #expect(h.store.notice?.isError == true)
        // The failing chunk is not retried song by song, and the chunk after it is never sent.
        #expect(await h.addCalls().map(\.count) == [50, 50])
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
        #expect(h.held("PLone") == Set(ids[0..<50]))
        #expect(h.store.picker?.isMixed(h.options![0]) == true)
        #expect(h.ticked.isEmpty)
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.closePicker() == true)
    }

    @Test("A failure on the first chunk keeps the failure's own line")
    func firstChunkFailureKeepsItsLine() async {
        let h = ActionsHarness()
        await h.backend.setAddError(videoId: "v1", MusicError.forbidden)
        await h.openSelection((1...60).map { "v\($0)" })
        await h.letLateWorkLand()

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == MusicTrackActionsStore.playlistForbiddenText })
        #expect(h.store.picker?.held["PLone"] == nil)
    }

    @Test("When a later chunk of a removal fails the line says how many went out, and they leave the open page")
    func partialRemovalFailure() async {
        let h = ActionsHarness()
        let ids = (1...60).map { "v\($0)" }
        _ = await h.openPage(ids.map { MusicSamples.track($0, setVideoId: "s-\($0)") })
        await h.openSelection(ids, options: [MusicSamples.playlistOption("PLfixtureMine", title: "Road Trip")])
        #expect(await h.until { h.ticked == ["PLfixtureMine"] })
        await h.backend.setRemoveFromPlaylistError(setVideoId: "s-v55", MusicError.rejected)

        h.tapRow("PLfixtureMine")

        #expect(await h.until { h.store.notice?.text == "Removed 50 of 60 songs from Road Trip" })
        #expect(h.store.notice?.isError == true)
        #expect(h.pageIds() == (51...60).map { "v\($0)" })
        // The playlist still holds ten of them: the row stays ticked for another try.
        #expect(h.ticked == ["PLfixtureMine"])
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.closePicker() == true)
    }

    @Test("A removal that fails at its first call keeps the plain line")
    func firstCallRemovalFailure() async {
        let h = ActionsHarness()
        await h.setRows("PLone", [("a", "s1"), ("b", "s2")])
        await h.openSelection(["a", "b"])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.backend.setRemoveFromPlaylistError(MusicError.rejected)

        h.tapRow("PLone")

        #expect(await h.until { h.store.notice?.text == "Not removed from Road Trip." })
        #expect(h.store.closePicker() == false)
    }

    @Test("A write that did not land does not count: a refused add leaves the menu as a cancel")
    func failedWriteDoesNotCount() async {
        let h = ActionsHarness()
        await h.backend.setAddToPlaylistError(MusicError.rejected)
        await h.openSelection(["a", "b"])
        await h.letLateWorkLand()
        h.tapRow("PLone")
        _ = await h.until { h.store.notice?.isError == true }
        #expect(h.store.closePicker() == false)
    }

    @Test("A partly landed batch counts as a write")
    func partialWriteCounts() async {
        let h = ActionsHarness()
        await h.backend.setRejectedAdds(["b"])
        await h.openSelection(["a", "b", "c"])
        await h.letLateWorkLand()
        h.tapRow("PLone")
        _ = await h.until { h.store.notice?.text == "Added 2 of 3 songs to Road Trip" }
        #expect(h.store.closePicker() == true)
    }
}

// MARK: - Remove from this playlist

@MainActor
@Suite("MusicTrackActionsStore remove the selection from the open playlist")
struct MusicSelectionRemoveRowsTests {
    private func rows(_ ids: [String]) -> [Deci.MusicTrack] {
        ids.map { MusicSamples.track($0, setVideoId: "s-\($0)") }
    }

    @Test("One call carries every row's place, the rows leave the page, and the line counts them")
    func removesRows() async {
        let h = ActionsHarness()
        let tracks = rows(["a", "b", "c", "d"])
        let context = await h.openPage(tracks)

        h.store.removeRows(Array(tracks[0...2]), in: context)

        #expect(await h.until { h.store.notice?.text == "Removed 3 songs from Mine" })
        #expect(h.store.notice?.isError == false)
        let calls = await h.backend.removeBatchCalls
        #expect(calls.count == 1)
        #expect(calls.first?.playlistId == "VLPLfixtureMine")
        #expect(calls.first?.removals == ["a", "b", "c"].map { MusicPlaylistRemoval(videoId: $0, setVideoId: "s-\($0)") })
        #expect(h.pageIds() == ["d"])
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
    }

    @Test("Two picked copies of one song are two rows, both go")
    func sameSongTwice() async {
        let h = ActionsHarness()
        let tracks = [
            MusicSamples.track("a", setVideoId: "s1"), MusicSamples.track("b", setVideoId: "s2"),
            MusicSamples.track("a", setVideoId: "s3"),
        ]
        let context = await h.openPage(tracks)

        h.store.removeRows([tracks[0], tracks[2]], in: context)

        #expect(await h.until { h.store.notice?.text == "Removed 2 songs from Mine" })
        #expect(await h.backend.removeBatchCalls.first?.removals.map(\.setVideoId) == ["s1", "s3"])
        #expect(h.pageIds() == ["b"])
    }

    @Test("A row with no place is left out, and a pick with none at all sends nothing")
    func rowsWithoutAPlace() async {
        let h = ActionsHarness()
        let placed = MusicSamples.track("a", setVideoId: "s1")
        let loose = MusicSamples.track("b")
        let context = await h.openPage([placed, loose])

        h.store.removeRows([placed, loose], in: context)
        #expect(await h.until { h.store.notice?.text == "Removed 1 song from Mine" })
        #expect(await h.backend.removeBatchCalls.first?.removals.map(\.videoId) == ["a"])

        let before = await h.backend.removeBatchCalls.count
        h.store.removeRows([loose], in: context)
        await h.letLateWorkLand()
        #expect(await h.backend.removeBatchCalls.count == before)
    }

    @Test("Nothing goes out for a page the user cannot edit, Liked music, or a page that is no playlist")
    func contextRules() async {
        let h = ActionsHarness()
        let tracks = rows(["a", "b"])
        let contexts = [
            MusicTrackContext(pageBrowseId: "VLPLmine", pageTitle: "Mine", pageIsEditable: false),
            MusicTrackContext(pageBrowseId: "VLLM", pageTitle: "Liked", pageIsEditable: true),
            MusicTrackContext(pageBrowseId: "MPREb_album", pageTitle: "Album", pageIsEditable: true),
            MusicTrackContext(pageBrowseId: nil, pageTitle: nil, pageIsEditable: false),
            .upNext,
        ]
        for context in contexts { h.store.removeRows(tracks, in: context) }
        await h.letLateWorkLand()
        #expect(await h.backend.removeBatchCalls.isEmpty)
        #expect(h.store.notice == nil)
    }

    @Test("A long pick goes in chunks of 50, each landing on the page as it is answered")
    func chunks() async {
        let h = ActionsHarness()
        let ids = (1...60).map { "v\($0)" }
        let tracks = rows(ids)
        let context = await h.openPage(tracks)

        h.store.removeRows(tracks, in: context)

        #expect(await h.until { h.store.notice?.text == "Removed 60 songs from Mine" })
        #expect(await h.backend.removeBatchCalls.map(\.removals.count) == [50, 10])
        #expect(h.pageIds().isEmpty)
    }

    @Test("A call that fails after another landed says how many went, and the rows before it stay removed")
    func refused() async {
        let h = ActionsHarness()
        let tracks = rows((1...60).map { "v\($0)" })
        let context = await h.openPage(tracks)
        // The second chunk holds v51 to v60: refuse the call that carries s-v55.
        await h.backend.setRemoveFromPlaylistError(setVideoId: "s-v55", MusicError.rejected)

        h.store.removeRows(tracks, in: context)

        #expect(await h.until { h.store.notice?.text == "Removed 50 of 60 songs from Mine" })
        #expect(h.store.notice?.isError == true)
        #expect(h.pageIds() == (51...60).map { "v\($0)" })
    }

    @Test("A refused first call leaves every row on the page and says nothing went")
    func firstCallRefused() async {
        let h = ActionsHarness()
        let tracks = rows(["a", "b", "c"])
        let context = await h.openPage(tracks)
        await h.backend.setRemoveFromPlaylistError(MusicError.rejected)

        h.store.removeRows(tracks, in: context)

        #expect(await h.until { h.store.notice?.text == "Not removed from Mine." })
        #expect(h.store.notice?.isError == true)
        #expect(h.pageIds() == ["a", "b", "c"])
    }

    @Test("The done callback runs once, when every call has landed, and never for a failure")
    func onRemoved() async {
        let h = ActionsHarness()
        let tracks = rows((1...60).map { "v\($0)" })
        let context = await h.openPage(tracks)
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)
        let done = PlaylistCallCounter()

        h.store.removeRows(tracks, in: context, onRemoved: { done.count += 1 })
        _ = await h.until { await h.backend.removeBatchCalls.count == 1 }
        #expect(done.count == 0)
        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Removed 60 songs from Mine" })
        #expect(done.count == 1)

        // A failure of the second call: the callback is not run.
        let other = rows((61...120).map { "v\($0)" })
        let again = await h.openPage(other, id: "VLPLfixtureOther")
        await h.backend.setRemoveFromPlaylistError(setVideoId: "s-v115", MusicError.rejected)
        h.store.removeRows(other, in: again, onRemoved: { done.count += 1 })
        #expect(await h.until { h.store.notice?.text == "Removed 50 of 60 songs from Mine" })
        #expect(done.count == 1)
    }

    @Test("A session that ends before the answer drops it, with no line and the page as it is")
    func sessionEnds() async {
        let h = ActionsHarness()
        let tracks = rows(["a", "b"])
        let context = await h.openPage(tracks)
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)

        h.store.removeRows(tracks, in: context)
        _ = await h.until { await h.backend.removeBatchCalls.count == 1 }
        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()

        #expect(h.store.notice == nil)
        #expect(h.pageIds() == ["a", "b"])
    }

    @Test("The same pick sent twice while the first is out goes once")
    func busy() async {
        let h = ActionsHarness()
        let tracks = rows(["a", "b"])
        let context = await h.openPage(tracks)
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)

        h.store.removeRows(tracks, in: context)
        h.store.removeRows(tracks, in: context)
        _ = await h.until { await h.backend.removeBatchCalls.count >= 1 }
        await gate.open()

        #expect(await h.until { h.store.notice?.text == "Removed 2 songs from Mine" })
        #expect(await h.backend.removeBatchCalls.count == 1)
    }
}

// MARK: - Through the navigation

@MainActor
private struct PlaylistNavHarness {
    let backend = FakeMusicBackend()
    let service: MusicService
    let nav: MusicSearchNavigation

    init() {
        let service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: FakePlaybackEngine()),
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
        let host = MusicServiceHost(makeService: { service })
        host.loadIfNeeded()
        nav = host.navigation ?? MusicSearchNavigation(service: service)
    }

    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Opens a playlist page of `tracks` and waits for it. Returns the scope its rows are picked in.
    func openPage(
        _ id: String = "VLPLmine", tracks: [Deci.MusicTrack], isEditable: Bool = true
    ) async -> MusicSelectionScope {
        await backend.setPage(MusicSamples.page(id, tracks: tracks, title: "Mine", isEditable: isEditable))
        service.browse.open(MusicSamples.collection(id, title: "Mine"))
        _ = await until { if case .loaded = service.browse.pageState(id) { true } else { false } }
        return MusicSelectionScope(id: "page:\(id)", tracks: tracks, isUpNext: false)
    }

    func pick(_ ids: [String], in scope: MusicSelectionScope) {
        for id in ids {
            guard let track = scope.tracks.first(where: { $0.videoId == id }) else { continue }
            nav.selection.click(track, in: scope, modifiers: .command)
        }
    }

    func pageIds(_ id: String = "VLPLmine") -> [String] {
        if case .loaded(let page) = service.browse.pageState(id) { page.tracks.map(\.videoId) } else { [] }
    }
}

@MainActor
@Suite("Music selection playlist actions through the navigation")
struct MusicSelectionPlaylistNavigationTests {
    private func rows(_ ids: [String]) -> [Deci.MusicTrack] {
        ids.map { MusicSamples.track($0, title: "Song \($0)", setVideoId: "s-\($0)") }
    }

    // MARK: - What is offered

    @Test("On a playlist the user can edit, the selection offers Save and Remove from this playlist, counting rows")
    func offeredOnEditablePlaylist() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b", "c"]))
        h.pick(["a", "b", "c"], in: scope)

        #expect(h.nav.selectionActions == [.playNext, .addToQueue, .saveToPlaylist, .removeFromPlaylist])
        #expect(h.nav.selectionTitle(.saveToPlaylist) == "Save to playlist (3)")
        #expect(h.nav.selectionTitle(.removeFromPlaylist) == "Remove from this playlist (3)")
        #expect(h.nav.selectionTitle(.playNext) == "Play next (3)")
    }

    @Test("A page the user cannot edit, Liked music and a page that is no playlist offer no removal, but still Save")
    func notOfferedElsewhere() async {
        for (id, editable) in [("VLPLmine", false), ("VLLM", true), ("MPREb_album", true)] {
            let h = PlaylistNavHarness()
            let scope = await h.openPage(id, tracks: rows(["a", "b"]), isEditable: editable)
            h.pick(["a", "b"], in: scope)
            #expect(h.nav.selectionActions.contains(.saveToPlaylist), "page \(id)")
            #expect(!h.nav.selectionActions.contains(.removeFromPlaylist), "page \(id)")
        }
    }

    @Test("Another list on screen, even next to an editable page, offers Save only")
    func otherListOffersNoRemoval() async {
        let h = PlaylistNavHarness()
        _ = await h.openPage(tracks: rows(["a", "b"]))
        let results = MusicSelectionScope(id: "results:songs", tracks: rows(["a", "b"]), isUpNext: false)
        h.pick(["a", "b"], in: results)
        #expect(h.nav.selectionActions == [.playNext, .addToQueue, .saveToPlaylist])
    }

    @Test("Rows with no place are not counted, and the item hides when no picked row has one")
    func rowsWithoutPlace() async {
        let h = PlaylistNavHarness()
        let tracks = rows(["a", "b"]) + [MusicSamples.track("c", title: "Song c")]
        let scope = await h.openPage(tracks: tracks)

        h.pick(["a", "c"], in: scope)
        #expect(h.nav.selectionActions.contains(.removeFromPlaylist))
        #expect(h.nav.selectionTitle(.removeFromPlaylist) == "Remove from this playlist (1)")
        #expect(h.nav.selectionTitle(.saveToPlaylist) == "Save to playlist (2)")

        h.nav.selection.clear()
        h.pick(["c"], in: scope)
        #expect(!h.nav.selectionActions.contains(.removeFromPlaylist))
        #expect(h.nav.selectionActions.contains(.saveToPlaylist))
    }

    // MARK: - Remove from this playlist

    @Test("Picking it removes the picked rows in one call, clears the selection and says how many")
    func performRemove() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b", "c"]))
        h.pick(["a", "c"], in: scope)

        h.nav.performSelection(.removeFromPlaylist)

        #expect(await h.until { h.service.trackActions.notice?.text == "Removed 2 songs from Mine" })
        // Ended by the answer, not before it: a pick that is not in the playlist's rows goes with the rest.
        #expect(h.nav.selection.count == 0)
        let calls = await h.backend.removeBatchCalls
        #expect(calls.map(\.removals) == [[
            MusicPlaylistRemoval(videoId: "a", setVideoId: "s-a"), MusicPlaylistRemoval(videoId: "c", setVideoId: "s-c"),
        ]])
        #expect(h.pageIds() == ["b"])
    }

    @Test("Both copies of a song picked in a playlist are removed, though the selection counts the song once")
    func performRemoveBothCopies() async {
        let h = PlaylistNavHarness()
        let tracks = [
            MusicSamples.track("a", setVideoId: "s1"), MusicSamples.track("b", setVideoId: "s2"),
            MusicSamples.track("a", setVideoId: "s3"),
        ]
        let scope = await h.openPage(tracks: tracks)
        h.nav.selection.click(tracks[0], in: scope, modifiers: .command)
        h.nav.selection.click(tracks[2], in: scope, modifiers: .command)
        #expect(h.nav.selection.count == 1)
        #expect(h.nav.selectionTitle(.removeFromPlaylist) == "Remove from this playlist (2)")

        h.nav.performSelection(.removeFromPlaylist)

        #expect(await h.until { h.service.trackActions.notice?.text == "Removed 2 songs from Mine" })
        #expect(await h.backend.removeBatchCalls.first?.removals.map(\.setVideoId) == ["s1", "s3"])
    }

    @Test("The selection stays while the removal is out, and ends when it has landed")
    func removeClearsOnSuccess() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b", "c"]))
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)
        h.pick(["a", "c"], in: scope)

        h.nav.performSelection(.removeFromPlaylist)
        _ = await h.until { await h.backend.removeBatchCalls.count == 1 }
        #expect(h.nav.selection.count == 2)

        await gate.open()
        #expect(await h.until { h.service.trackActions.notice?.text == "Removed 2 songs from Mine" })
        #expect(h.nav.selection.count == 0)
    }

    @Test("A refused removal leaves the selection as it was")
    func removeKeepsSelectionOnFailure() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b", "c"]))
        await h.backend.setRemoveFromPlaylistError(MusicError.rejected)
        h.pick(["a", "c"], in: scope)

        h.nav.performSelection(.removeFromPlaylist)

        #expect(await h.until { h.service.trackActions.notice?.text == "Not removed from Mine." })
        #expect(h.nav.selection.count == 2)
        #expect(h.pageIds() == ["a", "b", "c"])
    }

    @Test("A failure after a first call landed keeps the rows that did not go picked")
    func removeKeepsLeftoverOnPartialFailure() async {
        let h = PlaylistNavHarness()
        let tracks = rows((1...60).map { "v\($0)" })
        let scope = await h.openPage(tracks: tracks)
        await h.backend.setRemoveFromPlaylistError(setVideoId: "s-v55", MusicError.rejected)
        h.pick(tracks.map(\.videoId), in: scope)

        h.nav.performSelection(.removeFromPlaylist)

        #expect(await h.until { h.service.trackActions.notice?.text == "Removed 50 of 60 songs from Mine" })
        // Not ended: the page's own sync takes the rows that went out of it, and the ten that stayed are still picked.
        #expect(h.nav.selection.count == 60)
        let left = Array(tracks[50...])
        h.nav.selection.sync(MusicSelectionScope(id: scope.id, tracks: left, isUpNext: false))
        #expect(h.nav.selection.count == 10)
        #expect(h.nav.selectionTitle(.removeFromPlaylist) == "Remove from this playlist (10)")
        #expect(h.pageIds() == (51...60).map { "v\($0)" })
    }

    @Test("A selection made elsewhere meanwhile is not ended by the answer")
    func removeAnswerLeavesAnotherList() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b", "c"]))
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)
        h.pick(["a"], in: scope)
        h.pick(["b"], in: scope)
        h.nav.performSelection(.removeFromPlaylist)
        _ = await h.until { await h.backend.removeBatchCalls.count == 1 }

        h.nav.selection.clear()
        let results = MusicSelectionScope(id: "results:songs", tracks: rows(["x", "y"]), isUpNext: false)
        h.pick(["x", "y"], in: results)
        await gate.open()

        #expect(await h.until { h.service.trackActions.notice?.text == "Removed 2 songs from Mine" })
        #expect(h.nav.selection.count == 2)
    }

    @Test("A second copy of a picked song moves the Remove count at once, and the bar's reading with it")
    func countFollowsSecondCopy() async {
        let h = PlaylistNavHarness()
        let tracks = [
            MusicSamples.track("a", setVideoId: "s1"), MusicSamples.track("b", setVideoId: "s2"),
            MusicSamples.track("a", setVideoId: "s3"),
        ]
        let scope = await h.openPage(tracks: tracks)
        h.nav.selection.click(tracks[0], in: scope, modifiers: .command)
        #expect(h.nav.selectionTitle(.removeFromPlaylist) == "Remove from this playlist (1)")

        let flag = PlaylistChangeFlag()
        withObservationTracking({
            _ = h.nav.selectionActions
            _ = h.nav.selectionTitle(.removeFromPlaylist)
        }, onChange: { flag.raise() })
        h.nav.selection.click(tracks[2], in: scope, modifiers: .command)

        #expect(h.nav.selection.count == 1)
        #expect(flag.raised)
        #expect(h.nav.selectionTitle(.removeFromPlaylist) == "Remove from this playlist (2)")
    }

    @Test("A pick the selection does not offer does nothing")
    func performNotOffered() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b"]), isEditable: false)
        h.pick(["a", "b"], in: scope)

        h.nav.performSelection(.removeFromPlaylist)

        #expect(h.nav.selection.count == 2)
        #expect(await h.backend.removeBatchCalls.isEmpty)
    }

    // MARK: - Save to playlist

    @Test("Picking Save opens the menu for the picked songs and keeps the selection")
    func performSave() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b", "c"]))
        await h.backend.setPlaylistOptions(videoId: "a", [MusicSamples.playlistOption("PLone", title: "Road Trip")])
        h.pick(["a", "c"], in: scope)

        h.nav.performSelection(.saveToPlaylist)

        #expect(h.nav.showsPicker)
        #expect(h.service.trackActions.picker?.title == "2 songs")
        #expect(h.service.trackActions.picker?.songs.map(\.videoId) == ["a", "c"])
        #expect(h.nav.selection.count == 2)
    }

    @Test("Closing the menu without a write keeps the selection")
    func cancelKeepsSelection() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b"]))
        await h.backend.setPlaylistOptions(videoId: "a", [MusicSamples.playlistOption("PLone", title: "Road Trip")])
        h.pick(["a", "b"], in: scope)
        h.nav.performSelection(.saveToPlaylist)

        h.nav.closePicker()

        #expect(!h.nav.showsPicker)
        #expect(h.nav.selection.count == 2)
    }

    @Test("Closing the menu after a write clears the selection")
    func writeClearsSelection() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b"]))
        await h.backend.setPlaylistOptions(videoId: "a", [MusicSamples.playlistOption("PLone", title: "Road Trip")])
        h.pick(["a", "b"], in: scope)
        h.nav.performSelection(.saveToPlaylist)
        _ = await h.until { if case .loaded? = h.service.trackActions.picker?.load { true } else { false } }

        h.service.trackActions.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
        #expect(await h.until { h.service.trackActions.notice?.text == "Added 2 songs to Road Trip" })
        // The menu stays open as it did, and so does the selection until it closes.
        #expect(h.nav.selection.count == 2)

        h.nav.closePicker()

        #expect(h.nav.selection.count == 0)
    }

    @Test("Every move that closes the menu ends the selection after a write, as closing the menu does")
    func movesEndSelectionAfterWrite() async {
        let moves: [(String, @MainActor (MusicSearchNavigation) -> Void)] = [
            ("queryChanged", { $0.queryChanged() }),
            ("toggleQueue", { $0.toggleQueue() }),
            ("toggleLyrics", { $0.toggleLyrics() }),
            ("openLyrics", { $0.openLyrics() }),
            ("openRelated", { $0.openRelated(for: MusicSamples.track("a")) }),
            ("select", { $0.select(.library) }),
        ]
        for (name, move) in moves {
            let h = PlaylistNavHarness()
            let scope = await h.openPage(tracks: rows(["a", "b"]))
            await h.backend.setPlaylistOptions(videoId: "a", [MusicSamples.playlistOption("PLone", title: "Road Trip")])
            h.pick(["a", "b"], in: scope)
            h.nav.performSelection(.saveToPlaylist)
            _ = await h.until { if case .loaded? = h.service.trackActions.picker?.load { true } else { false } }
            h.service.trackActions.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))
            #expect(await h.until { h.service.trackActions.notice?.text == "Added 2 songs to Road Trip" }, "\(name)")

            move(h.nav)

            #expect(!h.nav.showsPicker, "\(name)")
            #expect(h.nav.selection.count == 0, "\(name)")
        }
    }

    @Test("The same moves with no write leave the selection to try again")
    func movesKeepSelectionWithoutWrite() async {
        let moves: [(String, @MainActor (MusicSearchNavigation) -> Void)] = [
            ("queryChanged", { $0.queryChanged() }),
            ("toggleQueue", { $0.toggleQueue() }),
            ("openLyrics", { $0.openLyrics() }),
        ]
        for (name, move) in moves {
            let h = PlaylistNavHarness()
            let scope = await h.openPage(tracks: rows(["a", "b"]))
            await h.backend.setPlaylistOptions(videoId: "a", [MusicSamples.playlistOption("PLone", title: "Road Trip")])
            h.pick(["a", "b"], in: scope)
            h.nav.performSelection(.saveToPlaylist)

            move(h.nav)

            #expect(!h.nav.showsPicker, "\(name)")
            #expect(h.nav.selection.count == 2, "\(name)")
        }
    }

    @Test("Closing the menu while the add is still out ends the selection, and the late answer needs nothing more")
    func closeWhileSavingEndsSelection() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b"]))
        await h.backend.setPlaylistOptions(videoId: "a", [MusicSamples.playlistOption("PLone", title: "Road Trip")])
        let gate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(gate)
        h.pick(["a", "b"], in: scope)
        h.nav.performSelection(.saveToPlaylist)
        _ = await h.until { if case .loaded? = h.service.trackActions.picker?.load { true } else { false } }
        h.service.trackActions.choose(MusicSamples.playlistOption("PLone", title: "Road Trip"))

        #expect(h.nav.escape())

        #expect(h.nav.selection.count == 0)
        await gate.open()
        #expect(await h.until { h.service.trackActions.notice?.text == "Added 2 songs to Road Trip" })
    }

    @Test("Escape closes the menu first and leaves the selection, then clears the selection")
    func escapeOrder() async {
        let h = PlaylistNavHarness()
        let scope = await h.openPage(tracks: rows(["a", "b"]))
        await h.backend.setPlaylistOptions(videoId: "a", [MusicSamples.playlistOption("PLone")])
        h.pick(["a", "b"], in: scope)
        h.nav.performSelection(.saveToPlaylist)

        #expect(h.nav.escapeSelection() == false)
        #expect(h.nav.escape())
        #expect(!h.nav.showsPicker)
        #expect(h.nav.selection.count == 2)
        #expect(h.nav.escapeSelection() == true)
        #expect(h.nav.selection.count == 0)
    }
}

// MARK: - The request body

@MainActor
@Suite("InnerTubeClient playlist edits with several songs")
struct InnerTubeClientBatchEditTests {
    private static let editPath = "/youtubei/v1/browse/edit_playlist"

    private func makeClient(_ youtube: FakeYouTube) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: MusicTestJar.signedInStore(), now: { MusicTestJar.now })
    }

    private func sentActions(_ youtube: FakeYouTube) -> (playlistId: String?, actions: [[String: Any]], count: Int) {
        let requests = youtube.requests(path: Self.editPath)
        let body = requests.first.map { FakeYouTube.jsonBody($0) } ?? [:]
        return (body["playlistId"] as? String, body["actions"] as? [[String: Any]] ?? [], requests.count)
    }

    @Test("Adding several songs posts one request with one ACTION_ADD_VIDEO each, in order, and the plain playlist id")
    func addBody() async throws {
        let fake = FakeYouTube()
        try await makeClient(fake).addVideos(["a", "b", "c"], toPlaylist: "VLPLfixtureMine")

        let sent = sentActions(fake)
        #expect(sent.count == 1)
        #expect(sent.playlistId == "PLfixtureMine")
        #expect(sent.actions.map { $0["action"] as? String } == Array(repeating: "ACTION_ADD_VIDEO", count: 3))
        #expect(sent.actions.map { $0["addedVideoId"] as? String } == ["a", "b", "c"])
        #expect(sent.actions.allSatisfy { $0["dedupeOption"] == nil })
    }

    @Test("Removing several rows posts one request with one ACTION_REMOVE_VIDEO each, carrying both ids")
    func removeBody() async throws {
        let fake = FakeYouTube()
        let removals = [
            MusicPlaylistRemoval(videoId: "a", setVideoId: "s1"), MusicPlaylistRemoval(videoId: "a", setVideoId: "s2"),
            MusicPlaylistRemoval(videoId: "b", setVideoId: "s3"),
        ]
        try await makeClient(fake).removeVideos(removals, fromPlaylist: "PLfixtureMine")

        let sent = sentActions(fake)
        #expect(sent.count == 1)
        #expect(sent.playlistId == "PLfixtureMine")
        #expect(sent.actions.map { $0["action"] as? String } == Array(repeating: "ACTION_REMOVE_VIDEO", count: 3))
        #expect(sent.actions.map { $0["setVideoId"] as? String } == ["s1", "s2", "s3"])
        #expect(sent.actions.map { $0["removedVideoId"] as? String } == ["a", "a", "b"])
    }

    @Test("A single song is the same request as before: one action")
    func singleStillOneAction() async throws {
        let fake = FakeYouTube()
        try await makeClient(fake).addVideo("a", toPlaylist: "PLfixtureMine")
        try await makeClient(fake).removeVideo("a", setVideoId: "s1", fromPlaylist: "PLfixtureMine")
        let requests = fake.requests(path: Self.editPath)
        #expect(requests.count == 2)
        for request in requests {
            #expect((FakeYouTube.jsonBody(request)["actions"] as? [[String: Any]])?.count == 1)
        }
    }

    @Test("An empty list, or one with a blank id, is refused before any request")
    func blankRefused() async {
        let fake = FakeYouTube()
        let client = makeClient(fake)
        await #expect(throws: MusicError.self) { try await client.addVideos([], toPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.self) { try await client.addVideos(["a", ""], toPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.self) { try await client.addVideos(["a"], toPlaylist: "VL") }
        await #expect(throws: MusicError.self) { try await client.removeVideos([], fromPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.self) {
            try await client.removeVideos([MusicPlaylistRemoval(videoId: "a", setVideoId: "")], fromPlaylist: "PLfixtureMine")
        }
        #expect(fake.requests(path: Self.editPath).isEmpty)
    }

    @Test("A batch YouTube does not call succeeded is rejected")
    func rejected() async {
        let fake = FakeYouTube { $0.editPlaylistBody = Data(#"{"status":"STATUS_FAILED"}"#.utf8) }
        await #expect(throws: MusicError.rejected) {
            try await makeClient(fake).addVideos(["a", "b"], toPlaylist: "PLfixtureMine")
        }
        await #expect(throws: MusicError.rejected) {
            try await makeClient(fake).removeVideos([MusicPlaylistRemoval(videoId: "a", setVideoId: "s1")], fromPlaylist: "PLfixtureMine")
        }
    }

    @Test("A signed out client refuses before any request")
    func signedOut() async {
        let fake = FakeYouTube()
        let client = InnerTubeClient(transport: fake, secretStore: MemorySecretStore(), now: { MusicTestJar.now })
        await #expect(throws: MusicError.signedOut) { try await client.addVideos(["a"], toPlaylist: "PLfixtureMine") }
        #expect(fake.requests(path: Self.editPath).isEmpty)
    }
}

// MARK: - The revision

@MainActor
@Suite("MusicSongSelection revision")
struct MusicSongSelectionRevisionTests {
    private let rows = [
        MusicSamples.track("a", setVideoId: "s1"), MusicSamples.track("b", setVideoId: "s2"),
        MusicSamples.track("a", setVideoId: "s3"),
    ]
    private var scope: MusicSelectionScope { MusicSelectionScope(id: "page:VLPLmine", tracks: rows, isUpNext: false) }

    @Test("A second copy of a picked song moves the revision although the songs picked are the same")
    func secondCopyMoves() {
        let selection = MusicSongSelection()
        selection.click(at: 0, in: scope, modifiers: .command)
        let before = selection.revision

        selection.click(at: 2, in: scope, modifiers: .command)

        #expect(selection.tracks.map(\.videoId) == ["a"])
        #expect(selection.pickedRows.count == 2)
        #expect(selection.revision != before)
    }

    @Test("Taking one of two copies off again moves it too, and a click that changes nothing does not")
    func offAndNoChange() {
        let selection = MusicSongSelection()
        selection.click(at: 0, in: scope, modifiers: .command)
        selection.click(at: 2, in: scope, modifiers: .command)
        let both = selection.revision

        selection.click(at: 2, in: scope, modifiers: .command)
        #expect(selection.revision != both)

        // Shift from the anchor over rows already picked leaves the keys as they were.
        selection.click(at: 0, in: scope, modifiers: .command)
        selection.click(at: 0, in: scope, modifiers: .command)
        let settled = selection.revision
        selection.click(at: 0, in: scope, modifiers: .shift)
        #expect(selection.revision == settled)
    }

    @Test("The revision is observed, so a reader that kept its answer by it is told")
    func revisionIsObserved() {
        let selection = MusicSongSelection()
        selection.click(at: 0, in: scope, modifiers: .command)
        let flag = PlaylistChangeFlag()
        withObservationTracking({ _ = selection.revision }, onChange: { flag.raise() })

        selection.click(at: 2, in: scope, modifiers: .command)

        #expect(flag.raised)
    }

    @Test("A sync that takes a picked copy out of the list moves it, and a sync that changes nothing does not")
    func syncMoves() {
        let selection = MusicSongSelection()
        selection.click(at: 0, in: scope, modifiers: .command)
        selection.click(at: 2, in: scope, modifiers: .command)
        let both = selection.revision
        selection.sync(scope)
        #expect(selection.revision == both)

        selection.sync(MusicSelectionScope(id: "page:VLPLmine", tracks: Array(rows[0...1]), isUpNext: false))

        #expect(selection.pickedRows.count == 1)
        #expect(selection.revision != both)
    }
}
