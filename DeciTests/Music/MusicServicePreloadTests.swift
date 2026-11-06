// DeciTests/Music/MusicServicePreloadTests.swift
// The service's side of gapless playback: it hands the engine the next track only when that track is certain, takes
// the engine's "advanced" report as the track change (the same bookkeeping as starting a track, minus the teardown), and
// withdraws the preload whenever the next track might no longer be the one preloaded. A fake engine, no real player.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct PreloadHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let player: MusicPlayer
    let service: MusicService

    init() {
        let engine = self.engine
        let clock = self.clock
        let player = MusicPlayer(engine: engine)
        self.player = player
        self.service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
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

    /// Plays the first of `ids` with a radio of all of them behind it and the engine reporting playback.
    func startQueue(_ ids: [String]) async {
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)") }
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: nil)
        let putBack = !service.isAutoplayOn
        if putBack { service.setAutoplay(true) }
        service.play(tracks[0])
        if putBack { service.setAutoplay(false) }
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Ticks into the preload window and waits for the prefetch that feeds it.
    func enterWindow(at position: TimeInterval = 186) async {
        engine.tick(position, playing: true)
        await service.prefetchTask?.value
        engine.tick(position + 0.5, playing: true)
    }

    var preloadedIDs: [String] { engine.preloads.map(\.videoId) }
    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }
}

@MainActor
@Suite("MusicService preload")
struct MusicServicePreloadTests {
    @Test("the next track is handed to the engine inside the window, not before")
    func preloadsInsideTheWindow() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b", "c"])
        h.engine.tick(100, playing: true)
        await h.service.prefetchTask?.value
        #expect(h.preloadedIDs.isEmpty)

        await h.enterWindow()
        #expect(h.preloadedIDs == ["b"])

        h.engine.tick(187, playing: true)
        #expect(h.preloadedIDs == ["b"], "one offer per track")
    }

    @Test("with nothing certain to follow, nothing is preloaded")
    func noPreloadWithoutANextTrack() async {
        let h = PreloadHarness()
        h.service.setAutoplay(false)
        await h.startQueue(["a"])
        await h.enterWindow()
        #expect(h.preloadedIDs.isEmpty)
    }

    @Test("a paused track is not preloaded for")
    func noPreloadWhilePaused() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b"])
        h.engine.emit(.playingChanged(false))
        h.engine.tick(186, playing: false)
        await h.service.prefetchTask?.value
        #expect(h.preloadedIDs.isEmpty)
    }

    @Test("the engine's advance moves the queue and the player on without loading anything")
    func advanceRunsTheBookkeeping() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        let unloadsBefore = h.engine.unloadCount

        h.engine.advance()
        await h.settle()

        #expect(h.service.queue.current?.videoId == "b")
        #expect(h.player.nowPlaying?.videoId == "b")
        #expect(h.loadedIDs == ["a"], "the preloaded item plays on: no second load")
        #expect(h.engine.unloadCount == unloadsBefore, "the deck that is playing is never torn down")
        #expect(h.player.isLoading == false)
        #expect(h.player.hasEnded == false)

        // The next lap of the window preloads the track after it.
        await h.enterWindow()
        #expect(h.preloadedIDs == ["b", "c"])
    }

    @Test("an advance to a track the queue does not expect falls back to the ordinary track change")
    func mismatchFallsBack() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()

        h.engine.emit(.advanced(videoId: "zzz"))
        await h.settle()

        #expect(h.loadedIDs == ["a", "b"], "the queue's own next track is loaded the old way")
        #expect(h.service.queue.current?.videoId == "b")
    }

    @Test("without a preload the end of a track is the old path")
    func endedStillAdvances() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b"])
        h.engine.emit(.ended)
        await h.settle()
        #expect(h.loadedIDs == ["a", "b"])
    }

    @Test("Loop song preloads the same track and replays it without moving the queue")
    func loopSongPreloadsItself() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b"])
        h.service.setLoopMode(.song)
        await h.enterWindow()
        #expect(h.preloadedIDs == ["a"])

        h.engine.advance()
        await h.settle()
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.loadedIDs == ["a"])
        #expect(h.player.nowPlaying?.videoId == "a")
    }

    @Test("staged autoplay tracks are certain once the page has run out")
    func autoplayPreloads() async {
        let h = PreloadHarness()
        h.service.setAutoplay(true)
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        #expect(h.preloadedIDs == ["b"])
    }

    // MARK: - Cancelling

    @Test("a queue edit that changes the next track withdraws the preload")
    func queueEditCancels() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        let before = h.engine.cancelPreloadCount

        h.service.removeFromQueue(MusicSamples.track("b", title: "Song b"))
        #expect(h.engine.cancelPreloadCount > before)
        #expect(h.engine.preloadedVideoId == nil)
    }

    @Test("removing a track behind the next one leaves the preload alone")
    func harmlessEditKeepsIt() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        let before = h.engine.cancelPreloadCount

        h.service.removeFromQueue(MusicSamples.track("c", title: "Song c"))
        #expect(h.engine.cancelPreloadCount == before)
        #expect(h.engine.preloadedVideoId == "b")
    }

    @Test("Loop song, Autoplay and shuffle changes withdraw a preload they invalidate")
    func modeChangesCancel() async {
        let loop = PreloadHarness()
        await loop.startQueue(["a", "b", "c"])
        await loop.enterWindow()
        loop.service.setLoopMode(.song)
        #expect(loop.engine.preloadedVideoId == nil)

        let shuffle = PreloadHarness()
        await shuffle.startQueue(["a", "b", "c", "d", "e", "f"])
        await shuffle.enterWindow()
        let first = shuffle.engine.preloadedVideoId
        shuffle.service.setShuffle(true)
        // Shuffling reorders what follows: the preload stays only if the same track still comes next.
        #expect(shuffle.engine.preloadedVideoId == nil || shuffle.engine.preloadedVideoId == shuffle.service.queue.upcoming.first?.videoId)
        #expect(first != nil)

        let auto = PreloadHarness()
        auto.service.setAutoplay(true)
        await auto.startQueue(["a"])
        await auto.enterWindow()
        let autoBefore = auto.engine.preloadedVideoId
        auto.service.setAutoplay(false)
        if autoBefore != nil { #expect(auto.engine.preloadedVideoId == nil) }
    }

    @Test("skipping, going back and jumping withdraw the preload")
    func navigationCancels() async {
        let next = PreloadHarness()
        await next.startQueue(["a", "b", "c"])
        await next.enterWindow()
        next.service.next()
        #expect(next.engine.preloadedVideoId == nil)
        await next.settle()
        #expect(next.loadedIDs == ["a", "b"])

        let jump = PreloadHarness()
        await jump.startQueue(["a", "b", "c"])
        await jump.enterWindow()
        jump.service.jump(to: jump.service.queue.tracks[2])
        #expect(jump.engine.preloadedVideoId == nil)
        await jump.settle()
        #expect(jump.loadedIDs == ["a", "c"])
    }

    @Test("a seek out of the window withdraws the preload, and the window offers it again")
    func seekCancels() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        #expect(h.engine.preloadedVideoId == "b")

        h.service.seek(to: 20)
        #expect(h.engine.preloadedVideoId == nil)

        await h.enterWindow()
        #expect(h.engine.preloadedVideoId == "b")
    }

    @Test("a seek inside the window keeps the preload")
    func seekInsideKeeps() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        h.service.seek(to: 190)
        #expect(h.engine.preloadedVideoId == "b")
    }

    @Test("a stream refresh withdraws the preload")
    func refreshCancels() async {
        let h = PreloadHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        h.engine.emit(.failed)
        #expect(h.engine.preloadedVideoId == nil)
    }

    @Test("stopping and signing out withdraw the preload")
    func stopAndSignOutCancel() async {
        let stopped = PreloadHarness()
        await stopped.startQueue(["a", "b", "c"])
        await stopped.enterWindow()
        stopped.service.stop()
        #expect(stopped.engine.preloadedVideoId == nil)

        let out = PreloadHarness()
        await out.startQueue(["a", "b", "c"])
        await out.enterWindow()
        out.service.signOut()
        #expect(out.engine.preloadedVideoId == nil)
    }
}
