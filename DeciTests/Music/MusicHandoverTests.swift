// DeciTests/Music/MusicHandoverTests.swift
// Two songs whose tempos do not meet: a short handover with the EQ instead of a filter sweep every time.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicHandover")
struct MusicHandoverTests {
    typealias B = MusicBeatPlanner
    typealias BT = MusicBeatPlannerTests
    typealias Floor = MusicFloorBlendTests

    static func inputs(period: Double = 60.0 / 95, out: Double = 0.5) -> MusicTransitionInputs {
        BT.inputs(a: BT.grid(period: out), b: BT.grid(period: period, anchor: 0.1, phase: 1, span: 0.1...236))
    }

    static func floor(_ i: MusicTransitionInputs) throws -> TransitionPlan {
        try #require(B.floorBlendPlan(i, smart: Floor.smart(i)))
    }

    @Test("the fade is whole bars of the outgoing song, the new bass lands on the one of both songs", arguments: [0.3, 0.36, 0.42, 0.5, 0.6, 0.75, 0.85, 1.0])
    func landsOnBothOnes(out: Double) throws {
        let i = Self.inputs(out: out)
        let plan = try Self.floor(i)
        #expect(plan.mode == .beat && plan.style == .longBlend && plan.handsOverByEQ && plan.floorAligned && plan.incomingRate == 1)
        let bar = 4 * out
        let bars = plan.fadeSeconds / bar
        #expect(abs(bars - bars.rounded()) < 1e-9 && plan.fadeSeconds >= B.handoverMinSec - 1e-9 && plan.fadeSeconds < 6.5)
        let land = try #require(plan.bassSwapAtSec) + plan.bassHandoverSec
        #expect(abs(land - (bars > 1.5 ? bar : bar / 2)) < 1e-9)
        let a = try #require(i.outgoing.grid), b = try #require(i.incoming.grid)
        #expect(Floor.barOffset(a, try #require(plan.mixOutSec) + land) < 0.001)
        #expect(Floor.barOffset(b, try #require(plan.mixInSec) + land) < 0.001)
        #expect(try #require(plan.mixInSec) >= Floor.smart(i).incomingStartSec - 1e-9 && plan.incomingStartSec == plan.mixInSec)
        #expect(plan.outgoingEndSec == (plan.mixOutSec ?? 0) + plan.fadeSeconds)
    }

    @Test("the outgoing deck's own rate counts: its bars are shorter on the clock and the ones still meet")
    func deckRate() throws {
        var i = Self.inputs()
        i.outgoing.deckRate = 1.06
        let plan = try Self.floor(i)
        let land = try #require(plan.bassSwapAtSec) + plan.bassHandoverSec
        #expect(abs(plan.fadeSeconds - 2 * 2 / 1.06) < 1e-9)
        #expect(Floor.barOffset(try #require(i.outgoing.grid), try #require(plan.mixOutSec) + land * 1.06) < 0.001)
        #expect(Floor.barOffset(try #require(i.incoming.grid), try #require(plan.mixInSec) + land) < 0.001)
    }

    @Test("without both downbeats there is no one to land on: 6 s and an early, quick bass change")
    func quick() throws {
        for i in [
            BT.inputs(a: BT.grid(phase: nil), b: BT.grid(period: 60.0 / 95, anchor: 0.1, phase: 1)),
            BT.inputs(b: BT.grid(period: 60.0 / 95, anchor: 0.1, phase: nil)), BT.inputs(a: nil), BT.inputs(b: nil),
        ] {
            let plan = try Self.floor(i)
            #expect(B.handoverStep(i) == nil)
            #expect(plan.handsOverByEQ && !plan.floorAligned && plan.fadeSeconds == 6 && plan.bassSwapAtSec == 1.5)
        }
    }

    @Test("a quiet ending or a quiet start can run on: the usual 8 s with the bass handing over in the middle")
    func quietEdge() throws {
        for lufs in [-40.0, -8.0] {
            var ending = Self.inputs()
            ending.outgoing.analysis?.outroLUFS = lufs
            var opening = Self.inputs()
            opening.incoming.analysis?.introLUFS = lufs
            for i in [ending, opening] {
                let quiet = lufs == -40
                #expect(MusicTransitionStylePicker.hasQuietEdge(i) == quiet)
                let plan = try Self.floor(i)
                #expect(plan.handsOverByEQ == !quiet && plan.style == .longBlend)
                if quiet { #expect(plan.fadeSeconds == 8 && plan.bassSwapAtSec == 4 && !plan.floorAligned) }
            }
            // Left at a DJ exit the ending is not what is heard.
            ending.djMixOutSec = 120
            #expect(!MusicTransitionStylePicker.hasQuietEdge(ending))
        }
    }

    @Test("at a DJ exit the new bass lands on it and the plan counts as leaving there", arguments: [0.36, 0.5, 0.85])
    func atAnExit(out: Double) throws {
        var i = Self.inputs(out: out)
        let exit = 0.2 + 4 * out * (120 / (4 * out)).rounded()
        i.djMixOutSec = exit
        var smart = Floor.smart(i)
        smart.fadeStartSec = exit
        let plan = try #require(B.floorBlendPlan(i, smart: smart))
        let land = try #require(plan.bassSwapAtSec) + plan.bassHandoverSec
        #expect(abs((plan.mixOutSec ?? 0) + land - exit) < 0.001)
        #expect(MusicDJLength.leaves(plan, at: .init(point: exit, normal: 200, section: .chorus2)))
    }

    @Test("a late skip leaves from where it is, never before the earliest mix-out")
    func earliest() throws {
        var i = Self.inputs()
        i.earliestMixOutSec = 226.3
        let plan = try Self.floor(i)
        #expect(plan.handsOverByEQ && (plan.mixOutSec ?? 0) >= 226.3 - 1e-9 && (plan.outgoingEndSec ?? 0) <= 236 + 1e-9)
    }

    // MARK: The EQ of it

    @Test("the old song's mids and highs are gone as the new bass lands, and its voice with them")
    func eq() throws {
        let i = Self.inputs()
        let plan = try Self.floor(i)
        let eq = try #require(MusicMixEQPlan.make(for: plan, i))
        let land = try #require(plan.bassSwapAtSec) + plan.bassHandoverSec
        #expect(eq.outgoingMid.last == .init(at: land, gain: MusicMixEQPlan.handoverMidEnd))
        #expect(eq.outgoingMid.first?.gain == 1 && (eq.outgoingMid.first?.at ?? 0) < land)
        let last = try #require(eq.outgoingHigh.last)
        #expect(last.gain == MusicMixEQPlan.handoverHighEnd && last.at <= land + 1 && last.at > land)
        #expect(eq.incomingMid.last?.gain == 1 && (eq.incomingMid.last?.at ?? 9) <= land + 1e-9)
        for moves in [eq.incomingMid, eq.outgoingMid, eq.outgoingHigh] {
            #expect(zip(moves, moves.dropFirst()).allSatisfy { $0.at < $1.at } && moves.allSatisfy { $0.at >= 0 && $0.at <= plan.overlapSec })
        }
    }

    @Test("the quick one has the same shape, early in its 6 s")
    func quickEQ() throws {
        let i = BT.inputs(a: nil, b: nil)
        let plan = try Self.floor(i)
        let eq = try #require(MusicMixEQPlan.make(for: plan, i))
        #expect(eq.outgoingMid.last == .init(at: 1.75, gain: MusicMixEQPlan.handoverMidEnd))
        #expect(eq.outgoingHigh.last == .init(at: 2.25, gain: MusicMixEQPlan.handoverHighEnd))
    }

    @Test("a handover says so in the beat plan log line")
    func logLine() throws {
        let plan = try Self.floor(Self.inputs())
        let line = MusicTransitionLog.beatPlanLine(from: "a", to: "b", plan: plan, bpmA: 120, bpmB: 95)
        #expect(line.contains(" byEQ=1"))
        let matched = try Self.floor(BT.inputs())
        #expect(!MusicTransitionLog.beatPlanLine(from: "a", to: "b", plan: matched, bpmA: 120, bpmB: 120).contains("byEQ"))
    }
}
