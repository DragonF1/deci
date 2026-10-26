// DeciTests/Music/MusicTrackActionsStoreForbiddenTests.swift
// A playlist write that YouTube Music refuses with a 403 (the channel in use does not own the playlist) says so, and
// how to fix it, for every playlist write: removing a row from a playlist page, saving a song or a whole album or
// playlist, and taking a song out of a playlist from the save menu. Likes, reads and every other error keep their
// generic lines. Fakes only; nothing here reaches the network.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicTrackActionsStore forbidden")
struct MusicTrackActionsStoreForbiddenTests {
    private static let playlistText =
        "This channel can't edit that playlist. If it's on another channel, use Switch channel in the account card."

    private let road = MusicSamples.playlistOption("PLone", title: "Road Trip")

    // MARK: - Remove from a playlist page

    @Test("A removal from a playlist page that is forbidden says the channel can't edit the playlist, and keeps the row")
    func removeForbidden() async {
        let h = ActionsHarness()
        let row = MusicSamples.track("a", setVideoId: "s1")
        let context = await h.openPage([row])
        await h.backend.setRemoveFromPlaylistError(MusicError.forbidden)

        h.store.remove(row, in: context)

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == Self.playlistText)
        #expect(h.store.notice?.isError == true)
        #expect(h.pageIds() == ["a"])
        #expect(h.probe.expired == 0)
    }

    @Test("A removal from a playlist page that fails any other way keeps the generic line")
    func removeOtherErrors() async {
        for error in [MusicError.http(500), .http(403), .rejected, .parse("x")] {
            let h = ActionsHarness()
            let row = MusicSamples.track("a", setVideoId: "s1")
            let context = await h.openPage([row])
            await h.backend.setRemoveFromPlaylistError(error)

            h.store.remove(row, in: context)

            #expect(await h.until { h.store.notice != nil }, "\(error)")
            #expect(h.store.notice?.text == MusicService.message(for: error), "\(error)")
            #expect(h.store.notice?.text != Self.playlistText, "\(error)")
        }
    }

    // MARK: - Save

    @Test("A save to a playlist that is forbidden says the channel can't edit the playlist, and leaves the row unticked")
    func saveForbidden() async {
        let h = ActionsHarness()
        await h.openPicker()
        await h.backend.setAddToPlaylistError(MusicError.forbidden)

        h.store.choose(road)

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == Self.playlistText)
        #expect(h.store.notice?.isError == true)
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.options?.first { $0.playlistId == "PLone" }?.containsVideo == false)
        #expect(h.probe.expired == 0)

        // The same row can be tried again once the right channel is in use.
        await h.backend.setAddToPlaylistError(nil)
        h.store.choose(road)
        #expect(await h.until { h.store.notice?.text == "Saved to Road Trip" })
    }

    @Test("Saving a whole album or playlist that is forbidden says the same")
    func saveCollectionForbidden() async {
        let h = ActionsHarness()
        await h.openCollectionPicker(for: h.albumTile, sourceId: "OLAK5uy_tile")
        await h.backend.setAddToPlaylistError(MusicError.forbidden)

        h.store.choose(road)

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == Self.playlistText)
        #expect(h.store.notice?.isError == true)
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(await h.backend.addPlaylistCalls.count == 1)
    }

    @Test("A save that fails any other way keeps its own lines")
    func saveOtherErrors() async {
        let h = ActionsHarness()
        await h.openPicker()

        await h.backend.setAddToPlaylistError(MusicError.rejected)
        h.store.choose(road)
        #expect(await h.until { h.store.notice?.text == "Not added. Road Trip may already have it." })

        await h.backend.setAddToPlaylistError(MusicError.http(500))
        h.store.choose(road)
        #expect(await h.until { h.store.notice?.text == "YouTube Music returned an error (500)." })

        await h.backend.setAddToPlaylistError(MusicError.http(403))
        h.store.choose(road)
        #expect(await h.until { h.store.notice?.text == "YouTube Music returned an error (403)." })

        await h.backend.setAddToPlaylistError(URLError(.notConnectedToInternet))
        h.store.choose(road)
        #expect(await h.until { h.store.notice?.text == "Network problem. Check your connection." })
    }

    // MARK: - Take a song out from the save menu

    @Test("Taking a song out of a playlist from the save menu that is forbidden says the channel can't edit the playlist")
    func unsaveForbidden() async {
        let h = ActionsHarness()
        let tracks = [MusicSamples.track("x", setVideoId: "sx"), MusicSamples.track("vid-1", setVideoId: "s1")]
        await h.backend.setPage(MusicSamples.page("VLPLone", tracks: tracks))
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })
        await h.backend.setRemoveFromPlaylistError(MusicError.forbidden)

        h.store.choose(h.options?.first { $0.playlistId == "PLone" } ?? road)

        #expect(await h.until { h.store.notice != nil })
        #expect(h.store.notice?.text == Self.playlistText)
        #expect(h.store.notice?.isError == true)
        // The row stays ticked: the song is still in the playlist.
        #expect(h.ticked == ["PLone"])
        #expect(h.store.picker?.saving.isEmpty == true)
        #expect(h.probe.expired == 0)
    }

    @Test("A removal from the save menu that fails any other way keeps its own lines")
    func unsaveOtherErrors() async {
        let h = ActionsHarness()
        let tracks = [MusicSamples.track("vid-1", setVideoId: "s1")]
        await h.backend.setPage(MusicSamples.page("VLPLone", tracks: tracks))
        await h.openPicker(options: [road])
        #expect(await h.until { h.ticked == ["PLone"] })

        await h.backend.setRemoveFromPlaylistError(MusicError.rejected)
        h.store.choose(h.options?.first { $0.playlistId == "PLone" } ?? road)
        #expect(await h.until { h.store.notice?.text == "Not removed from Road Trip." })

        await h.backend.setRemoveFromPlaylistError(MusicError.http(500))
        h.store.choose(h.options?.first { $0.playlistId == "PLone" } ?? road)
        #expect(await h.until { h.store.notice?.text == "YouTube Music returned an error (500)." })
    }

    // MARK: - Not playlist writes

    @Test("A picker list that is forbidden keeps the generic line, which is not about a playlist edit")
    func pickerListForbidden() async {
        let h = ActionsHarness()
        await h.backend.setPlaylistOptionsError(videoId: "vid-1", MusicError.forbidden)

        h.store.openPicker(for: h.song)

        let generic = "YouTube Music refused that request (403)."
        #expect(generic == MusicService.message(for: MusicError.forbidden))
        #expect(await h.until { h.store.picker?.load == .failed(generic) })
        #expect(generic != Self.playlistText)
    }

    @Test("A like that is forbidden is a failed outcome and shows the generic failure line, not the playlist line")
    func likeForbidden() async {
        let h = ActionsHarness()
        let likes = MusicLikeStore(backend: h.backend)
        await h.backend.setRateError(videoId: "vid-1", MusicError.forbidden)

        let outcome = await likes.set(.like, videoId: "vid-1")
        h.store.postIfFailed(outcome)

        #expect(outcome == .failed)
        #expect(h.store.notice?.text == "Couldn't reach YouTube Music")
        #expect(h.store.notice?.text != Self.playlistText)
        #expect(h.store.notice?.isError == true)
        #expect(h.probe.expired == 0)
    }
}
