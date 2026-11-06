// DeciTests/Music/AVPlaybackEngineGaplessTests.swift
// The engine's two decks: the standby deck's item is built the same way as the active one's (its own tap mix), it never
// disturbs the active deck, it is thrown away on any cancel, and a real active item that ends hands over to a real
// preloaded one with an "advanced" event instead of an "ended" one. Most items point at files that do not exist, so
// nothing is fetched; the one real playback test is muted (the fallback level) and uses short tone files.

import Foundation
import AVFoundation
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine decks")
struct AVPlaybackEngineGaplessTests {
    private func stream(_ name: String, duration: Double? = 200, url: URL? = nil) -> ResolvedStream {
        ResolvedStream(
            videoId: name,
            url: url ?? URL(fileURLWithPath: "/nonexistent/deci-tests/\(name).m4a"),
            itag: 140,
            durationSeconds: duration,
            expiresAt: .distantFuture,
            playbackTrackingURL: nil,
            httpHeaders: [:]
        )
    }

    private final class Seen {
        var roles: [MusicTapDeck.Role?] = []
        var assets: [URL?] = []
    }

    // MARK: - Preload bookkeeping

    @Test("preload records the track, cancel and a cold load drop it")
    func preloadStateFollowsTheCalls() {
        let engine = AVPlaybackEngine()
        #expect(engine.preloadedVideoId == nil)

        engine.preload(stream("next"))
        #expect(engine.preloadedVideoId == "next")
        engine.cancelPreload()
        #expect(engine.preloadedVideoId == nil)

        engine.preload(stream("next"))
        engine.load(stream("cold"), startAt: 0, autoplay: false)
        #expect(engine.preloadedVideoId == nil, "a load of another track makes the preload stale")

        engine.preload(stream("next"))
        engine.unload()
        #expect(engine.preloadedVideoId == nil)
    }

    @Test("a second preload replaces the first")
    func secondPreloadReplaces() {
        let engine = AVPlaybackEngine()
        engine.preload(stream("one"))
        engine.preload(stream("two"))
        #expect(engine.preloadedVideoId == "two")
    }

    @Test("the standby's mix is built by the same builder, for its own asset, on the standby deck's handle")
    func standbyUsesTheSameMixPath() async {
        let seen = Seen()
        let chain = MusicDSPChain(sampleRate: 48_000)
        let engine = AVPlaybackEngine(chain: chain, makeMix: { asset, _, _ in
            seen.roles.append(MusicAudioTap.currentDeck?.role)
            seen.assets.append((asset as? AVURLAsset)?.url)
            return AVMutableAudioMix()
        })
        engine.load(stream("active"), startAt: 0, autoplay: false)
        engine.preload(stream("standby"))
        let built = await waitUntil(timeout: .seconds(10)) { seen.roles.count == 2 }
        #expect(built)
        #expect(seen.roles.contains(.active))
        #expect(seen.roles.contains(.standby))
        #expect(seen.assets.contains(URL(fileURLWithPath: "/nonexistent/deci-tests/standby.m4a")))
    }

    @Test("preloading never touches the active deck's item")
    func preloadLeavesTheActiveDeckAlone() async {
        let engine = AVPlaybackEngine()
        engine.load(stream("active"), startAt: 0, autoplay: false)
        let item = engine.currentItem
        #expect(item != nil)
        engine.preload(stream("standby"))
        #expect(engine.currentItem === item)
        engine.cancelPreload()
        #expect(engine.currentItem === item)
    }

    @Test("the standby waits without automatic stall waiting, and the active deck keeps it")
    func stallWaitingFlags() async {
        let engine = AVPlaybackEngine()
        engine.load(stream("active"), startAt: 0, autoplay: false)
        engine.preload(stream("standby"))
        #expect(engine.avPlayer.automaticallyWaitsToMinimizeStalling)
        #expect(engine.standbyAvPlayer.automaticallyWaitsToMinimizeStalling == false)
    }

    // MARK: - Output and level reach both decks

    @Test("the output device is set on both decks, including a multi-output aggregate")
    func outputDeviceReachesBoth() {
        let engine = AVPlaybackEngine()
        engine.setOutputDevice(uid: "aggregate-uid")
        #expect(engine.avPlayer.audioOutputDeviceUniqueID == "aggregate-uid")
        #expect(engine.standbyAvPlayer.audioOutputDeviceUniqueID == "aggregate-uid")

        engine.setOutputDevice(uid: nil)
        #expect(engine.avPlayer.audioOutputDeviceUniqueID == nil)
        #expect(engine.standbyAvPlayer.audioOutputDeviceUniqueID == nil)
    }

    @Test("the fallback volume and mute reach both decks")
    func fallbackLevelReachesBoth() {
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0.4, muted: true)
        for player in [engine.avPlayer, engine.standbyAvPlayer] {
            #expect(player.volume == 0.4)
            #expect(player.isMuted)
        }
    }

    @Test("a standby set up after the level and device were chosen starts with them")
    func laterStandbyInherits() {
        let engine = AVPlaybackEngine()
        engine.setOutputDevice(uid: "device")
        engine.setFallbackLevel(volume: 0.25, muted: false)
        engine.load(stream("one"), startAt: 0, autoplay: false)
        engine.preload(stream("two"))
        #expect(engine.standbyAvPlayer.audioOutputDeviceUniqueID == "device")
        #expect(engine.standbyAvPlayer.volume == 0.25)
    }

    // MARK: - Real playback

    private func writeTone(_ name: String, seconds: Double) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/gapless", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).m4a")
        let rate = 44_100.0
        let frames = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(0.2 * sin(2 * Double.pi * 440 * Double(frame) / rate))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        try await ToneFile.write(interleavedStereo: samples, sampleRate: rate, to: url)
        return url
    }

    @Test("a real item that ends hands over to the preloaded one: advanced, never ended")
    func realGaplessAdvance() async throws {
        let first = try await writeTone("a", seconds: 2)
        let second = try await writeTone("b", seconds: 2)
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0, muted: true)

        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }

        engine.load(stream("a", duration: 2, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("b", duration: 2, url: second))

        let advanced = await waitUntil(timeout: .seconds(20)) {
            events.contains(.advanced(videoId: "b"))
        }
        #expect(advanced, "events: \(events)")
        #expect(!events.contains(.ended), "the first item's end is the hand-over, not an end of playback")
        #expect(engine.preloadedVideoId == nil)
        #expect((engine.currentItem?.asset as? AVURLAsset)?.url == second)
        #expect(engine.avPlayer.automaticallyWaitsToMinimizeStalling, "the new active deck waits for stalls again")

        let ended = await waitUntil(timeout: .seconds(20)) { events.contains(.ended) }
        #expect(ended, "the second item ends the playback")
    }

    @Test("a pause on the active deck holds the hand-over until it plays again")
    func pauseHoldsTheHandOver() async throws {
        let first = try await writeTone("c", seconds: 3)
        let second = try await writeTone("d", seconds: 2)
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0, muted: true)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }

        engine.load(stream("c", duration: 3, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("d", duration: 2, url: second))
        let ready = await waitUntil(timeout: .seconds(20)) { engine.position > 0.3 }
        #expect(ready)
        engine.pause()
        try? await Task.sleep(for: .seconds(4))
        #expect(!events.contains(.advanced(videoId: "d")), "a paused track does not hand over")
        #expect(!events.contains(.ended))

        engine.play()
        let advanced = await waitUntil(timeout: .seconds(20)) { events.contains(.advanced(videoId: "d")) }
        #expect(advanced)
    }

    @Test("without a preload the end of the item is reported as ended")
    func endedWithoutPreload() async throws {
        let only = try await writeTone("e", seconds: 1)
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0, muted: true)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("e", duration: 1, url: only), startAt: 0, autoplay: true)
        let ended = await waitUntil(timeout: .seconds(20)) { events.contains(.ended) }
        #expect(ended)
    }

    @Test("a cancelled preload leaves the end of the item as ended")
    func cancelledPreloadEndsNormally() async throws {
        let first = try await writeTone("f", seconds: 1)
        let second = try await writeTone("g", seconds: 1)
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0, muted: true)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("f", duration: 1, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("g", duration: 1, url: second))
        engine.cancelPreload()
        let ended = await waitUntil(timeout: .seconds(20)) { events.contains(.ended) }
        #expect(ended)
        #expect(!events.contains(.advanced(videoId: "g")))
    }
}
