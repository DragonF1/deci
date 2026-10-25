// DeciTests/Music/MusicRelatedServiceTests.swift
// How MusicService feeds the related songs store: the playing song while the panel follows the player, nothing while it
// is closed or pinned elsewhere, and the resets on sign-out and a session that expires. Fake backend, fake engine.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct RelatedServiceHarness {
    let backend = FakeMusicBackend(signedIn: true)
    let engine = FakePlaybackEngine()
    let service: MusicService

    init() {
        service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: engine),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            queueRetryDelay: .seconds(60),
            refreshOnCreate: false
        )
    }

    /// A signed-in service, the way the app has it once the session check has answered.
    static func signedIn() async -> RelatedServiceHarness {
        let h = RelatedServiceHarness()
        await h.service.refreshAuth()
        return h
    }

    func play(_ id: String) async {
        service.play(MusicSamples.track(id, title: "Song \(id)"))
        await service.playTask?.value
        await service.radioTask?.value
    }

    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<600 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func letLateWorkLand() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    func script(_ seed: String, _ ids: String...) async {
        await backend.setRelated(videoId: seed, ids.map { MusicSamples.track($0, title: "Song \($0)") })
    }

    func relatedCalls() async -> [String] { await backend.relatedCalls }
}

@MainActor
@Suite("MusicService related songs wiring")
struct MusicRelatedServiceTests {

    @Test("The service owns a related store, and it starts closed")
    func ownsAStore() async {
        let h = await RelatedServiceHarness.signedIn()
        #expect(h.service.related.state == .idle)
    }

    @Test("Nothing is asked for any song while the panel is closed")
    func closedPanelAsksNothing() async {
        let h = await RelatedServiceHarness.signedIn()
        await h.play("a")
        await h.play("b")
        await h.letLateWorkLand()
        #expect(await h.relatedCalls().isEmpty)
        #expect(h.service.related.state == .idle)
    }

    @Test("A panel that follows the player moves to the next song when the player does")
    func followsThePlayer() async {
        let h = await RelatedServiceHarness.signedIn()
        await h.script("a", "ra")
        await h.script("b", "rb")
        await h.play("a")
        h.service.related.follow(h.service.player.nowPlaying)
        _ = await h.until { h.service.related.state == .loaded([MusicSamples.track("ra", title: "Song ra")]) }

        await h.play("b")
        let moved = await h.until { h.service.related.seed?.videoId == "b" && h.service.related.state != .loading }

        #expect(moved)
        #expect(h.service.related.subline == "From Song b")
        #expect(await h.relatedCalls() == ["a", "b"])
    }

    @Test("Stopping the player leaves a following panel with no seed")
    func stopLeavesNoSeed() async {
        let h = await RelatedServiceHarness.signedIn()
        await h.play("a")
        h.service.related.follow(h.service.player.nowPlaying)

        h.service.player.stop()

        #expect(h.service.related.state == .noSeed)
    }

    @Test("A seed a menu pinned stays while other songs play")
    func pinnedStays() async {
        let h = await RelatedServiceHarness.signedIn()
        await h.script("x", "rx")
        h.service.related.show(MusicSamples.track("x", title: "Song x"))
        _ = await h.until { h.service.related.state != .loading }

        await h.play("a")
        await h.letLateWorkLand()

        #expect(h.service.related.seed?.videoId == "x")
        #expect(await h.relatedCalls() == ["x"])
    }

    @Test("Signing out closes the panel's store and forgets what it had")
    func signOutForgets() async {
        let h = await RelatedServiceHarness.signedIn()
        await h.script("a", "ra")
        h.service.related.show(MusicSamples.track("a", title: "Song a"))
        _ = await h.until { h.service.related.state != .loading }

        h.service.signOut()

        #expect(h.service.related.state == .idle)
        #expect(h.service.related.seed == nil)
        let askedBefore = await h.backend.relatedCalls.count

        // Signed out, the panel can be opened again, but it asks for nothing: it says why (see `holdsOffline`).
        h.service.related.show(MusicSamples.track("a", title: "Song a"))
        #expect(h.service.related.state == .failed(MusicRelatedStore.signedOutMessage))
        #expect(await h.backend.relatedCalls.count == askedBefore)
    }

    @Test("A call that finds the session gone signs the service out")
    func sessionGoneSignsOut() async {
        let h = await RelatedServiceHarness.signedIn()
        await h.backend.setRelatedError(videoId: "a", MusicError.signedOut)

        h.service.related.show(MusicSamples.track("a", title: "Song a"))
        let out = await h.until { h.service.authState == .signedOut }

        #expect(out)
        #expect(h.service.related.state == .idle)
    }
}
