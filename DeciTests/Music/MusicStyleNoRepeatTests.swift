// DeciTests/Music/MusicStyleNoRepeatTests.swift
// Tier 4b P1: the planner asks the picker for every Mix pair and never repeats the style before it, grids or no grids.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicStyleNoRepeat")
struct MusicStyleNoRepeatTests {
    typealias BT = MusicBeatPlannerTests

    static func matched(previous: MusicTransitionStyle?) -> MusicTransitionInputs {
        var i = BT.inputs(a: BT.grid(period: 0.5), b: BT.grid(period: 0.5, anchor: 0.1, phase: 1, span: 0.1...236))
        i.previousStyle = previous
        return i
    }

    static func gridless(previous: MusicTransitionStyle?) -> MusicTransitionInputs {
        var i = BT.inputs(a: nil, b: nil)
        i.previousStyle = previous
        return i
    }

    static func clash(previous: MusicTransitionStyle?) -> MusicTransitionInputs {
        var i = BT.inputs(a: BT.grid(period: 0.5), b: BT.grid(period: 60 / 131, anchor: 0.1, phase: 1, span: 0.1...236))
        i.previousStyle = previous
        return i
    }

    /// A matched pair whose incoming song has a drop and whose energy rises, so every style is a candidate.
    static func everything(previous: MusicTransitionStyle?) -> MusicTransitionInputs {
        var i = matched(previous: previous)
        i.incoming.analysis?.energy = DropFixtures.envelope(steps: [40])
        i.outgoing.analysis?.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.4).encode()
        i.incoming.analysis?.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.7).encode()
        return i
    }

    @Test("a beat-matched pair is a long blend with no previous style, and something else right after a long blend")
    func blendThenSomethingElse() {
        #expect(MusicTransitionPlanner.plan(Self.matched(previous: nil)).style == .longBlend)
        let after = MusicTransitionPlanner.plan(Self.matched(previous: .longBlend))
        #expect(after.style != .longBlend)
        #expect(after.mode == .beat && after.overlapBars == 0)
    }

    @Test("a pair with no grid at all stays the plain fade until a fade would repeat, then it echoes or cuts without a grid")
    func gridlessRepeat() throws {
        let first = MusicTransitionPlanner.plan(Self.gridless(previous: nil))
        #expect(first.style == .longBlend && first.mode == .smart)
        let i = Self.gridless(previous: .longBlend)
        let smart = MusicTransitionPlanner.smartPlan(i)
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.style == .quickCut || plan.style == .echoOut)
        #expect(plan.mode == .beat && plan.incomingRate == 1)
        #expect(plan.mixOutSec == smart.fadeStartSec, "a cut without a grid lands at the fade start")
        let echo = try #require(MusicBeatPlanner.styledPlan(i, smart: smart, style: .echoOut))
        #expect(echo.echoDelaySec == MusicEchoSettings.untrustedDelaySeconds)
        #expect(echo.echoTailSec > 0 && echo.outgoingEndSec == (echo.mixOutSec ?? 0) + echo.echoTailSec)
    }

    @Test("whatever came before, no pair gets the same style twice in a row, grids or not")
    func neverRepeats() {
        let makers: [(MusicTransitionStyle?) -> MusicTransitionInputs] = [Self.matched, Self.gridless, Self.clash, Self.everything]
        for make in makers {
            for previous in MusicTransitionStyle.allCases {
                let plan = MusicTransitionPlanner.plan(make(previous))
                let ran = plan.mode == .beat ? plan.style : .longBlend
                #expect(ran != previous, "previous \(previous.rawValue) then \(ran.rawValue)")
            }
        }
    }

    @Test("a run over a pair with a drop and rising energy never repeats and uses the new styles")
    func everythingRun() {
        var previous: MusicTransitionStyle?
        var ran: [MusicTransitionStyle] = []
        for _ in 0..<10 {
            let plan = MusicTransitionPlanner.plan(Self.everything(previous: previous))
            let style: MusicTransitionStyle = plan.mode == .beat ? plan.style : .longBlend
            #expect(style != previous)
            ran.append(style)
            previous = style
        }
        #expect(ran.contains(.dropSwap) || ran.contains(.filterSweep))
    }

    @Test("when nothing else can be built the blend stays and is logged as noAlternative")
    func noAlternative() {
        var i = Self.gridless(previous: .longBlend)
        i.earliestMixOutSec = 10_000
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.style == .longBlend)
        #expect(plan.fallbackReason == MusicTransitionStylePicker.noAlternative)
        let line = MusicTransitionLog.styleLine(from: "a", to: "b", style: plan.style, reason: plan.fallbackReason, previous: .longBlend)
        #expect(line.contains("reason=noAlternative"))
    }

    @Test("a quick cut's fade is a few milliseconds, so the downbeat stays hard")
    func cutIsHard() {
        #expect(MusicBeatPlanner.cutFadeSeconds >= 0.003 && MusicBeatPlanner.cutFadeSeconds <= 0.005)
    }

    @Test("a run of low-confidence pairs gives fade, echo, fade, echo: the smart fade is not locked out")
    func lowConfidenceRun() {
        var previous: MusicTransitionStyle?
        var ran: [MusicTransitionStyle] = []
        for _ in 0..<6 {
            var i = BT.inputs(a: BT.grid(confidence: 0.3))
            i.previousStyle = previous
            let plan = MusicTransitionPlanner.plan(i)
            let style: MusicTransitionStyle = plan.mode == .beat ? plan.style : .longBlend
            ran.append(style)
            previous = style
        }
        #expect(ran == [.longBlend, .echoOut, .longBlend, .echoOut, .longBlend, .echoOut])
    }

    @Test("a run of pairs with a tempo clash never gets the fade: cut and echo take turns")
    func clashRun() {
        var previous: MusicTransitionStyle?
        for _ in 0..<4 {
            let plan = MusicTransitionPlanner.plan(Self.clash(previous: previous))
            #expect(plan.style == .quickCut || plan.style == .echoOut)
            previous = plan.style
        }
    }
}
