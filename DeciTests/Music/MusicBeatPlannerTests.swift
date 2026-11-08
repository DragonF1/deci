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
        bSilenceStart: Double = 0, bSilenceEnd: Double? = nil, swap: Bool = false
    ) -> MusicTransitionInputs {
        var i = T.inputs(
            a: T.side("aaaaaaaaaaa", duration: aDuration, analysis: T.analysis(
                "aaaaaaaaaaa", duration: aDuration, silenceEnd: aEnd, outroStart: aOutro)),
            b: T.side("bbbbbbbbbbb", duration: bDuration, analysis: T.analysis(
                "bbbbbbbbbbb", duration: bDuration, silenceStart: bSilenceStart, silenceEnd: bSilenceEnd, introEnd: bSilenceStart + 8))
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
        let inputs = Self.inputs(aOutro: 40, swap: true)
        let plan = Self.plan(inputs)
        #expect(plan.mode == .beat && plan.overlapBars == 16 && plan.overlapSec == 32)
        // The plan carries the smart start for an engine that has to give the beat plan up.
        #expect(plan.fallbackIncomingStartSec == MusicTransitionPlanner.smartPlan(inputs).incomingStartSec)
        #expect(plan.bassSwapAtSec == 16)
        #expect(plan.bassHandoverSec == 1)
        let mixOut = try #require(plan.mixOutSec)
        #expect(mixOut + 32 <= 236 + 1e-9)
    }

    /// Outgoing mixOut for an 8 bar overlap: grid period 0.5 (a bar is 2 s, a phrase 16 s), first bar at 0.2, the latest
    /// start `end - 16`, the earliest start `outro - 16`.
    static func mixOut(end: Double, outro: Double) -> Double? {
        let a = T.analysis("aaaaaaaaaaa", duration: 240, silenceEnd: end, outroStart: outro)
        return B.mixOutTime(grid: grid(), analysis: a, bars: 8, barSec: 2, end: end)
    }

    @Test("a phrase boundary that fits is still the one chosen")
    func phraseWinsWhenItFits() throws {
        // Window [60, 76]: the phrase boundary 64.2 fits and wins although the 4 bar boundary 72.2 is later.
        let time = try #require(Self.mixOut(end: 92, outro: 76))
        #expect(abs(time - 64.2) < 1e-9)
    }

    @Test("when the phrase boundary misses the window, a 4 bar boundary that fits is used")
    func fourBarFallback() throws {
        // Window [70, 76]: the latest phrase boundary 64.2 is too early, the latest 4 bar boundary 72.2 fits.
        let time = try #require(Self.mixOut(end: 92, outro: 86))
        #expect(abs(time - 72.2) < 1e-9)
    }

    @Test("when only a 1 bar boundary fits, that one is used")
    func oneBarFallback() throws {
        // Window [74.5, 77]: phrase 64.2 and 4 bar 72.2 are too early, bars fall at 74.2 and 76.2.
        let time = try #require(Self.mixOut(end: 93, outro: 90.5))
        #expect(abs(time - 76.2) < 1e-9)
    }

    @Test("a window with no bar boundary at all is no room")
    func noBoundary() {
        // Window [76.5, 77]: bars at 76.2 and 78.2 both miss.
        #expect(Self.mixOut(end: 93, outro: 92.5) == nil)
    }

    @Test("it falls to 8 bars when only 8 fit, and refuses when neither fits")
    func fallsToEight() {
        let tight = Self.inputs(aDuration: 100, aEnd: 100, aOutro: 90, swap: true)
        #expect(Self.plan(tight).overlapBars == 8)
        // Window [13, 14] for the mix out: no bar boundary (12.2, 14.2) lands in it.
        let none = Self.inputs(aDuration: 30, aEnd: 30, aOutro: 29, swap: true)
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

    // MARK: Review guards

    @Test("the whole overlap stays inside the outgoing validated span, give or take two beats")
    func overlapInsideSpan() throws {
        let a = Self.grid(span: 0.2...215)
        let plan = Self.plan(Self.inputs(a: a))
        #expect(plan.mode == .beat)
        let mixOut = try #require(plan.mixOutSec)
        #expect(mixOut + plan.overlapSec <= 215 + 2 * 0.5 + 1e-9)
        // Without the guard the latest phrase would start at 208.2 and end at 224.2.
        #expect(mixOut < 208)
    }

    @Test("the incoming mix in is not before its validated span, and its overlap ends inside it")
    func incomingSpan() throws {
        let late = Self.grid(anchor: 0.1, phase: 1, span: 20...236)
        let plan = Self.plan(Self.inputs(b: late))
        let mixIn = try #require(plan.mixInSec)
        #expect(plan.mode == .beat && mixIn >= 20 - 1 - 1e-9 && mixIn < 20 + 4)
        let short = Self.grid(anchor: 0.1, phase: 1, span: 0.1...12)
        let refused = Self.plan(Self.inputs(b: short))
        #expect(refused.mode == .smart && refused.fallbackReason == "noPhraseRoom")
    }

    @Test("an overlap over 40 s is never planned")
    func maxOverlap() {
        let slow = Self.grid(period: 1.5)
        let both = Self.plan(Self.inputs(a: slow, b: Self.grid(period: 1.5, anchor: 0.1, phase: 1), swap: true))
        #expect(both.mode == .smart && both.fallbackReason == "noPhraseRoom")
        // 60 bpm: 8 bars are 32 s, fine; 16 bars (64 s) are skipped.
        let sixty = Self.grid(period: 1)
        let plan = Self.plan(Self.inputs(a: sixty, b: Self.grid(period: 1, anchor: 0.1, phase: 1), swap: true))
        #expect(plan.mode == .beat && plan.overlapBars == 8 && plan.overlapSec == 32)
    }

    @Test("a mix out already in the past is refused as tooLate, or shortened when a shorter overlap still lies ahead")
    func tooLate() throws {
        var i = Self.inputs()
        let base = try #require(Self.plan(i).mixOutSec)
        i.earliestMixOutSec = base - 1
        #expect(Self.plan(i).mixOutSec == base)
        i.earliestMixOutSec = base + 1
        let late = Self.plan(i)
        #expect(late.mode == .smart && late.fallbackReason == "tooLate")
        var swap = Self.inputs(aOutro: 40, swap: true)
        let sixteen = Self.plan(swap)
        #expect(sixteen.overlapBars == 16)
        swap.earliestMixOutSec = try #require(sixteen.mixOutSec) + 1
        let shorter = Self.plan(swap)
        #expect(shorter.mode == .beat && shorter.overlapBars == 8)
        #expect(try #require(shorter.mixOutSec) >= swap.earliestMixOutSec!)
        // The 8-bar fallback still hands the bass over: at its own half way, across two beats.
        #expect(shorter.bassSwapAtSec == shorter.overlapSec / 2, "swapAt \(String(describing: shorter.bassSwapAtSec))")
        #expect(shorter.bassHandoverSec > 0)
    }

    @Test("a missing grid is only reported when a grid was expected")
    func gridMissingReporting() {
        // No song has a grid: silent (every song before 3b).
        #expect(MusicTransitionPlanner.plan(Self.inputs(a: nil, b: nil)).fallbackReason == nil)
        // The other song has one and this version 2 row has none: reported.
        #expect(MusicTransitionPlanner.plan(Self.inputs(a: nil)).fallbackReason == "gridMissing")
        // A version 2 row whose stored grid is corrupt: reported even when nothing else has a grid.
        var broken = Self.inputs(a: nil, b: nil)
        broken.outgoing.analysis?.beatGrid = Data([1, 2, 3])
        #expect(MusicTransitionPlanner.plan(broken).fallbackReason == "gridMissing")
        // A version 1 row: silent.
        var v1 = Self.inputs(a: nil)
        v1.outgoing.analysis?.version = 1
        #expect(MusicTransitionPlanner.plan(v1).fallbackReason == nil)
    }

    @Test("the incoming room is measured to its trimmed end")
    func silentTail() {
        // 60 s song, audio ends at 50: 16.6 s used leaves 33 s.
        #expect(Self.plan(Self.inputs(bDuration: 60, bSilenceEnd: 50)).mode == .beat)
        // Audio ends at 36: only 19.4 s would remain, though the file runs to 60.
        let plan = Self.plan(Self.inputs(bDuration: 60, bSilenceEnd: 36))
        #expect(plan.mode == .smart && plan.fallbackReason == "noPhraseRoom")
    }

    @Test("grids handed in directly with absurd anchors or spans are not trusted")
    func absurdGrids() {
        expectFallback(Self.inputs(a: Self.grid(anchor: 2e7)), "gridLowConf")
        expectFallback(Self.inputs(b: Self.grid(span: 0.2...3e7)), "gridLowConf")
        expectFallback(Self.inputs(a: Self.grid(anchor: -2e7)), "gridLowConf")
    }

    @Test("a negative anchor and a span that starts after the silence still land on the grid")
    func oddGrids() throws {
        let a = Self.grid(anchor: -5.3, span: 30...236)
        let analysis = T.analysis("aaaaaaaaaaa", duration: 240, silenceEnd: 236, outroStart: 200)
        let mixOut = try #require(B.mixOutTime(grid: a, analysis: analysis, bars: 8, barSec: 2, end: 236))
        let beats = (mixOut - a.anchorSec) / a.periodSec
        #expect(mixOut >= 30 && mixOut + 16 <= 236 && abs(beats - beats.rounded()) < 1e-9)
        let b = Self.grid(anchor: -3.1, phase: 2, span: 30...236)
        let mixIn = try #require(B.mixInTime(grid: b, start: 0))
        #expect(mixIn >= 29 - 1e-9 && mixIn < 29 + 2.5)
        let k = (mixIn - b.anchorSec) / b.periodSec
        #expect(abs(k - k.rounded()) < 1e-9)
        #expect(((Int(k.rounded()) - 2) % 4 + 4) % 4 == 0)
    }

    @Test("with the beat mix off, replan and skip style inputs give the smart plan with no reason")
    func disabledIsSmart() {
        var off = Self.inputs(); off.beatMixEnabled = false
        #expect(MusicTransitionPlanner.plan(off) == MusicTransitionPlanner.smartPlan(off))
        #expect(MusicTransitionPlanner.plan(off).fallbackReason == nil)
        var skip = off; skip.manualSkip = true
        #expect(MusicTransitionPlanner.plan(skip) == MusicTransitionPlanner.smartPlan(skip))
        #expect(MusicTransitionPlanner.plan(skip).fallbackReason == nil)
        var on = Self.inputs(); on.manualSkip = true
        #expect(MusicTransitionPlanner.plan(on).mode == .fixed)
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
            #expect(mixOut + plan.overlapSec <= a.spanEndSec + 2 * a.periodSec + 1e-6)
            #expect(mixIn >= b.spanStartSec - 2 * b.periodSec - 1e-6)
            #expect(mixIn + plan.overlapSec * plan.incomingRate <= b.spanEndSec + 2 * b.periodSec + 1e-6)
            #expect(plan.overlapSec <= B.maxOverlapSec)
        }
        #expect(beatPlans > 100, "only \(beatPlans) of 600 random pairs got a beat plan")
    }
}

// MARK: - Tier 3c: structural vocal guard

extension MusicBeatPlannerTests {
    /// The beat fixture with the guard on. A sings until `outro`, B from `bIntroEnd` (item time).
    static func guardedInputs(
        outro: Double, bIntroEnd: Double = 8, aEnd: Double = 236, swap: Bool, guardOn: Bool = true
    ) -> MusicTransitionInputs {
        var i = inputs(aEnd: aEnd, aOutro: outro, swap: swap)
        i.incoming.analysis?.introEnd = bIntroEnd
        i.vocalGuardEnabled = guardOn
        return i
    }

    private func collision(_ p: TransitionPlan, _ i: MusicTransitionInputs) -> Double {
        MusicVocalGuard.collisionSec(
            outgoing: i.outgoing.analysis, incoming: i.incoming.analysis, outStart: p.mixOutSec ?? 0,
            inStart: p.mixInSec ?? 0, rate: p.incomingRate, length: p.overlapSec
        ) ?? 0
    }

    @Test("guard off: a colliding 16 bar overlap is planned as today")
    func guardOffKeepsTheLongest() {
        let off = Self.plan(Self.guardedInputs(outro: 208, swap: true, guardOn: false))
        #expect(off.mode == .beat && off.overlapBars == 16)
        #expect(off.vocalAction == nil && off.vocalCollisionSec == nil && off.vocalBeforeSec == nil)
        // The same inputs on a build that never had the guard fields: identical to the plain plan.
        var plain = Self.guardedInputs(outro: 208, swap: true, guardOn: false)
        plain.vocalGuardEnabled = false
        #expect(Self.plan(plain) == off)
    }

    @Test("guard on with a clean 16 bar overlap changes nothing, field by field")
    func cleanOverlapIsIdentical() {
        for outro in [150.0, 200.0] {
            let on = Self.plan(Self.guardedInputs(outro: outro, swap: true))
            let off = Self.plan(Self.guardedInputs(outro: outro, swap: true, guardOn: false))
            #expect(on.mode == .beat)
            #expect(on == off, "outro \(outro)")
        }
    }

    @Test("no analysis side or an unusable proxy: the guard is a no-op")
    func noAnalysisNoOp() {
        var noProxy = Self.guardedInputs(outro: 208, swap: true)
        noProxy.outgoing.analysis?.introEnd = 220     // introEnd >= outroStart
        let off = Self.guardedInputs(outro: 208, swap: true, guardOn: false)
        var noProxyOff = off
        noProxyOff.outgoing.analysis?.introEnd = 220
        #expect(Self.plan(noProxy) == Self.plan(noProxyOff))
        #expect(Self.plan(noProxy).overlapBars == 16)
        var nan = Self.guardedInputs(outro: 208, swap: true)
        nan.incoming.analysis?.outroStart = .nan
        var nanOff = off
        nanOff.incoming.analysis?.outroStart = .nan
        #expect(Self.plan(nan) == Self.plan(nanOff))
    }

    @Test("16 colliding, 8 clean: the 8 bar overlap is picked")
    func sixteenCollidesEightClean() {
        let i = Self.guardedInputs(outro: 208, swap: true)
        let off = Self.plan(Self.guardedInputs(outro: 208, swap: true, guardOn: false))
        #expect(off.overlapBars == 16 && collision(off, i) > MusicVocalGuard.budgetSec)
        let on = Self.plan(i)
        #expect(on.mode == .beat && on.overlapBars == 8 && on.overlapSec == 16)
        #expect(collision(on, i) <= MusicVocalGuard.budgetSec)
        #expect(on.vocalAction == "shorten")
        #expect(on.vocalBeforeSec == collision(off, i))
        #expect(on.vocalCollisionSec == collision(on, i))
        // Everything else is the 8 bar plan the unguarded planner builds without the bass swap.
        let eight = Self.plan(Self.guardedInputs(outro: 208, swap: false, guardOn: false))
        #expect(on.mixOutSec == eight.mixOutSec && on.mixInSec == eight.mixInSec)
        #expect(on.bassSwapAtSec != nil)
    }

    @Test("every long length colliding: the 4 bar tier is picked with no bass swap")
    func fourBarTier() {
        let i = Self.guardedInputs(outro: 219, bIntroEnd: 8, swap: false)
        let off = Self.plan(Self.guardedInputs(outro: 219, bIntroEnd: 8, swap: false, guardOn: false))
        #expect(off.overlapBars == 8 && collision(off, i) > MusicVocalGuard.budgetSec)
        let on = Self.plan(i)
        #expect(on.mode == .beat && on.overlapBars == 4 && on.overlapSec == 8)
        #expect(on.bassSwapAtSec == nil && on.bassHandoverSec == 0)
        #expect(collision(on, i) <= MusicVocalGuard.budgetSec)
        #expect(on.vocalAction == "shorten" && on.fadeSeconds == 8 && on.outgoingEndSec == (on.mixOutSec ?? 0) + 8)
    }

    @Test("the 4 bar tier carries no bass swap even when the swap is available")
    func fourBarTierDropsTheSwap() {
        var i = Self.guardedInputs(outro: 219, bIntroEnd: 8, swap: true)
        i.outgoing.analysis?.outroStart = 219
        let on = Self.plan(i)
        if on.overlapBars == 4 {
            #expect(on.bassSwapAtSec == nil && on.bassHandoverSec == 0)
        }
        #expect(on.bassSwapAtSec == nil || on.overlapBars != 4)
    }

    @Test("every length colliding: vocalClash and the smart plan takes over")
    func allCollide() {
        // aEnd 228 puts the 4 bar overlap on the same phrase as the 8 bar one; B sings from 2 s on.
        let i = Self.guardedInputs(outro: 224, bIntroEnd: 2, aEnd: 228, swap: false)
        let smart = MusicTransitionPlanner.smartPlan(i)
        let plan = Self.plan(i)
        #expect(plan.mode == .smart && plan.fallbackReason == "vocalClash")
        #expect(plan.fadeSeconds == smart.fadeSeconds && plan.fadeStartSec == smart.fadeStartSec)
        #expect((plan.vocalBeforeSec ?? 0) > MusicVocalGuard.budgetSec)
        // Through the transition planner the smart plan is the guarded one and says it came from a beat plan.
        let full = MusicTransitionPlanner.plan(i)
        #expect(full.mode == .smart && full.fallbackReason == "vocalClash" && full.vocalAction == "beatToSmart")
        #expect(full.incomingStartSec == smart.incomingStartSec)
    }

    @Test("guard off, the same fixture: the 8 bar overlap is kept")
    func allCollideGuardOff() {
        let plan = Self.plan(Self.guardedInputs(outro: 224, bIntroEnd: 2, aEnd: 228, swap: false, guardOn: false))
        #expect(plan.mode == .beat && plan.overlapBars == 8)
    }

    @Test("a length skipped for a non-vocal reason keeps today's reason")
    func nonVocalReasonSurvives() {
        // The guard on, the overlap clean: a refusal is the same refusal with or without the guard.
        var tooLate = Self.guardedInputs(outro: 150, swap: true)
        tooLate.earliestMixOutSec = 1000
        var tooLateOff = tooLate
        tooLateOff.vocalGuardEnabled = false
        #expect(Self.plan(tooLate) == Self.plan(tooLateOff))
        #expect(Self.plan(tooLate).fallbackReason == "tooLate")
        // 16 skipped for a non-vocal reason (outro too late for it), 8 colliding: no 4 bar tier, no vocalClash.
        let mixed = Self.plan(Self.guardedInputs(outro: 219, bIntroEnd: 8, swap: true))
        #expect(mixed.fallbackReason != "vocalClash" || mixed.mode == .smart)
        #expect(mixed.mode != .beat || mixed.overlapBars != 4)
    }

    @Test("a 4 bar overlap shorter than 6 s is never tried")
    func shortFourBarTier() {
        // 160 BPM: a bar is 1.5 s, 4 bars 6 s (tried); 200 BPM: a bar is 1.2 s, 4 bars 4.8 s (not tried).
        let fast = Self.grid(period: 0.3, anchor: 0.2, phase: 0, span: 0.2...236)
        var i = Self.guardedInputs(outro: 219, bIntroEnd: 8, swap: false)
        i.outgoing.grid = fast
        i.incoming.grid = Self.grid(period: 0.3, anchor: 0.1, phase: 1, span: 0.1...236)
        let plan = Self.plan(i)
        #expect(plan.mode != .beat || plan.overlapBars != 4)
    }
}

// MARK: - Tier 3c review fixes

extension MusicBeatPlannerTests {
    /// A hand-made smart plan whose fade [135, 147] collides with the guard on (A sings to `outro`, B from its intro end).
    /// A plan built by `smartPlan` never collides for more than the budget, so the seam takes it as an argument.
    static func collidingSmart(for i: MusicTransitionInputs) -> TransitionPlan {
        var smart = MusicTransitionPlanner.smartPlan(i)
        smart.fadeSeconds = 12
        smart.fadeStartSec = 135
        smart.outgoingGainDb = -3
        smart.outgoingRampSeconds = 2
        return smart
    }

    @Test("a clean beat plan never inherits the guard's smart-fade shortening")
    func cleanBeatPlanIgnoresTheSmartGuard() {
        let on = Self.guardedInputs(outro: 150, swap: true)
        let off = Self.guardedInputs(outro: 150, swap: true, guardOn: false)
        let smart = Self.collidingSmart(for: on)
        #expect(MusicTransitionPlanner.vocalGuarded(smart, on) != smart, "fixture: the smart fade must collide")
        let planOn = MusicTransitionPlanner.plan(on, smart: smart)
        let planOff = MusicTransitionPlanner.plan(off, smart: smart)
        #expect(planOn.mode == .beat && planOn.overlapBars == 16)
        #expect(planOn.vocalAction == nil && planOn.vocalCollisionSec == nil && planOn.vocalBeforeSec == nil)
        #expect(planOn.outgoingRampSeconds == smart.outgoingRampSeconds)
        #expect(planOn == planOff)
    }

    @Test("a refusal still carries the guarded smart plan")
    func refusalCarriesTheGuardedSmart() {
        let i = Self.guardedInputs(outro: 224, bIntroEnd: 2, aEnd: 228, swap: false)
        let smart = Self.collidingSmart(for: i)
        let guarded = MusicTransitionPlanner.vocalGuarded(smart, i)
        #expect(guarded.fadeSeconds < smart.fadeSeconds)
        let plan = MusicTransitionPlanner.plan(i, smart: smart)
        #expect(plan.mode == .smart && plan.fallbackReason == "vocalClash" && plan.vocalAction == "beatToSmart")
        #expect(plan.fadeSeconds == guarded.fadeSeconds && plan.fadeStartSec == guarded.fadeStartSec)
        #expect(plan.outgoingRampSeconds == guarded.outgoingRampSeconds)
        #expect((plan.vocalBeforeSec ?? 0) > MusicVocalGuard.budgetSec)
        // Any other refusal: guarded smart plus the reason.
        var late = i
        late.earliestMixOutSec = 1000
        let tooLate = MusicTransitionPlanner.plan(late, smart: smart)
        #expect(tooLate.fallbackReason == "tooLate" && tooLate.fadeSeconds == guarded.fadeSeconds)
        #expect(tooLate.vocalAction == guarded.vocalAction)
    }
}
