// DeciTests/Music/MusicSongDataStoreTests.swift
// The Song data panel's state: a held stream shows at once, any other song is resolved for its metadata only, a switch
// or a close drops the answer that is out, and the offline and failure states say so quietly.

import Foundation
import Testing
@testable import Deci

@MainActor
private final class SongDataWorld {
    var held: [String: ResolvedStream] = [:]
    var analyses: [String: MusicAnalysis] = [:]
    var offline = false
    var expired = 0
}

@MainActor
private struct SongDataHarness {
    let backend = FakeMusicBackend()
    let store: MusicSongDataStore
    let world = SongDataWorld()

    init() {
        store = MusicSongDataStore(backend: backend)
        let world = self.world
        store.sources = MusicSongDataStore.Sources(
            heldStream: { world.held[$0] },
            analysis: { world.analyses[$0] },
            isOffline: { world.offline }
        )
        store.onSessionExpired = { world.expired += 1 }
    }

    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func settled() async {
        _ = await until { store.stream != .loading }
    }

    func letLateWorkLand() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    func resolved() async -> [String] { await backend.resolvedIDs }

    func row(_ id: String, source: MusicAnalysis.Source = .download) -> MusicAnalysis {
        MusicAnalysis(
            videoId: id, version: 1, format: .init(codec: "opus", itag: 251, durationMs: 200_000), analyzedAt: Date(),
            source: source, silenceStart: 0, silenceEnd: 200, introEnd: 10, outroStart: 190, integratedLUFS: -14,
            samplePeakDb: -1, introLUFS: nil, outroLUFS: nil, energy: [], youtubeLoudnessDb: nil,
            youtubePerceptualLoudnessDb: nil
        )
    }
}

@MainActor
@Suite("MusicSongDataStore")
struct MusicSongDataStoreTests {
    private func song(_ id: String) -> MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    // MARK: - Opening

    @Test("a closed store has no song and no panel")
    func startsClosed() {
        let h = SongDataHarness()
        #expect(h.store.track == nil)
        #expect(h.store.isOpen == false)
    }

    @Test("opening for a song with a held stream shows it at once and asks the backend for nothing")
    func heldStream() async {
        let h = SongDataHarness()
        let held = MusicSamples.stream(videoId: "a")
        h.world.held["a"] = held
        h.store.show(song("a"))
        #expect(h.store.isOpen)
        #expect(h.store.track?.videoId == "a")
        #expect(h.store.stream == .loaded(held))
        await h.letLateWorkLand()
        #expect(await h.resolved().isEmpty)
    }

    @Test("a song with no held stream is resolved once, for its metadata, and the answer is shown")
    func resolvesWhenNotHeld() async {
        let h = SongDataHarness()
        let answer = ResolvedStream(
            videoId: "a", url: URL(string: "https://example.com/a")!, itag: 251, durationSeconds: 200,
            expiresAt: .distantFuture, playbackTrackingURL: nil, httpHeaders: [:], audioCodec: "opus", bitrate: 130_000
        )
        await h.backend.setStream(answer)
        h.store.show(song("a"))
        #expect(h.store.stream == .loading)
        await h.settled()
        #expect(h.store.stream == .loaded(answer))
        #expect(await h.resolved() == ["a"])
    }

    @Test("the stored analysis row is read for the song and shown")
    func readsAnalysis() async {
        let h = SongDataHarness()
        h.world.analyses["a"] = h.row("a")
        h.store.show(song("a"))
        #expect(await h.until { h.store.analysis != nil })
        #expect(h.store.analysis?.videoId == "a")
    }

    @Test("a song with no analysis row has none")
    func noAnalysis() async {
        let h = SongDataHarness()
        h.store.show(song("a"))
        await h.settled()
        await h.letLateWorkLand()
        #expect(h.store.analysis == nil)
    }

    @Test("a blank video id resolves nothing and says Unavailable")
    func blankId() async {
        let h = SongDataHarness()
        h.store.show(song("  "))
        #expect(h.store.stream == .unavailable)
        #expect(await h.resolved().isEmpty)
    }

    // MARK: - Switching and closing

    @Test("opening for another song swaps the content and drops the first answer, which lands late")
    func switchDropsLateAnswer() async {
        let h = SongDataHarness()
        let gate = MusicTestGate()
        await h.backend.setResolveGate("a", gate)
        let b = MusicSamples.stream(videoId: "b")
        await h.backend.setStream(b)
        h.store.show(song("a"))
        h.store.show(song("b"))
        await h.settled()
        #expect(h.store.track?.videoId == "b")
        #expect(h.store.stream == .loaded(b))
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.track?.videoId == "b")
        #expect(h.store.stream == .loaded(b))
    }

    @Test("a late analysis row for the song left behind is dropped")
    func switchDropsLateAnalysis() async {
        let h = SongDataHarness()
        h.world.analyses["b"] = h.row("b")
        h.store.show(song("a"))
        h.store.show(song("b"))
        #expect(await h.until { h.store.analysis != nil })
        await h.letLateWorkLand()
        #expect(h.store.analysis?.videoId == "b")
    }

    @Test("a switch clears the old song's analysis at once")
    func switchClearsAnalysis() async {
        let h = SongDataHarness()
        h.world.analyses["a"] = h.row("a")
        h.store.show(song("a"))
        #expect(await h.until { h.store.analysis != nil })
        h.store.show(song("b"))
        #expect(h.store.analysis == nil)
    }

    @Test("closing returns to idle and a late answer lands nowhere")
    func closeDropsLateAnswer() async {
        let h = SongDataHarness()
        let gate = MusicTestGate()
        await h.backend.setResolveGate("a", gate)
        h.store.show(song("a"))
        h.store.close()
        #expect(h.store.isOpen == false)
        #expect(h.store.track == nil)
        #expect(h.store.analysis == nil)
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.isOpen == false)
        #expect(h.store.stream == .loading)
    }

    @Test("close cancels the work that is out")
    func closeCancels() async {
        let h = SongDataHarness()
        let gate = MusicTestGate()
        await h.backend.setResolveGate("a", gate)
        h.store.show(song("a"))
        #expect(await h.until { await h.resolved() == ["a"] })
        h.store.close()
        h.store.show(song("a"))
        await gate.open()
        await h.settled()
        // The second open is its own run: it lands, the first one did not land twice.
        #expect(h.store.stream != .loading)
    }

    @Test("opening for the same song again asks again from the start")
    func reopen() async {
        let h = SongDataHarness()
        h.store.show(song("a"))
        await h.settled()
        h.store.close()
        h.store.show(song("a"))
        await h.settled()
        #expect(await h.resolved() == ["a", "a"])
    }

    // MARK: - Offline and failure

    @Test("offline at open says Offline without asking")
    func offlineAtOpen() async {
        let h = SongDataHarness()
        h.world.offline = true
        h.store.show(song("a"))
        #expect(h.store.stream == .offline)
        #expect(await h.resolved().isEmpty)
    }

    @Test("a held stream still shows offline")
    func heldOffline() {
        let h = SongDataHarness()
        h.world.offline = true
        let held = MusicSamples.stream(videoId: "a")
        h.world.held["a"] = held
        h.store.show(song("a"))
        #expect(h.store.stream == .loaded(held))
    }

    @Test("the network failing mid-request says Offline")
    func networkError() async {
        let h = SongDataHarness()
        await h.backend.setResolveError("a", URLError(.notConnectedToInternet))
        h.store.show(song("a"))
        await h.settled()
        #expect(h.store.stream == .offline)
    }

    @Test("any other failure says Unavailable")
    func otherError() async {
        let h = SongDataHarness()
        await h.backend.setResolveError("a", MusicError.parse("no"))
        h.store.show(song("a"))
        await h.settled()
        #expect(h.store.stream == .unavailable)
    }

    @Test("a signed-out answer says Unavailable and tells the service the session is gone")
    func signedOut() async {
        let h = SongDataHarness()
        await h.backend.setResolveError("a", MusicError.signedOut)
        h.store.show(song("a"))
        await h.settled()
        #expect(h.store.stream == .unavailable)
        #expect(h.world.expired == 1)
    }

    @Test("the network returning asks once more for a song that said Offline")
    func connectionReturned() async {
        let h = SongDataHarness()
        h.world.offline = true
        h.store.show(song("a"))
        #expect(h.store.stream == .offline)
        h.world.offline = false
        h.store.connectionReturned()
        await h.settled()
        #expect(h.store.stream != .offline)
        #expect(await h.resolved() == ["a"])
    }

    @Test("the network returning does nothing for a closed panel or a song that loaded")
    func connectionReturnedIdle() async {
        let h = SongDataHarness()
        h.store.connectionReturned()
        #expect(h.store.isOpen == false)
        h.store.show(song("a"))
        await h.settled()
        h.store.connectionReturned()
        await h.letLateWorkLand()
        #expect(await h.resolved() == ["a"])
    }

    // MARK: - Reset

    @Test("a reset, on sign-out or an account swap, closes the panel and drops the answer that is out")
    func reset() async {
        let h = SongDataHarness()
        let gate = MusicTestGate()
        await h.backend.setResolveGate("a", gate)
        h.store.show(song("a"))
        h.store.reset()
        #expect(h.store.isOpen == false)
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.isOpen == false)
    }

    @Test("the subtitle is the song's title while open and nil while closed")
    func subtitle() {
        let h = SongDataHarness()
        #expect(h.store.subtitle == nil)
        h.store.show(song("a"))
        #expect(h.store.subtitle == "Song a")
        h.store.show(MusicSamples.track("b", title: "  "))
        #expect(h.store.subtitle == nil)
        h.store.close()
        #expect(h.store.subtitle == nil)
    }
}
