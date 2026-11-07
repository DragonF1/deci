// DeciTests/Music/BeatSync/AVPlaybackEngineBeatTests.swift
// Tier 3b P3 on the real engine: items keep their pitch at a nudged rate (.spectral), a beat plan schedules the standby
// at its rate, the rate glides back to 1 over play-intent time only, and a seek, a skip or an output change snaps it.
// Tone files, a real DSP chain at 0 gain so nothing is heard.

import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine beat mix")
struct AVPlaybackEngineBeatTests {
    private func writeTone(_ name: String, seconds: Double) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/beat-engine", isDirectory: true)
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

    private func beatPlan(rate: Double = 0.95, mixIn: Double = 2, mixOut: Double = 6, overlap: Double = 2) -> TransitionPlan {
        var plan = TransitionPlan(
            mode: .beat, incomingStartSec: mixIn, outgoingEndSec: mixOut + overlap, fadeStartSec: mixOut,
            fadeSeconds: overlap, incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0,
            outgoingRampSeconds: 0, reason: .ok
        )
        plan.incomingRate = rate
        plan.mixOutSec = mixOut
        plan.mixInSec = mixIn
        plan.overlapBars = 1
        plan.overlapSec = overlap
        plan.barSec = overlap
        plan.glideBackSec = 10
        return plan
    }

    private func makeEngine() -> AVPlaybackEngine {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        return AVPlaybackEngine(chain: chain)
    }

    // MARK: - Pure maths

    @Test("the glide rate is a smoothstep: flat at both ends, monotone, exactly 1 at the end")
    func glideMaths() {
        let from: Float = 0.9524
        #expect(AVPlaybackEngine.glideRate(from: from, elapsed: 0, total: 10) == from)
        #expect(AVPlaybackEngine.glideRate(from: from, elapsed: 10, total: 10) == 1)
        #expect(AVPlaybackEngine.glideRate(from: from, elapsed: 25, total: 10) == 1)
        var previous = from
        for step in 1...100 {
            let rate = AVPlaybackEngine.glideRate(from: from, elapsed: Double(step) * 0.1, total: 10)
            #expect(rate >= previous)
            #expect(rate <= 1)
            previous = rate
        }
        // A rate above 1 comes down monotonically.
        var down: Float = 1.05
        for step in 1...100 {
            let rate = AVPlaybackEngine.glideRate(from: 1.05, elapsed: Double(step) * 0.1, total: 10)
            #expect(rate <= down)
            down = rate
        }
        // Flat start: the first tick barely moves it.
        #expect(abs(AVPlaybackEngine.glideRate(from: from, elapsed: 0.1, total: 10) - from) < 0.0005)
        // Bad input is rate 1, never NaN.
        #expect(AVPlaybackEngine.glideRate(from: .nan, elapsed: 1, total: 10) == 1)
        #expect(AVPlaybackEngine.glideRate(from: from, elapsed: .nan, total: 10) == 1)
        #expect(AVPlaybackEngine.glideRate(from: from, elapsed: 1, total: 0) == 1)
    }

    @Test("the overlap drift is zero on the grid, positive when the incoming deck is ahead")
    func driftMaths() {
        let onGrid = AVPlaybackEngine.overlapDrift(incoming: 12.0 + 0.95 * 2, outgoing: 102, rate: 0.95, mixIn: 12, mixOut: 100)
        #expect(abs(onGrid) < 1e-6)
        let ahead = AVPlaybackEngine.overlapDrift(incoming: 12.0 + 0.95 * 2 + 0.05, outgoing: 102, rate: 0.95, mixIn: 12, mixOut: 100)
        #expect(abs(ahead - 0.05) < 1e-6)
        #expect(AVPlaybackEngine.resumeDriftTolerance == 0.03)
        #expect(AVPlaybackEngine.beatCalibrationSec == -0.007)
        #expect(AVPlaybackEngine.glideTick == 0.1)
    }

    // MARK: - Items

    @Test("every item keeps its pitch at a nudged rate: the active and the standby both carry .spectral")
    func itemsCarrySpectral() async throws {
        let first = try await writeTone("s1", seconds: 8)
        let second = try await writeTone("s2", seconds: 8)
        let engine = makeEngine()
        engine.load(stream("s1", duration: 8, url: first), startAt: 0, autoplay: false)
        engine.preload(stream("s2", duration: 8, url: second))
        let ready = await waitUntil(timeout: .seconds(30)) {
            engine.avPlayer.currentItem != nil && engine.standbyAvPlayer.currentItem != nil
        }
        #expect(ready)
        #expect(engine.avPlayer.currentItem?.audioTimePitchAlgorithm == .spectral)
        #expect(engine.standbyAvPlayer.currentItem?.audioTimePitchAlgorithm == .spectral)
    }

    // MARK: - Schedule

    @Test("a beat plan schedules the standby at the plan's rate, parked on the mix-in, with the grid's fade")
    func beatPlanSchedulesAtRate() async throws {
        let first = try await writeTone("b1", seconds: 10)
        let second = try await writeTone("b2", seconds: 12)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("b1", duration: 10, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("b2", duration: 12, url: second), plan: beatPlan())
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        let parked = engine.standbyAvPlayer.currentTime().seconds
        #expect(abs(parked - 2) < 0.1, "the standby is parked on the mix-in, was \(parked)")
        let scheduled = await waitUntil(timeout: .seconds(30)) { engine.scheduledStartHost != nil }
        #expect(scheduled)
        #expect(abs(engine.debugPlannedRate - 0.95) < 0.0001)
        let standbyRate = engine.standbyAvPlayer.rate
        #expect(abs(standbyRate - 0.95) < 0.001, "the standby was started at the plan's rate, was \(standbyRate)")
        // The scheduled host is the grid's mix-out: about 2 s before the (trimmed) end at 8 s.
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let delta = try #require(engine.scheduledStartHost).seconds - hostNow
        #expect(delta > 0 && delta < 8)
    }

    @Test("a beat plan whose fade is too short for the remaining item gives up the rate: a plain fade at 1")
    func lateBeatPlanRunsAtRateOne() async throws {
        let first = try await writeTone("l1", seconds: 4)
        let second = try await writeTone("l2", seconds: 12)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("l1", duration: 4, url: first), startAt: 0, autoplay: true)
        // The mix-out is 3 s into a 4 s song with a 4 s overlap: the fade does not fit, so the grid is given up.
        engine.preload(stream("l2", duration: 12, url: second), plan: beatPlan(mixIn: 2, mixOut: 3, overlap: 4))
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        _ = await waitUntil(timeout: .seconds(10)) { engine.scheduledStartHost != nil }
        #expect(engine.debugPlannedRate == 1)
    }

    // MARK: - Replan

    @Test("a replan that keeps the mix-in and the rate is accepted, one with another rate is refused")
    func replanRules() async throws {
        let first = try await writeTone("r1", seconds: 30)
        let second = try await writeTone("r2", seconds: 30)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("r1", duration: 30, url: first), startAt: 0, autoplay: false)
        engine.preload(stream("r2", duration: 30, url: second), plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 20, overlap: 4))
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)

        var same = beatPlan(rate: 0.95, mixIn: 2, mixOut: 22, overlap: 4)
        same.overlapBars = 2
        engine.updateTransitionPlan(same)
        #expect(engine.transitionPlan?.mixOutSec == 22, "a later mix-out with the same mix-in and rate is adopted")

        var other = beatPlan(rate: 0.97, mixIn: 2, mixOut: 24, overlap: 4)
        other.overlapBars = 3
        engine.updateTransitionPlan(other)
        #expect(engine.transitionPlan?.mixOutSec == 22, "a different rate is refused")
        #expect(engine.transitionPlan?.incomingRate == 0.95)

        let moved = beatPlan(rate: 0.95, mixIn: 5, mixOut: 24, overlap: 4)
        engine.updateTransitionPlan(moved)
        #expect(engine.transitionPlan?.mixOutSec == 22, "a different mix-in is refused")
    }

    // MARK: - Glide

    @Test("the glide steps from r to 1 monotonically and is over within 10 s of play intent")
    func glideSteps() async throws {
        let first = try await writeTone("g1", seconds: 4)
        let engine = makeEngine()
        engine.load(stream("g1", duration: 4, url: first), startAt: 0, autoplay: false)
        engine.debugSetWantsPlay(true)
        engine.debugStartGlide(from: 0.95, over: 10)
        var previous: Float = 0.95
        var steps = 0
        while let rate = engine.debugGlideCurrentRate {
            #expect(rate >= previous)
            #expect(rate <= 1)
            previous = rate
            engine.debugAdvanceGlide(by: AVPlaybackEngine.glideTick)
            steps += 1
            if steps > 200 { break }
        }
        #expect(engine.debugGlide == nil)
        #expect(steps >= 99 && steps <= 101, "10 s in 100 ms steps, was \(steps)")
        engine.unload()
    }

    @Test("a pause holds the glide where it is, and a resume carries on from there")
    func pauseHoldsGlide() async throws {
        let first = try await writeTone("p1", seconds: 4)
        let engine = makeEngine()
        engine.load(stream("p1", duration: 4, url: first), startAt: 0, autoplay: false)
        engine.debugSetWantsPlay(true)
        engine.debugStartGlide(from: 0.95, over: 10)
        for _ in 0..<30 { engine.debugAdvanceGlide(by: 0.1) }
        let held = try #require(engine.debugGlide)
        #expect(abs(held.elapsed - 3.0) < 0.001)
        engine.pause()
        for _ in 0..<50 { engine.debugAdvanceGlide(by: 0.1) }
        #expect(engine.debugGlide == held, "paused ticks do not count")
        engine.debugSetWantsPlay(true)
        engine.debugAdvanceGlide(by: 0.1)
        #expect(abs((engine.debugGlide?.elapsed ?? 0) - 3.1) < 0.001)
        engine.unload()
    }

    @Test("a seek, a skip, an output change and an unload each snap the glide to 1")
    func snapsToOne() async throws {
        let first = try await writeTone("n1", seconds: 6)
        let engine = makeEngine()
        engine.load(stream("n1", duration: 6, url: first), startAt: 0, autoplay: false)
        let loaded = await waitUntil(timeout: .seconds(30)) { engine.avPlayer.currentItem?.status == .readyToPlay }
        #expect(loaded)
        engine.debugSetWantsPlay(true)

        engine.debugStartGlide(from: 0.95, over: 10)
        #expect(engine.debugGlide != nil)
        engine.seek(to: 1)
        #expect(engine.debugGlide == nil, "seek")

        engine.debugStartGlide(from: 0.95, over: 10)
        engine.setOutputDevice(uid: nil)
        #expect(engine.debugGlide == nil, "output change")

        engine.debugStartGlide(from: 0.95, over: 10)
        engine.debugSetBeatOverlap(AVPlaybackEngine.BeatOverlap(rate: 0.95, mixIn: 2, mixOut: 6, glideSeconds: 10))
        engine.unload()
        #expect(engine.debugGlide == nil, "skip")
        #expect(engine.debugBeatOverlap == nil)
    }

    @Test("a rate that is already 1 starts no glide")
    func noGlideAtRateOne() async throws {
        let first = try await writeTone("z1", seconds: 4)
        let engine = makeEngine()
        engine.load(stream("z1", duration: 4, url: first), startAt: 0, autoplay: false)
        engine.debugStartGlide(from: 1, over: 10)
        #expect(engine.debugGlide == nil)
        engine.debugStartGlide(from: 0.95, over: 0)
        #expect(engine.debugGlide == nil)
        engine.unload()
    }

    @Test("a plan that is not a beat plan (a manual skip's) is accepted on a beat preload, at the same park offset")
    func skipPlanIsAccepted() async throws {
        let first = try await writeTone("k1", seconds: 30)
        let second = try await writeTone("k2", seconds: 30)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("k1", duration: 30, url: first), startAt: 0, autoplay: false)
        engine.preload(stream("k2", duration: 30, url: second), plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 20, overlap: 4))
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        let skip = TransitionPlan(
            mode: .fixed, incomingStartSec: 2, outgoingEndSec: nil, fadeStartSec: nil, fadeSeconds: 0.3,
            incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok
        )
        engine.updateTransitionPlan(skip)
        #expect(engine.transitionPlan?.mode == .fixed)
        #expect(engine.transitionPlan?.incomingRate == 1)
        // A beat plan with another rate is still refused.
        engine.updateTransitionPlan(beatPlan(rate: 0.97, mixIn: 2, mixOut: 20, overlap: 4))
        #expect(engine.transitionPlan?.mode == .fixed)
    }

    @Test("a pause stops the glide's ticker and a play starts it again from where it was held")
    func pauseStopsGlideTicker() async throws {
        let first = try await writeTone("t1", seconds: 8)
        let engine = makeEngine()
        engine.load(stream("t1", duration: 8, url: first), startAt: 0, autoplay: false)
        let loaded = await waitUntil(timeout: .seconds(30)) { engine.avPlayer.currentItem?.status == .readyToPlay }
        #expect(loaded)
        engine.debugSetWantsPlay(true)
        engine.debugStartGlide(from: 0.95, over: 10)
        #expect(engine.debugGlideTicking)
        engine.pause()
        #expect(!engine.debugGlideTicking, "no ticker while paused")
        let held = engine.debugGlide
        try await Task.sleep(for: .milliseconds(350))
        #expect(engine.debugGlide == held)
        engine.play()
        #expect(engine.debugGlideTicking, "the held glide ticks again")
        let moved = await waitUntil(timeout: .seconds(5)) { (engine.debugGlide?.elapsed ?? 0) > 0.15 }
        #expect(moved)
        engine.unload()
    }

    /// Plays A into B on a real beat overlap and returns once the flip has happened.
    private func overlapEngine() async throws -> AVPlaybackEngine {
        let first = try await writeTone("ra", seconds: 16)
        let second = try await writeTone("rb", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("ra", duration: 16, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("rb", duration: 20, url: second), plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 5, overlap: 8))
        let flipped = await waitUntil(timeout: .seconds(40)) { engine.isCrossfading && engine.debugBeatOverlap != nil }
        #expect(flipped)
        try await Task.sleep(for: .milliseconds(600))
        return engine
    }

    private func drift(_ engine: AVPlaybackEngine, rate: Float = 0.95) -> Double {
        let incoming = engine.avPlayer.currentTime().seconds
        let outgoing = engine.debugDrainingPlayer?.currentTime().seconds ?? .nan
        return AVPlaybackEngine.overlapDrift(incoming: incoming, outgoing: outgoing, rate: rate, mixIn: 2, mixOut: 5)
    }

    @Test("pause then play in a beat overlap does not trap: both decks restart at their rates, the flag is off, and it is restored after the drain")
    func resumeInOverlap() async throws {
        let engine = try await overlapEngine()
        engine.pause()
        #expect(engine.avPlayer.rate == 0)
        engine.play()
        let restarted = await waitUntil(timeout: .seconds(5)) { abs(engine.avPlayer.rate - 0.95) < 0.001 }
        #expect(restarted, "incoming rate \(engine.avPlayer.rate)")
        #expect(abs((engine.debugDrainingPlayer?.rate ?? 0) - 1) < 0.001)
        #expect(!engine.avPlayer.automaticallyWaitsToMinimizeStalling)
        #expect(engine.debugBeatOverlap != nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(abs(drift(engine)) < 0.06, "drift after a short pause \(drift(engine))")
        let drained = await waitUntil(timeout: .seconds(30)) { !engine.isCrossfading }
        #expect(drained)
        #expect(engine.avPlayer.automaticallyWaitsToMinimizeStalling, "restored once the glide starts")
        engine.unload()
    }

    @Test("a resume that finds the incoming deck more than 30 ms off the grid puts it back before restarting")
    func resumeSnapsOverDriftTolerance() async throws {
        let engine = try await overlapEngine()
        engine.pause()
        let now = engine.avPlayer.currentTime().seconds
        await engine.avPlayer.seek(to: CMTime(seconds: now + 1.0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(abs(drift(engine)) > 0.1, "set up: the incoming deck is ahead")
        engine.play()
        let restarted = await waitUntil(timeout: .seconds(5)) { abs(engine.avPlayer.rate - 0.95) < 0.001 }
        #expect(restarted)
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(drift(engine)) < 0.06, "drift after the snap \(drift(engine))")
        engine.unload()
    }
}
