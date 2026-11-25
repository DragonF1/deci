// DeciTests/Music/BeatSync/AVPlaybackEngineBeatTests.swift
// Tier 3b P3 on the real engine: items keep their pitch at a nudged rate (.spectral), a beat plan schedules the standby
// at rate 1 whatever rate the plan says (wjyijr: every song plays at its own tempo, no glide, no rate write while a deck
// plays), and a skip resets it.
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

    private func beatPlan(rate: Double = 0.95, mixIn: Double = 2, mixOut: Double = 6, overlap: Double = 2, swapAt: Double? = nil, handover: Double = 0, smartStart: Double? = nil) -> TransitionPlan {
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
        plan.bassSwapAtSec = swapAt
        plan.bassHandoverSec = handover
        plan.fallbackIncomingStartSec = smartStart
        return plan
    }

    private func makeEngine() -> AVPlaybackEngine {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        return AVPlaybackEngine(chain: chain)
    }

    // MARK: - Pure maths

    @Test("the overlap drift is zero on the grid, positive when the incoming deck is ahead")
    func driftMaths() {
        let onGrid = AVPlaybackEngine.overlapDrift(incoming: 12.0 + 0.95 * 2, outgoing: 102, rate: 0.95, mixIn: 12, mixOut: 100)
        #expect(abs(onGrid) < 1e-6)
        let ahead = AVPlaybackEngine.overlapDrift(incoming: 12.0 + 0.95 * 2 + 0.05, outgoing: 102, rate: 0.95, mixIn: 12, mixOut: 100)
        #expect(abs(ahead - 0.05) < 1e-6)
        #expect(AVPlaybackEngine.resumeDriftTolerance == 0.03)
        #expect(AVPlaybackEngine.beatCalibrationSec == -0.007)
        // Two different deck rates: the incoming deck's rate relative to the outgoing one's decides the drift.
        let relative = AVPlaybackEngine.overlapDrift(incoming: 12.0 + (0.95 / 1.05) * 2, outgoing: 102, rate: Float(0.95 / 1.05), mixIn: 12, mixOut: 100)
        #expect(abs(relative) < 1e-5)
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

    @Test("a beat plan with a rate of 0.95 schedules the standby at exactly 1, parked on the mix-in, with the grid's fade")
    func beatPlanSchedulesAtRateOne() async throws {
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
        #expect(engine.debugPlannedRate == 1, "planned rate was \(engine.debugPlannedRate)")
        let standbyRate = engine.standbyAvPlayer.rate
        #expect(standbyRate == 1, "the standby was started at \(standbyRate), not at the plan's 0.95")
        #expect(AVPlaybackEngine.beatStartRate == 1)
        // The scheduled host is the grid's mix-out: about 2 s before the (trimmed) end at 8 s.
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let delta = try #require(engine.scheduledStartHost).seconds - hostNow
        #expect(delta > 0 && delta < 8)
    }

    @Test("a beat plan at 0.99998 starts the standby at exactly 1: a rate change opens a gap in the output")
    func nearOnePlanRateStartsAtExactlyOne() async throws {
        let first = try await writeTone("n1", seconds: 10)
        let second = try await writeTone("n2", seconds: 12)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("n1", duration: 10, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("n2", duration: 12, url: second), plan: beatPlan(rate: 0.99998))
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        let scheduled = await waitUntil(timeout: .seconds(30)) { engine.scheduledStartHost != nil }
        #expect(scheduled)
        #expect(engine.debugPlannedRate == 1, "planned rate was \(engine.debugPlannedRate)")
        #expect(engine.standbyAvPlayer.rate == 1, "the standby was started at \(engine.standbyAvPlayer.rate)")
        engine.unload()
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
        #expect(engine.transitionPlan?.incomingRate == 0.95, "the held plan keeps its own rate, the engine plays it at 1")

        let moved = beatPlan(rate: 0.95, mixIn: 5, mixOut: 24, overlap: 4)
        engine.updateTransitionPlan(moved)
        #expect(engine.transitionPlan?.mixOutSec == 22, "a different mix-in is refused")
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

    /// Plays A into B on a real beat overlap and returns once the flip has happened.
    private func overlapEngine(swapAt: Double? = nil, handover: Double = 0) async throws -> AVPlaybackEngine {
        let first = try await writeTone("ra", seconds: 16)
        let second = try await writeTone("rb", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("ra", duration: 16, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("rb", duration: 20, url: second), plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 5, overlap: 8, swapAt: swapAt, handover: handover))
        let flipped = await waitUntil(timeout: .seconds(40)) { engine.isCrossfading && engine.debugBeatOverlap != nil }
        #expect(flipped)
        try await Task.sleep(for: .milliseconds(600))
        return engine
    }

    private func drift(_ engine: AVPlaybackEngine, rate: Float = 1) -> Double {
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
        let restarted = await waitUntil(timeout: .seconds(5)) { abs(engine.avPlayer.rate - 1) < 0.001 }
        #expect(restarted, "incoming rate \(engine.avPlayer.rate)")
        #expect(abs((engine.debugDrainingPlayer?.rate ?? 0) - 1) < 0.001)
        #expect(!engine.avPlayer.automaticallyWaitsToMinimizeStalling)
        #expect(engine.debugBeatOverlap != nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(abs(drift(engine)) < 0.06, "drift after a short pause \(drift(engine))")
        let drained = await waitUntil(timeout: .seconds(30)) { !engine.isCrossfading }
        #expect(drained)
        #expect(engine.avPlayer.automaticallyWaitsToMinimizeStalling, "restored once the overlap is over")
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
        let restarted = await waitUntil(timeout: .seconds(5)) { abs(engine.avPlayer.rate - 1) < 0.001 }
        #expect(restarted)
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(drift(engine)) < 0.06, "drift after the snap \(drift(engine))")
        engine.unload()
    }

    // MARK: - Bass swap (3b P4)

    @Test("a beat plan with a bass swap drives the lease channels: the outgoing deck holds 1 and hands over, the incoming holds 0")
    func bassSwapDrivesLeases() async throws {
        let engine = try await overlapEngine(swapAt: 4, handover: 1)
        #expect(engine.debugBassSwapActive)
        let outgoing = try #require(engine.debugDrainingTap?.debugBass)
        let incoming = try #require(engine.debugActiveTap?.debugBass)
        #expect(outgoing.active && incoming.active)
        #expect(outgoing.initial == 1 && outgoing.target == 0)
        #expect(incoming.initial == 0 && incoming.target == 1)
        let rate = engine.debugActiveTap?.debugLeaseRate ?? 0
        #expect(rate > 0)
        // Both swap 4 s into what is heard of the overlap: sooner in rendered audio by what each deck has rendered ahead
        // (at least the time pitch's 4096 frames), later by the start gap (up to 0.25 s).
        for (deck, delay) in [("outgoing", outgoing.delayFrames), ("incoming", incoming.delayFrames)] {
            let seconds = Double(delay) / rate
            #expect(seconds > 1 && seconds <= 4.25, "\(deck) waits \(seconds) s")
        }
        // The decks agree: the same start gap, and the same output in front of them, give or take a start gap of each.
        #expect(abs(outgoing.delayFrames - incoming.delayFrames) <= Int(0.3 * rate))
        #expect(outgoing.rampFrames == Int((1 * rate).rounded()) && incoming.rampFrames == outgoing.rampFrames)
        engine.unload()
    }

    @Test("a gridless floor plan (rate 1, no bars, no glide, a bass swap) plays through the beat path with the bass swap")
    func gridlessFloorPlanRunsTheBeatPath() async throws {
        let first = try await writeTone("fa", seconds: 24)
        let second = try await writeTone("fb", seconds: 30)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("fa", duration: 24, url: first), startAt: 0, autoplay: true)
        // The shape MusicBeatPlanner.floorBlendPlan builds: bars 0, bar length 0, no glide, an 8 s overlap, the bass at the
        // middle for 2 s, no tempo change.
        var plan = beatPlan(rate: 1, mixIn: 0, mixOut: 4, overlap: 8, swapAt: 4, handover: 2)
        plan.overlapBars = 0
        plan.barSec = 0
        engine.preload(stream("fb", duration: 30, url: second), plan: plan)
        let flipped = await waitUntil(timeout: .seconds(40)) { engine.isCrossfading && engine.debugBeatOverlap != nil }
        #expect(flipped, "a gridless beat plan must take the beat path")
        try await Task.sleep(for: .milliseconds(600))
        #expect(engine.debugBassSwapActive)
        let outgoing = try #require(engine.debugDrainingTap?.debugBass)
        let incoming = try #require(engine.debugActiveTap?.debugBass)
        #expect(outgoing.active && incoming.active)
        #expect(outgoing.initial == 1 && outgoing.target == 0 && incoming.initial == 0 && incoming.target == 1)
        #expect(abs(engine.avPlayer.rate - 1) < 0.001)
        engine.unload()
    }

    @Test("a plan without a swap leaves the bass channels off")
    func noSwapNoChannels() async throws {
        let engine = try await overlapEngine()
        #expect(!engine.debugBassSwapActive)
        #expect(engine.debugDrainingTap?.debugBass?.active != true)
        #expect(engine.debugActiveTap?.debugBass?.active != true)
        engine.unload()
    }

    @Test("when the overlap ends the channels are off again on both decks")
    func bassSwapEndsWithTheDrain() async throws {
        let engine = try await overlapEngine(swapAt: 4, handover: 1)
        let drained = await waitUntil(timeout: .seconds(30)) { !engine.isCrossfading }
        #expect(drained)
        #expect(!engine.debugBassSwapActive)
        #expect(engine.debugActiveTap?.debugBass?.active != true)
        #expect(engine.debugStandbyTap?.debugBass?.active != true)
        engine.unload()
    }

    @Test("a cancelled schedule leaves no bass channel behind on the standby deck")
    func cancelResetsBass() async throws {
        let first = try await writeTone("ca", seconds: 16)
        let second = try await writeTone("cb", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("ca", duration: 16, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("cb", duration: 20, url: second), plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 12, overlap: 2, swapAt: 1, handover: 0.5))
        engine.cancelPreload()
        #expect(!engine.debugBassSwapActive)
        #expect(engine.debugStandbyTap?.debugBass?.active != true)
        engine.unload()
    }

    @Test("a seek in the middle of the swap ends the drain fast and leaves both channels off")
    func seekMidSwapResets() async throws {
        let engine = try await overlapEngine(swapAt: 4, handover: 1)
        #expect(engine.debugBassSwapActive)
        engine.seek(to: 5)
        let drained = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(drained)
        #expect(!engine.debugBassSwapActive)
        #expect(engine.debugActiveTap?.debugBass?.active != true)
        engine.unload()
    }

    // MARK: - Tap ordering (3b P4 review)

    @Test("the incoming lease renders SR frames per wall second: the tap sits downstream of time-pitch, so no rate scaling")
    func tapCountsOutputFrames() async throws {
        let engine = try await overlapEngine()
        let tap = try #require(engine.debugActiveTap)
        let sampleRate = try #require(tap.debugLeaseRate)
        let start = try #require(tap.debugRenderedFrames)
        let began = ContinuousClock.now
        try await Task.sleep(for: .seconds(3))
        let end = try #require(tap.debugRenderedFrames)
        let wall = (ContinuousClock.now - began) / .seconds(1)
        let perSecond = Double(end - start) / wall / sampleRate
        print("TAPORDER frames per wall second / SR at rate 1 = \(perSecond)")
        #expect(abs(engine.avPlayer.rate - 1) < 0.001, "set up: the incoming deck runs at 1, whatever the plan says")
        #expect(abs(perSecond - 1) < 0.02, "measured \(perSecond): output frames per wall second are SR")
        engine.unload()
    }

    @Test("the render lead is the head past the clock plus the time pitch's delay, none when the head makes no sense")
    func renderLeadMaths() throws {
        let pitch = 4_096.0 / 44_100
        let speakers = try #require(AVPlaybackEngine.renderLead(head: 60.02, now: 60, rate: 1, sampleRate: 44_100))
        #expect(abs(speakers - 0.02 - pitch) < 1e-9)
        let bluetooth = try #require(AVPlaybackEngine.renderLead(head: 60.14, now: 60, rate: 1, sampleRate: 44_100))
        #expect(abs(bluetooth - 0.14 - pitch) < 1e-9)
        // The clock can pass the label by a buffer, never the audio.
        let behind = try #require(AVPlaybackEngine.renderLead(head: 59.95, now: 60, rate: 1, sampleRate: 48_000))
        #expect(behind >= 0 && behind < 0.09)
        #expect(AVPlaybackEngine.renderLead(head: 20, now: 60, rate: 1, sampleRate: 44_100) == nil, "a head from before a seek")
        #expect(AVPlaybackEngine.renderLead(head: 90, now: 60, rate: 1, sampleRate: 44_100) == nil)
        #expect(AVPlaybackEngine.renderLead(head: .nan, now: 60, rate: 1, sampleRate: 44_100) == nil)
        #expect(AVPlaybackEngine.renderLead(head: 60, now: .nan, rate: 1, sampleRate: 44_100) == nil)
        #expect(AVPlaybackEngine.renderLead(head: 60, now: 60, rate: 0, sampleRate: 44_100) == nil)
    }

    @Test("the start gap is the scheduled host less now, fadeLead without a schedule, clamped to [0, 0.25]")
    func startGapMaths() {
        let now = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
        func gap(_ host: Double?) -> Double {
            AVPlaybackEngine.startGap(scheduledHost: host.map { CMTime(seconds: $0, preferredTimescale: 1_000_000_000) }, now: now)
        }
        #expect(abs(gap(100.04) - 0.04) < 1e-6)
        #expect(gap(nil) == 0.05)
        #expect(gap(99) == 0)
        #expect(gap(110) == 0.25)
        #expect(AVPlaybackEngine.startGap(scheduledHost: .invalid, now: now) == 0.05)
    }

    // MARK: - Beat fallback starts at the smart start

    private func standbyTime(_ engine: AVPlaybackEngine) -> Double { engine.standbyAvPlayer.currentTime().seconds }

    /// A late beat plan (the fade does not fit what is left of a 4 s song) with the smart start at 0.5 s.
    private func lateEngine(chain: Bool = true, name: String = "f") async throws -> AVPlaybackEngine {
        let first = try await writeTone(name + "1", seconds: 4)
        let second = try await writeTone(name + "2", seconds: 12)
        let engine = chain ? makeEngine() : AVPlaybackEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream(name + "1", duration: 4, url: first), startAt: 0, autoplay: true)
        engine.preload(stream(name + "2", duration: 12, url: second), plan: beatPlan(mixIn: 2, mixOut: 3, overlap: 4, smartStart: 0.5))
        return engine
    }

    @Test("a late beat plan re-parks the standby on the smart start, not the mix-in")
    func lateFallbackStartsAtSmartStart() async throws {
        let engine = try await lateEngine()
        let moved = await waitUntil(timeout: .seconds(30)) { engine.debugBeatGivenUp && !engine.debugReparkPending && abs(self.standbyTime(engine) - 0.5) < 0.05 }
        #expect(moved, "standby at \(standbyTime(engine)), given up \(engine.debugBeatGivenUp)")
        #expect(engine.transitionPlan?.incomingStartSec == 0.5)
        #expect(engine.debugStandbyStartOffset == 0.5)
        engine.unload()
    }

    @Test("a beat plan with no lease on a deck re-parks the standby on the smart start")
    func noLeaseFallbackStartsAtSmartStart() async throws {
        let engine = try await lateEngine(chain: false, name: "n")
        let moved = await waitUntil(timeout: .seconds(30)) { engine.debugBeatGivenUp && !engine.debugReparkPending && abs(self.standbyTime(engine) - 0.5) < 0.05 }
        #expect(moved, "standby at \(standbyTime(engine)), given up \(engine.debugBeatGivenUp)")
        #expect(engine.transitionPlan?.incomingStartSec == 0.5)
        engine.unload()
    }

    @Test("a play that starts right on the lead (too close to move) re-parks the standby on the smart start")
    func tooCloseFallbackStartsAtSmartStart() async throws {
        let first = try await writeTone("t1", seconds: 8)
        let second = try await writeTone("t2", seconds: 12)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("t1", duration: 8, url: first), startAt: 4.97, autoplay: false)
        engine.preload(stream("t2", duration: 12, url: second), plan: beatPlan(mixIn: 2, mixOut: 5, overlap: 2, smartStart: 0.5))
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        engine.play()
        let moved = await waitUntil(timeout: .seconds(30)) { engine.debugBeatGivenUp && !engine.debugReparkPending && abs(self.standbyTime(engine) - 0.5) < 0.05 }
        #expect(moved, "standby at \(standbyTime(engine)), given up \(engine.debugBeatGivenUp)")
        engine.unload()
    }

    @Test("a re-park seek that fails puts the standby back on the mix-in, and the start goes ahead from there")
    func failedReseekKeepsMixIn() async throws {
        let first = try await writeTone("r1", seconds: 4)
        let second = try await writeTone("r2", seconds: 12)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.debugFailNextReseek = true
        engine.load(stream("r1", duration: 4, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("r2", duration: 12, url: second), plan: beatPlan(mixIn: 2, mixOut: 3, overlap: 4, smartStart: 0.5))
        let reverted = await waitUntil(timeout: .seconds(30)) { engine.debugBeatGivenUp && !engine.debugReparkPending && engine.debugStandbyStartOffset == 2 }
        #expect(reverted, "offset \(engine.debugStandbyStartOffset)")
        #expect(engine.transitionPlan?.incomingStartSec == 2)
        engine.unload()
    }

    @Test("the item ending before the re-park lands starts the next song from the mix-in")
    func endBeforeReseekStartsAtMixIn() async throws {
        let engine = try await lateEngineHeld()
        let held = await waitUntil(timeout: .seconds(30)) { engine.debugBeatGivenUp && engine.debugReparkPending && engine.preloadIsReady }
        #expect(held)
        engine.debugActiveItemEnded()
        #expect(!engine.debugReparkPending)
        let there = await waitUntil(timeout: .seconds(10)) { engine.avPlayer.currentTime().seconds >= 1.9 }
        #expect(there, "next song at \(engine.avPlayer.currentTime().seconds)")
        #expect(engine.avPlayer.currentTime().seconds < 3)
        engine.unload()
    }

    @Test("an end before the mix-out starts a song that was parked past its intro from its plain start")
    func endBeforeDeepEntryStartsPlain() async throws {
        let first = try await writeTone("de1", seconds: 14)
        let second = try await writeTone("de2", seconds: 16)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("de1", duration: 14, url: first), startAt: 0, autoplay: true)
        let plan = beatPlan(mixIn: 8, mixOut: 11, overlap: 2, smartStart: 0.5)
        #expect(plan.entersDeep)
        engine.preload(stream("de2", duration: 16, url: second), plan: plan)
        let parked = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady && abs(engine.standbyAvPlayer.currentTime().seconds - 8) < 0.1 }
        #expect(parked, "standby at \(engine.standbyAvPlayer.currentTime().seconds)")
        engine.debugActiveItemEnded()
        let there = await waitUntil(timeout: .seconds(10)) {
            let now = engine.avPlayer.currentTime().seconds
            return engine.avPlayer.rate > 0 && now >= 0.4 && now < 4
        }
        #expect(there, "next song at \(engine.avPlayer.currentTime().seconds)")
        engine.unload()
    }

    @Test("an end while the re-park of such a song is on its way starts it from its plain start too")
    func endBeforeDeepReseekStartsPlain() async throws {
        let engine = try await lateEngineHeld(mixIn: 8)
        let held = await waitUntil(timeout: .seconds(30)) { engine.debugBeatGivenUp && engine.debugReparkPending && engine.preloadIsReady }
        #expect(held)
        engine.debugActiveItemEnded()
        #expect(!engine.debugReparkPending)
        let there = await waitUntil(timeout: .seconds(10)) {
            let now = engine.avPlayer.currentTime().seconds
            return engine.avPlayer.rate > 0 && now >= 0.4 && now < 4
        }
        #expect(there, "next song at \(engine.avPlayer.currentTime().seconds)")
        engine.unload()
    }

    @Test("a seek near the trimmed end takes a song that was parked past its intro back to its plain start")
    func seekNearEndReparksDeepEntry() async throws {
        let first = try await writeTone("ds1", seconds: 30)
        let second = try await writeTone("ds2", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("ds1", duration: 30, url: first), startAt: 0, autoplay: true)
        let plan = beatPlan(mixIn: 8, mixOut: 17, overlap: 3, smartStart: 0.5)
        #expect(plan.entersDeep && plan.djSection == nil)
        engine.preload(stream("ds2", duration: 20, url: second), plan: plan)
        let parked = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady && abs(engine.standbyAvPlayer.currentTime().seconds - 8) < 0.1 }
        #expect(parked, "standby at \(engine.standbyAvPlayer.currentTime().seconds)")
        engine.seek(to: 18.5)
        let plain = await waitUntil(timeout: .seconds(10)) { abs(engine.standbyAvPlayer.currentTime().seconds - 0.5) < 0.1 }
        #expect(plain, "standby at \(engine.standbyAvPlayer.currentTime().seconds)")
        engine.unload()
    }

    private func lateEngineHeld(mixIn: Double = 2) async throws -> AVPlaybackEngine {
        let first = try await writeTone("h1", seconds: 4)
        let second = try await writeTone("h2", seconds: 12)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.debugHoldReseek = true
        engine.load(stream("h1", duration: 4, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("h2", duration: 12, url: second), plan: beatPlan(mixIn: mixIn, mixOut: 3, overlap: 4, smartStart: 0.5))
        return engine
    }

    @Test("a beat plan that runs normally keeps its mix-in park and never gives the grid up")
    func normalBeatPlanUnchanged() async throws {
        let engine = try await overlapEngine()
        #expect(!engine.debugBeatGivenUp)
        #expect(!engine.debugReparkPending)
        #expect(engine.debugBeatOverlap != nil)
        engine.unload()
    }

    // MARK: - What the flip builds follows what was scheduled (review fixes)

    @Test("beatStartRate is the constant 1, whatever the plan's rate; isUnityRate reads a Float rate against 1")
    func beatStartRateIsOne() {
        #expect(AVPlaybackEngine.beatStartRate == 1)
        #expect(AVPlaybackEngine.isUnityRate(AVPlaybackEngine.beatStartRate))
        #expect(AVPlaybackEngine.isUnityRate(1))
        #expect(!AVPlaybackEngine.isUnityRate(0.9999))
    }

    @Test("a plan rate of 0.9996 is scheduled at 1 too: no plan rate is ever started")
    func smallNudgeStartsAtOne() async throws {
        let first = try await writeTone("sn1", seconds: 16)
        let second = try await writeTone("sn2", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("sn1", duration: 16, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("sn2", duration: 20, url: second), plan: beatPlan(rate: 0.9996, mixIn: 2, mixOut: 5, overlap: 8))
        let scheduled = await waitUntil(timeout: .seconds(40)) { engine.scheduledStartHost != nil }
        #expect(scheduled)
        #expect(engine.debugPlannedRate == 1, "planned \(engine.debugPlannedRate)")
        #expect(await waitUntil(timeout: .seconds(10)) { engine.debugPlannedBeat })
        engine.unload()
    }

    /// Waits for the flip of a prepared engine, then returns what it built (the overlap) at that moment.
    private func awaitFlip(_ engine: AVPlaybackEngine) async -> Bool {
        await waitUntil(timeout: .seconds(40)) { engine.isCrossfading }
    }

    /// The overlap is over: the deck runs at exactly 1 or is in the glide (no lone rate set), with the outcome reported.
    private func awaitDrain(_ engine: AVPlaybackEngine) async -> Bool {
        await waitUntil(timeout: .seconds(40)) { !engine.isCrossfading }
    }

    private func preparedEngine(
        plan: TransitionPlan, firstSeconds: Double = 16, name: String
    ) async throws -> AVPlaybackEngine {
        let first = try await writeTone(name + "a", seconds: firstSeconds)
        let second = try await writeTone(name + "b", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream(name + "a", duration: firstSeconds, url: first), startAt: 0, autoplay: true)
        engine.preload(stream(name + "b", duration: 20, url: second), plan: plan)
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        return engine
    }

    @Test("a beat plan whose rate is 0.95: the flip keeps the overlap at rate 1, the swap runs, the deck stays at 1 after the drain")
    func flipRunsBeatAtRateOne() async throws {
        let engine = try await preparedEngine(plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 5, overlap: 8, swapAt: 4, handover: 1), name: "fn")
        #expect(await awaitFlip(engine))
        #expect(engine.debugBeatOverlap?.rate == 1)
        #expect(engine.debugBassSwapActive)
        #expect(abs(engine.avPlayer.rate - 1) < 0.001)
        #expect(await awaitDrain(engine))
        #expect(engine.deckRate == 1)
        #expect(abs(engine.avPlayer.rate - 1) < 0.001, "the rate is kept after the overlap, was \(engine.avPlayer.rate)")
        #expect(engine.debugBeatOverlap == nil)
        engine.unload()
    }

    private func equalizedPlan() -> TransitionPlan {
        var plan = beatPlan(rate: 1, mixIn: 2, mixOut: 5, overlap: 8, swapAt: 3.5, handover: 0.5)
        plan.mixEQ = MusicMixEQPlan(
            incomingMid: [.init(at: 1, gain: 0.35), .init(at: 4, gain: 1)],
            outgoingMid: [.init(at: 3, gain: 1), .init(at: 5, gain: 0.5)],
            outgoingHigh: [.init(at: 4, gain: 1), .init(at: 6, gain: 0.4)]
        )
        return plan
    }

    @Test("a plan's EQ moves start on both decks at the flip and are over, with the incoming deck open, after the drain")
    func mixEQRunsWithTheOverlap() async throws {
        let engine = try await preparedEngine(plan: equalizedPlan(), name: "eq")
        #expect(await awaitFlip(engine))
        #expect(engine.debugMixEQActive)
        let incoming = try #require(engine.debugActiveTap?.debugMixEQ)
        let outgoing = try #require(engine.debugDrainingTap?.debugMixEQ)
        #expect(incoming.active && incoming.settings.mid.map(\.gain) == [0.35, 1] && incoming.settings.high.isEmpty)
        #expect(outgoing.active && outgoing.settings.mid.map(\.gain) == [1, 0.5] && outgoing.settings.high.map(\.gain) == [1, 0.4])
        // Each deck's moves are shifted whole, by what it has rendered ahead of what is heard.
        let rate = try #require(engine.debugActiveTap?.debugLeaseRate)
        let spread = Double(outgoing.settings.mid[1].frame - outgoing.settings.mid[0].frame) / rate
        #expect(abs(spread - 2) < 0.01, "outgoing moves \(spread) s apart")
        let first = Double(incoming.settings.mid[1].frame) / rate
        #expect(first > 1 && first <= 4.01, "incoming's last move \(first) s on")
        #expect(await awaitDrain(engine))
        #expect(!engine.debugMixEQActive)
        #expect(engine.debugActiveTap?.debugMixEQ?.releases == 1)
        engine.unload()
    }

    @Test("a seek in the overlap opens the incoming deck's EQ within the quick drain")
    func mixEQEndsWithASeek() async throws {
        let engine = try await preparedEngine(plan: equalizedPlan(), name: "es")
        #expect(await awaitFlip(engine))
        try await Task.sleep(for: .milliseconds(400))
        engine.seek(to: 10)
        let released = await waitUntil(timeout: .seconds(5)) { (engine.debugActiveTap?.debugMixEQ?.releases ?? 0) >= 1 }
        #expect(released)
        #expect(await awaitDrain(engine))
        #expect(!engine.debugMixEQActive)
        engine.unload()
    }

    @Test("a plan given up by a seek into its end runs no EQ")
    func mixEQNotOnAPlainFade() async throws {
        let engine = try await preparedEngine(plan: equalizedPlan(), name: "ep")
        engine.seek(to: 11.5)
        #expect(await awaitFlip(engine))
        #expect(!engine.debugMixEQActive && engine.debugActiveTap?.debugMixEQ?.active != true)
        #expect(await awaitDrain(engine))
        engine.unload()
    }

    @Test("a near-1 plan (0.99998) keeps its overlap at rate 1: a shared-host resume, the swap, and no glide and no rate set after the drain")
    func flipKeepsNearOneBeatAtRateOne() async throws {
        let engine = try await preparedEngine(plan: beatPlan(rate: 0.99998, mixIn: 2, mixOut: 5, overlap: 8, swapAt: 4, handover: 1), name: "f1")
        #expect(await waitUntil(timeout: .seconds(10)) { engine.debugPlannedBeat })
        #expect(engine.debugPlannedRate == 1)
        #expect(await awaitFlip(engine))
        let overlap = try #require(engine.debugBeatOverlap, "a beat overlap at rate 1 is still an overlap")
        #expect(overlap.rate == 1)
        #expect(engine.debugBassSwapActive)
        // A pause and a resume in the middle: both decks restart at rate 1 on one host time.
        try await Task.sleep(for: .milliseconds(600))
        engine.pause()
        #expect(engine.avPlayer.rate == 0)
        engine.play()
        let restarted = await waitUntil(timeout: .seconds(5)) { engine.avPlayer.rate == 1 && engine.debugDrainingPlayer?.rate == 1 }
        #expect(restarted, "incoming \(engine.avPlayer.rate), outgoing \(engine.debugDrainingPlayer?.rate ?? -1)")
        #expect(!engine.avPlayer.automaticallyWaitsToMinimizeStalling, "the synced resume ran")
        #expect(await awaitDrain(engine))
        #expect(engine.avPlayer.rate == 1)
        engine.unload()
    }

    @Test("a plan given up by a seek into its end is a plain fade at rate 1: no overlap, no swap, no glide after the drain")
    func flipAfterSeekIntoEndIsPlain() async throws {
        let engine = try await preparedEngine(plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 5, overlap: 8, swapAt: 4, handover: 1), name: "fs")
        engine.seek(to: 11.5)
        #expect(await awaitFlip(engine))
        #expect(engine.debugBeatOverlap == nil, "the flip must not build an overlap from the plan, \(String(describing: engine.debugBeatOverlap))")
        #expect(!engine.debugBassSwapActive)
        #expect(await awaitDrain(engine))
        #expect(engine.avPlayer.rate == 1, "rate after the drain \(engine.avPlayer.rate)")
        engine.unload()
    }

    @Test("a late plan (the fade does not fit what is left) is a plain fade at rate 1: no overlap and no glide")
    func flipOfLatePlanIsPlain() async throws {
        let engine = try await lateEngine(name: "fl")
        let flipped = await waitUntil(timeout: .seconds(40)) { engine.isCrossfading || engine.fallbackAdvanceCount + engine.scheduledAdvanceCount > 0 }
        #expect(flipped)
        #expect(engine.debugBeatOverlap == nil)
        #expect(!engine.debugBassSwapActive)
        _ = await awaitDrain(engine)
        #expect(engine.avPlayer.rate == 1, "rate after the hand-over \(engine.avPlayer.rate)")
        engine.unload()
    }

    @Test("a beat plan given up after it was scheduled is rescheduled as a plain fade at rate 1: no overlap, no glide")
    func flipOfGivenUpPlanIsPlain() async throws {
        let engine = try await preparedEngine(plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 5, overlap: 8, swapAt: 4, handover: 1), name: "fg")
        #expect(await waitUntil(timeout: .seconds(10)) { engine.debugPlannedBeat })
        engine.debugGiveUpBeat()
        // A changed setting makes the engine plan the start again, and it now sees the plan was given up.
        engine.crossfadeSeconds = 3
        engine.debugEvaluateSchedule()
        let replanned = await waitUntil(timeout: .seconds(30)) { engine.scheduledStartHost != nil && !engine.debugPlannedBeat }
        #expect(replanned)
        #expect(engine.debugPlannedRate == 1)
        #expect(await awaitFlip(engine))
        #expect(engine.debugBeatOverlap == nil)
        #expect(!engine.debugBassSwapActive)
        #expect(await awaitDrain(engine))
        #expect(engine.avPlayer.rate == 1, "rate after the drain \(engine.avPlayer.rate)")
        engine.unload()
    }

    // MARK: - Constant deck rate (Tier 4c): no rate write while a deck plays

    /// Rates the player reports from now on (KVO), so any rate write on a playing deck shows up. Zero is a pause.
    private final class RateLog {
        var rates: [Float] = []
        var observation: NSKeyValueObservation?
        init(_ player: AVPlayer) {
            observation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
                if let rate = change.newValue { MainActor.assumeIsolated { self?.rates.append(rate) } }
            }
        }
        var moving: [Float] { rates.filter { $0 != 0 } }
    }

    /// A beat mix (plan rate 0.95) that has fully drained: the incoming deck runs at 1 for good.
    private func drainedNudgedEngine(name: String) async throws -> AVPlaybackEngine {
        let engine = try await preparedEngine(plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 5, overlap: 4), name: name)
        #expect(await awaitFlip(engine))
        #expect(await awaitDrain(engine))
        return engine
    }

    @Test("a beat mix makes no rate write on the playing incoming deck, and it stays at 1 after the overlap")
    func zeroRateWritesAfterTheFlip() async throws {
        let engine = try await preparedEngine(plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 5, overlap: 4), name: "zw")
        #expect(await awaitFlip(engine))
        let log = RateLog(engine.avPlayer)
        #expect(await awaitDrain(engine))
        try await Task.sleep(for: .seconds(3))
        #expect(engine.playingRateWriteCount == 0)
        #expect(log.moving.allSatisfy { abs($0 - 1) < 1e-5 }, "rates seen on the incoming deck \(log.rates)")
        #expect(abs(engine.avPlayer.rate - 1) < 1e-5)
        #expect(engine.deckRate == 1)
        engine.unload()
    }

    @Test("pause and play after a beat mix keep rate 1, with no write")
    func rateKeptAfterPausePlay() async throws {
        let engine = try await drainedNudgedEngine(name: "pp")
        let log = RateLog(engine.avPlayer)
        engine.pause()
        #expect(engine.avPlayer.rate == 0)
        engine.play()
        let resumed = await waitUntil(timeout: .seconds(10)) { engine.avPlayer.rate != 0 }
        #expect(resumed)
        #expect(abs(engine.avPlayer.rate - 1) < 1e-5, "after pause and play \(engine.avPlayer.rate)")
        #expect(log.moving.allSatisfy { abs($0 - 1) < 1e-5 }, "rates \(log.rates)")
        #expect(engine.playingRateWriteCount == 0)
        engine.unload()
    }

    @Test("a seek after a beat mix keeps rate 1")
    func rateKeptAfterSeek() async throws {
        let engine = try await drainedNudgedEngine(name: "sk")
        engine.seek(to: 4)
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(engine.avPlayer.rate - 1) < 1e-5, "after a seek \(engine.avPlayer.rate)")
        #expect(engine.deckRate == 1)
        #expect(engine.playingRateWriteCount == 0)
        engine.unload()
    }

    @Test("a pause in the middle of a beat overlap and a resume restart both decks at 1, still no write on a playing deck")
    func resumeInOverlapKeepsBothRates() async throws {
        let engine = try await overlapEngine()
        let log = RateLog(engine.avPlayer)
        engine.pause()
        engine.play()
        let restarted = await waitUntil(timeout: .seconds(5)) { abs(engine.avPlayer.rate - 1) < 0.001 }
        #expect(restarted)
        #expect(await awaitDrain(engine))
        #expect(log.moving.allSatisfy { abs($0 - 1) < 1e-5 }, "rates \(log.rates)")
        #expect(engine.playingRateWriteCount == 0)
        engine.unload()
    }

    @Test("a schedule armed after a beat mix fires at the right host time: the deck plays at 1, whatever the next plan says")
    func scheduleAtANonUnityDeckRate() async throws {
        let engine = try await drainedNudgedEngine(name: "sc")
        let third = try await writeTone("sc3", seconds: 20)
        engine.preload(stream("sc3", duration: 20, url: third), plan: beatPlan(rate: 1.05, mixIn: 2, mixOut: 15, overlap: 2))
        let scheduled = await waitUntil(timeout: .seconds(40)) { engine.scheduledStartHost != nil }
        #expect(scheduled)
        let host = try #require(engine.scheduledStartHost).seconds
        let nowHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let end = try #require(engine.debugEffectiveEnd)
        let position = engine.avPlayer.currentTime().seconds
        // The standby starts `lead` wall seconds before the end: the plan's fade start is item 15, so the lead is
        // end - 15 wall seconds (at least the fade), the deck playing at 1.
        #expect(engine.deckRate == 1)
        let lead = max(2.0, end - 15)
        let expected = nowHost + (end - position) - lead
        #expect(abs(host - expected) < 0.25, "scheduled \(host - nowHost) s ahead, expected \(expected - nowHost)")
        // The plan asked for 1.05: the standby is still planned at 1.
        #expect(engine.debugPlannedRate == 1)
        engine.unload()
    }

    @Test("the host time of an item time after a beat mix is the item time itself in wall seconds: the deck plays at 1")
    func hostTimeOfActiveItemTimeUsesTheDeckRate() async throws {
        let engine = try await drainedNudgedEngine(name: "ht")
        let position = engine.avPlayer.currentTime().seconds
        let nowHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let host = try #require(engine.hostTime(ofActiveItemTime: position + 3)?.seconds)
        #expect(abs((host - nowHost) - 3) < 0.15, "3 item seconds are \(host - nowHost) wall seconds")
        engine.unload()
    }

    @Test("a manual load after a beat mix keeps the deck rate at 1")
    func skipResetsTheRate() async throws {
        let engine = try await drainedNudgedEngine(name: "rs")
        let next = try await writeTone("rs-next", seconds: 10)
        engine.load(stream("rs-next", duration: 10, url: next), startAt: 0, autoplay: true)
        #expect(engine.deckRate == 1)
        #expect(engine.avPlayer.defaultRate == 1)
        let playing = await waitUntil(timeout: .seconds(30)) { engine.avPlayer.rate != 0 }
        #expect(playing)
        #expect(engine.avPlayer.rate == 1, "a new song plays at 1, was \(engine.avPlayer.rate)")
        engine.unload()
    }

    @Test("a plain fade (no beat plan) after a beat mix runs the next song at 1")
    func plainFadeAfterNudgedMixIsRateOne() async throws {
        let engine = try await drainedNudgedEngine(name: "pf")
        let next = try await writeTone("pf-next", seconds: 20)
        engine.preload(stream("pf-next", duration: 20, url: next))
        let ready = await waitUntil(timeout: .seconds(30)) { engine.preloadIsReady }
        #expect(ready)
        let scheduled = await waitUntil(timeout: .seconds(40)) { engine.scheduledStartHost != nil }
        #expect(scheduled)
        #expect(engine.debugPlannedRate == 1)
        #expect(await awaitFlip(engine))
        #expect(engine.deckRate == 1)
        #expect(await awaitDrain(engine))
        #expect(engine.avPlayer.rate == 1, "after the plain fade \(engine.avPlayer.rate)")
        engine.unload()
    }

    // MARK: - wjyijr: the song never plays off its own tempo

    @Test("wjyijr: a beat plan at 0.95 starts the standby at exactly 1, flips to deckRate 1, and the song stays at 1 for the rest of it")
    func beatPlanAtPointNineFiveNeverSlowsTheSong() async throws {
        let engine = try await preparedEngine(plan: beatPlan(rate: 0.95, mixIn: 2, mixOut: 5, overlap: 4), name: "wj")
        let scheduled = await waitUntil(timeout: .seconds(30)) { engine.scheduledStartHost != nil }
        #expect(scheduled)
        #expect(engine.standbyAvPlayer.rate == 1, "the standby started at \(engine.standbyAvPlayer.rate)")
        #expect(engine.debugPlannedRate == 1)
        #expect(await awaitFlip(engine))
        #expect(engine.deckRate == 1)
        let log = RateLog(engine.avPlayer)
        #expect(await awaitDrain(engine))
        #expect(engine.deckRate == 1)
        #expect(engine.avPlayer.rate == 1)
        // A few seconds into the rest of the song: still exactly 1, and nothing wrote a rate on the playing deck.
        try await Task.sleep(for: .seconds(3))
        #expect(engine.avPlayer.rate == 1, "rate through the rest of the song \(engine.avPlayer.rate)")
        #expect(engine.deckRate == 1)
        #expect(engine.playingRateWriteCount == 0)
        #expect(log.moving.allSatisfy { $0 == 1 }, "rates seen on the incoming deck \(log.rates)")
        engine.unload()
    }
}
