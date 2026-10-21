// DeciTests/Music/MusicTrackActionsStoreUnsaveTests.swift
// Tapping a ticked row of a song's save to playlist menu takes the song out of that playlist: the playlist is read on
// every tap for the place of each row that holds the song (its setVideoId), the song goes once per place, with the
// busy, notice and failure lines around it, late answers that are dropped, a session that ends between two writes, and
// the menu of an album or playlist, which stays add only. Fakes only; nothing here reaches the network.

import Foundation
import Testing
@testable import Deci

/// A playlist row as a test writes it: the video id, and the setVideoId YouTube gives its place (nil: it gives none).
private typealias Row = (video: String, place: String?)

private extension ActionsHarness {
    /// A playlist's first page, its rows carrying their place in the playlist as a real playlist page does.
    func setPlaylistRows(_ playlistId: String, _ rows: [Row], continuation: String? = nil) async {
        let tracks = rows.map { MusicSamples.track($0.video, setVideoId: $0.place) }
        await backend.setPage(MusicSamples.page("VL" + playlistId, tracks: tracks, continuation: continuation))
    }

    /// The page behind `continuation` of a playlist.
    func setMoreRows(_ playlistId: String, continuation: String, _ rows: [Row], next: String? = nil) async {
        let tracks = rows.map { MusicSamples.track($0.video, setVideoId: $0.place) }
        await backend.setMoreTracks(browseId: "VL" + playlistId, continuation: continuation, tracks: tracks, next: next)
    }

    /// Taps a row as the menu does: with the list's own copy of it.
    func tap(_ playlistId: String) {
        store.choose(options?.first { $0.playlistId == playlistId } ?? MusicSamples.playlistOption(playlistId))
    }

    func removal(_ video: String, _ place: String, _ playlistId: String) -> FakeMusicBackend.RemoveFromPlaylistCall {
        FakeMusicBackend.RemoveFromPlaylistCall(videoId: video, setVideoId: place, playlistId: playlistId)
    }

    /// Waits for the membership pass to have read `count` playlist pages, so a test that changes the world after it
    /// knows the pass has already seen the old one.
    func waitForPageReads(_ count: Int) async {
        _ = await until { await backend.pageCalls.count >= count }
    }
}

@MainActor
@Suite("MusicTrackActionsStore remove from the save menu")
struct MusicTrackActionsStoreUnsaveTests {
    private let road = MusicSamples.playlistOption("PLone", title: "Road Trip")
    /// A row YouTube itself flags as holding the song: the pass never reads it, so it is only ticked from the start.
    private let flaggedWorkout = MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true)

    // MARK: - The pass only ticks; the tap reads

    @Test("A row that holds the song but gives no place is still ticked by the pass")
    func passTicksRowsWithoutAPlace() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", nil)])
        await h.setPlaylistRows("PLtwo", [("vid-1", "")])
        await h.openPicker(options: [MusicSamples.playlistOption("PLone"), MusicSamples.playlistOption("PLtwo")])

        #expect(await h.until { h.ticked == ["PLone", "PLtwo"] })
    }

    @Test("A tap removes the song from every place it sits in, on the page the pass stopped at and on pages behind it")
    func tapRemovesOccurrencesOnFirstAndLaterPages() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "s1"), ("a", "sa")], continuation: "c1")
        await h.setMoreRows("PLone", continuation: "c1", [("b", "sb"), ("vid-1", "s2")], next: "c2")
        await h.setMoreRows("PLone", continuation: "c2", [("vid-1", "s3"), ("vid-1", "s4")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.letLateWorkLand()
        // The pass stopped on the first page, where it saw the song, and read nothing behind it.
        #expect(await h.backend.moreTracksCalls.isEmpty)

        h.tap("PLone")

        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["c1", "c2"])
        let expected = ["s1", "s2", "s3", "s4"].map { h.removal("vid-1", $0, "PLone") }
        #expect(await h.backend.removeFromPlaylistCalls == expected)
        #expect(h.ticked.isEmpty)
        #expect(h.store.picker?.saving.isEmpty == true)
    }

    @Test("A song the pass found on a later page and that sits further down too is removed from all of its places")
    func tapRemovesOccurrencesPastTheOneThePassFound() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("a", "sa")], continuation: "c1")
        await h.setMoreRows("PLone", continuation: "c1", [("vid-1", "s2"), ("vid-1", "s3")], next: "c2")
        await h.setMoreRows("PLone", continuation: "c2", [("vid-1", "s4")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.letLateWorkLand()

        h.tap("PLone")

        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(await h.backend.removeFromPlaylistCalls.map(\.setVideoId) == ["s2", "s3", "s4"])
    }

    @Test("A row the pass already ticked is read again on the tap, and the removal uses the places the playlist has now")
    func tapOnAPassTickedRowReadsAgain() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("x", "sx"), ("vid-1", "s1")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.letLateWorkLand()
        #expect(await h.backend.pageCalls == ["VLPLone"])

        // The playlist changed since the pass read it: the song sits in other places now.
        await h.setPlaylistRows("PLone", [("x", "sx"), ("vid-1", "s1b"), ("vid-1", "s1c")])
        h.tap("PLone")

        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(await h.backend.pageCalls == ["VLPLone", "VLPLone"])
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "s1b", "PLone"), h.removal("vid-1", "s1c", "PLone")])
    }

    // MARK: - Tapping a ticked row removes

    @Test("Tapping a row the pass ticked reads that playlist, removes the song, unticks the row and says it removed")
    func tapRemoves() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("x", "sx"), ("vid-1", "s1")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })

        h.tap("PLone")

        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(h.store.notice?.isError == false)
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "s1", "PLone")])
        #expect(h.ticked.isEmpty)
        #expect(h.options?.map(\.playlistId) == ["PLone"])
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.picker?.track == h.song)
        // The pass read the playlist once to tick the row, and the tap read it once more for the places.
        #expect(await h.backend.pageCalls == ["VLPLone", "VLPLone"])
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
    }

    @Test("A song in a playlist twice is removed once per place, in order, with one line when all are gone")
    func tapRemovesEveryOccurrence() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "sA"), ("x", "sx"), ("vid-1", "sB")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })

        h.tap("PLone")

        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "sA", "PLone"), h.removal("vid-1", "sB", "PLone")])
        #expect(h.ticked.isEmpty)
    }

    @Test("Removing from one playlist leaves the tick of the others and sends nothing to them")
    func tapLeavesOtherRows() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "s1")])
        await h.setPlaylistRows("PLtwo", [("vid-1", "s2")])
        await h.openPicker(options: [road, MusicSamples.playlistOption("PLtwo", title: "Workout")])
        #expect(await h.until { h.ticked == ["PLone", "PLtwo"] })

        h.tap("PLone")

        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(h.ticked == ["PLtwo"])
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "s1", "PLone")])
    }

    @Test("Taps on two ticked rows go out together, and each row is unticked when its own call lands")
    func removeFromTwoAtOnce() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "s1")])
        await h.setPlaylistRows("PLtwo", [("vid-1", "s2")])
        await h.openPicker(options: [road, MusicSamples.playlistOption("PLtwo", title: "Workout")])
        #expect(await h.until { h.ticked == ["PLone", "PLtwo"] })
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)

        h.tap("PLone")
        h.tap("PLtwo")
        #expect(h.store.picker?.saving == ["PLone", "PLtwo"])
        #expect(h.store.picker?.removing == ["PLone", "PLtwo"])
        await gate.open()

        #expect(await h.until { h.ticked.isEmpty && h.store.picker?.saving.isEmpty == true })
        #expect(h.store.picker?.removing.isEmpty == true)
        #expect(await h.backend.removeFromPlaylistCalls.count == 2)
    }

    @Test("A row shows busy while its removal is out, stays ticked, and a second tap sends nothing more")
    func removeIsBusyUntilItLands() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "s1")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)

        h.tap("PLone")
        #expect(h.store.picker?.saving == ["PLone"])
        #expect(h.store.picker?.removing == ["PLone"])
        #expect(await h.until { await h.backend.removeFromPlaylistCalls.count == 1 })
        #expect(h.ticked == ["PLone"])
        #expect(h.store.notice == nil)
        h.tap("PLone")

        await gate.open()
        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        await h.letLateWorkLand()
        #expect(await h.backend.removeFromPlaylistCalls.count == 1)
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.picker?.removing.isEmpty == true)
        #expect(h.ticked.isEmpty)
    }

    @Test("A playlist's name with Unicode, emoji and markup goes into the removed line as it is")
    func removedLineKeepsTheName() async {
        let h = ActionsHarness()
        let title = "Caf\u{E9} \u{1F3B5} <b>&amp;</b> 'quoted' \"too\""
        await h.setPlaylistRows("PLone", [("vid-1", "s1")])
        await h.openPicker(options: [MusicSamples.playlistOption("PLone", title: title)])
        #expect(await h.until { h.ticked == ["PLone"] })
        h.tap("PLone")
        #expect(await h.until { h.store.notice?.text == "Removed from \(title)" })
    }

    @Test("A playlist page that is open loses the row that was removed, and keeps the others")
    func removalDropsTheRowFromAnOpenPage() async {
        let h = ActionsHarness()
        _ = await h.openPage([MusicSamples.track("vid-1", setVideoId: "s1"), MusicSamples.track("b", setVideoId: "s2")], id: "VLPLone")
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })

        h.tap("PLone")

        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(h.pageIds("VLPLone") == ["b"])
    }

    // MARK: - A removal that fails

    @Test("A refused removal keeps the tick, says it did not remove, and a retry reads the playlist again and goes out")
    func failureKeepsTheTick() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "s1")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.backend.setRemoveFromPlaylistError(MusicError.rejected)

        h.tap("PLone")

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == "Not removed from Road Trip.")
        #expect(h.store.notice?.isError == true)
        #expect(h.ticked == ["PLone"])
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.picker?.removing.isEmpty == true)

        await h.backend.setRemoveFromPlaylistError(nil)
        h.tap("PLone")
        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "s1", "PLone"), h.removal("vid-1", "s1", "PLone")])
        // One read for the pass and one for each tap.
        #expect(await h.backend.pageCalls == ["VLPLone", "VLPLone", "VLPLone"])
        #expect(h.ticked.isEmpty)
    }

    @Test("A network or server failure shows the usual line for it, keeps the tick, and does not sign out")
    func failureShowsTheUsualLine() async {
        let errors: [any Error] = [URLError(.notConnectedToInternet), MusicError.http(500), MusicError.parse("x")]
        for error in errors {
            let h = ActionsHarness()
            await h.setPlaylistRows("PLone", [("vid-1", "s1")])
            await h.openPicker(options: [road])
            #expect(await h.until { h.ticked == ["PLone"] }, "\(error)")
            await h.backend.setRemoveFromPlaylistError(error)

            h.tap("PLone")

            #expect(await h.until { h.store.notice != nil }, "\(error)")
            #expect(h.store.notice?.text == MusicService.message(for: error), "\(error)")
            #expect(h.store.notice?.isError == true, "\(error)")
            #expect(h.ticked == ["PLone"], "\(error)")
            #expect(h.probe.expired == 0, "\(error)")
        }
    }

    @Test("A removal that finds the session gone tells the service, shows no error line and keeps the tick")
    func failureSignedOut() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "s1")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.backend.setRemoveFromPlaylistError(MusicError.signedOut)

        h.tap("PLone")

        #expect(await h.until { h.probe.expired == 1 })
        #expect(h.store.notice == nil)
        #expect(h.ticked == ["PLone"])
        #expect(h.store.picker?.saving.isEmpty == true)
    }

    @Test("When one of two places fails, the row stays ticked, and a retry reads the playlist and sends just what is left")
    func partialFailure() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "sA"), ("vid-1", "sB")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.backend.setRemoveFromPlaylistError(setVideoId: "sB", MusicError.rejected)

        h.tap("PLone")

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == "Not removed from Road Trip.")
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "sA", "PLone"), h.removal("vid-1", "sB", "PLone")])
        #expect(h.ticked == ["PLone"])
        #expect(h.store.picker?.saving.isEmpty == true)

        // YouTube took the first place out, so the playlist now holds the song once.
        await h.setPlaylistRows("PLone", [("vid-1", "sB")])
        await h.backend.setRemoveFromPlaylistError(setVideoId: "sB", nil)
        h.tap("PLone")
        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(await h.backend.removeFromPlaylistCalls.suffix(1) == [h.removal("vid-1", "sB", "PLone")])
        #expect(await h.backend.removeFromPlaylistCalls.count == 3)
        #expect(h.ticked.isEmpty)
    }

    // MARK: - The playlist is read first

    @Test("A row YouTube flagged is never read by the pass, so the tap reads that one playlist and then removes the song")
    func flaggedRowReadsOnePlaylistOnTap() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLtwo", [("x", "sx"), ("vid-1", "s9")])
        await h.openPicker(options: [flaggedWorkout, MusicSamples.playlistOption("PLthree", title: "Other")])
        #expect(h.ticked == ["PLtwo"])

        h.tap("PLtwo")

        #expect(h.store.picker?.saving == ["PLtwo"])
        #expect(h.store.picker?.removing == ["PLtwo"])
        #expect(await h.until { h.store.notice?.text == "Removed from Workout" })
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "s9", "PLtwo")])
        #expect(await h.backend.pageCalls.filter { $0 == "VLPLtwo" }.count == 1)
        #expect(h.ticked.isEmpty)
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.picker?.removing.isEmpty == true)
    }

    @Test("The playlist is read to its end, not to the first hit, so a song in it twice is removed from both places")
    func lookupFindsEveryOccurrence() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLtwo", [("a", "sa"), ("vid-1", "s1")], continuation: "c1")
        await h.setMoreRows("PLtwo", continuation: "c1", [("b", "sb"), ("vid-1", "s2")], next: "c2")
        await h.setMoreRows("PLtwo", continuation: "c2", [("vid-1", "s3")])
        await h.openPicker(options: [flaggedWorkout])

        h.tap("PLtwo")

        #expect(await h.until { h.store.notice?.text == "Removed from Workout" })
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["c1", "c2"])
        #expect(await h.backend.removeFromPlaylistCalls.map(\.setVideoId) == ["s1", "s2", "s3"])
        #expect(h.ticked.isEmpty)
    }

    @Test("A very long playlist is read through whole and the song at its very end is found")
    func lookupLargePlaylist() async {
        let h = ActionsHarness()
        var rows = (0..<9_999).map { (index: Int) -> Row in ("v\(index)", "s\(index)") }
        rows.append(("vid-1", "sLast"))
        await h.setPlaylistRows("PLtwo", rows)
        await h.openPicker(options: [flaggedWorkout])

        h.tap("PLtwo")

        #expect(await h.until { h.store.notice?.text == "Removed from Workout" })
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "sLast", "PLtwo")])
    }

    @Test("A song added in this menu is removed by reading the playlist for the place YouTube gave it")
    func addThenRemoveThenAddAgain() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("x", "sx")])
        await h.openPicker(options: [road])
        await h.waitForPageReads(1)
        h.tap("PLone")
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(h.ticked == ["PLone"])

        // YouTube holds the song now, with a place of its own.
        await h.setPlaylistRows("PLone", [("x", "sx"), ("vid-1", "s7")])
        h.tap("PLone")
        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "s7", "PLone")])
        #expect(await h.backend.pageCalls == ["VLPLone", "VLPLone"])
        #expect(h.ticked.isEmpty)
        #expect(h.store.picker?.saving.isEmpty == true)

        // And the same row adds again.
        h.tap("PLone")
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(await h.backend.addToPlaylistCalls.count == 2)
        #expect(h.ticked == ["PLone"])
    }

    @Test("A playlist that no longer holds the song fails the removal: a line, the tick kept, and no remove call")
    func lookupFindsNothing() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLtwo", [("x", "sx"), ("y", "sy")])
        await h.openPicker(options: [flaggedWorkout])

        h.tap("PLtwo")

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == "Not removed. Couldn't find it in Workout.")
        #expect(h.store.notice?.isError == true)
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        #expect(h.ticked == ["PLtwo"])
        #expect(h.store.picker?.saving.isEmpty == true)
    }

    @Test("A playlist whose row for the song gives no place fails the same way, since there is nothing to remove by")
    func lookupFindsSongWithoutAPlace() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLtwo", [("vid-1", nil)])
        await h.openPicker(options: [flaggedWorkout])

        h.tap("PLtwo")

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == "Not removed. Couldn't find it in Workout.")
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        #expect(h.ticked == ["PLtwo"])
    }

    @Test("The playlist is read for at most the page limit, and a song only past it counts as not found")
    func lookupStopsAtThePageLimit() async {
        let h = ActionsHarness()
        await h.setLongPlaylist("PLtwo", pages: 30, songOnPage: 25)
        await h.openPicker(options: [flaggedWorkout])

        h.tap("PLtwo")

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == "Not removed. Couldn't find it in Workout.")
        #expect(await h.backend.moreTracksCalls.count == MusicTrackActionsStore.membershipPageLimit - 1)
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        #expect(h.ticked == ["PLtwo"])
    }

    @Test("A playlist that cannot be read fails the removal with the usual line and keeps the tick")
    func lookupFails() async {
        let errors: [any Error] = [MusicError.http(500), MusicError.parse("x"), URLError(.notConnectedToInternet)]
        for error in errors {
            let h = ActionsHarness()
            await h.openPicker(options: [flaggedWorkout])
            await h.backend.setPageError("VLPLtwo", error)

            h.tap("PLtwo")

            #expect(await h.until { h.store.notice != nil }, "\(error)")
            #expect(h.store.notice?.text == MusicService.message(for: error), "\(error)")
            #expect(h.store.notice?.isError == true, "\(error)")
            #expect(await h.backend.removeFromPlaylistCalls.isEmpty, "\(error)")
            #expect(h.ticked == ["PLtwo"], "\(error)")
            #expect(h.store.picker?.saving.isEmpty == true, "\(error)")
            #expect(h.store.picker?.removing.isEmpty == true, "\(error)")
            #expect(h.probe.expired == 0, "\(error)")
        }
    }

    @Test("A playlist read that finds the session gone tells the service and shows no line")
    func lookupSignedOut() async {
        let h = ActionsHarness()
        await h.openPicker(options: [flaggedWorkout])
        await h.backend.setPageError("VLPLtwo", MusicError.signedOut)

        h.tap("PLtwo")

        #expect(await h.until { h.probe.expired == 1 })
        #expect(h.store.notice == nil)
        #expect(h.ticked == ["PLtwo"])
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
    }

    @Test("A second tap while the playlist is being read sends no second read and no second removal")
    func lookupOnlyOnce() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLtwo", [("vid-1", "s9")])
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLtwo", gate)
        await h.openPicker(options: [flaggedWorkout])

        h.tap("PLtwo")
        h.tap("PLtwo")
        #expect(await h.until { await h.backend.pageCalls.count == 1 })
        #expect(h.store.picker?.saving == ["PLtwo"])
        #expect(h.store.picker?.removing == ["PLtwo"])
        await gate.open()

        #expect(await h.until { h.store.notice?.text == "Removed from Workout" })
        await h.letLateWorkLand()
        #expect(await h.backend.pageCalls.count == 1)
        #expect(await h.backend.removeFromPlaylistCalls.count == 1)
    }

    // MARK: - Late answers

    @Test("A playlist read that lands after the menu was closed removes nothing, shows nothing, and frees the row")
    func staleLookupAfterClose() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLtwo", [("vid-1", "s9")])
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLtwo", gate)
        await h.openPicker(options: [flaggedWorkout])
        h.tap("PLtwo")
        #expect(await h.until { await h.backend.pageCalls.count == 1 })

        h.store.closePicker()
        await gate.open()
        await h.letLateWorkLand()
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        #expect(h.store.notice == nil)
        #expect(h.store.picker == nil)

        // The row was freed: opened again it is not busy, and a tap on it goes through.
        await h.openPicker(options: [flaggedWorkout])
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.picker?.removing.isEmpty == true)
        h.tap("PLtwo")
        #expect(await h.until { h.store.notice?.text == "Removed from Workout" })
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "s9", "PLtwo")])
    }

    @Test("A playlist read that lands after another song's menu was opened removes nothing and touches that menu not")
    func staleLookupForAnotherSong() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLtwo", [("vid-1", "s9")])
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLtwo", gate)
        await h.openPicker(options: [flaggedWorkout])
        h.tap("PLtwo")
        #expect(await h.until { await h.backend.pageCalls.count == 1 })

        let other = MusicSamples.track("vid-2", title: "Other")
        await h.openPicker(for: other, options: [MusicSamples.playlistOption("PLtwo", title: "Workout")])
        await gate.open()
        await h.letLateWorkLand()

        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        #expect(h.store.notice == nil)
        #expect(h.store.picker?.track == other)
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.picker?.removing.isEmpty == true)
    }

    @Test("A playlist read that lands after a reset removes nothing and shows nothing")
    func staleLookupAfterReset() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLtwo", [("vid-1", "s9")])
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLtwo", gate)
        await h.openPicker(options: [flaggedWorkout])
        h.tap("PLtwo")
        #expect(await h.until { await h.backend.pageCalls.count == 1 })

        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()

        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        #expect(h.store.notice == nil)
        #expect(h.store.picker == nil)
    }

    @Test("A removal that lands after the menu was closed still says it removed")
    func removalLandsAfterClose() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "s1")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)

        h.tap("PLone")
        #expect(await h.until { await h.backend.removeFromPlaylistCalls.count == 1 })
        h.store.closePicker()
        await gate.open()

        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(h.store.picker == nil)
    }

    @Test("A menu opened again while a removal is out shows the row busy, and unticks it when the removal lands")
    func removalLandsInAReopenedMenu() async {
        let h = ActionsHarness()
        await h.openPicker(options: [flaggedWorkout])
        await h.setPlaylistRows("PLtwo", [("vid-1", "s9")])
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)
        h.tap("PLtwo")
        #expect(await h.until { await h.backend.removeFromPlaylistCalls.count == 1 })

        h.store.closePicker()
        await h.openPicker(options: [flaggedWorkout])
        #expect(h.store.picker?.saving == ["PLtwo"])
        #expect(h.store.picker?.removing == ["PLtwo"])
        h.tap("PLtwo")
        await gate.open()

        #expect(await h.until { h.store.notice?.text == "Removed from Workout" })
        #expect(await h.until { h.ticked.isEmpty })
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.picker?.removing.isEmpty == true)
        await h.letLateWorkLand()
        #expect(await h.backend.removeFromPlaylistCalls.count == 1)
    }

    @Test("A removal that lands after a reset shows no line from the old session")
    func removalAfterReset() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "s1")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)

        h.tap("PLone")
        #expect(await h.until { await h.backend.removeFromPlaylistCalls.count == 1 })
        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()

        #expect(h.store.notice == nil)
        #expect(h.store.picker == nil)
    }

    @Test("A session that ends between two writes of one removal stops the rest: no more deletes, no line, no sign-out")
    func sessionEndsBetweenWrites() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "sA"), ("x", "sx"), ("vid-1", "sB"), ("vid-1", "sC")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)

        h.tap("PLone")
        #expect(await h.until { await h.backend.removeFromPlaylistCalls.count == 1 })
        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()

        // The write that was out when the session ended finished; the other two never went to the new session.
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "sA", "PLone")])
        #expect(h.store.notice == nil)
        #expect(h.store.picker == nil)
        #expect(h.probe.expired == 0)

        // The new session is not held back by the old one: the same row there removes every place.
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        h.tap("PLone")
        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        let places = ["sA", "sB", "sC"].map { h.removal("vid-1", $0, "PLone") }
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "sA", "PLone")] + places)
        #expect(h.store.picker?.saving.isEmpty == true)
    }

    @Test("Closing the menu between two writes of one removal does not stop it: every place goes and the line says so")
    func closeBetweenWritesStillFinishes() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "sA"), ("vid-1", "sB")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        let gate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(gate)

        h.tap("PLone")
        #expect(await h.until { await h.backend.removeFromPlaylistCalls.count == 1 })
        h.store.closePicker()
        await gate.open()

        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })
        #expect(await h.backend.removeFromPlaylistCalls == [h.removal("vid-1", "sA", "PLone"), h.removal("vid-1", "sB", "PLone")])
        #expect(h.store.picker == nil)
    }

    @Test("A membership read that began before a removal landed does not tick the row again when it answers")
    func staleMembershipDoesNotRetick() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "s1")])
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        let removalGate = MusicTestGate()
        await h.backend.setRemoveFromPlaylistGate(removalGate)
        h.tap("PLone")
        #expect(await h.until { await h.backend.removeFromPlaylistCalls.count == 1 })

        // The menu is opened again while the removal is out, and its pass reads the playlist that still holds the song.
        h.store.closePicker()
        let pageGate = MusicTestGate()
        await h.backend.setPageGate("VLPLone", pageGate)
        await h.openPicker(options: [road])
        await h.waitForPageReads(2)
        await removalGate.open()
        #expect(await h.until { h.store.notice?.text == "Removed from Road Trip" })

        await pageGate.open()
        await h.letLateWorkLand()
        #expect(h.ticked.isEmpty)
    }

    // MARK: - An album or playlist stays add only

    @Test("A ticked row in the menu of an album or playlist still says Already in, and sends no add, no remove and no read")
    func collectionStaysAddOnly() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLtile", [("s1", "a")])
        await h.setPlaylistRows("PLone", [("s1", "b")])
        let workout = MusicSamples.playlistOption("PLtwo", title: "Workout", contains: true)
        await h.openCollectionPicker(for: h.playlistTile, sourceId: "PLtile", options: [road, workout])
        #expect(await h.until { h.ticked == ["PLone", "PLtwo"] })
        await h.waitForPageReads(2)

        h.tap("PLone")
        #expect(h.store.notice?.text == "Already in Road Trip")
        #expect(h.store.notice?.isError == false)
        h.tap("PLtwo")
        #expect(h.store.notice?.text == "Already in Workout")

        await h.letLateWorkLand()
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        #expect(await h.backend.addPlaylistCalls.isEmpty)
        #expect(await h.backend.addToPlaylistCalls.isEmpty)
        #expect(await h.backend.pageCalls.sorted() == ["VLPLone", "VLPLtile"])
        #expect(h.ticked == ["PLone", "PLtwo"])
        #expect(h.store.picker?.saving.isEmpty == true)
    }

    @Test("A row of an album's menu ticked by a save says Already in on the next tap, whatever copy the tap carried")
    func collectionSaveThenTap() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile", options: [road])
        h.store.choose(road)
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })

        h.store.choose(road)
        #expect(h.store.notice?.text == "Already in Road Trip")
        await h.letLateWorkLand()
        #expect(await h.backend.addPlaylistCalls.count == 1)
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        #expect(h.ticked == ["PLone"])
    }

    @Test("A row ticked by a late membership read while its save is out is busy with a save, not a removal")
    func lateTickDuringASaveIsNotARemoval() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("vid-1", "s1")])
        let pageGate = MusicTestGate()
        await h.backend.setPageGate("VLPLone", pageGate)
        await h.openPicker(options: [road])
        let addGate = MusicTestGate()
        await h.backend.setAddToPlaylistGate(addGate)

        // The row is not ticked yet, so the tap adds; then the pass, still reading, ticks it under the save.
        h.tap("PLone")
        #expect(await h.until { await h.backend.addToPlaylistCalls.count == 1 })
        await pageGate.open()
        #expect(await h.until { h.ticked == ["PLone"] })

        #expect(h.store.picker?.saving == ["PLone"])
        #expect(h.store.picker?.removing.isEmpty == true)
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        await addGate.open()
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.store.picker?.removing.isEmpty == true)
    }

    @Test("An unticked row of a song's menu still adds, as it always did")
    func untickedRowStillAdds() async {
        let h = ActionsHarness()
        await h.setPlaylistRows("PLone", [("x", "sx")])
        await h.openPicker(options: [road])
        await h.waitForPageReads(1)

        h.tap("PLone")

        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
        #expect(await h.backend.addToPlaylistCalls == [FakeMusicBackend.AddToPlaylistCall(videoId: "vid-1", playlistId: "PLone")])
        #expect(await h.backend.removeFromPlaylistCalls.isEmpty)
        #expect(h.ticked == ["PLone"])
    }

    // MARK: - What the rows say

    @Test("A ticked row of a song's menu says it removes; an unticked row, and any row of an album's menu, say nothing new")
    func rowHelp() {
        #expect(MusicSaveMenuRowWords.help(title: "Road Trip", isTicked: true, isSong: true) == "Remove from Road Trip")
        #expect(MusicSaveMenuRowWords.help(title: "Road Trip", isTicked: false, isSong: true) == nil)
        #expect(MusicSaveMenuRowWords.help(title: "Road Trip", isTicked: true, isSong: false) == nil)
        #expect(MusicSaveMenuRowWords.help(title: "Road Trip", isTicked: false, isSong: false) == nil)
        #expect(MusicSaveMenuRowWords.help(title: "Caf\u{E9} \u{1F3B5}", isTicked: true, isSong: true) == "Remove from Caf\u{E9} \u{1F3B5}")
    }

    @Test("VoiceOver hears Removing only for a removal, and Saving for any other busy row, ticked or not")
    func rowState() {
        let has = "Has this song"
        #expect(MusicSaveMenuRowWords.state(isTicked: false, isBusy: false, isRemoving: false, tickedText: has) == "")
        #expect(MusicSaveMenuRowWords.state(isTicked: true, isBusy: false, isRemoving: false, tickedText: has) == has)
        #expect(MusicSaveMenuRowWords.state(isTicked: false, isBusy: true, isRemoving: false, tickedText: has) == "Saving")
        // A ticked row can be busy with an add: a save went out, then a late membership read ticked the row.
        #expect(MusicSaveMenuRowWords.state(isTicked: true, isBusy: true, isRemoving: false, tickedText: has) == "Saving")
        #expect(MusicSaveMenuRowWords.state(isTicked: true, isBusy: true, isRemoving: true, tickedText: has) == "Removing")
    }

    @Test("A row that is not busy never says Removing, whatever the store still lists as removing")
    func rowStateNeedsBusyToRemove() {
        #expect(MusicSaveMenuRowWords.state(isTicked: true, isBusy: false, isRemoving: true, tickedText: "Has this song") == "Has this song")
        #expect(MusicSaveMenuRowWords.state(isTicked: false, isBusy: false, isRemoving: true, tickedText: "Has this song") == "")
    }

    @Test("None of the new lines carries an em-dash")
    func linesHaveNoEmDash() {
        let lines = [
            MusicSaveMenuRowWords.help(title: "x", isTicked: true, isSong: true) ?? "",
            MusicSaveMenuRowWords.state(isTicked: true, isBusy: true, isRemoving: true, tickedText: ""),
            MusicSaveMenuRowWords.state(isTicked: true, isBusy: true, isRemoving: false, tickedText: ""),
            MusicSaveMenuRowWords.state(isTicked: false, isBusy: true, isRemoving: false, tickedText: ""),
        ]
        for line in lines { #expect(!line.contains("\u{2014}")) }
    }
}
