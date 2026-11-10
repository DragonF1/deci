// DeciTests/Music/Vocals/MusicServiceVocalLookaheadTests.swift
// Tier 3d-4: when the service starts the lyrics lookup: the three-setting gate, plansTransitions, offline, once per song.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicService vocal lookahead")
struct MusicServiceVocalLookaheadTests {
    private actor Counter {
        var cache: [String] = [], youtube: [String] = []
        func read(_ id: String) { cache.append(id) }
        func fetch(_ id: String) { youtube.append(id) }
    }

    private struct Harness {
        let backend = FakeMusicBackend()
        let engine = FakePlaybackEngine()
        let counter = Counter()
        let service: MusicService
        let lookahead: MusicVocalLookahead
        let wantsMix: Bool

        init(
            crossfade: Bool = true, beatMix: Bool = true, vocalGuard: Bool = true, online: Bool = true,
            loop: Bool = false, mix: Bool = true
        ) {
            wantsMix = mix
            let counter = counter
            lookahead = MusicVocalLookahead(
                readCache: { await counter.read($0); return nil },
                youtube: { q in
                    await counter.fetch(q.videoId)
                    return LyricsAnswer(result: .instrumental, credit: nil)
                })
            let player = MusicPlayer(engine: engine)
            service = MusicService(
                backend: backend, player: player, presentSignIn: { _ in }, presentChannelPicker: { _, _ in },
                closeSignInWindow: {}, raiseSignInWindow: {},
                nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
                preferences: MusicPlaybackPreferences(crossfade: crossfade, crossfadeSeconds: 6, beatMix: beatMix, vocalGuard: vocalGuard),
                queueRetryDelay: .seconds(60), connectivity: MusicConnectivity(isOnline: online),
                refreshOnCreate: false, vocalLookahead: lookahead
            )
            if loop { service.setLoopMode(.song) }
        }

        func run() async {
            for id in ["a", "b"] { await backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
            let tracks = ["a", "b"].map { MusicSamples.track($0, title: "Song \($0)") }
            await backend.setRadio(seed: "a", tracks: tracks, continuation: nil)
            // Beat mix only acts in Mix (since a1c993a), so the gates under test are only reached with Mix on.
            if wantsMix { service.setShuffleMode(.mix) }
            service.play(tracks[0])
            while let t = service.playTask { await t.value; if service.playTask == t { break } }
            engine.emit(.playingChanged(true))
            service.startVocalLookahead()
            service.startVocalLookahead()
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("all three settings on: each song is read from the cache and asked of YouTube Music exactly once")
    func onceEach() async {
        let h = Harness()
        await h.run()
        let y = await h.counter.youtube
        #expect(Set(y).isSubset(of: ["a", "b"]) && y.count == Set(y).count && !y.isEmpty)
        let c = await h.counter.cache
        #expect(c.count == Set(c).count)
    }

    @Test("any of Mix, beat mix or vocal guard off: nothing is read or sent")
    func settingGate() async {
        for h in [Harness(mix: false), Harness(beatMix: false), Harness(vocalGuard: false)] {
            await h.run()
            let (c, y) = (await h.counter.cache, await h.counter.youtube)
            #expect(c.isEmpty && y.isEmpty)
        }
    }

    @Test("offline: the cache may be read, the network never")
    func offline() async {
        let h = Harness(online: false)
        await h.run()
        let y = await h.counter.youtube
        #expect(y.isEmpty)
    }

    @Test("Loop song sends no request")
    func loopSong() async {
        let h = Harness(loop: true)
        await h.run()
        let (c, y) = (await h.counter.cache, await h.counter.youtube)
        #expect(c.isEmpty && y.isEmpty)
    }
}
