// DeciTests/Music/MusicServiceGenreLookaheadTests.swift
// When the service starts the genre lookup: only in Mixing, not with the network offline, once per song, artist and title only.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicService genre lookahead")
struct MusicServiceGenreLookaheadTests {
    private actor Calls {
        var read: [String] = [], asked: [String] = [], queries: [MusicSongFactsQuery] = []
        func read(_ id: String) { read.append(id) }
        func ask(_ id: String, _ query: MusicSongFactsQuery) { asked.append(id); queries.append(query) }
    }

    private struct Harness {
        let backend = FakeMusicBackend()
        let engine = FakePlaybackEngine()
        let calls = Calls()
        let service: MusicService
        let lookahead: MusicGenreLookahead
        let wantsMix: Bool

        init(beatMix: Bool = true, vocalGuard: Bool = true, online: Bool = true, mix: Bool = true) {
            wantsMix = mix
            lookahead = MusicGenreLookahead(
                readCache: { [calls] in await calls.read($0); return nil },
                lookup: { [calls] in await calls.ask($0, $1); return .notFound }
            )
            service = MusicService(
                backend: backend, player: MusicPlayer(engine: engine), presentSignIn: { _ in }, presentChannelPicker: { _, _ in },
                closeSignInWindow: {}, raiseSignInWindow: {},
                nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
                preferences: MusicPlaybackPreferences(
                    transitionMode: MusicPlaybackPreferences.migratedTransitionMode(mixShuffle: mix, beatMix: beatMix, crossfade: true),
                    crossfadeSeconds: 6, vocalGuard: vocalGuard
                ),
                queueRetryDelay: .seconds(60), connectivity: MusicConnectivity(isOnline: online),
                refreshOnCreate: false, genreLookahead: lookahead
            )
        }

        func run() async {
            for id in ["a", "b"] { await backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
            let tracks = ["a", "b"].map { MusicSamples.track($0, title: "Song \($0)") }
            await backend.setRadio(seed: "a", tracks: tracks, continuation: nil)
            if wantsMix { service.setShuffleMode(.flow) }
            service.play(tracks[0])
            while let t = service.playTask { await t.value; if service.playTask == t { break } }
            engine.emit(.playingChanged(true))
            service.startGenreLookahead()
            service.startGenreLookahead()
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("in Mixing each song is read from the cache and asked for exactly once, by artist and title")
    func onceEach() async {
        let h = Harness()
        await h.run()
        let (read, asked, queries) = (await h.calls.read, await h.calls.asked, await h.calls.queries)
        #expect(!asked.isEmpty && asked.count == Set(asked).count && Set(asked).isSubset(of: ["a", "b"]))
        #expect(read.count == Set(read).count)
        #expect(queries.allSatisfy { $0.title.hasPrefix("Song ") && $0.durationSeconds != nil })
    }

    @Test("out of Mixing nothing is read or sent; the vocal guard does not matter")
    func settingGate() async {
        for h in [Harness(mix: false), Harness(beatMix: false)] {
            await h.run()
            #expect(await h.calls.read.isEmpty)
            #expect(await h.calls.asked.isEmpty)
        }
        let unguarded = Harness(vocalGuard: false)
        await unguarded.run()
        #expect(await !unguarded.calls.asked.isEmpty)
    }

    @Test("offline nothing is asked")
    func offline() async {
        let h = Harness(online: false)
        await h.run()
        #expect(await h.calls.asked.isEmpty)
    }
}
