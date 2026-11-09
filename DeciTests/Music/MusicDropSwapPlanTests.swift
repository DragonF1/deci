// DeciTests/Music/MusicDropSwapPlanTests.swift
// Tier 4b P2: the drop swap and filter sweep plans. The incoming song's drop lands on the outgoing phrase end, within a
// millisecond, at equal tempo and with a rate nudge.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicDropSwapPlan")
struct MusicDropSwapPlanTests {
    typealias B = MusicBeatPlanner
    typealias BT = MusicBeatPlannerTests

    /// A pair whose incoming song has a loud step at `stepSec` (rounded to the 100 ms energy block).
    static func inputs(
        a: MusicBeatGrid? = BT.grid(), b: MusicBeatGrid? = BT.grid(anchor: 0.1, phase: 1, span: 0.1...236),
        stepSec: Double? = 40, previous: MusicTransitionStyle? = nil
    ) -> MusicTransitionInputs {
        var i = BT.inputs(a: a, b: b)
        if let stepSec {
            i.incoming.analysis?.energy = DropFixtures.envelope(steps: [(stepSec * 10).rounded() / 10])
        }
        i.previousStyle = previous
        return i
    }

    static func dropPlan(_ i: MusicTransitionInputs) -> TransitionPlan? {
        B.dropSwapPlan(i, smart: MusicTransitionPlanner.smartPlan(i))
    }

    /// The outgoing second at which the incoming song's drop is heard.
    static func dropOnTimeline(_ plan: TransitionPlan, drop: Double) throws -> Double {
        let mixOut = try #require(plan.mixOutSec)
        let mixIn = try #require(plan.mixInSec)
        return mixOut + (drop - mixIn) / plan.incomingRate
    }

    @Test("at equal tempo the drop lands on the outgoing phrase end, 8 bars of lead")
    func equalTempo() throws {
        let i = Self.inputs()
        let grid = try #require(i.incoming.grid)
        let analysis = try #require(i.incoming.analysis)
        let drop = try #require(MusicDropDetector.best(in: analysis, grid: grid))
        let plan = try #require(Self.dropPlan(i))
        #expect(plan.style == .dropSwap && plan.mode == .beat && plan.reason == .ok)
        #expect(plan.overlapBars == 8 && plan.overlapSec == 16 && plan.fadeSeconds == 16)
        let phraseEnd = try #require(plan.outgoingEndSec)
        let heard = try Self.dropOnTimeline(plan, drop: drop.timeSec)
        #expect(abs(heard - phraseEnd) < 0.001, "drop at \(heard) s, phrase end \(phraseEnd) s")
        #expect(plan.mixOutSec == phraseEnd - plan.overlapSec)
        #expect(plan.fadeStartSec == plan.mixOutSec)
        #expect(plan.incomingStartSec == plan.mixInSec)
        // The phrase end is a phrase boundary of the outgoing grid and is not past the song's end.
        let a = try #require(i.outgoing.grid)
        let first = try #require(a.barTime(0))
        let phrases = (phraseEnd - first) / (8 * 4 * a.periodSec)
        #expect(abs(phrases - phrases.rounded()) < 1e-9)
        #expect(phraseEnd <= 236 + 1e-9)
    }

    @Test("with a rate nudge the drop still lands on the phrase end within a millisecond")
    func withNudge() throws {
        let b = BT.grid(period: 60 / 128, anchor: 0.1, phase: 1, span: 0.1...236)
        let i = Self.inputs(b: b, stepSec: 39.5)
        let analysis = try #require(i.incoming.analysis)
        let drop = try #require(MusicDropDetector.best(in: analysis, grid: b))
        let plan = try #require(Self.dropPlan(i))
        #expect(abs(plan.incomingRate - 0.9375) < 1e-9)
        let heard = try Self.dropOnTimeline(plan, drop: drop.timeSec)
        let phraseEnd = try #require(plan.outgoingEndSec)
        #expect(abs(heard - phraseEnd) < 0.001, "drop at \(heard) s, phrase end \(phraseEnd) s")
        // The incoming start is the lead earlier in item time, scaled by the rate.
        let mixIn = try #require(plan.mixInSec)
        #expect(abs(mixIn - (drop.timeSec - plan.overlapSec * plan.incomingRate)) < 1e-9)
    }

    @Test("a drop with fewer than 8 bars of room before it gets a 4 bar lead")
    func fourBarFallback() throws {
        // The drop is at about 12 s: 8 bars (16 s) would start before the song, 4 bars (8 s) fit.
        let i = Self.inputs(stepSec: 12.1)
        let analysis = try #require(i.incoming.analysis)
        let grid = try #require(i.incoming.grid)
        let drop = try #require(MusicDropDetector.best(in: analysis, grid: grid))
        #expect(drop.timeSec < 16)
        let plan = try #require(Self.dropPlan(i))
        #expect(plan.overlapBars == 4 && plan.overlapSec == 8)
        let heard = try Self.dropOnTimeline(plan, drop: drop.timeSec)
        let phraseEnd = try #require(plan.outgoingEndSec)
        let mixIn = try #require(plan.mixInSec)
        #expect(abs(heard - phraseEnd) < 0.001)
        #expect(mixIn >= 0)
    }

    @Test("no drop, no drop swap")
    func noDrop() {
        #expect(Self.dropPlan(Self.inputs(stepSec: nil)) == nil)
        // A step too early to have 4 bars before it.
        #expect(Self.dropPlan(Self.inputs(stepSec: 3)) == nil)
    }

    @Test("a drop swap needs two trusted grids with a downbeat and tempos that meet at the same bar length")
    func needsGrids() {
        #expect(Self.dropPlan(Self.inputs(a: nil)) == nil)
        #expect(Self.dropPlan(Self.inputs(b: nil)) == nil)
        #expect(Self.dropPlan(Self.inputs(a: BT.grid(confidence: 0.3))) == nil)
        #expect(Self.dropPlan(Self.inputs(a: BT.grid(phase: nil))) == nil)
        #expect(Self.dropPlan(Self.inputs(b: BT.grid(period: 60 / 131, anchor: 0.1, phase: 1))) == nil)
        // Double time is a different bar length: not a drop swap.
        #expect(Self.dropPlan(Self.inputs(b: BT.grid(period: 0.25, anchor: 0.1, phase: 1, span: 0.1...236))) == nil)
    }

    @Test("the planner picks the drop swap for a pair with a drop, and logs its name")
    func plannerPicksIt() throws {
        let plan = MusicTransitionPlanner.plan(Self.inputs(previous: nil))
        #expect(plan.mode == .beat)
        #expect(plan.style == .longBlend || plan.style == .dropSwap)
        let swap = MusicTransitionPlanner.plan(Self.inputs(previous: .longBlend))
        #expect(swap.style == .dropSwap)
        #expect(swap.overlapBars > 0 && swap.mode == .beat)
        let line = MusicTransitionLog.styleLine(from: "a", to: "b", style: swap.style, reason: swap.fallbackReason, previous: .longBlend)
        #expect(line == "transition_style from=a to=b style=dropSwap reason=none prev=longBlend")
        // And the pristine blend wins when nothing came before.
        #expect(plan.style == .longBlend)
    }

    @Test("a pair with no drop is never a drop swap, whatever came before")
    func neverWithoutDrop() {
        for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
            let plan = MusicTransitionPlanner.plan(Self.inputs(stepSec: nil, previous: previous))
            #expect(plan.style != .dropSwap)
        }
    }

    // MARK: Filter sweep

    @Test("the filter sweep is the beat blend with the same timing and a 30 Hz to 1.5 kHz ramp")
    func sweepIsTheBlend() throws {
        let i = BT.inputs()
        let blend = MusicTransitionPlanner.plan(i)
        let sweep = try #require(B.filterSweepPlan(from: blend))
        #expect(sweep.style == .filterSweep)
        #expect(sweep.sweepFromHz == 30 && sweep.sweepToHz == 1_500)
        var same = sweep
        same.style = .longBlend
        same.sweepFromHz = 0
        same.sweepToHz = 0
        same.bassSwapAtSec = blend.bassSwapAtSec
        same.bassHandoverSec = blend.bassHandoverSec
        #expect(same == blend, "nothing but the style and the ramp differs from the blend")
        // Only a beat blend can sweep.
        #expect(B.filterSweepPlan(from: MusicTransitionPlanner.smartPlan(i)) == nil)
        let cut = try #require(B.styledPlan(i, smart: MusicTransitionPlanner.smartPlan(i), style: .quickCut))
        #expect(B.filterSweepPlan(from: cut) == nil)
    }

    @Test("a sweep hands the incoming lows over where its high-pass passes 80 Hz, from its own range, not at the middle")
    func sweepBassSwapFollowsTheRamp() throws {
        var i = BT.inputs()
        i.bassSwapAvailable = true
        let blend = MusicTransitionPlanner.plan(i)
        let blendSwap = try #require(blend.bassSwapAtSec, "the blend has a bass swap to start from")
        let sweep = try #require(B.filterSweepPlan(from: blend))
        let swap = try #require(sweep.bassSwapAtSec)
        let expected = sweep.overlapSec * log(80 / sweep.sweepFromHz) / log(sweep.sweepToHz / sweep.sweepFromHz)
        #expect(abs(swap - expected) < 1e-9, "swap \(swap) expected \(expected)")
        #expect(swap < blendSwap && abs(swap / sweep.overlapSec - 0.25) < 0.02)
        #expect(swap + sweep.bassHandoverSec <= sweep.overlapSec + 1e-9 && sweep.bassHandoverSec > 0)
        // Another range moves it: nothing is hard-coded to a quarter.
        let wide = B.sweepBassSwapSec(overlap: 10, fromHz: 20, toHz: 20_000)
        #expect(abs(wide - 10 * log(4) / log(1000)) < 1e-9)
        // A sweep on a blend with no bass swap has none either.
        i.bassSwapAvailable = false
        let none = try #require(B.filterSweepPlan(from: MusicTransitionPlanner.plan(i)))
        #expect(none.bassSwapAtSec == nil)
    }

    @Test("the planner builds a sweep for a rising pair after a blend, and the ramp is on the plan")
    func plannerSweep() throws {
        var i = BT.inputs()
        i.outgoing.analysis?.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.4).encode()
        i.incoming.analysis?.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.7).encode()
        i.previousStyle = .longBlend
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.style == .filterSweep, "got \(plan.style.rawValue)")
        #expect(plan.sweepFromHz == 30 && plan.sweepToHz == 1_500)
        #expect(plan.overlapBars > 0 && plan.mode == .beat)
        // After the sweep, something else.
        i.previousStyle = .filterSweep
        #expect(MusicTransitionPlanner.plan(i).style != .filterSweep)
    }
}
