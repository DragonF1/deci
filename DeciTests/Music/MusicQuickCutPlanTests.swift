// DeciTests/Music/MusicQuickCutPlanTests.swift
// Tier 4b P1: the cut and echo plans land on bar lines, for any tempo gap.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicQuickCutPlan")
struct MusicQuickCutPlanTests {
    typealias BT = MusicBeatPlannerTests

    static func plan(_ style: MusicTransitionStyle, aBpm: Double = 120, bBpm: Double = 131, trusted: Bool = true) throws -> (TransitionPlan, MusicBeatGrid, MusicBeatGrid) {
        let a = BT.grid(period: 60 / aBpm, anchor: 0.2, phase: 0, confidence: trusted ? 0.9 : 0.3)
        let b = BT.grid(period: 60 / bBpm, anchor: 0.1, phase: 1, span: 0.1...236)
        let i = BT.inputs(a: a, b: b)
        let smart = MusicTransitionPlanner.smartPlan(i)
        return (try #require(MusicBeatPlanner.styledPlan(i, smart: smart, style: style)), a, b)
    }

    static func onBar(_ time: Double, grid: MusicBeatGrid) -> Bool {
        let beats = (time - grid.anchorSec) / grid.periodSec - Double(grid.downbeatPhase ?? 0)
        let bars = beats / 4
        return abs(bars - bars.rounded()) * 4 * grid.periodSec < 0.001
    }

    @Test("a cut has no overlap, rate 1 and a fade of a few ms, on a bar line of each song, at any tempo gap")
    func cutShape() throws {
        for (aBpm, bBpm) in [(90.0, 150.0), (120, 131), (150, 90), (128, 128), (70, 175)] {
            let (plan, a, b) = try Self.plan(.quickCut, aBpm: aBpm, bBpm: bBpm)
            #expect(plan.mode == .beat && plan.style == .quickCut)
            #expect(plan.overlapBars == 0 && plan.incomingRate == 1)
            #expect(plan.fadeSeconds > 0 && plan.fadeSeconds <= 0.01)
            let out = try #require(plan.mixOutSec), mixIn = try #require(plan.mixInSec)
            #expect(Self.onBar(out, grid: a))
            #expect(Self.onBar(mixIn, grid: b))
            #expect(plan.fadeStartSec == out && plan.outgoingEndSec == out)
            #expect(plan.incomingStartSec == mixIn && plan.echoTailSec == 0)
            #expect(plan.bassSwapAtSec == nil)
            #expect(plan.fallbackIncomingStartSec != nil)
        }
    }

    @Test("an echo delays one beat on a trusted grid, 0.375 s on a shaky one, and keeps the outgoing song playing for the tail")
    func echoShape() throws {
        let (trusted, a, _) = try Self.plan(.echoOut)
        #expect(trusted.style == .echoOut)
        #expect(abs(trusted.echoDelaySec - a.periodSec) < 1e-9)
        #expect(trusted.echoTailSec > 0 && trusted.echoTailSec <= MusicBeatPlanner.maxEchoTailSec)
        let out = try #require(trusted.mixOutSec)
        #expect(abs(try #require(trusted.outgoingEndSec) - (out + trusted.echoTailSec)) < 1e-9)
        let (shaky, _, _) = try Self.plan(.echoOut, trusted: false)
        #expect(shaky.echoDelaySec == 0.375)
    }

    @Test("the tail never runs past the end of the song")
    func tailTruncated() throws {
        for period in stride(from: 0.2, through: 0.5, by: 0.01) {
            let a = BT.grid(period: period, anchor: 0.2, phase: 0)
            let i = BT.inputs(a: a)
            let smart = MusicTransitionPlanner.smartPlan(i)
            let plan = try #require(MusicBeatPlanner.styledPlan(i, smart: smart, style: .echoOut))
            let end = try #require(plan.outgoingEndSec)
            #expect(end <= 236 + 1e-9)
            let out = try #require(plan.mixOutSec)
            #expect(abs(plan.echoTailSec - min(min(period * 6, 3), 236 - out)) < 1e-9)
        }
    }

    @Test("no plan for a mix point already past or a style that is not a cut or an echo; no grid falls to the smart fade start")
    func refusals() throws {
        let none = BT.inputs(a: nil)
        let smart = MusicTransitionPlanner.smartPlan(none)
        let gridless = try #require(MusicBeatPlanner.styledPlan(none, smart: smart, style: .quickCut))
        #expect(gridless.mixOutSec == smart.fadeStartSec)
        var late = BT.inputs()
        late.earliestMixOutSec = 1_000
        #expect(MusicBeatPlanner.styledPlan(late, smart: MusicTransitionPlanner.smartPlan(late), style: .quickCut) == nil)
        let ok = BT.inputs()
        #expect(MusicBeatPlanner.styledPlan(ok, smart: MusicTransitionPlanner.smartPlan(ok), style: .longBlend) == nil)
    }
}
