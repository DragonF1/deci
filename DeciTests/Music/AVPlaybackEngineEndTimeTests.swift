// DeciTests/Music/AVPlaybackEngineEndTimeTests.swift
// A playing item's forwardPlaybackEndTime is never written: CoreMedia answers it with a teardown, a reprepare and a preroll
// (a pause, and on Bluetooth a jump back). The trimmed end is the engine's own, and it lets the outgoing deck go itself.

import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine end time")
struct AVPlaybackEngineEndTimeTests {
    private func writeTone(_ name: String, seconds: Double) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/endtime", isDirectory: true)
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

    private func stream(_ name: String, duration: Double, url: URL) -> ResolvedStream {
        ResolvedStream(
            videoId: name, url: url, itag: 140, durationSeconds: duration,
            expiresAt: .distantFuture, playbackTrackingURL: nil, httpHeaders: [:]
        )
    }

    private func plan(_ mode: TransitionPlan.Mode, end: Double? = nil, fade: Double = 0) -> TransitionPlan {
        TransitionPlan(
            mode: mode, incomingStartSec: 0, outgoingEndSec: end, fadeStartSec: nil, fadeSeconds: fade,
            incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok
        )
    }

    private func makeEngine() -> AVPlaybackEngine {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        return AVPlaybackEngine(chain: chain)
    }

    @Test("plan commit, replan and cancel on a playing item never move its end time")
    func playingItemEndIsNeverWritten() async throws {
        let first = try await writeTone("w1", seconds: 12)
        let second = try await writeTone("w2", seconds: 12)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("w1", duration: 12, url: first), startAt: 0, autoplay: true)
        let playing = await waitUntil(timeout: .seconds(30)) {
            engine.avPlayer.timeControlStatus == .playing && engine.avPlayer.currentTime().seconds > 0.3
        }
        #expect(playing)
        #expect(abs((engine.debugItemEnd ?? 0) - 12) < 0.01)

        // Commit while the item plays.
        engine.preload(stream("w2", duration: 12, url: second), plan: plan(.fixed, end: 9, fade: 2))
        #expect(abs((engine.debugItemEnd ?? 0) - 12) < 0.01, "commit")
        #expect(abs((engine.debugEffectiveEnd ?? 0) - 9) < 0.01, "the engine's own end is the trim")

        // Replan (a Crossfade toggle hands the engine another plan at the same park offset).
        engine.updateTransitionPlan(plan(.gapless, end: 8))
        #expect(abs((engine.debugItemEnd ?? 0) - 12) < 0.01, "replan")
        #expect(abs((engine.debugEffectiveEnd ?? 0) - 8) < 0.01)
        engine.updateTransitionPlan(plan(.gapless, end: nil))
        #expect(abs((engine.debugItemEnd ?? 0) - 12) < 0.01)
        #expect(abs((engine.debugEffectiveEnd ?? 0) - 12) < 0.01, "no trim: the real end")

        // A seek into the trim (a user action) gives the real end back without touching the item either.
        engine.updateTransitionPlan(plan(.fixed, end: 9, fade: 2))
        engine.cancelPreload()
        #expect(abs((engine.debugItemEnd ?? 0) - 12) < 0.01, "cancel")
        #expect(abs((engine.debugEffectiveEnd ?? 0) - 12) < 0.01)
        #expect(!engine.debugTrimEndScheduled)
        engine.unload()
    }

    @Test("a gapless switch at a trim hands over at the trim, stops the outgoing deck and never advances twice")
    func gaplessTrimStopsTheOutgoingDeck() async throws {
        let first = try await writeTone("g1", seconds: 9)
        let second = try await writeTone("g2", seconds: 14)
        let engine = makeEngine()
        var events: [PlaybackEngineEvent] = []
        var playingSince: Date?
        var advancedAt: Date?
        engine.onEvent = { event in
            events.append(event)
            if event == .playingChanged(true), playingSince == nil { playingSince = Date() }
            if event == .advanced(videoId: "g2"), advancedAt == nil { advancedAt = Date() }
        }
        engine.load(stream("g1", duration: 9, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("g2", duration: 14, url: second), plan: plan(.gapless, end: 4))
        let advanced = await waitUntil(timeout: .seconds(30)) { advancedAt != nil }
        #expect(advanced)
        let elapsed = advancedAt.flatMap { end in playingSince.map { end.timeIntervalSince($0) } } ?? 99
        #expect(elapsed > 3.4 && elapsed < 5.6, "the switch came after \(elapsed) s, the trim is 4 s (real end 9 s)")
        #expect(engine.standbyAvPlayer.currentItem == nil, "the outgoing deck is released")
        #expect(engine.standbyAvPlayer.rate == 0)
        // Past the outgoing song's real end: no second advance and no end.
        try await Task.sleep(for: .seconds(6))
        #expect(events.filter { $0 == .advanced(videoId: "g2") }.count == 1)
        #expect(!events.contains(.ended))
        engine.unload()
    }

    @Test("a fade planned at a trim ends with the fade: the outgoing deck is released near the trim, not at the real end")
    func fadeAtTrimReleasesTheDeck() async throws {
        let first = try await writeTone("f1", seconds: 12)
        let second = try await writeTone("f2", seconds: 14)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        var events: [PlaybackEngineEvent] = []
        var playingSince: Date?
        engine.onEvent = { event in
            events.append(event)
            if event == .playingChanged(true), playingSince == nil { playingSince = Date() }
        }
        engine.load(stream("f1", duration: 12, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("f2", duration: 14, url: second), plan: plan(.fixed, end: 7, fade: 2))
        let flipped = await waitUntil(timeout: .seconds(30)) { engine.isCrossfading }
        #expect(flipped, "events: \(events)")
        let drained = await waitUntil(timeout: .seconds(20)) { !engine.isCrossfading }
        #expect(drained)
        let since = playingSince.map { Date().timeIntervalSince($0) } ?? 99
        #expect(since > 6 && since < 9.5, "released \(since) s into the song, the trim is 7 s and the real end 12 s")
        #expect(engine.standbyAvPlayer.currentItem == nil)
        try await Task.sleep(for: .seconds(6))
        #expect(events.filter { $0 == .advanced(videoId: "f2") }.count == 1)
        #expect(!events.contains(.ended))
        engine.unload()
    }

    @Test("a plan that cannot start (the preload never gets ready) plays the outgoing song to its real end")
    func noPreloadPlaysToTheRealEnd() async throws {
        let first = try await writeTone("n1", seconds: 7)
        let engine = makeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("n1", duration: 7, url: first), startAt: 0, autoplay: true)
        // A preload whose file is missing fails: the preload is cancelled and the trim with it.
        let missing = stream("n2", duration: 7, url: URL(fileURLWithPath: "/Volumes/Storage/_test/deci/endtime/missing.m4a"))
        engine.preload(missing, plan: plan(.gapless, end: 3))
        let ended = await waitUntil(timeout: .seconds(30)) { events.contains(.ended) }
        #expect(ended, "events: \(events)")
        #expect((engine.position) > 6, "it played to the real end, not the 3 s trim: \(engine.position)")
    }
}
