// DeciTests/Music/MusicPlaybackKeyTargetTests.swift
// Deci's side of the play/pause, next and previous keys: what counts as playing (a song loading counts, a paused one does
// not), what counts as paused with a song loaded, and that the actions reach the player through the same calls the
// Now Playing remote commands use. The target never builds the music service.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct KeyTargetHarness {
    let backend = FakeMusicBackend(signedIn: true)
    let engine = FakePlaybackEngine()
    let service: MusicService
    let host: MusicServiceHost
    let target: MusicPlaybackKeyTarget

    /// `loaded: false` is the app before the Music popup was ever opened: the host has no service yet.
    init(loaded: Bool = true) {
        let service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: engine),
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
        self.host = host
        target = MusicPlaybackKeyTarget(musicHost: host)
        if loaded { host.loadIfNeeded() }
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

    /// Plays the first of `ids` with a radio of the rest behind it, waits for both, and has the engine report playing.
    func startPlaying(_ ids: [String]) async {
        await backend.setRadio(seed: ids[0], tracks: ids.map { song($0) })
        service.play(song(ids[0]))
        await settle()
        engine.emit(.playingChanged(true))
    }

    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }
}

@MainActor
@Suite("MusicPlaybackKeyTarget")
struct MusicPlaybackKeyTargetTests {
    @Test("Before the Music popup was ever opened nothing plays, and the target does not build the service")
    func neverBuildsTheService() {
        let h = KeyTargetHarness(loaded: false)
        #expect(h.target.playbackState == .idle)
        for action in [DeciPlaybackAction.pause, .resume, .next, .previous] {
            h.target.perform(action)
        }
        #expect(h.host.service == nil)
        #expect(h.engine.playCount == 0)
        #expect(h.engine.pauseCount == 0)
    }

    @Test("A service with nothing loaded is idle, and the actions do nothing")
    func nothingLoaded() {
        let h = KeyTargetHarness()
        #expect(h.target.playbackState == .idle)
        for action in [DeciPlaybackAction.pause, .resume, .next, .previous] {
            h.target.perform(action)
        }
        #expect(h.engine.loads.isEmpty)
        #expect(h.engine.playCount == 0)
    }

    @Test("A song that is still loading counts as playing")
    func loadingIsPlaying() async {
        let h = KeyTargetHarness()
        await h.backend.setRadio(seed: "a", tracks: [h.song("a")])
        h.service.play(h.song("a"))
        // Nothing has loaded or started yet: the player only shows the song as loading.
        #expect(h.service.player.isLoading)
        #expect(h.service.player.isPlaying == false)
        #expect(h.target.playbackState == .playing)
        await h.settle()
    }

    @Test("A song the engine reports as playing is playing")
    func playing() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b"])
        #expect(h.target.playbackState == .playing)
    }

    @Test("Pause pauses the player, which then reads as paused with a song loaded")
    func pauseThenPaused() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b"])
        h.target.perform(.pause)
        #expect(h.engine.pauseCount == 1)
        h.engine.emit(.playingChanged(false))
        #expect(h.target.playbackState == .pausedWithSong)
    }

    @Test("Pause is a pause even for a song that stalled, where a toggle would have resumed it")
    func pauseWhileStalled() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b"])
        // The engine stalls: it is not playing, but the listener still wants it to.
        h.engine.emit(.playingChanged(false))
        #expect(h.target.playbackState == .playing)
        let playsBefore = h.engine.playCount
        h.target.perform(.pause)
        #expect(h.engine.pauseCount == 1)
        #expect(h.engine.playCount == playsBefore)
        #expect(h.target.playbackState == .pausedWithSong)
    }

    @Test("Resume plays the paused song again")
    func resume() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b"])
        h.target.perform(.pause)
        h.engine.emit(.playingChanged(false))
        let playsBefore = h.engine.playCount
        h.target.perform(.resume)
        #expect(h.engine.playCount == playsBefore + 1)
        h.engine.emit(.playingChanged(true))
        #expect(h.target.playbackState == .playing)
    }

    @Test("Next moves on to the next song in the queue")
    func next() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b", "c"])
        h.target.perform(.next)
        await h.settle()
        #expect(h.loadedIDs == ["a", "b"])
    }

    @Test("Next a second time while the first is still loading moves on again")
    func nextTwiceWhileLoading() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b", "c"])
        h.target.perform(.next)
        // The second press comes before b has loaded: the player already shows it loading, so it is playing.
        #expect(h.target.playbackState == .playing)
        h.target.perform(.next)
        await h.settle()
        #expect(h.loadedIDs.last == "c")
    }

    @Test("Previous goes back one song when the current one has only just started")
    func previous() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b", "c"])
        h.target.perform(.next)
        await h.settle()
        h.engine.emit(.playingChanged(true))
        h.target.perform(.previous)
        await h.settle()
        #expect(h.loadedIDs == ["a", "b", "a"])
    }

    // MARK: - Pause during a load

    @Test("Pause right after Next, while the next song is still resolving, keeps it paused when it loads")
    func pauseAfterNextSticks() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b", "c"])
        let gate = MusicTestGate()
        await h.backend.setResolveGate("b", gate)

        h.target.perform(.next)
        #expect(h.target.playbackState == .playing)
        h.target.perform(.pause)
        #expect(h.target.playbackState == .pausedWithSong)

        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["a", "b"])
        #expect(h.engine.loads.last?.autoplay == false)
        #expect(h.engine.playCount == 0)
        #expect(h.service.player.isPlaying == false)
        #expect(h.target.playbackState == .pausedWithSong)
    }

    @Test("Resume after a pause that came during the load plays the song once it is loaded")
    func resumeAfterPausedLoad() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b", "c"])
        let gate = MusicTestGate()
        await h.backend.setResolveGate("b", gate)
        h.target.perform(.next)
        h.target.perform(.pause)
        await gate.open()
        await h.settle()

        h.target.perform(.resume)
        #expect(h.engine.playCount == 1)
        h.engine.emit(.playingChanged(true))
        #expect(h.target.playbackState == .playing)
    }

    @Test("Pause then resume, both before the next song has resolved, still starts it")
    func pauseThenResumeBeforeResolve() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b", "c"])
        let gate = MusicTestGate()
        await h.backend.setResolveGate("b", gate)
        h.target.perform(.next)

        h.target.perform(.pause)
        h.target.perform(.resume)
        #expect(h.target.playbackState == .playing)
        await gate.open()
        await h.settle()

        #expect(h.engine.loads.last?.autoplay == true)
        #expect(h.loadedIDs == ["a", "b"])
    }

    @Test("A Next after a pause that came during a load plays the song it moves to")
    func nextAfterPausedLoad() async {
        let h = KeyTargetHarness()
        await h.startPlaying(["a", "b", "c"])
        let gate = MusicTestGate()
        await h.backend.setResolveGate("b", gate)
        h.target.perform(.next)
        h.target.perform(.pause)

        h.target.perform(.next)
        await gate.open()
        await h.settle()

        #expect(h.loadedIDs.last == "c")
        #expect(h.engine.loads.last?.autoplay == true)
        #expect(h.target.playbackState == .playing)
    }
}
