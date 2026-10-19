// DeciTests/Music/MusicLyricsServiceTests.swift
// How MusicService feeds the lyrics store: the current track and its exact duration, playback
// position, and the resets on sign-out and an account swap. Fake backend, fake engine, fake LRCLIB.

import Foundation
import Testing
@testable import Deci

@MainActor
private final class Probe {
    var completion: (@MainActor ([StoredCookie]?) -> Void)?
}

@MainActor
private struct Harness {
    let backend = FakeMusicBackend(signedIn: true)
    let engine = FakePlaybackEngine()
    let provider = FakeLyricsProvider()
    let clock = MutableClock()
    let probe = Probe()
    let player: MusicPlayer
    let lyrics: MusicLyricsStore
    let service: MusicService

    init() {
        let engine = self.engine
        let probe = self.probe
        let provider = self.provider
        let clock = self.clock
        let player = MusicPlayer(engine: engine)
        let lyrics = MusicLyricsStore(provider: provider, now: { clock.now }, sleep: { _ in })
        self.player = player
        self.lyrics = lyrics
        service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { probe.completion = $0 },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            lyrics: lyrics,
            refreshOnCreate: false
        )
    }

    func play(_ id: String, duration: Double? = nil) async {
        if let duration { await backend.setStream(MusicSamples.stream(videoId: id, duration: duration)) }
        service.play(MusicSamples.track(id, title: "Song \(id)"))
        await service.playTask?.value
        await service.radioTask?.value
    }
}

@MainActor
@Suite("MusicService lyrics wiring")
struct MusicLyricsServiceTests {

    @Test("The service owns a lyrics store")
    func ownsAStore() {
        let h = Harness()
        #expect(h.service.lyrics === h.lyrics)
    }

    @Test("Nothing is fetched for any track while the panel is closed")
    func closedPanelFetchesNothing() async {
        let h = Harness()
        await h.play("a")
        await h.play("b")
        #expect(h.provider.queries.isEmpty)
        #expect(h.lyrics.state == .idle)
    }

    @Test("Opening the panel asks for the playing track with the exact length the player knows")
    func openingAsksForTheTrack() async {
        let h = Harness()
        await h.play("a", duration: 213.7)
        #expect(h.player.duration == 213.7)
        h.lyrics.setPanelOpen(true)
        await h.lyrics.loadTask?.value
        #expect(h.provider.queries.count == 1)
        #expect(h.provider.queries.first?.videoId == "a")
        #expect(h.provider.queries.first?.title == "Song a")
        #expect(h.provider.queries.first?.duration == 213.7)
    }

    @Test("A new track while the panel is open is fetched")
    func trackChangeWhileOpen() async {
        let h = Harness()
        h.lyrics.setPanelOpen(true)
        await h.play("a")
        await h.lyrics.loadTask?.value
        await h.play("b")
        await h.lyrics.loadTask?.value
        #expect(h.provider.videoIds == ["a", "b"])
    }

    @Test("A stream arriving for the same track does not fetch twice")
    func streamLoadDoesNotRefetch() async {
        let h = Harness()
        h.lyrics.setPanelOpen(true)
        await h.play("a", duration: 213.7)
        await h.lyrics.loadTask?.value
        h.service.seek(to: 30)
        #expect(h.provider.queries.count == 1)
    }

    @Test("Stopping playback ends the lyrics for the track")
    func stopClearsTrack() async {
        let h = Harness()
        h.lyrics.setPanelOpen(true)
        await h.play("a")
        await h.lyrics.loadTask?.value
        h.player.stop()
        #expect(h.lyrics.track == nil)
        #expect(h.lyrics.state == .idle)
    }

    @Test("Position ticks feed the playhead, with or without a session")
    func ticksFeedThePlayhead() async {
        let h = Harness()
        h.lyrics.setPanelOpen(true)
        h.engine.tick(7, playing: true)
        #expect(h.lyrics.playhead.time == 7)
        #expect(h.lyrics.playhead.isPlaying)
        await h.play("a")
        h.engine.tick(12.5, playing: true)
        #expect(h.lyrics.playhead.time == 12.5)
        h.engine.tick(13, playing: false)
        #expect(h.lyrics.playhead.time == 13)
        #expect(!h.lyrics.playhead.isPlaying)
    }

    @Test("A seek moves the playhead at once")
    func seekMovesThePlayhead() async {
        let h = Harness()
        h.lyrics.setPanelOpen(true)
        await h.play("a", duration: 200)
        h.service.seek(to: 42)
        #expect(h.lyrics.playhead.time == 42)
    }

    @Test("A seek while paused moves the playhead at once and leaves it paused")
    func seekWhilePausedMovesThePlayhead() async {
        let h = Harness()
        h.lyrics.setPanelOpen(true)
        await h.play("a", duration: 200)
        h.engine.tick(10, playing: true)
        h.service.togglePlayback()
        #expect(!h.player.isPlaying)
        h.service.seek(to: 77)
        #expect(h.lyrics.playhead.time == 77)
        #expect(!h.lyrics.playhead.isPlaying)
    }

    @Test("A closed panel or a hidden popup does not follow the player")
    func hiddenIgnoresTicks() async {
        let h = Harness()
        await h.play("a", duration: 200)
        h.engine.tick(20, playing: true)
        #expect(h.lyrics.playhead == .zero)

        h.lyrics.setPanelOpen(true)
        h.lyrics.setPopupVisible(false)
        h.engine.tick(30, playing: true)
        h.service.seek(to: 40)
        #expect(h.lyrics.playhead.time == 20)
    }

    @Test("Opening the panel, or showing the popup, reads the player's position at once")
    func openingSamplesThePlayer() async {
        let h = Harness()
        await h.play("a", duration: 200)
        h.engine.tick(55, playing: true)
        #expect(h.lyrics.playhead == .zero)

        h.lyrics.setPanelOpen(true)
        #expect(h.player.currentTime == 55)
        #expect(h.lyrics.playhead.time == 55)
        #expect(h.lyrics.playhead.isPlaying == h.player.isPlaying)
        #expect(h.lyrics.playhead.observedAt == h.clock.now)

        h.lyrics.setPopupVisible(false)
        h.engine.tick(90, playing: true)
        h.clock.advance(by: 12)
        h.lyrics.setPopupVisible(true)
        #expect(h.lyrics.playhead.time == 90)
        #expect(h.lyrics.playhead.observedAt == h.clock.now)
    }

    @Test("A length that shows up after the lookup is used for one more lookup")
    func lateDurationRefetches() async {
        let h = Harness()
        await h.backend.setStream(MusicSamples.stream(videoId: "a", duration: 0))
        h.provider.setResult(.plain("From a"), for: "a")
        h.lyrics.setPanelOpen(true)
        h.service.play(MusicSamples.track("a", title: "Song a", seconds: nil))
        await h.service.playTask?.value
        await h.service.radioTask?.value
        await h.lyrics.loadTask?.value
        #expect(h.provider.queries.first?.duration == nil)

        h.lyrics.trackChanged(h.player.nowPlaying, duration: 187.5)
        await h.lyrics.loadTask?.value
        #expect(h.provider.queries.map(\.duration) == [nil, 187.5])
    }

    @Test("A service built with no lyrics store uses the no-op provider, never the network")
    func defaultStoreIsOffline() {
        let service = MusicService(
            backend: FakeMusicBackend(signedIn: true),
            player: MusicPlayer(engine: FakePlaybackEngine()),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            refreshOnCreate: false
        )
        #expect(service.lyrics.provider is NoLyricsProvider)
    }

    @Test("Sign-out clears the lyrics, the open panel and the playhead")
    func signOutResets() async {
        let h = Harness()
        h.provider.setResult(.plain("From a"), for: "a")
        h.lyrics.setPanelOpen(true)
        await h.play("a")
        await h.lyrics.loadTask?.value
        #expect(h.lyrics.state == .loaded(.plain("From a")))
        h.service.signOut()
        #expect(h.lyrics.state == .idle)
        #expect(h.lyrics.track == nil)
        #expect(!h.lyrics.isPanelOpen)
        #expect(h.lyrics.playhead == .zero)
        await h.service.signOutTask?.value
    }

    @Test("Sign-out drops a fetch still in flight")
    func signOutDropsInFlight() async {
        let h = Harness()
        let gate = MusicTestGate()
        h.provider.setGate(gate, for: "a")
        h.provider.setResult(.plain("From a"), for: "a")
        h.lyrics.setPanelOpen(true)
        await h.play("a")
        #expect(await eventually { h.provider.videoIds == ["a"] })
        h.service.signOut()
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.lyrics.state == .idle)
        await h.service.signOutTask?.value
    }

    @Test("Adding another account clears the lyrics too")
    func accountSwapResets() async {
        let h = Harness()
        await h.backend.setSessionCookies([StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))])
        await h.service.refreshAuth()
        h.provider.setResult(.plain("From a"), for: "a")
        h.lyrics.setPanelOpen(true)
        await h.play("a")
        await h.lyrics.loadTask?.value
        #expect(h.lyrics.state == .loaded(.plain("From a")))

        h.service.useAnotherAccount()
        h.probe.completion?([StoredCookie(MusicSamples.cookie("__Secure-3PAPISID", domain: ".youtube.com"))])
        await h.service.addAccountTask?.value
        #expect(h.lyrics.state == .idle)
        #expect(h.lyrics.track == nil)
        #expect(!h.lyrics.isPanelOpen)
    }
}
