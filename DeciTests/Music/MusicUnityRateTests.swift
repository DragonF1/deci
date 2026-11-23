// DeciTests/Music/MusicUnityRateTests.swift
// wjyijr: every song plays at rate 1, its own tempo. A beat mix used to start the incoming deck at a matched rate (up to 8%
// off) and keep it for the whole song, because a rate write on a playing deck opens a gap in the output. Now the planner
// places the rate-1 start so the beats stay within `maxBeatDriftSec` of the outgoing ones, and refuses a blend where they
// would not.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicUnityRate")
struct MusicUnityRateTests {
    typealias B = MusicBeatPlanner
    typealias BT = MusicBeatPlannerTests

    // MARK: unityStart

    @Test("unityStart centres the walk: the start moves by half of (rate - 1) times the overlap")
    func centredShift() throws {
        let rate = 1.002, length = 16.0
        let start = try #require(B.unityStart(mixIn: 10, rate: rate, wallLength: length))
        #expect(abs(start - (10 + (rate - 1) * length / 2)) < 1e-12)
        let slow = try #require(B.unityStart(mixIn: 10, rate: 0.998, wallLength: length))
        #expect(abs(slow - (10 + (0.998 - 1) * length / 2)) < 1e-12)
        #expect(slow < 10 && start > 10)
    }

    @Test("unityStart with the end anchor moves by the whole walk, so the beats meet at the end of the overlap")
    func endAnchor() throws {
        let rate = 1.0015, length = 16.0
        let start = try #require(B.unityStart(mixIn: 10, rate: rate, wallLength: length, anchor: 1))
        #expect(abs(start - (10 + (rate - 1) * length)) < 1e-12)
        let beginning = try #require(B.unityStart(mixIn: 10, rate: rate, wallLength: length, anchor: 0))
        #expect(beginning == 10)
        // The whole walk is the drift at the other end: 32 ms is over the budget.
        #expect(B.unityStart(mixIn: 10, rate: 1.002, wallLength: length, anchor: 1) == nil)
    }

    @Test("unityStart clamps the start at 0 and still accepts it when the drift stays inside the budget")
    func clampAtZeroWithinBudget() throws {
        // Centred shift would be -16 ms; only 10 ms of song is before the start.
        let start = try #require(B.unityStart(mixIn: 0.01, rate: 0.998, wallLength: 16))
        #expect(start == 0)
        // Drift is 10 ms at the start and 22 ms at the end: inside 30 ms.
        let none = try #require(B.unityStart(mixIn: 0, rate: 0.9985, wallLength: 16))
        #expect(none == 0)
    }

    @Test("unityStart is nil when the clamp at 0 pushes the drift over the budget")
    func clampOverBudget() {
        // Nothing to shift into: the full 32 ms of walk shows at the end.
        #expect(B.unityStart(mixIn: 0, rate: 0.998, wallLength: 16) == nil)
        // 1 ms of room: 1 ms at the start, 31 ms at the end.
        #expect(B.unityStart(mixIn: 0.001, rate: 0.998, wallLength: 16) == nil)
    }

    @Test("unityStart accepts exactly 30 ms and refuses just over it")
    func budgetEdge() throws {
        // Centred drift is half of the walk: 60 ms of walk is 30 ms each way.
        #expect(B.maxBeatDriftSec == 0.030)
        #expect(B.unityStart(mixIn: 10, rate: 1.003, wallLength: 20) != nil)
        #expect(B.unityStart(mixIn: 10, rate: 1.00305, wallLength: 20) == nil)
        #expect(B.unityStart(mixIn: 10, rate: 0.99695, wallLength: 20) == nil)
        #expect(B.unityStart(mixIn: 10, rate: 1.00295, wallLength: 20) != nil)
    }

    @Test("unityStart at equal tempos is the start unchanged, and bad numbers give nil")
    func equalTempoAndBadInput() {
        #expect(B.unityStart(mixIn: 12.5, rate: 1, wallLength: 16) == 12.5)
        #expect(B.unityStart(mixIn: 12.5, rate: 1, wallLength: 16, anchor: 1) == 12.5)
        #expect(B.unityStart(mixIn: 0, rate: 1, wallLength: 16) == 0)
        #expect(B.unityStart(mixIn: .nan, rate: 1, wallLength: 16) == nil)
        #expect(B.unityStart(mixIn: 1, rate: .nan, wallLength: 16) == nil)
        #expect(B.unityStart(mixIn: 1, rate: 0, wallLength: 16) == nil)
        #expect(B.unityStart(mixIn: 1, rate: -1, wallLength: 16) == nil)
        #expect(B.unityStart(mixIn: 1, rate: 1, wallLength: -1) == nil)
        #expect(B.unityStart(mixIn: 1, rate: 1, wallLength: .infinity) == nil)
    }

    // MARK: Regression: no entry point ever plans a rate other than 1

    /// A pair at `outBpm` against `inBpm`, the outgoing deck held at `deckRate`.
    static func pair(_ outBpm: Double, _ inBpm: Double, deckRate: Double = 1) -> MusicTransitionInputs {
        let a = BT.grid(period: 60 / outBpm, anchor: 0.2, phase: 0)
        let b = BT.grid(period: 60 / inBpm, anchor: 0.1, phase: 1, span: 0.1...236)
        var i = BT.inputs(a: a, b: b)
        i.outgoing.deckRate = deckRate
        return i
    }

    /// Outgoing 120 against 100...140 in 0.5 bpm steps, half and double time, and outgoing deck rates 1 and 1.03.
    static var bpmPairs: [(out: Double, inn: Double, deck: Double)] {
        var pairs: [(Double, Double, Double)] = []
        for deck in [1.0, 1.03] {
            for tenths in stride(from: 1000, through: 1400, by: 5) {
                pairs.append((120, Double(tenths) / 10, deck))
            }
            // Half and double time, near and far.
            for inn in [60.0, 60.2, 61, 62, 64, 119.8, 120.2, 238, 240, 240.5, 242, 250] {
                pairs.append((120, inn, deck))
            }
            for out in [70.0, 140, 90, 180] {
                pairs.append((out, out * 2, deck))
                pairs.append((out, out / 2, deck))
                pairs.append((out, out * 2.01, deck))
            }
        }
        return pairs.map { (out: $0.0, inn: $0.1, deck: $0.2) }
    }

    @Test("every planner entry point that returns a plan plays the incoming song at rate 1, across a sweep of tempo pairs")
    func everyEntryPointPlansRateOne() throws {
        var counts: [String: Int] = [:]
        func check(_ plan: TransitionPlan?, _ name: String, _ label: String) {
            guard let plan else { return }
            counts[name, default: 0] += 1
            #expect(plan.incomingRate == 1, "\(name) at \(label) planned rate \(plan.incomingRate)")
        }
        for (out, inn, deck) in Self.bpmPairs {
            let label = "\(out) -> \(inn) bpm, deck \(deck)"
            let i = Self.pair(out, inn, deckRate: deck)
            let smart = MusicTransitionPlanner.smartPlan(i)
            check(B.plan(i, smart: smart), "plan", label)
            check(MusicTransitionPlanner.plan(i), "transitionPlan", label)
            check(B.floorBlendPlan(i, smart: smart), "floorBlendPlan", label)
            check(B.gridlessSweepPlan(i, smart: smart), "gridlessSweepPlan", label)
            check(B.loopExtendPlan(i, smart: smart), "loopExtendPlan", label)
            for style in MusicTransitionStyle.allCases {
                check(B.styledPlan(i, smart: smart, style: style), "styledPlan.\(style.rawValue)", label)
            }
            var dropped = MusicDropSwapPlanTests.inputs(
                a: BT.grid(period: 60 / out, anchor: 0.2, phase: 0),
                b: BT.grid(period: 60 / inn, anchor: 0.1, phase: 1, span: 0.1...236)
            )
            dropped.outgoing.deckRate = deck
            check(MusicDropSwapPlanTests.dropPlan(dropped), "dropSwapPlan", label)
        }
        // The sweep is not vacuous: the entry points did return plans for many pairs.
        #expect((counts["plan"] ?? 0) > 100, "main plans \(counts["plan"] ?? 0)")
        #expect((counts["floorBlendPlan"] ?? 0) > 100)
        #expect((counts["gridlessSweepPlan"] ?? 0) > 100)
        #expect((counts["dropSwapPlan"] ?? 0) > 0, "drop swaps \(counts["dropSwapPlan"] ?? 0)")
        #expect((counts["styledPlan.quickCut"] ?? 0) > 100)
    }

    @Test("the loop-extend plan is reachable at equal tempo and plays at rate 1")
    func loopExtendAtRateOne() throws {
        var i = MusicLoopExtendTests.shortIntro()
        i.outgoing.grid = BT.grid(period: 0.5, anchor: 0.2, phase: 0)
        i.incoming.grid = BT.grid(period: 0.5, anchor: 0.1, phase: 1, span: 0.1...236)
        let plan = try #require(B.loopExtendPlan(i, smart: MusicTransitionPlanner.smartPlan(i)))
        #expect(plan.style == .loopExtend && plan.incomingRate == 1)
    }

    @Test("a main beat blend never drifts more than 30 ms anywhere in its overlap, across the sweep")
    func mainBlendStaysInsideTheDriftBudget() throws {
        var blends = 0
        for (out, inn, deck) in Self.bpmPairs {
            let i = Self.pair(out, inn, deckRate: deck)
            let plan = B.plan(i, smart: MusicTransitionPlanner.smartPlan(i))
            guard plan.mode == .beat, plan.fallbackReason == nil else { continue }
            blends += 1
            let a = try #require(i.outgoing.grid), b = try #require(i.incoming.grid)
            let tempo = try #require(B.tempoMatch(outBpm: a.bpm * deck, inBpm: b.bpm))
            let walk = abs(tempo.rate - 1) * plan.overlapSec
            #expect(walk / 2 <= B.maxBeatDriftSec + 1e-9, "\(out) -> \(inn) bpm, deck \(deck): walk \(walk)")
        }
        #expect(blends > 10, "only \(blends) blends")
    }

    // MARK: 0.2 percent and 1.44 percent apart

    @Test("a pair 0.2 percent apart gets a main beat blend at rate 1 with a start centred on the drift")
    func pointTwoPercentIsABlend() throws {
        let inBpm = 120 / 1.002
        let i = Self.pair(120, inBpm)
        let plan = B.plan(i, smart: MusicTransitionPlanner.smartPlan(i))
        #expect(plan.mode == .beat && plan.fallbackReason == nil && plan.style == .longBlend, "plan: \(plan)")
        #expect(plan.incomingRate == 1)
        let b = try #require(i.incoming.grid)
        let tempo = try #require(B.tempoMatch(outBpm: 120, inBpm: inBpm))
        #expect(tempo.rate > 1.0019 && tempo.rate < 1.0021)
        let mixIn = try #require(plan.mixInSec)
        // The matched rate would start on a beat of the incoming grid; the rate-1 start is that beat moved by half the walk.
        let beat = b.beatTime(Int(((mixIn - b.anchorSec) / b.periodSec).rounded()))
        let expected = (tempo.rate - 1) * plan.overlapSec / 2
        #expect(abs(expected) > 0.005, "set up: the centring is a real shift, \(expected)")
        #expect(abs((mixIn - beat) - expected) < 1e-6, "start is \(mixIn - beat) s off its beat, expected \(expected)")
        #expect(plan.incomingStartSec == mixIn && plan.fallbackIncomingStartSec != nil)
        // Beats drift by the same amount at both ends of the overlap, in opposite directions.
        let atStart = mixIn - beat
        let atEnd = atStart - (tempo.rate - 1) * plan.overlapSec
        #expect(abs(atStart + atEnd) < 1e-6 && abs(atStart) <= B.maxBeatDriftSec)
    }

    @Test("the beats really meet half way: measured on both grids from the plan's mix points, 0.25 percent apart")
    func beatsMeetHalfWay() throws {
        let inBpm = 120 / 1.0025
        let i = Self.pair(120, inBpm)
        let plan = B.plan(i, smart: MusicTransitionPlanner.smartPlan(i))
        #expect(plan.mode == .beat && plan.fallbackReason == nil, "plan: \(plan)")
        #expect(plan.incomingRate == 1)
        let a = try #require(i.outgoing.grid), b = try #require(i.incoming.grid)
        let mixOut = try #require(plan.mixOutSec), mixIn = try #require(plan.mixInSec)
        // Both decks play at rate 1: wall time w into the overlap is mixOut + w on the outgoing song and mixIn + w on the
        // incoming one. The error is how far the incoming song is from its nearest beat while the outgoing one is on a beat.
        let first = Int(((mixOut - a.anchorSec) / a.periodSec).rounded())
        func error(atOutgoingBeat n: Int) -> Double {
            let position = mixIn + (a.beatTime(first + n) - mixOut)
            return position - b.beatTime(Int(((position - b.anchorSec) / b.periodSec).rounded()))
        }
        let beats = Int((plan.overlapSec / a.periodSec).rounded())
        let start = error(atOutgoingBeat: 0), middle = error(atOutgoingBeat: beats / 2), end = error(atOutgoingBeat: beats)
        #expect(abs(middle) < 0.002, "middle \(middle)")
        #expect(abs(start) > 0.01 && abs(end) > 0.01, "set up: a real walk, start \(start), end \(end)")
        #expect(abs(start + end) < 0.002, "start \(start) and end \(end) should mirror each other")
        #expect(max(abs(start), abs(end)) <= B.maxBeatDriftSec + 1e-6)
    }

    @Test("the logged pair, 120 against 118.3 bpm (1.44 percent), gets no main beat blend: tempoClash, and a rate-1 filter sweep floor")
    func loggedPairIsASweep() throws {
        let i = Self.pair(120, 118.3)
        let smart = MusicTransitionPlanner.smartPlan(i)
        let plan = B.plan(i, smart: smart)
        #expect(plan.mode != .beat && plan.fallbackReason == "tempoClash", "plan: \(plan.mode) \(plan.fallbackReason ?? "nil")")
        let floor = try #require(B.floorBlendPlan(i, smart: smart))
        #expect(floor.mode == .beat && floor.style == .filterSweep && floor.incomingRate == 1 && !floor.floorAligned)
        #expect(floor.sweepFromHz > 0)
        // What the transition planner hands the engine is that sweep.
        let final = MusicTransitionPlanner.plan(i)
        #expect(final.mode == .beat && final.style == .filterSweep && final.incomingRate == 1)
    }

    @Test("the floor's tempo window is 0.75 percent: 0.5 percent is an aligned blend, 1 percent a sweep")
    func floorWindow() throws {
        #expect(abs(B.floorTempoError - 0.0075) < 1e-12)
        let near = Self.pair(120, 120 / 1.005)
        let aligned = try #require(B.floorBlendPlan(near, smart: MusicTransitionPlanner.smartPlan(near)))
        #expect(aligned.style == .longBlend && aligned.floorAligned && aligned.incomingRate == 1)
        let far = Self.pair(120, 120 / 1.01)
        let sweep = try #require(B.floorBlendPlan(far, smart: MusicTransitionPlanner.smartPlan(far)))
        #expect(sweep.style == .filterSweep && !sweep.floorAligned && sweep.incomingRate == 1)
    }
}
