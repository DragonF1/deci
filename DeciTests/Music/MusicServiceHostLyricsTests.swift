// DeciTests/Music/MusicServiceHostLyricsTests.swift
// The popup stays mounted while hidden, so MenuBarPopupView tells MusicServiceHost, and the host tells the lyrics
// store: a hidden popup fetches and animates nothing. The flag is remembered for a service built later.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicServiceHost popup visibility and lyrics")
struct MusicServiceHostLyricsTests {

    private func makeHost(
        provider: FakeLyricsProvider = FakeLyricsProvider(),
        backend: FakeMusicBackend = FakeMusicBackend()
    ) -> MusicServiceHost {
        MusicServiceHost(makeService: {
            MusicService(
                backend: backend,
                player: MusicPlayer(engine: FakePlaybackEngine()),
                presentSignIn: { _ in },
                nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
                lyrics: MusicLyricsStore(provider: provider, sleep: { _ in }),
                refreshOnCreate: false
            )
        })
    }

    @Test("The popup is visible by default, for the host and for a new store")
    func defaults() throws {
        let host = makeHost()
        #expect(host.isPopupVisible)
        host.loadIfNeeded()
        #expect(try #require(host.service).lyrics.isPopupVisible)
    }

    @Test("isPopupVisible is forwarded to the lyrics store, hidden then shown")
    func forwardsToTheStore() throws {
        let host = makeHost()
        host.loadIfNeeded()
        let lyrics = try #require(host.service).lyrics

        host.isPopupVisible = false
        #expect(!lyrics.isPopupVisible)
        host.isPopupVisible = true
        #expect(lyrics.isPopupVisible)
    }

    @Test("A flag set before the service exists is replayed to the new store")
    func replayedOnCreate() throws {
        let host = makeHost()
        host.isPopupVisible = false
        #expect(host.service == nil)
        host.loadIfNeeded()
        #expect(try #require(host.service).lyrics.isPopupVisible == false)
    }

    @Test("Setting the flag with no service yet is harmless, and the last value wins")
    func lastValueWinsBeforeCreate() throws {
        let host = makeHost()
        host.isPopupVisible = false
        host.isPopupVisible = true
        host.isPopupVisible = false
        host.loadIfNeeded()
        #expect(try #require(host.service).lyrics.isPopupVisible == false)

        host.isPopupVisible = true
        #expect(try #require(host.service).lyrics.isPopupVisible)
    }

    @Test("A hidden popup keeps an open lyrics panel from fetching, and showing it fetches")
    func hiddenPopupGatesTheFetch() async throws {
        let provider = FakeLyricsProvider()
        provider.setResult(.plain("From a"), for: "a")
        let host = makeHost(provider: provider)
        host.isPopupVisible = false
        host.loadIfNeeded()
        let lyrics = try #require(host.service).lyrics
        lyrics.setPanelOpen(true)
        lyrics.trackChanged(MusicSamples.track("a"), duration: 200)
        for _ in 0..<20 { await Task.yield() }
        #expect(provider.queries.isEmpty)

        host.isPopupVisible = true
        await lyrics.loadTask?.value
        #expect(provider.videoIds == ["a"])
        #expect(lyrics.state == .loaded(.plain("From a")))
    }

    @Test("Hiding the popup mid-fetch cancels it")
    func hidingCancels() async throws {
        let provider = FakeLyricsProvider()
        let gate = MusicTestGate()
        provider.setGate(gate, for: "a")
        let host = makeHost(provider: provider)
        host.loadIfNeeded()
        let lyrics = try #require(host.service).lyrics
        lyrics.setPanelOpen(true)
        lyrics.trackChanged(MusicSamples.track("a"), duration: 200)
        #expect(await eventually { provider.videoIds == ["a"] })

        host.isPopupVisible = false
        #expect(lyrics.state == .idle)
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        #expect(lyrics.state == .idle)
    }

    // MARK: - Related songs

    @Test("The Related store is told the popup's visibility too, hidden then shown")
    func forwardsToTheRelatedStore() throws {
        let host = makeHost()
        host.loadIfNeeded()
        let related = try #require(host.service).related
        #expect(related.isPopupVisible)

        host.isPopupVisible = false
        #expect(related.isPopupVisible == false)
        host.isPopupVisible = true
        #expect(related.isPopupVisible)
    }

    @Test("A flag set before the service exists is replayed to the new Related store")
    func replayedToRelatedOnCreate() throws {
        let host = makeHost()
        host.isPopupVisible = false
        host.loadIfNeeded()
        #expect(try #require(host.service).related.isPopupVisible == false)
    }

    @Test("A hidden popup keeps an open Related panel from asking, and showing it asks once")
    func hiddenPopupGatesRelated() async throws {
        let backend = FakeMusicBackend()
        await backend.setRelated(videoId: "a", [MusicSamples.track("ra")])
        await backend.setRelated(videoId: "b", [MusicSamples.track("rb")])
        let host = makeHost(backend: backend)
        host.loadIfNeeded()
        let related = try #require(host.service).related
        related.follow(MusicSamples.track("a"))
        #expect(await eventually { related.state != .loading })

        host.isPopupVisible = false
        related.nowPlayingChanged(MusicSamples.track("b"))
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await backend.relatedCalls == ["a"])

        host.isPopupVisible = true
        #expect(await eventually { related.state != .loading })
        #expect(await backend.relatedCalls == ["a", "b"])
    }
}
