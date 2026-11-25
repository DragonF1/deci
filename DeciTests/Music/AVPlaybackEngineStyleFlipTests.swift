// DeciTests/Music/AVPlaybackEngineStyleFlipTests.swift
// Tier 4b P1 on the real engine: a quick cut and an echo out flip real tone decks. The chain is at 0 gain so nothing is
// heard (the render path then never reaches the echo DSP; that is covered offline in MusicEchoDSPTests), but the engine's
// own bookkeeping (what is torn down when, what the lease is asked for) is the real thing.

import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine style flips")
struct AVPlaybackEngineStyleFlipTests {
    private func writeTone(_ name: String, seconds: Double) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/style-engine", isDirectory: true)
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

    private func styledPlan(_ style: MusicTransitionStyle, mixIn: Double = 2, cut: Double, tail: Double = 0, delay: Double = 0) -> TransitionPlan {
        var plan = TransitionPlan(
            mode: .beat, incomingStartSec: mixIn, outgoingEndSec: cut + tail, fadeStartSec: cut,
            fadeSeconds: MusicBeatPlanner.cutFadeSeconds, incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0,
            outgoingRampSeconds: 0, reason: .ok
        )
        plan.style = style
        plan.incomingRate = 1
        plan.mixOutSec = cut
        plan.mixInSec = mixIn
        plan.overlapBars = 0
        plan.overlapSec = MusicBeatPlanner.cutFadeSeconds
        plan.barSec = 2
        plan.echoTailSec = tail
        plan.echoDelaySec = delay
        return plan
    }

    private func makeEngine() -> AVPlaybackEngine {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        return AVPlaybackEngine(chain: chain)
    }

    /// Loads A (`first` seconds long), preloads B with `plan` and waits for the flip. Returns the engine.
    private func flipped(_ plan: TransitionPlan, first: Double = 8, markMono: Bool = false) async throws -> AVPlaybackEngine {
        let a = try await writeTone("fa", seconds: first)
        let b = try await writeTone("fb", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("fa", duration: first, url: a), startAt: 0, autoplay: true)
        engine.preload(stream("fb", duration: 20, url: b), plan: plan)
        // A tap may build its lease again while it prepares, so the mono mark is renewed on whatever lease the deck holds
        // until the flip has happened.
        let didFlip = await waitUntil(timeout: .seconds(40)) {
            if markMono { engine.debugActiveTap?.debugLease?.debugMarkGainOnly() }
            return engine.isCrossfading
        }
        #expect(didFlip)
        return engine
    }

    @Test("a quick cut flips as a cut, and the outgoing deck lives until the incoming deck has played past its start")
    func quickCutDrainsAfterTheIncomingStarts() async throws {
        let engine = try await flipped(styledPlan(.quickCut, cut: 4))
        #expect(engine.lastTransitionStyle == .quickCut)
        let lease = try #require(engine.debugDrainingTap?.debugLease)
        #expect(!lease.isEchoActive, "a cut has no echo")
        // Poll while the outgoing deck lives: the incoming deck must have moved past its start by the time it goes.
        var incomingWhenLastSeen = 0.0
        let began = Date()
        while engine.isCrossfading, Date().timeIntervalSince(began) < 5 {
            incomingWhenLastSeen = engine.avPlayer.currentTime().seconds
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!engine.isCrossfading)
        // The outgoing deck drains startGap + a 4 ms ramp after the flip, so it goes just after the incoming deck's first
        // frame: the incoming item time (it starts at 2 s) is at or past its start when the outgoing deck is gone.
        #expect(incomingWhenLastSeen - 2 >= 0, "the incoming deck was at \(incomingWhenLastSeen - 2) s when the outgoing one went")
        engine.unload()
    }

    @Test("an echo keeps the outgoing item until the cut plus the tail, then tears it down and ends the echo")
    func echoLivesUntilTheTailEnds() async throws {
        let engine = try await flipped(styledPlan(.echoOut, cut: 4, tail: 1.5, delay: 0.25))
        let flippedAt = Date()
        #expect(engine.lastTransitionStyle == .echoOut)
        let lease = try #require(engine.debugDrainingTap?.debugLease)
        #expect(lease.isEchoActive)
        try await Task.sleep(for: .milliseconds(900))
        #expect(engine.isCrossfading, "0.9 s into a 1.5 s tail the outgoing deck still plays")
        #expect(lease.isEchoActive)
        let over = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(over)
        let elapsed = Date().timeIntervalSince(flippedAt)
        #expect(elapsed >= 1.4 && elapsed <= 2.6, "the tail lasted \(elapsed) s")
        #expect(!lease.isEchoActive, "the echo is ended with the deck")
        engine.unload()
    }

    @Test("an echo whose song ends before the planned tail is over is torn down with the song, not held for the plan")
    func echoTailTruncatedBySongEnd() async throws {
        // The plan asks for a 3 s tail, but the song is only 4.6 s long and the cut is at 4.0 s.
        let engine = try await flipped(styledPlan(.echoOut, cut: 4, tail: 3, delay: 0.5), first: 4.6)
        let flippedAt = Date()
        let over = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(over)
        let elapsed = Date().timeIntervalSince(flippedAt)
        #expect(elapsed < 1.6, "the song had under a second left, the tail lasted \(elapsed) s")
        engine.unload()
    }

    @Test("a seek in the middle of the tail ramps the wet out and cleans the lease up")
    func seekMidTail() async throws {
        let engine = try await flipped(styledPlan(.echoOut, cut: 4, tail: 2.5, delay: 0.4), first: 10)
        let lease = try #require(engine.debugDrainingTap?.debugLease)
        let before = lease.debugEchoRelease
        try await Task.sleep(for: .milliseconds(400))
        #expect(lease.isEchoActive)
        engine.seek(to: 6)
        let asked = lease.debugEchoRelease
        #expect(asked.generation == before.generation + 1, "the wet ramp was requested once")
        #expect(asked.frames > 0 && asked.frames <= Int(0.05 * 48_000), "about 30 ms, was \(asked.frames) frames")
        let over = await waitUntil(timeout: .seconds(5)) { !engine.isCrossfading }
        #expect(over)
        #expect(!lease.isEchoActive)
        engine.unload()
    }

    @Test("an echo on a lease with no stereo path flips as a quick cut: there is no silent tail")
    func monoLeaseFallsBackToCut() async throws {
        let engine = try await flipped(styledPlan(.echoOut, cut: 4, tail: 1.5, delay: 0.25), markMono: true)
        #expect(engine.lastTransitionStyle == .quickCut)
        let lease = try #require(engine.debugDrainingTap?.debugLease)
        #expect(!lease.isEchoActive)
        let flippedAt = Date()
        let over = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(over)
        #expect(Date().timeIntervalSince(flippedAt) < 1.2, "the outgoing deck is not kept for a tail nobody hears")
        engine.unload()
    }

    @Test("a plan the engine runs as a plain fade (rate and grid given up) reports a long blend")
    func downgradeReportsLongBlend() async throws {
        let a = try await writeTone("da", seconds: 8)
        let b = try await writeTone("db", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("da", duration: 8, url: a), startAt: 0, autoplay: true)
        engine.preload(stream("db", duration: 20, url: b), plan: styledPlan(.quickCut, cut: 4))
        let scheduled = await waitUntil(timeout: .seconds(40)) { engine.debugPlannedBeat }
        #expect(scheduled)
        // Given up after it was scheduled; a changed setting plans the start again as a plain fade.
        engine.debugGiveUpBeat()
        engine.crossfadeSeconds = 3
        engine.debugEvaluateSchedule()
        let replanned = await waitUntil(timeout: .seconds(30)) { engine.scheduledStartHost != nil && !engine.debugPlannedBeat }
        #expect(replanned)
        let didFlip = await waitUntil(timeout: .seconds(40)) { engine.isCrossfading }
        #expect(didFlip)
        #expect(engine.lastTransitionStyle == .longBlend)
        engine.unload()
    }

    @Test("a seek tells the lease to forget its echo history, now and again once the seek has landed")
    func seekClearsHistory() async throws {
        let a = try await writeTone("ha", seconds: 10)
        let engine = makeEngine()
        engine.load(stream("ha", duration: 10, url: a), startAt: 0, autoplay: true)
        let ready = await waitUntil(timeout: .seconds(30)) { (engine.debugActiveTap?.debugRenderedFrames ?? 0) > 0 }
        #expect(ready)
        let lease = try #require(engine.debugActiveTap?.debugLease)
        let before = lease.debugHistoryClearGeneration
        engine.seek(to: 5)
        #expect(lease.debugHistoryClearGeneration >= before + 1)
        let landed = await waitUntil(timeout: .seconds(10)) { lease.debugHistoryClearGeneration >= before + 2 }
        #expect(landed, "cleared again when the seek landed")
        engine.unload()
    }

    // MARK: Tier 4b P2

    private func overlapPlan(_ style: MusicTransitionStyle, mixOut: Double = 3, mixIn: Double = 5, overlap: Double = 2) -> TransitionPlan {
        var plan = TransitionPlan(
            mode: .beat, incomingStartSec: mixIn, outgoingEndSec: mixOut + overlap, fadeStartSec: mixOut,
            fadeSeconds: overlap, incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0,
            outgoingRampSeconds: 0, reason: .ok
        )
        plan.style = style
        plan.incomingRate = 1
        plan.mixOutSec = mixOut
        plan.mixInSec = mixIn
        plan.overlapBars = 1
        plan.overlapSec = overlap
        plan.barSec = overlap
        if style == .filterSweep {
            plan.sweepFromHz = 30
            plan.sweepToHz = 1_500
        }
        return plan
    }

    @Test("a filter sweep asks the outgoing lease for a 30 Hz to 1.5 kHz high-pass across the overlap, and ends it with the deck")
    func sweepReachesTheOutgoingLease() async throws {
        let engine = try await flipped(overlapPlan(.filterSweep), first: 10)
        #expect(engine.lastTransitionStyle == .filterSweep)
        let lease = try #require(engine.debugDrainingTap?.debugLease)
        let asked = lease.debugSweep
        #expect(asked.active && asked.generation >= 1)
        #expect(asked.settings.fromHz == 30 && asked.settings.toHz == 1_500 && asked.settings.highpass)
        #expect(asked.settings.durationFrames > 48_000 && asked.settings.durationFrames <= 2 * 48_000 + 4_800, "ramp was \(asked.settings.durationFrames) frames")
        #expect(asked.settings.startFrame >= 0)
        let over = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(over)
        #expect(!lease.isSweepActive, "the sweep is ended with the deck")
        engine.unload()
    }

    @Test("a filter sweep on a lease with no stereo path flips as a plain long blend, and asks for no sweep")
    func monoSweepFallsBack() async throws {
        let engine = try await flipped(overlapPlan(.filterSweep), first: 10, markMono: true)
        #expect(engine.lastTransitionStyle == .longBlend)
        let lease = try #require(engine.debugDrainingTap?.debugLease)
        #expect(!lease.isSweepActive)
        engine.unload()
    }

    @Test("a drop swap starts the incoming song at its planned offset and asks for no sweep")
    func dropSwapStartsAtTheOffset() async throws {
        let engine = try await flipped(overlapPlan(.dropSwap, mixOut: 3, mixIn: 5, overlap: 2), first: 10)
        #expect(engine.lastTransitionStyle == .dropSwap)
        let incoming = engine.avPlayer.currentTime().seconds
        #expect(incoming >= 5 - 0.05 && incoming <= 5 + 2, "incoming item time was \(incoming) s")
        let lease = try #require(engine.debugDrainingTap?.debugLease)
        #expect(!lease.isSweepActive && !lease.isEchoActive)
        let over = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(over, "the outgoing song is gone after the overlap")
        engine.unload()
    }

    // MARK: - The new moves

    private static let newMoves: [MusicTransitionStyle] = [.lowpassSweep, .echoThrow, .reverbOut, .brake, .loopRoll, .doubleDrop]

    /// A plan for `style` with everything its move needs.
    private func movePlan(_ style: MusicTransitionStyle) -> TransitionPlan {
        switch style {
        case .reverbOut: return styledPlan(style, cut: 4, tail: 1.5)
        case .brake:
            var plan = styledPlan(style, cut: 4, tail: 0.5)
            plan.brakeLeadSec = 0.5
            return plan
        default:
            var plan = overlapPlan(style)
            plan.sweepFromHz = style == .lowpassSweep ? 18_000 : 0
            plan.sweepToHz = style == .lowpassSweep ? 300 : 0
            plan.sweepHighpass = style != .lowpassSweep
            if style == .echoThrow {
                plan.echoThrowAtSec = 1
                plan.echoDelaySec = 0.5
                plan.echoTailSec = 2
                plan.outgoingEndSec = 6
            }
            if style == .loopRoll {
                plan.rollAtSec = 1
                plan.rollBeatSec = 0.2
            }
            return plan
        }
    }

    @Test("a low-pass sweep asks the outgoing lease for a falling low-pass across the overlap")
    func lowpassReachesTheLease() async throws {
        let engine = try await flipped(movePlan(.lowpassSweep), first: 10)
        #expect(engine.lastTransitionStyle == .lowpassSweep)
        let asked = try #require(engine.debugDrainingTap?.debugLease).debugSweep
        #expect(asked.active && !asked.settings.highpass)
        #expect(asked.settings.fromHz == 18_000 && asked.settings.toHz == 300)
        engine.unload()
    }

    @Test("a reverb out asks for its tail, keeps the deck for it and ends with it")
    func reverbReachesTheLease() async throws {
        let engine = try await flipped(movePlan(.reverbOut), first: 10)
        let flippedAt = Date()
        #expect(engine.lastTransitionStyle == .reverbOut)
        let tap = try #require(engine.debugDrainingTap)
        let asked = try #require(tap.debugReverb)
        #expect(abs(Double(asked.tailFrames) / 48_000 - 1.5) < 0.15, "\(asked.tailFrames) frames")
        #expect(asked.cutAfterFrames < 48_000 / 4)
        #expect(tap.debugBrake == nil && tap.debugRoll == nil && tap.debugLease?.isEchoActive == false)
        let over = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(over)
        let elapsed = Date().timeIntervalSince(flippedAt)
        #expect(elapsed >= 1.4 && elapsed <= 2.6, "the tail lasted \(elapsed) s")
        #expect(tap.debugReverb == nil)
        engine.unload()
    }

    @Test("a brake alone before the new song's 1 is loud, one with nothing before it is covered, and neither writes a rate")
    func brakeReachesTheLease() async throws {
        let engine = try await flipped(movePlan(.brake), first: 10)
        #expect(engine.lastTransitionStyle == .brake)
        let asked = try #require(engine.debugDrainingTap?.debugBrake)
        #expect(abs(Double(asked.lengthFrames) / 48_000 - 0.5) < 0.06)
        #expect(asked.gain == MusicBrakeSettings.soloGain)
        #expect(engine.avPlayer.rate == 1 || engine.avPlayer.rate == 0)
        let over = await waitUntil(timeout: .seconds(5)) { !engine.isCrossfading }
        #expect(over)
        engine.unload()
        var covered = movePlan(.brake)
        covered.brakeLeadSec = 0
        let second = try await flipped(covered, first: 10)
        #expect(second.debugDrainingTap?.debugBrake?.gain == MusicBrakeSettings.coveredGain)
        second.unload()
    }

    @Test("a throw asks for an echo at its moment, and the deck outlives the overlap for the repeats")
    func throwReachesTheLease() async throws {
        let engine = try await flipped(movePlan(.echoThrow), first: 10)
        let flippedAt = Date()
        #expect(engine.lastTransitionStyle == .echoThrow)
        let lease = try #require(engine.debugDrainingTap?.debugLease)
        #expect(lease.isEchoActive)
        let over = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(over)
        let elapsed = Date().timeIntervalSince(flippedAt)
        #expect(elapsed >= 2.6, "the overlap is 2 s, the throw at 1 s rings for 2 s, it lasted \(elapsed) s")
        #expect(!lease.isEchoActive)
        engine.unload()
    }

    @Test("a roll asks for its bar, and a double drop starts the incoming song at its offset with no effect")
    func rollAndDoubleDropReachTheLease() async throws {
        let engine = try await flipped(movePlan(.loopRoll), first: 10)
        #expect(engine.lastTransitionStyle == .loopRoll)
        let asked = try #require(engine.debugDrainingTap?.debugRoll)
        #expect(asked.beatFrames >= 44_100 / 5 - 2 && asked.beatFrames <= 48_000 / 5 + 2)
        #expect(asked.startFrame > 0 && asked.startFrame < 48_000 * 3 / 2)
        engine.unload()
        let second = try await flipped(movePlan(.doubleDrop), first: 10)
        #expect(second.lastTransitionStyle == .doubleDrop)
        let incoming = second.avPlayer.currentTime().seconds
        #expect(incoming >= 5 - 0.05 && incoming <= 5 + 2, "incoming item time was \(incoming) s")
        let tap = try #require(second.debugDrainingTap)
        #expect(tap.debugRoll == nil && tap.debugBrake == nil && tap.debugReverb == nil && tap.debugLease?.isEchoActive == false)
        second.unload()
    }

    @Test("with no stereo path a tail is a quick cut, a move on a blend is the plain blend, and nothing is asked for")
    func monoMovesFallBack() async throws {
        for style in Self.newMoves where style != .doubleDrop {
            let engine = try await flipped(movePlan(style), first: 10, markMono: true)
            #expect(engine.lastTransitionStyle == (style.hasTail ? .quickCut : .longBlend), "\(style.rawValue)")
            let tap = try #require(engine.debugDrainingTap)
            #expect(tap.debugRoll == nil && tap.debugBrake == nil && tap.debugReverb == nil && tap.debugLease?.isEchoActive == false)
            engine.unload()
        }
    }

    @Test("a move whose plan does not say where it goes is the plain blend or cut")
    func incompleteMovesFallBack() async throws {
        for style in [MusicTransitionStyle.echoThrow, .loopRoll, .lowpassSweep] {
            let engine = try await flipped(overlapPlan(style), first: 10)
            #expect(engine.lastTransitionStyle == .longBlend, "\(style.rawValue)")
            engine.unload()
        }
        let engine = try await flipped(styledPlan(.reverbOut, cut: 4), first: 10)
        #expect(engine.lastTransitionStyle == .quickCut)
        engine.unload()
    }

    @Test("a seek in the middle of a tail or a roll takes it out smoothly and cleans the lease up", arguments: [
        MusicTransitionStyle.reverbOut, .brake, .loopRoll, .echoThrow,
    ])
    func seekMidMove(style: MusicTransitionStyle) async throws {
        let engine = try await flipped(movePlan(style), first: 10)
        let lease = try #require(engine.debugDrainingTap?.debugLease)
        let before = [lease.reverb, lease.brake, lease.roll].map(releases)
        engine.seek(to: 6)
        for (effect, count) in zip([lease.reverb, lease.brake, lease.roll] as [AnyObject], before) {
            let asked = releases(effect)
            #expect(asked.count == count.count + 1, "released once")
            #expect(asked.frames > 0 && asked.frames <= Int(0.05 * 48_000))
        }
        let over = await waitUntil(timeout: .seconds(5)) { !engine.isCrossfading }
        #expect(over)
        #expect(!lease.isTailActive && !lease.roll.control.isActive)
        engine.unload()
    }

    private func releases(_ effect: AnyObject) -> (count: Int, frames: Int) {
        let control = (effect as? MusicReverbTail)?.control ?? (effect as? MusicVinylBrake)?.control ?? (effect as? MusicLoopRoll)?.control
        return control?.debugReleases ?? (0, 0)
    }

    // MARK: - A drop swap never leaks its deep mix-in into a plain fade

    /// A drop swap whose standby is parked deep (`mixIn`) while the song's normal start is `smart`.
    private func deepDropSwap(mixOut: Double = 8, mixIn: Double = 6, smart: Double = 0.5, overlap: Double = 2) -> TransitionPlan {
        var plan = overlapPlan(.dropSwap, mixOut: mixOut, mixIn: mixIn, overlap: overlap)
        plan.fallbackIncomingStartSec = smart
        return plan
    }

    @Test("a seek into a drop swap's overlap parks the standby on the song's normal start, not the deep mix-in")
    func seekIntoDropSwapOverlapUsesNormalStart() async throws {
        let a = try await writeTone("sa", seconds: 12)
        let b = try await writeTone("sb", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("sa", duration: 12, url: a), startAt: 0, autoplay: false)
        engine.preload(stream("sb", duration: 20, url: b), plan: deepDropSwap())
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        #expect(engine.debugStandbyStartOffset == 6, "parked on the mix-in first")
        engine.seek(to: 9)
        let moved = await waitUntil(timeout: .seconds(30)) { !engine.debugReparkPending && engine.debugStandbyStartOffset == 0.5 }
        #expect(moved, "standby offset \(engine.debugStandbyStartOffset)")
        #expect(engine.transitionPlan?.incomingStartSec == 0.5)
        engine.play()
        let didFlip = await waitUntil(timeout: .seconds(40)) { engine.isCrossfading }
        #expect(didFlip)
        let incoming = engine.avPlayer.currentTime().seconds
        #expect(incoming < 3, "the incoming song started at \(incoming) s, not deep in the song")
        engine.unload()
    }

    @Test("an end that comes before the re-park landed still starts a drop swap's song at its normal start")
    func endBeforeReparkKeepsNormalStart() async throws {
        let a = try await writeTone("ea", seconds: 4)
        let b = try await writeTone("eb", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.debugHoldReseek = true
        var advanced = false
        engine.onEvent = { event in if case .advanced = event { advanced = true } }
        engine.load(stream("ea", duration: 4, url: a), startAt: 0, autoplay: true)
        engine.preload(stream("eb", duration: 20, url: b), plan: deepDropSwap(mixOut: 3, mixIn: 6, overlap: 4))
        let started = await waitUntil(timeout: .seconds(40)) { advanced || engine.crossfadeCount > 0 }
        #expect(started)
        try await Task.sleep(for: .milliseconds(600))
        let incoming = engine.avPlayer.currentTime().seconds
        #expect(incoming < 3, "the incoming song was at \(incoming) s, not deep in the song")
        #expect(engine.transitionPlan?.incomingStartSec != 6)
        engine.unload()
    }
}
