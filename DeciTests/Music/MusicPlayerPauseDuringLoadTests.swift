// DeciTests/Music/MusicPlayerPauseDuringLoadTests.swift
// A pause while a song is loading has to stick. The load has two stages: the stream is still being resolved (the player
// shows the song as loading and has nothing to hand the engine), then the stream is installed and the engine is
// buffering. A pause in the first stage used to be forgotten when the stream arrived, and the song played anyway. The
// keyboard's play/pause key and the Now Playing pause command both go through `MusicPlayer.pause()`.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicPlayer: pause during a load")
struct MusicPlayerPauseDuringLoadTests {
    private struct Rig {
        let engine = FakePlaybackEngine()
        let player: MusicPlayer

        init() {
            player = MusicPlayer(engine: engine)
        }

        /// The stream for `track` arrives, as `MusicService` hands it over once it has resolved.
        func resolve(_ track: MusicTrack) {
            player.load(stream: MusicSamples.stream(videoId: track.videoId, expiresAt: Date().addingTimeInterval(3600)), track: track)
        }
    }

    // MARK: - Stream still being resolved

    @Test("A song that has just started loading counts as active and wants to play")
    func loadingWantsToPlay() {
        let rig = Rig()
        rig.player.beginLoading(MusicSamples.track("a"))
        #expect(rig.player.isLoading)
        #expect(rig.player.isActive)
    }

    @Test("A pause before the stream arrives leaves the song paused when it does")
    func pauseBeforeStreamSticks() {
        let rig = Rig()
        let track = MusicSamples.track("a")
        rig.player.beginLoading(track)

        rig.player.pause()
        #expect(rig.player.isActive == false)
        rig.resolve(track)

        #expect(rig.engine.loads.map(\.autoplay) == [false])
        #expect(rig.engine.playCount == 0)
        #expect(rig.player.isActive == false)
        #expect(rig.player.isPlaying == false)
        #expect(rig.player.nowPlaying?.videoId == "a")
    }

    @Test("A song that arrives paused is not left showing as loading")
    func pausedArrivalIsNotLoading() {
        let rig = Rig()
        let track = MusicSamples.track("a")
        rig.player.beginLoading(track)
        rig.player.pause()
        rig.resolve(track)

        #expect(rig.player.isLoading == false)
        rig.engine.emit(.ready(duration: 200))
        #expect(rig.player.isLoading == false)
        #expect(rig.player.isActive == false)
        #expect(rig.player.duration == 200)
    }

    @Test("Play after that pause, still before the stream arrives, starts the song when it does")
    func playAgainBeforeStream() {
        let rig = Rig()
        let track = MusicSamples.track("a")
        rig.player.beginLoading(track)
        rig.player.pause()

        rig.player.play()
        #expect(rig.player.isActive)
        rig.resolve(track)

        #expect(rig.engine.loads.map(\.autoplay) == [true])
        #expect(rig.player.isActive)
    }

    @Test("Toggle in the first stage pauses, then plays again")
    func toggleBeforeStream() {
        let rig = Rig()
        let track = MusicSamples.track("a")
        rig.player.beginLoading(track)

        rig.player.toggle()
        #expect(rig.player.isActive == false)
        rig.player.toggle()
        #expect(rig.player.isActive)
        rig.player.toggle()
        #expect(rig.player.isActive == false)

        rig.resolve(track)
        #expect(rig.engine.loads.map(\.autoplay) == [false])
    }

    @Test("Playing a song that is already loading, before the stream arrives, changes nothing")
    func playWhileLoadingIsHarmless() {
        let rig = Rig()
        let track = MusicSamples.track("a")
        rig.player.beginLoading(track)
        rig.player.play()
        rig.resolve(track)
        #expect(rig.engine.loads.map(\.autoplay) == [true])
        #expect(rig.engine.playCount == 0)
    }

    @Test("The next song starts playing even after the one before it was paused while loading")
    func nextSongAfterPausedLoad() {
        let rig = Rig()
        rig.player.beginLoading(MusicSamples.track("a"))
        rig.player.pause()

        let next = MusicSamples.track("b")
        rig.player.beginLoading(next)
        #expect(rig.player.isActive)
        rig.resolve(next)

        #expect(rig.engine.loads.map(\.autoplay) == [true])
        #expect(rig.engine.loads.map(\.stream.videoId) == ["b"])
    }

    @Test("A stream for some other song than the one loading still plays: only a pause for this song is remembered")
    func otherSongStillPlays() {
        let rig = Rig()
        rig.player.beginLoading(MusicSamples.track("a"))
        rig.player.pause()

        rig.resolve(MusicSamples.track("z"))

        #expect(rig.engine.loads.map(\.autoplay) == [true])
    }

    @Test("A stream loaded with no loading state before it plays, as every direct load does")
    func directLoadPlays() {
        let rig = Rig()
        rig.player.pause()
        rig.resolve(MusicSamples.track("a"))
        #expect(rig.engine.loads.map(\.autoplay) == [true])
        #expect(rig.player.isLoading)
        #expect(rig.player.isActive)
    }

    @Test("Giving up on the stream leaves nothing to play when it is resolved later, and the song reads as paused")
    func failLoadingClearsIntent() {
        let rig = Rig()
        rig.player.beginLoading(MusicSamples.track("a"))
        rig.player.failLoading()
        #expect(rig.player.isLoading == false)
        #expect(rig.player.isActive == false)
        rig.player.play()
        #expect(rig.player.isActive == false)
        #expect(rig.engine.playCount == 0)
    }

    // MARK: - Engine buffering

    @Test("A pause while the engine is buffering stays paused when it becomes ready")
    func pauseWhileBuffering() {
        let rig = Rig()
        let track = MusicSamples.track("a")
        rig.player.beginLoading(track)
        rig.resolve(track)
        #expect(rig.engine.loads.map(\.autoplay) == [true])

        rig.player.pause()
        #expect(rig.engine.pauseCount == 1)
        #expect(rig.player.isActive == false)

        rig.engine.emit(.ready(duration: 200))
        #expect(rig.player.isLoading == false)
        #expect(rig.player.isActive == false)
        #expect(rig.player.isPlaying == false)
    }

    @Test("Play after a pause while buffering plays the loaded stream")
    func playAfterBufferingPause() {
        let rig = Rig()
        let track = MusicSamples.track("a")
        rig.player.beginLoading(track)
        rig.resolve(track)
        rig.player.pause()
        rig.engine.emit(.ready(duration: 200))

        rig.player.play()
        #expect(rig.engine.playCount == 1)
        #expect(rig.player.isActive)
    }

    // MARK: - Recovery

    @Test("A pause while a dead stream is being replaced stays paused when the new one arrives")
    func pauseDuringRefresh() async {
        let rig = Rig()
        let track = MusicSamples.track("a")
        let gate = MusicTestGate()
        rig.player.onNeedsFreshStream = { track in
            await gate.wait()
            return MusicSamples.stream(videoId: track.videoId, expiresAt: Date().addingTimeInterval(3600))
        }
        rig.player.beginLoading(track)
        rig.resolve(track)
        rig.engine.emit(.playingChanged(true))
        rig.engine.emit(.failed)
        let refresh = rig.player.refreshTask
        #expect(refresh != nil)

        rig.player.pause()
        await gate.open()
        await refresh?.value

        #expect(rig.engine.loads.map(\.autoplay) == [true, false])
        #expect(rig.player.isActive == false)
    }
}
