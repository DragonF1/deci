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
}
