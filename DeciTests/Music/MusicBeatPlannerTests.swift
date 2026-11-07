// DeciTests/Music/MusicBeatPlannerTests.swift
// Tier 3b P2: the pure beat mix planner.

import Foundation
import Testing
@testable import Deci

@Suite("MusicBeatPlanner")
struct MusicBeatPlannerTests {
    typealias B = MusicBeatPlanner
    typealias T = MusicTransitionPlannerTests

    // MARK: Builders

    static func grid(
        period: Double = 0.5, anchor: Double = 0.2, phase: Int? = 0, confidence: Float = 0.9,
        spread: Float = 0.01, drift: Float = 0, span: ClosedRange<Double> = 0.2...236
    ) -> MusicBeatGrid {
        MusicBeatGrid(
            periodSec: period, anchorSec: anchor, downbeatPhase: phase, beatConfidence: confidence,
            downbeatConfidence: phase == nil ? 0 : 0.6, intervalSpread: spread, driftSec: drift,
            spanStartSec: span.lowerBound, spanEndSec: span.upperBound
        )
    }

    /// Outgoing 240 s ending at 236 with the outro at 200; incoming 240 s, no leading silence.
    static func inputs(
        a: MusicBeatGrid? = grid(), b: MusicBeatGrid? = grid(anchor: 0.1, phase: 1, span: 0.1...236),
        aDuration: Double = 240, aEnd: Double = 236, aOutro: Double = 200, bDuration: Double = 240,
        bSilenceStart: Double = 0, swap: Bool = false
    ) -> MusicTransitionInputs {
        var i = T.inputs(
            a: T.side("aaaaaaaaaaa", duration: aDuration, analysis: T.analysis(
                "aaaaaaaaaaa", duration: aDuration, silenceEnd: aEnd, outroStart: aOutro)),
            b: T.side("bbbbbbbbbbb", duration: bDuration, analysis: T.analysis(
                "bbbbbbbbbbb", duration: bDuration, silenceStart: bSilenceStart, introEnd: bSilenceStart + 8))
        )
        i.outgoing.grid = a
        i.incoming.grid = b
        i.bassSwapAvailable = swap
        return i
    }

    static func plan(_ i: MusicTransitionInputs) -> TransitionPlan {
        B.plan(i, smart: MusicTransitionPlanner.smartPlan(i))
    }

    // MARK: tempoMatch

    @Test("tempoMatch: same tempo, near tempo, clash")
    func tempoBasics() throws {
        let same = try #require(B.tempoMatch(outBpm: 120, inBpm: 120))
        #expect(same.rate == 1 && same.multiple == 1)
        let near = try #require(B.tempoMatch(outBpm: 120, inBpm: 128))
        #expect(abs(near.rate - 0.9375) < 1e-12 && near.multiple == 1)
        #expect(B.tempoMatch(outBpm: 120, inBpm: 131) == nil)
    }

    @Test("tempoMatch: half and double time")
    func tempoMultiples() throws {
        let double = try #require(B.tempoMatch(outBpm: 70, inBpm: 140))
        #expect(double.multiple == 2 && abs(double.rate - 1) < 1e-12)
        let half = try #require(B.tempoMatch(outBpm: 140, inBpm: 71))
        #expect(half.multiple == 0.5 && abs(half.rate - 140 * 0.5 / 71) < 1e-12)
        let nearDouble = try #require(B.tempoMatch(outBpm: 70, inBpm: 148))
        #expect(nearDouble.multiple == 2)
    }

    @Test("tempoMatch: exactly 8 percent matches, beyond does not, bad bpm never")
    func tempoBoundary() {
        #expect(B.tempoMatch(outBpm: 108, inBpm: 100) != nil)
        #expect(B.tempoMatch(outBpm: 92, inBpm: 100) != nil)
        #expect(B.tempoMatch(outBpm: 108.2, inBpm: 100) == nil)
        #expect(B.tempoMatch(outBpm: 91.5, inBpm: 100) == nil)
        for bad in [0.0, -120, .nan, .infinity] {
            #expect(B.tempoMatch(outBpm: bad, inBpm: 120) == nil)
            #expect(B.tempoMatch(outBpm: 120, inBpm: bad) == nil)
        }
    }

    // MARK: Phrase maths

    @Test("an 8 bar overlap starts on an 8 bar multiple counted from the first bar and fits before the end")
    func phraseMaths() throws {
        let i = Self.inputs()
        let plan = Self.plan(i)
        #expect(plan.mode == .beat && plan.fallbackReason == nil && plan.reason == .ok)
        let a = Self.grid()
        let first = try #require(a.barTime(0))
        let mixOut = try #require(plan.mixOutSec)
        let phrase = 8 * plan.barSec
        #expect(plan.barSec == 2 && plan.overlapBars == 8 && plan.overlapSec == 16)
        let phrases = (mixOut - first) / phrase
        #expect(abs(phrases - phrases.rounded()) < 1e-9)
        #expect(mixOut + plan.overlapSec <= 236 + 1e-9)
        // The latest such boundary: the next phrase would not fit.
        #expect(mixOut + phrase + plan.overlapSec > 236)
        #expect(plan.fadeStartSec == mixOut && plan.fadeSeconds == plan.overlapSec)
        #expect(plan.outgoingEndSec == mixOut + plan.overlapSec)
        #expect(plan.glideBackSec == 10 && plan.incomingRate == 1)
    }

    @Test("the incoming start is its first bar boundary at or after the trimmed start")
    func mixInIsABarBoundary() throws {
        let b = Self.grid(anchor: 0.1, phase: 1, span: 0.1...236)
        let plan = Self.plan(Self.inputs(b: b, bSilenceStart: 3))
        let mixIn = try #require(plan.mixInSec)
        #expect(mixIn >= 3 - 1e-9 && mixIn < 3 + 4 * 0.5)
        let beat = (mixIn - b.anchorSec) / b.periodSec
        #expect(abs(beat - beat.rounded()) < 1e-9)
        #expect(((Int(beat.rounded()) - 1) % 4 + 4) % 4 == 0)
        #expect(plan.incomingStartSec == mixIn)
    }

    @Test("a beat of the incoming song at mixIn lands on a beat of the outgoing after rate scaling", arguments: [
        (120.0, 120.0), (120.0, 128.0), (128.0, 120.0), (70.0, 140.0), (140.0, 71.0), (100.0, 107.0),
    ])
    func beatPhase(outBpm: Double, inBpm: Double) throws {
        let a = Self.grid(period: 60 / outBpm, anchor: 0.23)
        let b = Self.grid(period: 60 / inBpm, anchor: 0.41, phase: 2, span: 0.41...236)
        let plan = Self.plan(Self.inputs(a: a, b: b))
        #expect(plan.mode == .beat)
        let mixOut = try #require(plan.mixOutSec), mixIn = try #require(plan.mixInSec)
        let multiple = try #require(B.tempoMatch(outBpm: outBpm, inBpm: inBpm)).multiple
        #expect(abs(mixOut - a.beatTime(a.nextBeat(atOrAfter: mixOut).index)) < 1e-6)
        let kIn = b.nextBeat(atOrAfter: mixIn).index
        #expect(abs(b.beatTime(kIn) - mixIn) < 1e-6)
        // Every few incoming beats: its time in the outgoing timeline against the outgoing beat grid.
        for step in [4, 8, 16, 32] {
            let incomingTime = mixOut + (b.beatTime(kIn + step) - mixIn) / plan.incomingRate
            let position = (incomingTime - a.anchorSec) / a.periodSec
            #expect(abs(position - position.rounded()) * a.periodSec < 1e-6, "step \(step) off by \(position - position.rounded()) beats")
            let expected = (mixOut - a.anchorSec) / a.periodSec + Double(step) / multiple
            #expect(abs(position - expected) * a.periodSec < 1e-6)
        }
    }

    // MARK: Overlap length

    @Test("8 bars without the bass swap even with room for 16")
    func capsAtEight() {
        let plan = Self.plan(Self.inputs(aOutro: 40, swap: false))
        #expect(plan.overlapBars == 8 && plan.bassSwapAtSec == nil && plan.bassHandoverSec == 0)
    }

    @Test("16 bars once the bass swap exists and both songs have room")
    func sixteenWithSwap() throws {
        let plan = Self.plan(Self.inputs(aOutro: 40, swap: true))
        #expect(plan.mode == .beat && plan.overlapBars == 16 && plan.overlapSec == 32)
        #expect(plan.bassSwapAtSec == 16)
        #expect(plan.bassHandoverSec == 1)
        let mixOut = try #require(plan.mixOutSec)
        #expect(mixOut + 32 <= 236 + 1e-9)
    }

    @Test("it falls to 8 bars when only 8 fit, and refuses when neither fits")
    func fallsToEight() {
        let tight = Self.inputs(aDuration: 100, aEnd: 100, aOutro: 90, swap: true)
        #expect(Self.plan(tight).overlapBars == 8)
        let none = Self.inputs(aDuration: 30, aEnd: 30, aOutro: 28, swap: true)
        let plan = Self.plan(none)
        #expect(plan.mode == .smart && plan.fallbackReason == "noPhraseRoom")
    }

    @Test("an unknown downbeat on either song gives a bar aligned 8 bar plan with no swap")
    func unknownDownbeat() throws {
        let a = Self.grid(phase: nil)
        let plan = Self.plan(Self.inputs(a: a, swap: true))
        #expect(plan.mode == .beat && plan.overlapBars == 8 && plan.bassSwapAtSec == nil)
        let mixOut = try #require(plan.mixOutSec)
        let bars = (mixOut - a.anchorSec) / plan.barSec
        #expect(abs(bars - bars.rounded()) < 1e-9)
        #expect(mixOut + plan.overlapSec <= 236 + 1e-9)

        let b = Self.grid(anchor: 0.1, phase: nil, span: 0.1...236)
        let second = Self.plan(Self.inputs(b: b, swap: true))
        #expect(second.mode == .beat && second.overlapBars == 8 && second.bassSwapAtSec == nil)
    }

    @Test("the incoming song needs 20 s left after the overlap")
    func incomingRoom() {
        #expect(Self.plan(Self.inputs(bDuration: 60)).mode == .beat)
        let short = Self.plan(Self.inputs(bDuration: 30))
        #expect(short.mode == .smart && short.fallbackReason == "noPhraseRoom")
    }

    @Test("a mix out beyond the validated span is no room")
    func spanLimit() {
        let a = Self.grid(span: 0.2...100)
        let plan = Self.plan(Self.inputs(a: a))
        #expect(plan.mode == .smart && plan.fallbackReason == "noPhraseRoom")
    }

    // MARK: Fallbacks

    func expectFallback(_ i: MusicTransitionInputs, _ reason: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let smart = MusicTransitionPlanner.smartPlan(i)
        let plan = B.plan(i, smart: smart)
        var expected = smart
        expected.fallbackReason = reason
        #expect(plan == expected, "fallback \(reason)", sourceLocation: sourceLocation)
        #expect(plan.mode != .beat, sourceLocation: sourceLocation)
    }

    @Test("a missing grid on either side")
    func gridMissing() {
        expectFallback(Self.inputs(a: nil), "gridMissing")
        expectFallback(Self.inputs(b: nil), "gridMissing")
    }

    @Test("a version 1 row has no usable grid")
    func versionOneRow() {
        var i = Self.inputs(a: nil, b: nil)
        i.outgoing.analysis?.version = 1
        i.incoming.analysis?.version = 1
        i.outgoing.analysis?.beatGrid = Self.grid().encode()
        i.incoming.analysis?.beatGrid = Self.grid().encode()
        expectFallback(i, "gridMissing")
        // The same rows at version 2 do give a plan, with no side.grid at all.
        i.outgoing.analysis?.version = 2
        i.incoming.analysis?.version = 2
        #expect(Self.plan(i).mode == .beat)
    }

    @Test("low confidence, spread and drift gate both songs", arguments: [
        (Float(0.3), Float(0.01), Float(0)), (0.13, 0.01, 0), (0.49, 0.01, 0),
        (0.9, 0.05, 0), (0.9, 0.01, 0.004), (0.9, 0.01, -0.004),
    ])
    func lowConfidence(confidence: Float, spread: Float, drift: Float) {
        let weak = Self.grid(confidence: confidence, spread: spread, drift: drift)
        expectFallback(Self.inputs(a: weak), "gridLowConf")
        expectFallback(Self.inputs(b: weak), "gridLowConf")
    }

    @Test("the confidence limits themselves pass")
    func confidenceLimits() {
        let edge = Self.grid(confidence: 0.5, spread: 0.04, drift: 0.003)
        #expect(Self.plan(Self.inputs(a: edge, b: edge)).mode == .beat)
    }

    @Test("a tempo clash")
    func tempoClash() {
        expectFallback(Self.inputs(b: Self.grid(period: 60 / 131, anchor: 0.1, phase: 1)), "tempoClash")
    }

    @Test("flags, album order, loop, too short and disabled keep the smart plan")
    func eligibility() {
        var i = Self.inputs(); i.cleanStartFlag = true
        expectFallback(i, "noMixFlag")
        i = Self.inputs(); i.cleanPairFlag = true
        expectFallback(i, "noMixFlag")
        i = Self.inputs(); i.albumInOrder = true
        expectFallback(i, "albumInOrder")
        i = Self.inputs(); i.loopSong = true
        expectFallback(i, "loopSong")
        i = Self.inputs(); i.beatMixEnabled = false
        expectFallback(i, "disabled")
        i = Self.inputs(); i.crossfadeOn = false
        expectFallback(i, "disabled")
        i = Self.inputs(aDuration: 1.5, aEnd: 1.5, aOutro: 1)
        #expect(MusicTransitionPlanner.smartPlan(i).reason == .tooShort)
        expectFallback(i, "tooShort")
    }

    @Test("a fallback leaves every other plan field exactly the smart plan")
    func fallbackKeepsSmartFields() {
        let i = Self.inputs(b: Self.grid(period: 60 / 131, anchor: 0.1, phase: 1))
        let smart = MusicTransitionPlanner.smartPlan(i)
        var plan = B.plan(i, smart: smart)
        #expect(plan.fallbackReason == "tempoClash")
        plan.fallbackReason = nil
        #expect(plan == smart)
        #expect(smart.incomingRate == 1 && smart.mixOutSec == nil && smart.overlapBars == 0)
    }

    // MARK: Through the tier 2 planner

    @Test("MusicTransitionPlanner.plan upgrades, falls back with a reason, and stays silent without grids")
    func throughPlanner() {
        let good = MusicTransitionPlanner.plan(Self.inputs())
        #expect(good.mode == .beat)

        let clash = MusicTransitionPlanner.plan(Self.inputs(b: Self.grid(period: 60 / 131, anchor: 0.1, phase: 1)))
        #expect(clash.mode == .smart && clash.fallbackReason == "tempoClash")

        let none = Self.inputs(a: nil, b: nil)
        let plan = MusicTransitionPlanner.plan(none)
        #expect(plan == MusicTransitionPlanner.smartPlan(none) && plan.fallbackReason == nil)

        var off = Self.inputs(); off.beatMixEnabled = false
        let offPlan = MusicTransitionPlanner.plan(off)
        #expect(offPlan.mode == .smart && offPlan.fallbackReason == nil)
    }

    @Test("the calibration constant")
    func calibration() {
        #expect(AVPlaybackEngine.beatCalibrationSec == -0.007)
    }

    // MARK: Property

    struct Lcg { var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    @Test("for random grids the overlap always fits and at least 20 s of the incoming song remains")
    func property() throws {
        var random = Lcg(state: 42)
        var beatPlans = 0
        for _ in 0..<600 {
            let bpm = 70 + random.next() * 110
            let inBpm = bpm * (0.88 + random.next() * 0.24)
            let aDuration = 60 + random.next() * 340
            let bDuration = 60 + random.next() * 340
            let aEnd = aDuration - random.next() * 4
            let outro = aEnd - random.next() * 60
            let a = Self.grid(period: 60 / bpm, anchor: random.next() * 2, phase: random.next() < 0.2 ? nil : Int(random.next() * 4), span: 0.5...aEnd)
            let b = Self.grid(period: 60 / inBpm, anchor: random.next() * 2, phase: random.next() < 0.2 ? nil : Int(random.next() * 4), span: 0.5...bDuration)
            let i = Self.inputs(a: a, b: b, aDuration: aDuration, aEnd: aEnd, aOutro: outro, bDuration: bDuration,
                                bSilenceStart: random.next() * 10, swap: random.next() < 0.5)
            let plan = Self.plan(i)
            guard plan.mode == .beat else {
                #expect(plan.fallbackReason != nil)
                continue
            }
            beatPlans += 1
            let mixOut = try #require(plan.mixOutSec), mixIn = try #require(plan.mixInSec)
            #expect(mixOut >= 0)
            #expect(mixOut + plan.overlapSec <= aEnd + 1e-6)
            #expect(bDuration - (mixIn + plan.overlapSec * plan.incomingRate) >= 20 - 1e-6)
            #expect(plan.overlapBars == 8 || plan.overlapBars == 16)
            #expect(abs(plan.incomingRate - 1) <= 0.08 + 1e-9)
            #expect(plan.incomingRate > 0.9 && plan.incomingRate < 1.1)
        }
        #expect(beatPlans > 100, "only \(beatPlans) of 600 random pairs got a beat plan")
    }
}
