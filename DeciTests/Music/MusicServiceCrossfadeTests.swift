// DeciTests/Music/MusicServiceCrossfadeTests.swift
// Phase 1c: the service's side of crossfade. It tells the engine how long the next transition fades (0 is the gapless
// switch), opens the preload window earlier by that length, takes the engine's "advanced" report at fade start as the
// track change exactly once, and answers a manual Next onto the preloaded track with a 0.3 s crossfade. A fake engine
// under a mutable clock; the engine's own scheduling is covered by the real-playback tests.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct CrossfadeHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let connectivity = MusicConnectivity(isOnline: true)
    let player: MusicPlayer
    let service: MusicService
    let saved = SavedPreferences()

    @MainActor
    final class SavedPreferences {
        var all: [MusicPlaybackPreferences] = []
    }

    init(crossfade: Bool = true, seconds: Double = 6, live: (@MainActor () -> Double)? = nil) {
        let engine = self.engine
        let clock = self.clock
        let saved = self.saved
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
            preferences: MusicPlaybackPreferences(crossfade: crossfade, crossfadeSeconds: seconds),
            savePreferences: { saved.all.append($0) },
            crossfadeSeconds: live,
            queueRetryDelay: .seconds(60),
            connectivity: connectivity,
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

    func startQueue(_ ids: [String]) async {
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)") }
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
    }

    func startPage(_ browseId: String, _ ids: [String]) async {
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)") }
        service.play(tracks[0], in: MusicSamples.page(browseId, tracks: tracks))
        await settle()
        engine.emit(.playingChanged(true))
    }

    func enterWindow(at position: TimeInterval = 186) async {
        engine.tick(position, playing: true)
        await service.prefetchTask?.value
        engine.tick(position + 0.5, playing: true)
    }

    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }
}

@MainActor
@Suite("MusicService crossfade")
struct MusicServiceCrossfadeTests {
    // MARK: - What the engine is told

    @Test("with Crossfade on the engine plans the Settings length, with it off it plans none")
    func engineGetsTheLength() async {
        let on = CrossfadeHarness(crossfade: true, seconds: 8)
        await on.startQueue(["a", "b", "c"])
        await on.enterWindow()
        #expect(on.engine.crossfadeSeconds == 8)

        let off = CrossfadeHarness(crossfade: false, seconds: 8)
        await off.startQueue(["a", "b", "c"])
        await off.enterWindow()
        #expect(off.engine.crossfadeSeconds == 0)
    }

    @Test("turning the toggle changes the next transition, the preload stays")
    func toggleChangesTheNextTransition() async {
        let h = CrossfadeHarness(crossfade: false)
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        #expect(h.engine.crossfadeSeconds == 0)
        h.service.setCrossfade(true)
        #expect(h.engine.crossfadeSeconds == 6)
        #expect(h.engine.preloadedVideoId == "b", "no preload is lost to the toggle")
        h.service.setCrossfade(false)
        #expect(h.engine.crossfadeSeconds == 0)
    }

    @Test("the length is read live from Settings, clamped to 1 to 12 seconds")
    func lengthIsLiveAndClamped() async {
        var live = 4.0
        let h = CrossfadeHarness(crossfade: true, seconds: 6, live: { live })
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        #expect(h.engine.crossfadeSeconds == 4)
        live = 40
        #expect(h.service.crossfadeSeconds == 12)
        live = 0
        #expect(h.service.crossfadeSeconds == 1)
        live = .nan
        #expect(h.service.crossfadeSeconds == 6)
    }

    @Test("Loop song gets no crossfade into itself")
    func loopSongHasNoFade() async {
        let h = CrossfadeHarness()
        await h.startQueue(["a", "b"])
        h.service.setLoopMode(.song)
        await h.enterWindow()
        #expect(h.engine.crossfadeSeconds == 0)
        h.service.setLoopMode(.off)
        #expect(h.service.effectiveCrossfadeSeconds == 6)
    }

    @Test("an album played in order stays gapless, a playlist and a shuffled album fade")
    func albumInOrderStaysGapless() async {
        let album = CrossfadeHarness()
        await album.startPage("MPREb_album", ["a", "b", "c"])
        await album.enterWindow()
        #expect(album.engine.crossfadeSeconds == 0)
        #expect(album.engine.preloadedVideoId == "b", "still preloaded, for the gapless switch")

        let olak = CrossfadeHarness()
        await olak.startPage("VLOLAK5uy_album", ["a", "b", "c"])
        await olak.enterWindow()
        #expect(olak.engine.crossfadeSeconds == 0)

        let playlist = CrossfadeHarness()
        await playlist.startPage("VLPL1", ["a", "b", "c"])
        await playlist.enterWindow()
        #expect(playlist.engine.crossfadeSeconds == 6)

        let shuffled = CrossfadeHarness()
        await shuffled.startPage("MPREb_album", ["a", "b", "c", "d"])
        shuffled.service.setShuffle(true)
        await shuffled.enterWindow()
        #expect(shuffled.engine.crossfadeSeconds == 6, "a shuffled album is no longer in order")
    }

    @Test("the preload window opens the fade length earlier, and not with Crossfade off")
    func windowOpensEarlier() async {
        let on = CrossfadeHarness(crossfade: true, seconds: 12)
        await on.startQueue(["a", "b", "c"])
        // 24 s left: outside the gapless window (15 s), inside the crossfade one (15 + 12).
        on.engine.tick(176, playing: true)
        await on.service.prefetchTask?.value
        on.engine.tick(176.5, playing: true)
        #expect(on.engine.preloads.map(\.videoId) == ["b"])

        let off = CrossfadeHarness(crossfade: false, seconds: 12)
        await off.startQueue(["a", "b", "c"])
        off.engine.tick(176, playing: true)
        await off.service.prefetchTask?.value
        off.engine.tick(176.5, playing: true)
        #expect(off.engine.preloads.isEmpty, "toggle off is the 1a window")
    }

    // MARK: - Flip at fade start

    @Test("the engine's advance at fade start is the track change, once")
    func flipIsOneTrackChange() async {
        let h = CrossfadeHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        let unloads = h.engine.unloadCount

        h.engine.advance()
        await h.settle()
        #expect(h.service.queue.current?.videoId == "b")
        #expect(h.player.nowPlaying?.videoId == "b")
        #expect(h.loadedIDs == ["a"], "the incoming deck was preloaded: no load")
        #expect(h.engine.unloadCount == unloads, "the outgoing deck is the engine's to drain, never unloaded here")

        h.engine.advance()
        await h.settle()
        #expect(h.service.queue.current?.videoId == "b", "a second report moves nothing")
        #expect(h.player.nowPlaying?.videoId == "b")
    }

    // MARK: - Manual Next and Previous

    @Test("Next onto the preloaded track is a 0.3 s crossfade with no load")
    func nextOntoThePreload() async {
        let h = CrossfadeHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()

        h.service.next()
        await h.settle()
        #expect(h.engine.manualCrossfades == [0.3])
        #expect(h.loadedIDs == ["a"])
        #expect(h.service.queue.current?.videoId == "b")
        #expect(h.player.nowPlaying?.videoId == "b")
        #expect(h.player.isLoading == false)

        // The next lap offers the track after it.
        await h.enterWindow()
        #expect(h.engine.preloads.map(\.videoId) == ["b", "c"])
    }

    @Test("Next with nothing preloaded keeps today's behaviour: the track is loaded the old way")
    func nextWithoutPreload() async {
        let h = CrossfadeHarness()
        await h.startQueue(["a", "b", "c"])
        h.engine.tick(20, playing: true)
        h.service.next()
        await h.settle()
        #expect(h.engine.manualCrossfades.isEmpty)
        #expect(h.loadedIDs == ["a", "b"])
    }

    @Test("with Crossfade off Next never crossfades, even with the preload ready")
    func nextWithCrossfadeOff() async {
        let h = CrossfadeHarness(crossfade: false)
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        h.service.next()
        await h.settle()
        #expect(h.engine.manualCrossfades.isEmpty)
        #expect(h.loadedIDs == ["a", "b"])
    }

    @Test("a preload that is not ready yet is not crossfaded to: the ordinary load runs")
    func nextWithPreloadNotReady() async {
        let h = CrossfadeHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        h.engine.preloadReady = false
        h.service.next()
        await h.settle()
        #expect(h.engine.manualCrossfades.isEmpty)
        #expect(h.loadedIDs == ["a", "b"])
    }

    @Test("an engine that refuses the crossfade leaves the ordinary track change to run")
    func engineRefuses() async {
        let h = CrossfadeHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        h.engine.refusesManualCrossfade = true
        h.service.next()
        await h.settle()
        #expect(h.loadedIDs == ["a", "b"])
        #expect(h.service.queue.current?.videoId == "b")
    }

    @Test("a paused player skips the ordinary way")
    func pausedSkips() async {
        let h = CrossfadeHarness()
        await h.startQueue(["a", "b", "c"])
        await h.enterWindow()
        h.engine.emit(.playingChanged(false))
        h.service.next()
        await h.settle()
        #expect(h.engine.manualCrossfades.isEmpty)
        #expect(h.loadedIDs == ["a", "b"])
    }

    // MARK: - Preferences

    @Test("the toggle is saved with the length, and the reset puts it back off")
    func toggleIsSaved() async {
        let h = CrossfadeHarness(crossfade: false, seconds: 9)
        h.service.setCrossfade(true)
        #expect(h.saved.all.last == MusicPlaybackPreferences(crossfade: true, crossfadeSeconds: 9))
        h.service.setCrossfade(true)
        #expect(h.saved.all.count == 1, "no change, no write")
        h.service.settingsDidReset()
        #expect(h.service.isCrossfadeOn == false)
    }
}
