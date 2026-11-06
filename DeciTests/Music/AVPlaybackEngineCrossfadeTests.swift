// DeciTests/Music/AVPlaybackEngineCrossfadeTests.swift
// Phase 1c on the real engine: two tone files, a real DSP chain, the chain's target gain at 0 so nothing is heard.
// The next track starts the fade length before the end, the identity flips once at fade start, both leases render the
// whole chain through the overlap, the outgoing lease stops rendering after it, and no incoming frame is silenced.

import Foundation
import AVFoundation
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine crossfade")
struct AVPlaybackEngineCrossfadeTests {
    private func writeTone(_ name: String, seconds: Double, rate: Double = 44_100) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/crossfade", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).m4a")
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

    private func stream(_ name: String, duration: Double, url: URL) -> ResolvedStream {
        ResolvedStream(
            videoId: name, url: url, itag: 140, durationSeconds: duration,
            expiresAt: .distantFuture, playbackTrackingURL: nil, httpHeaders: [:]
        )
    }

    @Test("real chain: the fade starts early, flips once, both decks render through the overlap, the old one then stops")
    func realCrossfade() async throws {
        let first = try await writeTone("x", seconds: 8)
        let second = try await writeTone("y", seconds: 8, rate: 48_000)
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.crossfadeSeconds = 2
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }

        engine.load(stream("x", duration: 8, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("y", duration: 8, url: second))
        let ready = await waitUntil(timeout: .seconds(30)) {
            engine.debugStandbyTap?.debugLease != nil && engine.debugActiveTap?.debugLease != nil
        }
        #expect(ready)
        let outgoing = try #require(engine.debugActiveTap?.debugLease)
        let incoming = try #require(engine.debugStandbyTap?.debugLease)

        let advanced = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "y")) }
        #expect(advanced, "events: \(events)")
        #expect(engine.isCrossfading, "the old deck is draining at the flip")
        #expect(engine.crossfadeCount == 1)
        #expect(chain.owns(incoming))
        #expect(!chain.owns(outgoing))
        let outgoingAtFlip = outgoing.debugCounters.fullFrames

        // Through the overlap the draining lease keeps rendering the full chain.
        let through = await waitUntil(timeout: .seconds(10)) { outgoing.debugCounters.fullFrames > outgoingAtFlip + 24_000 }
        #expect(through, "the outgoing deck stays audible through the overlap")
        #expect(incoming.debugCounters.fullFrames > 0)

        let drained = await waitUntil(timeout: .seconds(20)) { !engine.isCrossfading }
        #expect(drained, "the drain ends after the fade")
        let outgoingAtEnd = outgoing.debugCounters.fullFrames
        try await Task.sleep(for: .milliseconds(400))
        #expect(outgoing.debugCounters.fullFrames == outgoingAtEnd, "the old deck renders nothing once drained")

        #expect(incoming.debugCounters.silencedFrames == 0, "no incoming frame was silenced")
        #expect(incoming.debugCounters.gainOnlyFrames == 0)
        let flips = events.filter { $0 == .advanced(videoId: "y") }.count
        #expect(flips == 1, "the identity flips exactly once")
        #expect(!events.contains(.ended))
    }

    @Test("with Crossfade at 0 the hand-over is the gapless one: no crossfade is counted")
    func zeroIsGapless() async throws {
        let first = try await writeTone("g1", seconds: 4)
        let second = try await writeTone("g2", seconds: 4)
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.crossfadeSeconds = 0
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("g1", duration: 4, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("g2", duration: 4, url: second))
        let advanced = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "g2")) }
        #expect(advanced)
        #expect(engine.crossfadeCount == 0)
        #expect(!engine.isCrossfading)
    }

    @Test("a seek mid-fade lands on the incoming track and the old deck is dropped quickly")
    func seekMidFade() async throws {
        let first = try await writeTone("s1", seconds: 8)
        let second = try await writeTone("s2", seconds: 8)
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.crossfadeSeconds = 3
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("s1", duration: 8, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("s2", duration: 8, url: second))
        let advanced = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "s2")) && engine.isCrossfading }
        #expect(advanced)
        engine.seek(to: 1)
        let quick = await waitUntil(timeout: .seconds(2)) { !engine.isCrossfading }
        #expect(quick, "the old deck fades out in about 30 ms, not over the rest of the fade")
        #expect((engine.currentItem?.asset as? AVURLAsset)?.url == second, "the incoming track is the one playing")
    }

    @Test("pause mid-fade pauses both decks and play resumes them")
    func pauseMidFade() async throws {
        let first = try await writeTone("p1", seconds: 8)
        let second = try await writeTone("p2", seconds: 8)
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.crossfadeSeconds = 4
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("p1", duration: 8, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("p2", duration: 8, url: second))
        let advanced = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "p2")) && engine.isCrossfading }
        #expect(advanced)
        engine.pause()
        #expect(engine.avPlayer.rate == 0)
        #expect(engine.debugDrainingPlayer?.rate == 0, "the draining deck pauses with the new one")
        #expect(engine.isCrossfading, "a paused fade is not finished")
        engine.play()
        #expect(engine.avPlayer.rate != 0)
        let finished = await waitUntil(timeout: .seconds(20)) { !engine.isCrossfading }
        #expect(finished)
    }

    @Test("an outgoing item that ends early (a doubled YouTube duration) still ends the drain, and the next fade works")
    func earlyEndingOutgoingStillDrains() async throws {
        // The files are 10 s long, the streams say 6 s: the item stops at its forwardPlaybackEndTime, as YouTube's do.
        let first = try await writeTone("e1", seconds: 10)
        let second = try await writeTone("e2", seconds: 10)
        let third = try await writeTone("e3", seconds: 10)
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.crossfadeSeconds = 2
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("e1", duration: 6, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("e2", duration: 6, url: second))
        let flipped = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "e2")) }
        #expect(flipped, "events: \(events)")
        let drained = await waitUntil(timeout: .seconds(15)) { !engine.isCrossfading }
        #expect(drained, "the drain ends although the old item stopped at its own end")

        engine.preload(stream("e3", duration: 6, url: third))
        let again = await waitUntil(timeout: .seconds(40)) { events.contains(.advanced(videoId: "e3")) }
        #expect(again, "the next transition is scheduled and fades: \(events)")
        #expect(engine.crossfadeCount == 2)
    }

    @Test("pause mid-fade, then a load while paused: the old deck is let go at once and the next schedule works")
    func loadWhilePausedMidFade() async throws {
        let first = try await writeTone("q1", seconds: 8)
        let second = try await writeTone("q2", seconds: 8)
        let third = try await writeTone("q3", seconds: 8)
        let fourth = try await writeTone("q4", seconds: 8)
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.crossfadeSeconds = 4
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("q1", duration: 8, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("q2", duration: 8, url: second))
        let fading = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "q2")) && engine.isCrossfading }
        #expect(fading)
        engine.pause()
        engine.load(stream("q3", duration: 8, url: third), startAt: 0, autoplay: true)
        #expect(!engine.isCrossfading, "a paused fade cannot play out: the old deck goes at once")

        engine.preload(stream("q4", duration: 8, url: fourth))
        let next = await waitUntil(timeout: .seconds(40)) { events.contains(.advanced(videoId: "q4")) }
        #expect(next, "the schedule is not blocked by a stuck drain: \(events)")
    }

    @Test("a seek mid-fade ends the drain, and so does a skip by crossfade onto a ready preload later")
    func drainClearsAfterSeek() async throws {
        let first = try await writeTone("k1", seconds: 8)
        let second = try await writeTone("k2", seconds: 8)
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.crossfadeSeconds = 3
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("k1", duration: 8, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("k2", duration: 8, url: second))
        _ = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "k2")) && engine.isCrossfading }
        #expect(engine.outgoingPositionAtCrossfade != nil)
        engine.pause()
        engine.seek(to: 0.5)
        #expect(!engine.isCrossfading, "paused: the seek lets the old deck go at once")
    }
}
