// DeciTests/Music/MusicServiceHostMixerTests.swift
// The host owns the mixer state and says when the YouTube Music row belongs in the Mixer tab: only while the service
// exists and has a track loaded. Reading that never creates the service, so the Music tab stays lazy.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicServiceHost mixer")
struct MusicServiceHostMixerTests {
    private let track = MusicSamples.track()

    private func makeMixer() -> MusicMixerState {
        MusicMixerState(
            settings: SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            environment: FakeMusicMixerEnvironment()
        )
    }

    private func makeHost(mixer: MusicMixerState? = nil, engine: FakePlaybackEngine = FakePlaybackEngine()) -> MusicServiceHost {
        MusicServiceHost(mixer: mixer, makeService: {
            MusicService(
                backend: FakeMusicBackend(),
                player: MusicPlayer(engine: engine),
                presentSignIn: { _ in },
                nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
                lyrics: MusicLyricsStore(provider: FakeLyricsProvider(), sleep: { _ in }),
                refreshOnCreate: false
            )
        })
    }

    @Test("the host keeps the mixer it was given, and works without one")
    func ownsTheMixer() {
        let mixer = makeMixer()
        #expect(makeHost(mixer: mixer).mixer === mixer)
        #expect(makeHost().mixer == nil)
    }

    @Test("nothing is loaded before the Music tab is used, and asking does not create the service")
    func hiddenBeforeTheTabIsUsed() {
        let host = makeHost(mixer: makeMixer())
        #expect(!host.hasLoadedTrack)
        #expect(host.service == nil, "reading it must leave the service lazy")
    }

    @Test("a service with nothing in the player has no track loaded")
    func noTrack() {
        let host = makeHost(mixer: makeMixer())
        host.loadIfNeeded()
        #expect(!host.hasLoadedTrack)
    }

    @Test("a track in the player counts as loaded, playing or paused, and stopping removes it")
    func trackLifecycle() throws {
        let host = makeHost(mixer: makeMixer())
        host.loadIfNeeded()
        let player = try #require(host.service).player

        player.beginLoading(track)
        #expect(host.hasLoadedTrack)

        player.load(stream: MusicSamples.stream(duration: 200), track: track)
        #expect(host.hasLoadedTrack)
        player.pause()
        #expect(host.hasLoadedTrack, "paused is still loaded")

        player.stop()
        #expect(!host.hasLoadedTrack)
    }

    @Test("building the live player binds the mixer to its engine, so a stored output device applies at once")
    func livePlayerBindsTheMixer() {
        let mixer = makeMixer()
        #expect(!mixer.hasEngine)
        _ = MusicServiceHost.makePlayer(mixer: mixer)
        #expect(mixer.hasEngine)
    }
}
