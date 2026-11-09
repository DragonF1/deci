// DeciTests/Music/MusicTransitionStyleTests.swift
// Tier 4b P1: the style picker and the planner hook. A pair that cannot beat mix gets a cut or an echo, never a plain fade,
// and the picker never repeats the style before it.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicTransitionStyle")
struct MusicTransitionStyleTests {
    typealias P = MusicTransitionStylePicker
    typealias S = MusicTransitionStyleInputs
    typealias BT = MusicBeatPlannerTests

    /// 120 bpm out, 131 bpm in: more than 8 percent apart.
    static func clash(previous: MusicTransitionStyle? = nil) -> MusicTransitionInputs {
        var i = BT.inputs(b: BT.grid(period: 60 / 131, anchor: 0.1, phase: 1))
        i.previousStyle = previous
        return i
    }

    static let samples: [S] = [
        S(), S(tempoError: 0), S(tempoError: 0.2), S(tempoError: 0.5, energyJump: 0.5, keyDistance: 5),
        S(tempoError: 0.02, energyJump: -0.4, outroEnergy: 0.2, introEnergy: 0.9, keyDistance: 4),
        S(tempoError: 0.2, energyJump: -0.4, outroEnergy: 0.1, gridTrusted: true, genres: ["Ambient"]),
        S(tempoError: .nan, energyJump: .nan), S(tempoError: 0.01, outroEnergy: 0.9, introEnergy: 0.9),
    ]

    @Test("the picker never returns the previous style, whatever the signals")
    func neverRepeats() {
        for signals in Self.samples {
            for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
                let pick = P.pick(signals, previous: previous)
                #expect(pick != previous)
                #expect(MusicTransitionStyle.pickable.contains(pick))
                #expect(!P.ranked(signals, previous: previous).contains { $0 == previous })
            }
        }
    }

    @Test("the picker is deterministic")
    func deterministic() {
        for signals in Self.samples {
            let first = P.ranked(signals, previous: .quickCut)
            for _ in 0..<5 { #expect(P.ranked(signals, previous: .quickCut) == first) }
        }
    }

    @Test("unknown numbers never throw and fall to a blend")
    func unknowns() {
        #expect(P.pick(S(), previous: nil) == .longBlend)
        #expect(P.pick(S(tempoError: .nan, energyJump: .infinity), previous: nil) == .longBlend)
        #expect(!P.isClash(S()))
    }

    @Test("a tempo clash picks a cut or an echo, a near tempo a blend")
    func clashPicks() {
        let big = P.pick(S(tempoError: 0.3), previous: nil)
        #expect(big == .quickCut || big == .echoOut)
        #expect(P.pick(S(tempoError: 0.3), previous: .quickCut) == .echoOut)
        #expect(P.pick(S(tempoError: 0.3), previous: .echoOut) == .quickCut)
        #expect(P.pick(S(tempoError: 0.02), previous: nil) == .longBlend)
    }

    @Test("genres only break a tie, they never beat a signal")
    func genresTieBreak() {
        let soft = S(tempoError: 0.3, genres: ["ambient", "folk"])
        let punchy = S(tempoError: 0.3, genres: ["techno"])
        #expect(P.pick(soft, previous: nil) == P.pick(S(tempoError: 0.3), previous: nil))
        #expect(P.pick(punchy, previous: nil) == P.pick(S(tempoError: 0.3), previous: nil))
    }

    @Test("the planner turns a tempo clash into a cut or echo plan, not a plain fade")
    func plannerClash() throws {
        let plan = MusicTransitionPlanner.plan(Self.clash())
        #expect(plan.mode == .beat)
        #expect(plan.style == .quickCut || plan.style == .echoOut)
        #expect(plan.fallbackReason == "tempoClash")
        #expect(plan.overlapBars == 0 && plan.incomingRate == 1)
        #expect(plan.mixOutSec != nil && plan.mixInSec != nil)
        let next = MusicTransitionPlanner.plan(Self.clash(previous: plan.style))
        #expect(next.style != plan.style)
        #expect(next.mode == .beat)
    }

    @Test("a beat mix carries the long blend style, and a blend right after a blend gets the next style")
    func blendThenStyle() {
        let first = MusicTransitionPlanner.plan(BT.inputs())
        #expect(first.mode == .beat && first.style == .longBlend && first.overlapBars > 0)
        var again = BT.inputs()
        again.previousStyle = .longBlend
        let second = MusicTransitionPlanner.plan(again)
        #expect(second.style != .longBlend)
        #expect(second.style == .quickCut || second.style == .echoOut)
        again.previousStyle = .quickCut
        #expect(MusicTransitionPlanner.plan(again).style == .longBlend)
    }

    @Test("a grid that failed the trust checks keeps the guarded fade, and gets a style when a fade would repeat")
    func lowConfidence() {
        let low = BT.grid(confidence: 0.3)
        let first = MusicTransitionPlanner.plan(BT.inputs(a: low))
        #expect(first.mode == .smart && first.fallbackReason == "gridLowConf")
        var again = BT.inputs(a: low)
        again.previousStyle = .longBlend
        let plan = MusicTransitionPlanner.plan(again)
        #expect(plan.mode == .beat && plan.style == .echoOut)
        #expect(plan.fallbackReason == "gridLowConf")
        var none = BT.inputs(a: BT.grid(phase: nil, confidence: 0.3))
        #expect(MusicTransitionPlanner.plan(none).mode == .smart)
        none.previousStyle = .longBlend
        let noPhase = MusicTransitionPlanner.plan(none)
        // No downbeat at all: the gridless echo at the smart plan's fade start.
        #expect(noPhase.mode == .beat && noPhase.style == .echoOut && noPhase.fallbackReason == "gridLowConf")
    }

    @Test("styles apply only with Mix on: off, manual skip, album order and loop stay plain")
    func onlyWithMix() {
        var off = Self.clash(); off.beatMixEnabled = false
        #expect(MusicTransitionPlanner.plan(off).style == .longBlend && MusicTransitionPlanner.plan(off).mode == .smart)
        var skip = Self.clash(); skip.manualSkip = true
        #expect(MusicTransitionPlanner.plan(skip).mode == .fixed)
        var album = Self.clash(); album.albumInOrder = true
        #expect(MusicTransitionPlanner.plan(album).mode == .gapless)
        var fadeOff = Self.clash(); fadeOff.crossfadeOn = false
        #expect(MusicTransitionPlanner.plan(fadeOff).style == .longBlend)
        #expect(MusicTransitionPlanner.plan(fadeOff).mode != .beat)
    }

    @Test("the style line is ids and plain words only")
    func styleLine() {
        let line = MusicTransitionLog.styleLine(
            from: "aaaaaaaaaaa", to: "bbbbbbbbbbb", style: .echoOut, reason: "tempoClash", previous: .quickCut
        )
        #expect(line == "transition_style from=aaaaaaaaaaa to=bbbbbbbbbbb style=echoOut reason=tempoClash prev=quickCut")
        #expect(MusicTransitionLog.styleLine(from: "a", to: "b", style: .quickCut, reason: nil, previous: nil)
            == "transition_style from=a to=b style=quickCut reason=none prev=none")
        #expect(!line.contains("\u{2014}"))
    }

    // MARK: Low-confidence pairs (follow-up 1)

    @Test("a cut needs a trusted downbeat: without a trusted grid the echo outranks it, whatever the energy says")
    func echoBeforeCutWithoutGrid() {
        var jump = MusicTransitionStyleInputs(tempoError: 0.0, energyJump: 0.5, keyDistance: 5, gridTrusted: false)
        #expect(MusicTransitionStylePicker.ranked(jump, previous: .longBlend) == [.echoOut, .quickCut])
        jump.tempoError = 0.4
        #expect(MusicTransitionStylePicker.ranked(jump, previous: nil).first == .echoOut)
        jump.gridTrusted = true
        #expect(MusicTransitionStylePicker.ranked(jump, previous: .longBlend).first == .quickCut)
    }

    @Test("a refusal that is not a clash ranks the fade first unless it came before; a clash ranks the fade last")
    func fadeCandidate() {
        let calm = MusicTransitionStyleInputs(tempoError: 0.0, gridTrusted: false)
        #expect(MusicTransitionStylePicker.ranked(calm, previous: nil) == [.longBlend, .echoOut, .quickCut])
        #expect(MusicTransitionStylePicker.ranked(calm, previous: .echoOut).first == .longBlend)
        #expect(MusicTransitionStylePicker.ranked(calm, previous: .longBlend).first == .echoOut)
        let clash = MusicTransitionStyleInputs(tempoError: 0.4, gridTrusted: true)
        #expect(MusicTransitionStylePicker.ranked(clash, previous: nil).last == .longBlend)
    }
}
