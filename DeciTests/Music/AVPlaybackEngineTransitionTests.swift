// DeciTests/Music/AVPlaybackEngineTransitionTests.swift
// Tier 2b P2 on the real engine: a TransitionPlan drives the incoming start offset, the trimmed end of the outgoing
// item, the fade start and length, and the loudness offsets. Tone files, a real DSP chain, the chain's target gain at 0
// so nothing is heard.

import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine transition plan")
struct AVPlaybackEngineTransitionTests {
    private func writeTone(_ name: String, seconds: Double, rate: Double = 44_100) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/transition", isDirectory: true)
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

    private func plan(
        _ mode: TransitionPlan.Mode,
        start: Double = 0,
        end: Double? = nil,
        fadeStart: Double? = nil,
        fade: Double = 0,
        inGain: Double = 0,
        glide: Double = 0,
        outGain: Double = 0,
        ramp: Double = 0
    ) -> TransitionPlan {
        TransitionPlan(
            mode: mode, incomingStartSec: start, outgoingEndSec: end, fadeStartSec: fadeStart, fadeSeconds: fade,
            incomingGainDb: inGain, incomingGlideSeconds: glide, outgoingGainDb: outGain, outgoingRampSeconds: ramp,
            reason: .ok
        )
    }

    private func makeEngine() -> (AVPlaybackEngine, MusicDSPChain) {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        return (AVPlaybackEngine(chain: chain), chain)
    }

    private func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func itemEnd(_ engine: AVPlaybackEngine) -> Double? {
        engine.debugEffectiveEnd
    }

    // MARK: - Incoming start offset

    @Test("the standby is parked at the planned offset before it prerolls, and plays on from there at the hand-over")
    func standbyStartsAtOffset() async throws {
        let first = try await writeTone("o1", seconds: 6)
        let second = try await writeTone("o2", seconds: 8)
        let (engine, _) = makeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("o1", duration: 6, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("o2", duration: 8, url: second), plan: plan(.gapless, start: 3))
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        let parked = engine.standbyAvPlayer.currentTime().seconds
        #expect(abs(parked - 3) < 0.05, "parked at \(parked)")
        #expect(engine.transitionPlan?.incomingStartSec == 3)

        let advanced = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "o2")) }
        #expect(advanced, "events: \(events)")
        #expect(engine.position >= 3, "the incoming plays from its offset, not from 0: \(engine.position)")
        #expect(engine.transitionPlan == nil, "the plan is consumed by the hand-over")
        #expect(!events.contains(.ended))
    }

    @Test("an offset the seek cannot land falls back to 0, the preload is kept and the plan says so")
    func failedParkSeekKeepsThePreload() async throws {
        let first = try await writeTone("f1", seconds: 5)
        let second = try await writeTone("f2", seconds: 8)
        let (engine, _) = makeEngine()
        engine.debugFailNextParkSeek = true
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("f1", duration: 5, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("f2", duration: 8, url: second), plan: plan(.gapless, start: 3))
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready, "the preload is not lost")
        #expect(engine.transitionPlan?.incomingStartSec == 0, "the plan reports where the standby really is")
        #expect(engine.standbyAvPlayer.currentTime().seconds < 0.05)
        let advanced = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "f2")) }
        #expect(advanced)
        #expect(engine.position < 2.5, "it starts at 0: \(engine.position)")
    }

    @Test("an offset at or past the stream's end is dropped (0), never seeked")
    func offsetPastTheEndIsDropped() async throws {
        let first = try await writeTone("p1", seconds: 5)
        let second = try await writeTone("p2", seconds: 8)
        let (engine, _) = makeEngine()
        engine.load(stream("p1", duration: 5, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("p2", duration: 4, url: second), plan: plan(.gapless, start: 3.5))
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        #expect(engine.transitionPlan?.incomingStartSec == 0)
        #expect(engine.standbyAvPlayer.currentTime().seconds < 0.05)
    }

    // MARK: - Trimmed end

    @Test("the trimmed end is the engine's own, the item keeps its natural end, and cancelPreload drops the trim")
    func trimmedEndIsRestored() async throws {
        let first = try await writeTone("t1", seconds: 8)
        let second = try await writeTone("t2", seconds: 8)
        let (engine, _) = makeEngine()
        engine.load(stream("t1", duration: 8, url: first), startAt: 0, autoplay: true)
        // Made before the item is on the player: the end moves when it is installed.
        engine.preload(stream("t2", duration: 8, url: second), plan: plan(.gapless, end: 5))
        let trimmed = await waitUntil(timeout: .seconds(30)) { itemEnd(engine).map { abs($0 - 5) < 0.01 } ?? false }
        #expect(trimmed, "end \(String(describing: itemEnd(engine)))")
        #expect(abs((engine.debugItemEnd ?? 0) - 8) < 0.01, "a playing item's end time is never written")
        engine.cancelPreload()
        #expect(abs((itemEnd(engine) ?? 0) - 8) < 0.01, "restored to the stream's own end")
        #expect(engine.transitionPlan == nil)
    }

    @Test("the end comes from the stream duration: a longer item or a plan past the stream does not move it")
    func endUsesTheStreamDuration() async throws {
        // The file is 8 s, the stream says 4 s (the item's own duration disagrees with the stream, as YouTube's does).
        let first = try await writeTone("d1", seconds: 8)
        let second = try await writeTone("d2", seconds: 8)
        let (engine, _) = makeEngine()
        engine.load(stream("d1", duration: 4, url: first), startAt: 0, autoplay: true)
        let installed = await waitUntil(timeout: .seconds(30)) { engine.currentItem != nil }
        #expect(installed)
        #expect(abs((itemEnd(engine) ?? 0) - 4) < 0.01)

        engine.preload(stream("d2", duration: 8, url: second), plan: plan(.gapless, end: 6))
        #expect(abs((itemEnd(engine) ?? 0) - 4) < 0.01, "a plan end past the stream's end changes nothing")

        engine.preload(stream("d2", duration: 8, url: second), plan: plan(.gapless, end: 3))
        #expect(abs((itemEnd(engine) ?? 0) - 3) < 0.01, "a plan end inside it is used")

        engine.preload(stream("d2", duration: 8, url: second), plan: plan(.gapless, end: 0.5))
        #expect(abs((itemEnd(engine) ?? 0) - 4) < 0.01, "an end within a second of now is not applied")
    }

    @Test("gapless and clean plans end the outgoing item at its trimmed end")
    func gaplessAndCleanEndAtTheTrimmedEnd() async throws {
        for mode in [TransitionPlan.Mode.gapless, .clean] {
            let first = try await writeTone("g1", seconds: 9)
            let second = try await writeTone("g2", seconds: 9)
            let (engine, _) = makeEngine()
            var playingSince: Date?
            var advancedAt: Date?
            engine.onEvent = { event in
                if event == .playingChanged(true), playingSince == nil { playingSince = Date() }
                if event == .advanced(videoId: "g2") { advancedAt = Date() }
            }
            engine.load(stream("g1", duration: 9, url: first), startAt: 0, autoplay: true)
            engine.preload(stream("g2", duration: 9, url: second), plan: plan(mode, start: 1, end: 4))
            let advanced = await waitUntil(timeout: .seconds(30)) { advancedAt != nil }
            #expect(advanced, "\(mode)")
            let elapsed = advancedAt.flatMap { end in playingSince.map { end.timeIntervalSince($0) } } ?? 99
            #expect(elapsed > 3.4 && elapsed < 5.6, "\(mode): the switch came after \(elapsed) s, the trimmed end is 4 s (natural 9 s)")
            #expect(engine.crossfadeCount == 0, "\(mode) never fades")
            #expect(engine.position >= 1, "the incoming plays from its offset: \(engine.position)")
        }
    }

    // MARK: - Smart fade

    @Test("a smart plan starts the standby at its fade start, fades over the planned length and drops the outgoing deck after the fade")
    func smartFadeFollowsThePlan() async throws {
        let first = try await writeTone("m1", seconds: 12)
        let second = try await writeTone("m2", seconds: 12, rate: 48_000)
        let (engine, _) = makeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("m1", duration: 12, url: first), startAt: 0, autoplay: true)
        engine.preload(
            stream("m2", duration: 12, url: second),
            plan: plan(.smart, start: 1, end: 10, fadeStart: 5, fade: 2)
        )
        let ready = await waitUntil(timeout: .seconds(30)) {
            engine.debugStandbyTap?.debugLease != nil && engine.debugActiveTap?.debugLease != nil
        }
        #expect(ready)
        let outgoing = try #require(engine.debugActiveTap?.debugLease)

        var scheduled: CMTime?
        let isScheduled = await waitUntil(timeout: .seconds(30)) {
            scheduled = engine.scheduledStartHost
            return scheduled != nil
        }
        #expect(isScheduled)
        // Sampled together: the host time of item time 5 s, from the playing position.
        let position = engine.position
        let expected = hostNow() + (5 - position)
        let actual = scheduled?.seconds ?? 0
        #expect(abs(actual - expected) < 0.05, "scheduled start off by \(actual - expected) s")
        #expect(position < 4.5, "scheduled well ahead of the fade start (position \(position))")

        let flipped = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "m2")) && engine.isCrossfading }
        #expect(flipped, "events: \(events)")
        let flippedAt = Date()
        let outgoingPosition = engine.outgoingPositionAtCrossfade ?? -1
        #expect(abs(outgoingPosition - 5) < 0.25, "the overlap started at \(outgoingPosition), planned 5")
        #expect(engine.crossfadeCount == 1)
        #expect(engine.position >= 1, "the incoming started from its parked offset")

        let drained = await waitUntil(timeout: .seconds(20)) { !engine.isCrossfading }
        #expect(drained)
        let took = Date().timeIntervalSince(flippedAt)
        #expect(took > 1.8 && took < 3.2, "the outgoing deck was dropped \(took) s after the flip (fade 2 + 0.1)")
        let atEnd = outgoing.debugCounters.fullFrames
        try await Task.sleep(for: .milliseconds(300))
        #expect(outgoing.debugCounters.fullFrames == atEnd, "the outgoing deck renders nothing after the fade, its tail is never played")
        #expect(!events.contains(.ended))
    }

    @Test("the loudness offsets go on at the flip: incoming attenuated, outgoing ramped, then the incoming glides back to 0 dB")
    func loudnessOffsets() async throws {
        let first = try await writeTone("l1", seconds: 10)
        let second = try await writeTone("l2", seconds: 10)
        let (engine, _) = makeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("l1", duration: 10, url: first), startAt: 0, autoplay: true)
        engine.preload(
            stream("l2", duration: 10, url: second),
            plan: plan(.smart, end: 9, fadeStart: 4, fade: 2, inGain: -6, glide: 2, outGain: -3, ramp: 0.5)
        )
        let ready = await waitUntil(timeout: .seconds(30)) {
            engine.debugStandbyTap?.debugLease != nil && engine.debugActiveTap?.debugLease != nil
        }
        #expect(ready)
        let outgoing = try #require(engine.debugActiveTap?.debugLease)
        let incoming = try #require(engine.debugStandbyTap?.debugLease)
        #expect(incoming.offsetTarget == 1 && outgoing.offsetTarget == 1, "nothing is applied before the overlap")

        let flipped = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "l2")) && engine.isCrossfading }
        #expect(flipped)
        #expect(abs(incoming.offsetTarget - 0.501) < 0.01, "incoming at -6 dB: \(incoming.offsetTarget)")
        #expect(abs(outgoing.offsetTarget - 0.708) < 0.01, "outgoing at -3 dB: \(outgoing.offsetTarget)")

        let drained = await waitUntil(timeout: .seconds(20)) { !engine.isCrossfading }
        #expect(drained)
        #expect(incoming.offsetTarget == 1, "the glide back to 0 dB starts when the outgoing deck has drained")
    }

    @Test("a manual skip keeps the incoming attenuation and its glide, and never attenuates the outgoing deck")
    func manualSkipGains() async throws {
        let first = try await writeTone("k1", seconds: 10)
        let second = try await writeTone("k2", seconds: 10)
        let (engine, _) = makeEngine()
        engine.load(stream("k1", duration: 10, url: first), startAt: 0, autoplay: true)
        engine.preload(
            stream("k2", duration: 10, url: second),
            plan: plan(.fixed, start: 0, fade: 0.3, inGain: -4, glide: 1, outGain: -3, ramp: 0.5)
        )
        let ready = await waitUntil(timeout: .seconds(30)) {
            engine.preloadIsReady && engine.debugStandbyTap?.debugLease != nil && engine.debugActiveTap?.debugLease != nil
        }
        #expect(ready)
        let outgoing = try #require(engine.debugActiveTap?.debugLease)
        let incoming = try #require(engine.debugStandbyTap?.debugLease)
        #expect(engine.crossfadeToPreloaded(seconds: 0.3))
        #expect(abs(incoming.offsetTarget - 0.631) < 0.01, "incoming at -4 dB: \(incoming.offsetTarget)")
        #expect(outgoing.offsetTarget == 1, "no outgoing attenuation on a skip")
        let drained = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(drained)
        #expect(incoming.offsetTarget == 1, "glide started")
    }

    @Test("a seek mid-fade still ends the drain quickly and starts the pending glide at once")
    func seekMidFadeStartsTheGlide() async throws {
        let first = try await writeTone("s1", seconds: 12)
        let second = try await writeTone("s2", seconds: 12)
        let (engine, _) = makeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("s1", duration: 12, url: first), startAt: 0, autoplay: true)
        engine.preload(
            stream("s2", duration: 12, url: second),
            plan: plan(.smart, end: 11, fadeStart: 4, fade: 6, inGain: -6, glide: 8)
        )
        let ready = await waitUntil(timeout: .seconds(30)) {
            engine.debugStandbyTap?.debugLease != nil && engine.debugActiveTap?.debugLease != nil
        }
        #expect(ready)
        let incoming = try #require(engine.debugStandbyTap?.debugLease)
        let fading = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "s2")) && engine.isCrossfading }
        #expect(fading)
        #expect(abs(incoming.offsetTarget - 0.501) < 0.01)
        engine.seek(to: 1)
        let quick = await waitUntil(timeout: .seconds(2)) { !engine.isCrossfading }
        #expect(quick, "the old deck is dropped in about 30 ms, not over the rest of the fade")
        #expect(incoming.offsetTarget == 1, "the glide is not left pending")
        #expect((engine.currentItem?.asset as? AVURLAsset)?.url == second)
    }

    // MARK: - Plan updates

    @Test("updateTransitionPlan: accepted with the same offset, ignored without a preload or with another offset")
    func updateRules() async throws {
        let first = try await writeTone("u1", seconds: 8)
        let second = try await writeTone("u2", seconds: 8)
        let (engine, _) = makeEngine()
        engine.updateTransitionPlan(plan(.gapless))
        #expect(engine.transitionPlan == nil, "ignored with nothing preloaded")

        engine.load(stream("u1", duration: 8, url: first), startAt: 0, autoplay: true)
        let original = plan(.gapless, start: 2, end: 7)
        engine.preload(stream("u2", duration: 8, url: second), plan: original)
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)

        engine.updateTransitionPlan(plan(.gapless, start: 3, end: 7))
        #expect(engine.transitionPlan == original, "another offset is ignored: the standby is already parked")

        let replanned = plan(.fixed, start: 2, end: 7, fade: 2)
        engine.updateTransitionPlan(replanned)
        #expect(engine.transitionPlan == replanned)
        #expect(abs((itemEnd(engine) ?? 0) - 7) < 0.01)
        #expect(engine.standbyAvPlayer.currentTime().seconds > 1.9, "the standby was not rebuilt or re-parked")
    }

    @Test("a plan update re-plans a scheduled start: smart to gapless moves the start from the fade start to the end")
    func updateReschedules() async throws {
        let first = try await writeTone("r1", seconds: 12)
        let second = try await writeTone("r2", seconds: 12)
        let (engine, _) = makeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("r1", duration: 12, url: first), startAt: 0, autoplay: true)
        engine.preload(
            stream("r2", duration: 12, url: second),
            plan: plan(.smart, end: 10, fadeStart: 5, fade: 2)
        )
        let smartScheduled = await waitUntil(timeout: .seconds(30)) { engine.scheduledStartHost != nil }
        #expect(smartScheduled)
        #expect(engine.position < 3)
        engine.updateTransitionPlan(plan(.gapless, end: 10))
        #expect(engine.transitionPlan?.mode == .gapless)

        // The new start is at the trimmed end: 10 s of item time.
        let moved = await waitUntil(timeout: .seconds(20)) {
            guard let host = engine.scheduledStartHost?.seconds else { return false }
            let expectedEnd = hostNow() + (10 - engine.position)
            return abs(host - expectedEnd) < 0.1
        }
        #expect(moved, "the start follows the gapless plan")
        let advanced = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "r2")) }
        #expect(advanced)
        #expect(engine.crossfadeCount == 0, "the fade was dropped with the plan")
    }

    @Test("a fade that is already running is never re-planned")
    func runningFadeIsNotReplanned() async throws {
        let first = try await writeTone("n1", seconds: 12)
        let second = try await writeTone("n2", seconds: 12)
        let (engine, _) = makeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("n1", duration: 12, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("n2", duration: 12, url: second), plan: plan(.smart, end: 10, fadeStart: 3, fade: 6))
        let fading = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "n2")) && engine.isCrossfading }
        #expect(fading)
        engine.updateTransitionPlan(plan(.gapless))
        #expect(engine.transitionPlan == nil, "the plan went with the hand-over, the update finds no preload")
        #expect(engine.isCrossfading)
        #expect(engine.crossfadeCount == 1)
    }

    // MARK: - Without a plan

    @Test("without a plan the engine is Tier 1: natural end, no offset, nothing recorded")
    func noPlanIsTier1() async throws {
        let first = try await writeTone("z1", seconds: 8)
        let second = try await writeTone("z2", seconds: 8)
        let (engine, _) = makeEngine()
        engine.load(stream("z1", duration: 8, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("z2", duration: 8, url: second))
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        #expect(engine.transitionPlan == nil)
        #expect(abs((itemEnd(engine) ?? 0) - 8) < 0.01)
        #expect(engine.standbyAvPlayer.currentTime().seconds < 0.05)
    }
    // MARK: - Review fixes

    @Test("a seek to or near the trimmed end brings the natural end back; a seek well before it keeps the trim")
    func seekPastTheTrimRestoresTheNaturalEnd() async throws {
        let first = try await writeTone("sk1", seconds: 10)
        let second = try await writeTone("sk2", seconds: 8)
        let (engine, _) = makeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("sk1", duration: 10, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("sk2", duration: 8, url: second), plan: plan(.smart, end: 8, fadeStart: 5, fade: 2))
        let trimmed = await waitUntil(timeout: .seconds(30)) { itemEnd(engine).map { abs($0 - 8) < 0.01 } ?? false }
        #expect(trimmed)
        engine.seek(to: 1)
        #expect(abs((itemEnd(engine) ?? 0) - 8) < 0.01, "a seek well before the trim keeps it")
        // 7 is inside trimmed end (8) minus lead (3) minus 1 s.
        engine.seek(to: 7)
        #expect(abs((itemEnd(engine) ?? 0) - 10) < 0.01, "natural end is back: \(String(describing: itemEnd(engine)))")
        #expect(engine.transitionPlan?.outgoingEndSec == nil, "the plan reflects the restored end")
        engine.updateTransitionPlan(plan(.smart, end: 8, fadeStart: 5, fade: 2))
        #expect(abs((itemEnd(engine) ?? 0) - 10) < 0.01, "a plan update does not trim it again")
        #expect(engine.transitionPlan?.outgoingEndSec == nil, "a plan update does not put the trimmed end back in the plan")
        let advanced = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "sk2")) }
        #expect(advanced, "events: \(events)")
        #expect(!events.contains(.ended))
        #expect(engine.position >= 0)
    }

    @Test("a plan that comes late (smart lead longer than what is left) still fades, held to what remains")
    func latePlanIsClamped() async throws {
        let first = try await writeTone("lt1", seconds: 12)
        let second = try await writeTone("lt2", seconds: 12)
        let (engine, _) = makeEngine()
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("lt1", duration: 12, url: first), startAt: 8.5, autoplay: true)
        engine.preload(stream("lt2", duration: 12, url: second), plan: plan(.smart, fadeStart: 1, fade: 2))
        let flipped = await waitUntil(timeout: .seconds(30)) {
            events.contains(.advanced(videoId: "lt2")) && engine.isCrossfading
        }
        #expect(flipped, "events: \(events)")
        #expect(engine.crossfadeCount == 1, "a fade, not a gapless cut")
        #expect(engine.fallbackAdvanceCount == 0)
    }
}
