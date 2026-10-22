// DeciTests/Music/MusicServiceQueueEditTests.swift
// Play next, Add to queue and Remove from queue through the service, with a fake backend and a fake AVPlayer seam: what
// plays, what Up next lists, the short notice line, and the autoplay rule that Up next is never empty.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct QueueEditHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let service: MusicService

    init(preferences: MusicPlaybackPreferences = MusicPlaybackPreferences()) {
        let clock = self.clock
        service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: engine),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: preferences,
            savePreferences: { _ in },
            shuffleSeed: 1,
            queueRetryDelay: .seconds(60),
            refreshOnCreate: false
        )
    }

    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            await play?.value
            await radio?.value
            if service.playTask == play, service.radioTask == radio { break }
        }
    }

    func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    /// Plays `tap` from a playlist page of `ids` and waits for the queue work.
    func startPage(_ ids: [String], tap: String? = nil) async {
        let page = MusicSamples.page("VLPL1", tracks: ids.map { song($0) })
        service.play(song(tap ?? ids[0]), in: page)
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Plays the first of `ids` with a radio of the rest behind it. A tapped song gets a radio only with Autoplay on,
    /// so a harness that starts with it off turns it on for the tap and puts it back at once, before the radio lands:
    /// that radio lands parked, so the queue holds the tapped song alone.
    func startRadio(_ ids: [String]) async {
        await backend.setRadio(seed: ids[0], tracks: ids.map { song($0) })
        let putBack = !service.isAutoplayOn
        if putBack { service.setAutoplay(true) }
        service.play(song(ids[0]))
        if putBack { service.setAutoplay(false) }
        await settle()
        engine.emit(.playingChanged(true))
    }

    func finishTrack() async {
        engine.emit(.ended)
        await settle()
        engine.emit(.playingChanged(true))
    }

    var listing: MusicQueueListing {
        MusicQueueListing(
            queue: service.queue,
            listsNextLap: service.listsNextLap,
            listsAutoplay: service.playsAutoplay,
            autoplayIsOn: service.isAutoplayOn
        )
    }

    var queuedIDs: [String] { service.queue.tracks.map(\.videoId) }
    var upNextIDs: [String] { listing.upcoming.map(\.videoId) }
    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }
    var notice: String? { service.trackActions.notice?.text }
}

@MainActor
@Suite("MusicService queue edits")
struct MusicServiceQueueEditTests {
    @Test("With nothing playing Play next and Add to queue just start the song, with a radio behind it and no notice line")
    func nothingPlaying() async {
        for add in [false, true] {
            let h = QueueEditHarness()
            await h.backend.setRadio(seed: "x", tracks: MusicSamples.tracks("x", "r1", "r2", "r3", "r4"))
            if add { h.service.addToQueue(h.song("x")) } else { h.service.playNext(h.song("x")) }
            await h.settle()

            #expect(h.service.queue.current?.videoId == "x")
            #expect(h.loadedIDs == ["x"])
            #expect(await h.backend.radioSeeds == ["x"])
            #expect(h.queuedIDs == ["x", "r1", "r2", "r3", "r4"])
            #expect(h.notice == nil)
        }
    }

    @Test("Play next plays the song as soon as the current one ends, says so, and Up next lists it first")
    func playNextPlaysNext() async {
        let h = QueueEditHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.service.playNext(h.song("x"))

        #expect(h.notice == "Playing next")
        #expect(Array(h.upNextIDs.prefix(3)) == ["x", "b", "c"])
        await h.finishTrack()
        #expect(h.loadedIDs == ["a", "x"])
        #expect(h.service.queue.current?.videoId == "x")
    }

    @Test("A queue that played out starts the song put into it, as there is nothing playing")
    func playedOutQueueStartsSong() async {
        for add in [false, true] {
            let h = QueueEditHarness(preferences: MusicPlaybackPreferences(autoplay: false))
            await h.startRadio(["a", "r1"])
            await h.finishTrack()
            h.engine.emit(.ended)
            await h.settle()
            #expect(h.loadedIDs == ["a"])

            if add { h.service.addToQueue(h.song("x")) } else { h.service.playNext(h.song("x")) }
            await h.settle()
            #expect(h.loadedIDs == ["a", "x"])
            #expect(h.service.queue.current?.videoId == "x")
        }
    }

    @Test("Add to queue goes after the playlist and before the radio that follows it")
    func addToQueueAfterPage() async {
        let h = QueueEditHarness()
        await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1", "r2", "r3", "r4", "r5"))
        await h.startPage(["a", "b", "c"])
        h.service.addToQueue(h.song("x"))

        #expect(h.notice == "Added to queue")
        #expect(h.queuedIDs == ["a", "b", "c", "x"])
        #expect(h.upNextIDs == ["b", "c", "x", "r1", "r2", "r3", "r4", "r5"])
    }

    @Test("Playing a song that is already upcoming moves it, it never shows twice in Up next")
    func movesInsteadOfDoubling() async {
        let h = QueueEditHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.service.playNext(h.song("d"))
        h.service.addToQueue(h.song("b"))

        #expect(h.queuedIDs == ["a", "d", "c", "e", "b"])
        #expect(Set(h.upNextIDs).count == h.upNextIDs.count)
    }

    @Test("Under Loop playlist a queued song plays in the next lap too")
    func queuedSongInNextLap() async {
        let h = QueueEditHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.startPage(["a", "b"])
        h.service.playNext(h.song("x"))
        await h.finishTrack()
        await h.finishTrack()
        #expect(h.loadedIDs == ["a", "x", "b"])
        // The page ends, the lap starts over, and the queued song is in it.
        await h.finishTrack()
        await h.finishTrack()
        #expect(h.loadedIDs == ["a", "x", "b", "a", "x"])
    }

    @Test("A Next that waits for the radio takes the song queued meanwhile")
    func parkedNextTakesQueuedSong() async {
        let h = QueueEditHarness()
        let gate = MusicTestGate()
        await h.backend.setRadioGate(seed: "a", gate)
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a", "r1", "r2"))
        h.service.play(h.song("a"))
        await h.service.playTask?.value
        h.engine.emit(.playingChanged(true))

        h.service.next()
        h.service.playNext(h.song("x"))
        await h.service.playTask?.value

        #expect(h.loadedIDs == ["a", "x"])
        await gate.open()
        await h.settle()
        #expect(h.queuedIDs.first == "a")
        #expect(h.service.queue.current?.videoId == "x")
    }

    // MARK: - Remove

    @Test("Remove from queue takes the song out, says so, and Next skips it")
    func removeSkipsSong() async {
        let h = QueueEditHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.service.removeFromQueue(h.song("b"))

        #expect(h.notice == "Removed from queue")
        #expect(Array(h.upNextIDs.prefix(3)) == ["c", "d", "e"])
        await h.finishTrack()
        #expect(h.loadedIDs == ["a", "c"])
    }

    @Test("Remove from queue on a song that is gone says nothing")
    func removeGoneSong() async {
        let h = QueueEditHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.service.removeFromQueue(h.song("zzz"))
        h.service.removeFromQueue(h.song("a"))
        #expect(h.notice == nil)
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e"])
    }

    @Test("With Autoplay on, removing the staged radio's songs and then the playlist's never leaves Up next empty")
    func upNextNeverEmpty() async {
        let h = QueueEditHarness()
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("r1", "r2", "r3", "r4"))
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("r1", "s1", "s2"))
        await h.startPage(["a", "b"])
        #expect(h.upNextIDs == ["b", "r1", "r2", "r3", "r4"])

        for id in ["r1", "r2", "r3", "r4"] { h.service.removeFromQueue(h.song(id)) }
        await h.settle()

        // The refill asked for another radio; the song the listener removed is not in it, though that radio held it.
        #expect(await h.backend.radioSeeds == ["b", "a"])
        #expect(h.upNextIDs == ["b", "s1", "s2"])

        h.service.removeFromQueue(h.song("b"))
        await h.settle()
        #expect(h.upNextIDs == ["s1", "s2"])
    }

    @Test("With Autoplay and Loop off, removing the last upcoming song lets the queue end after the current one")
    func removeLastWithoutAutoplay() async {
        let h = QueueEditHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.startRadio(["a", "b"])
        h.service.removeFromQueue(h.song("b"))
        await h.settle()

        #expect(h.upNextIDs.isEmpty)
        #expect(h.service.canGoNext == false)
        h.engine.emit(.ended)
        await h.settle()
        #expect(h.loadedIDs == ["a"])
        #expect(h.service.queue.current?.videoId == "a")
    }
}
