// DeciTests/Music/MusicFloorBlendTests.swift
// Tier 4c Batch B: the floor of every Mix transition. Whatever the grids, tempos, phrase room or singers say, a pair gets a
// 6 to 8 s blend in beat mode at rate 1 with a bass swap; only a song too short for it keeps the plain smart fade. Also the
// vocal cut-off guard and the cold-intro rule.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicFloorBlend")
struct MusicFloorBlendTests {
    typealias B = MusicBeatPlanner
    typealias BT = MusicBeatPlannerTests

    static func smart(_ i: MusicTransitionInputs) -> TransitionPlan { MusicTransitionPlanner.smartPlan(i) }

    // MARK: floorBlendPlan

    @Test("a matched pair gets a long blend floor: 8 s, rate 1, bass swap at the middle, 2 s handover, from the smart start")
    func matchedFloor() throws {
        let i = BT.inputs()
        let smart = Self.smart(i)
        let plan = try #require(B.floorBlendPlan(i, smart: smart))
        #expect(plan.mode == .beat && plan.style == .longBlend && plan.reason == .ok)
        #expect(plan.incomingRate == 1 && plan.fadeSeconds == 8 && plan.overlapSec == 8 && plan.overlapBars == 0)
        #expect(plan.mixOutSec == smart.fadeStartSec && plan.mixInSec == smart.incomingStartSec)
        #expect(plan.bassSwapAtSec == 4 && plan.bassHandoverSec == 2)
        #expect(plan.outgoingEndSec == (plan.mixOutSec ?? 0) + 8)
        #expect(plan.glideBackSec == 0)
    }

    @Test("a tempo mismatch above 3 percent thins the outgoing song early: a sweep from the settings, the bass in at about a quarter")
    func mismatchedFloorThins() throws {
        let i = BT.inputs(b: BT.grid(period: 60 / 131, anchor: 0.1, phase: 1))
        let plan = try #require(B.floorBlendPlan(i, smart: Self.smart(i)))
        #expect(plan.mode == .beat && plan.style == .filterSweep && plan.incomingRate == 1)
        #expect(plan.sweepFromHz == Double(MusicSweepSettings.defaultFromHz) && plan.sweepToHz == Double(MusicSweepSettings.defaultToHz))
        let swap = try #require(plan.bassSwapAtSec)
        #expect(swap < plan.fadeSeconds / 2 && abs(swap / plan.fadeSeconds - 0.25) < 0.02)
        // Within 3 percent (and at double time) the kicks stay together: no thinning.
        let close = BT.inputs(b: BT.grid(period: 0.5 * 0.98, anchor: 0.1, phase: 1))
        #expect(try #require(B.floorBlendPlan(close, smart: Self.smart(close))).style == .longBlend)
        let double = BT.inputs(b: BT.grid(period: 0.25, anchor: 0.1, phase: 1))
        #expect(try #require(B.floorBlendPlan(double, smart: Self.smart(double))).style == .longBlend)
    }

    @Test("with no grid at all (unknown tempo) the floor still blends, thinned")
    func gridlessFloor() throws {
        let i = BT.inputs(a: nil, b: nil)
        let plan = try #require(B.floorBlendPlan(i, smart: Self.smart(i)))
        #expect(plan.mode == .beat && plan.style == .filterSweep && plan.fadeSeconds == 8 && plan.bassSwapAtSec != nil)
    }

    @Test("a song too short to hold the fade gets no floor, and the plain smart fade stays")
    func tooShort() {
        let i = BT.inputs(a: nil, b: nil, bDuration: 12)
        #expect(B.floorBlendPlan(i, smart: Self.smart(i)) == nil)
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.mode == .smart)
    }

    @Test("the planner never gives up: gridless, low-confidence, clashing and no-phrase-room pairs all blend")
    func plannerNeverGivesUp() {
        let pairs: [MusicTransitionInputs] = [
            BT.inputs(a: nil, b: nil), BT.inputs(a: BT.grid(confidence: 0.3)), BT.inputs(a: BT.grid(phase: nil, confidence: 0.3)),
            BT.inputs(b: BT.grid(period: 60 / 131, anchor: 0.1, phase: 1)), BT.inputs(bDuration: 60),
        ]
        for i in pairs {
            let plan = MusicTransitionPlanner.plan(i)
            #expect(plan.mode == .beat && plan.fadeSeconds >= 6 && plan.fadeSeconds <= 16)
            #expect(plan.overlapBars > 0 || plan.bassSwapAtSec != nil, "a floor blend always swaps the bass")
            #expect(plan.style != .quickCut && plan.style != .echoOut)
        }
    }

    // MARK: gridless sweep

    @Test("the gridless sweep is an 8 s floor blend with the sweep from the settings and the bass in where it passes 80 Hz")
    func gridlessSweep() throws {
        let i = BT.inputs(a: nil, b: nil)
        let plan = try #require(B.gridlessSweepPlan(i, smart: Self.smart(i)))
        #expect(plan.mode == .beat && plan.style == .filterSweep && plan.fadeSeconds == 8 && plan.incomingRate == 1)
        #expect(plan.sweepFromHz == Double(MusicSweepSettings.defaultFromHz) && plan.sweepToHz == Double(MusicSweepSettings.defaultToHz))
        let expected = B.sweepBassSwapSec(overlap: 8, fromHz: plan.sweepFromHz, toHz: plan.sweepToHz)
        #expect(plan.bassSwapAtSec == expected)
        // A matched pair with grids is swept too.
        let matched = BT.inputs()
        #expect(try #require(B.gridlessSweepPlan(matched, smart: Self.smart(matched))).style == .filterSweep)
    }

    // MARK: cold intros

    @Test("a smart fade shorter than 6 s (a cold intro) is lengthened to a blend of at least 6 s")
    func coldIntro() {
        // The outgoing song ends hard (outro length 0): the smart fade is 2 s.
        let i = BT.inputs(a: nil, b: nil, aOutro: 236)
        let smart = Self.smart(i)
        #expect(smart.fadeSeconds < MusicTransitionPlanner.floorFadeThreshold, "fade \(smart.fadeSeconds)")
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.mode == .beat && plan.fadeSeconds >= 6)
    }

    // MARK: vocal cut-off guard

    @Test("with lyric intervals an end inside a sung line cuts the singer; the edges and the gaps do not")
    func cutsWithIntervals() {
        let lines: [ClosedRange<Double>] = [10...20, 30...40]
        #expect(MusicVocalGuard.cutsOutgoingSinger(lines, endSec: 15))
        #expect(!MusicVocalGuard.cutsOutgoingSinger(lines, endSec: 25))
        #expect(!MusicVocalGuard.cutsOutgoingSinger(lines, endSec: 20))
        #expect(!MusicVocalGuard.cutsOutgoingSinger(lines, endSec: 5))
        #expect(!MusicVocalGuard.cutsOutgoingSinger(lines, endSec: .nan))
        #expect(!MusicVocalGuard.cutsOutgoingSinger([], endSec: 15))
    }

    @Test("without intervals the proxy is: no cut before the outro starts")
    func cutsWithProxy() {
        let analysis = BT.inputs().outgoing.analysis
        let outro = analysis?.outroStart ?? 0
        #expect(MusicVocalGuard.cutsOutgoingSinger(outgoing: analysis, intervals: nil, endSec: outro - 10))
        #expect(!MusicVocalGuard.cutsOutgoingSinger(outgoing: analysis, intervals: nil, endSec: outro + 5))
        #expect(!MusicVocalGuard.cutsOutgoingSinger(outgoing: nil, intervals: nil, endSec: 100))
    }

    @Test("the nearest vocal gap within 4 s is found, and none when the line is longer than that")
    func nearestGap() throws {
        let lines: [ClosedRange<Double>] = [210...227]
        let gap = try #require(MusicVocalGuard.nearestGap(lines, to: 226))
        #expect(gap > 227 && gap < 227.2)
        #expect(MusicVocalGuard.nearestGap([200...240], to: 220) == nil)
    }

    @Test("a floor blend that would end mid-word is moved to end in a gap between lines")
    func floorMovesOffASinger() throws {
        var i = BT.inputs(a: nil, b: nil)
        i.vocalGuardEnabled = true
        let smart = Self.smart(i)
        let end = (smart.fadeStartSec ?? 0) + 8
        let lines: [ClosedRange<Double>] = [(end - 12)...(end + 1)]
        i.outgoing.vocalIntervals = lines
        let plan = try #require(B.floorBlendPlan(i, smart: smart))
        let planEnd = (plan.mixOutSec ?? 0) + plan.fadeSeconds
        #expect(!MusicVocalGuard.cutsOutgoingSinger(lines, endSec: planEnd), "ends at \(planEnd) inside \(lines)")
        #expect(plan.mode == .beat && plan.fadeSeconds >= 6)
    }

    @Test("two singers beyond the budget move the floor blend off the smart start; when nowhere is clean the least bad is kept and marked min")
    func floorKeepsSingersApart() throws {
        var i = BT.inputs(a: nil, b: nil)
        i.vocalGuardEnabled = true
        let smart = Self.smart(i)
        let start = smart.fadeStartSec ?? 0
        i.outgoing.vocalIntervals = [(start + 1)...(start + 6)]
        i.incoming.vocalIntervals = [0...60]
        let plan = try #require(B.floorBlendPlan(i, smart: smart))
        let collision = MusicVocalGuard.collisionSec(
            outgoing: i.outgoing.analysis, incoming: i.incoming.analysis, outStart: plan.mixOutSec ?? 0, inStart: plan.mixInSec ?? 0,
            length: plan.fadeSeconds, outgoingIntervals: i.outgoing.vocalIntervals, incomingIntervals: i.incoming.vocalIntervals
        ) ?? 99
        #expect(collision <= MusicVocalGuard.budgetSec, "collision \(collision)")
        #expect(plan.mixOutSec != start)
        // Singing the whole way: nowhere is clean, so the blend stays and says so.
        i.outgoing.vocalIntervals = [0...236]
        let worst = try #require(B.floorBlendPlan(i, smart: smart))
        #expect(worst.mode == .beat && worst.vocalAction == "min")
    }
}
