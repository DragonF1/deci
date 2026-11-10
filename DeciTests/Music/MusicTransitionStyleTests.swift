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

    @Test("the picker always has an answer, a pickable one, and a long blend is always on the list")
    func alwaysAnswers() {
        for signals in Self.samples {
            for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
                let pick = P.pick(signals, previous: previous)
                #expect(MusicTransitionStyle.pickable.contains(pick))
                #expect(P.ranked(signals, previous: previous).contains(.longBlend))
            }
        }
    }

    @Test("a repeat is marked down, not removed: a long blend repeats freely, a cut loses twice as much")
    func repeatPenalty() {
        #expect(P.penalty(.longBlend, previous: .longBlend) == 0)
        #expect(P.penalty(.loopExtend, previous: .loopExtend) == 0)
        #expect(P.penalty(.filterSweep, previous: .filterSweep) == P.repeatPenalty)
        #expect(P.penalty(.quickCut, previous: .quickCut) == 2 * P.repeatPenalty)
        #expect(P.penalty(.echoOut, previous: .echoOut) == 2 * P.repeatPenalty)
        #expect(P.penalty(.quickCut, previous: .longBlend) == 0)
        #expect(P.penalty(.quickCut, previous: nil) == 0)
        #expect(P.pick(S(tempoError: 0.0), previous: .longBlend) == .longBlend)
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

    @Test("a tempo clash is a blend, never a cut or an echo, whatever came before")
    func clashPicks() {
        for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
            let ranked = P.ranked(S(tempoError: 0.3, tailDropDb: 1, mixOutOnPhrase: true), previous: previous)
            #expect(!ranked.contains(.quickCut) && !ranked.contains(.echoOut))
            #expect(ranked.first == .longBlend)
        }
        #expect(P.pick(S(tempoError: 0.02), previous: nil) == .longBlend)
    }

    @Test("a cut or an echo suits a hard ending, matched tempo and a phrase end, and nothing less")
    func suitsRule() {
        let hard = S(tempoError: 0.01, tailDropDb: 3, mixOutOnPhrase: true)
        for style in [MusicTransitionStyle.quickCut, .echoOut] {
            #expect(P.suits(style, hard))
            #expect(!P.suits(style, S(tempoError: 0.01, tailDropDb: 9, mixOutOnPhrase: true)), "a fading tail")
            #expect(!P.suits(style, S(tempoError: 0.01, tailDropDb: nil, mixOutOnPhrase: true)), "unknown tail")
            #expect(!P.suits(style, S(tempoError: 0.08, tailDropDb: 3, mixOutOnPhrase: true)), "tempo off")
            #expect(!P.suits(style, S(tempoError: nil, tailDropDb: 3, mixOutOnPhrase: true)), "tempo unknown")
            #expect(!P.suits(style, S(tempoError: 0.01, tailDropDb: 3, mixOutOnPhrase: false)), "off the phrase")
        }
        #expect(P.suits(.longBlend, S()))
        #expect(P.ranked(hard, previous: nil).contains(.quickCut) || P.ranked(hard, previous: nil).contains(.echoOut))
    }

    @Test("genres only break a tie, they never beat a signal")
    func genresTieBreak() {
        let soft = S(tempoError: 0.3, genres: ["ambient", "folk"])
        let punchy = S(tempoError: 0.3, genres: ["techno"])
        #expect(P.pick(soft, previous: nil) == P.pick(S(tempoError: 0.3), previous: nil))
        #expect(P.pick(punchy, previous: nil) == P.pick(S(tempoError: 0.3), previous: nil))
    }

    @Test("the planner turns a tempo clash into a floor blend: beat mode, 6 to 8 s, a bass swap, no cut")
    func plannerClash() throws {
        for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
            let plan = MusicTransitionPlanner.plan(Self.clash(previous: previous))
            #expect(plan.mode == .beat)
            #expect(plan.style != .quickCut && plan.style != .echoOut)
            #expect(plan.fadeSeconds >= 6 && plan.incomingRate == 1)
            #expect(plan.bassSwapAtSec != nil)
            #expect(plan.mixOutSec != nil && plan.mixInSec != nil)
        }
    }

    @Test("a beat mix carries the long blend style, and a blend right after a blend is a blend again")
    func blendThenBlend() {
        let first = MusicTransitionPlanner.plan(BT.inputs())
        #expect(first.mode == .beat && first.style == .longBlend && first.overlapBars > 0)
        var again = BT.inputs()
        again.previousStyle = .longBlend
        let second = MusicTransitionPlanner.plan(again)
        #expect(second.mode == .beat && second.style == .longBlend)
        again.previousStyle = .quickCut
        #expect(MusicTransitionPlanner.plan(again).style == .longBlend)
    }

    @Test("a grid that failed the trust checks, or has no downbeat, still gets a blend, never a plain fade")
    func lowConfidence() {
        let low = BT.grid(confidence: 0.3)
        for previous in [nil, MusicTransitionStyle.longBlend] {
            var i = BT.inputs(a: low)
            i.previousStyle = previous
            let plan = MusicTransitionPlanner.plan(i)
            #expect(plan.mode == .beat && plan.fadeSeconds >= 6 && plan.bassSwapAtSec != nil)
            #expect(plan.style != .quickCut && plan.style != .echoOut)
            var none = BT.inputs(a: BT.grid(phase: nil, confidence: 0.3))
            none.previousStyle = previous
            let noPhase = MusicTransitionPlanner.plan(none)
            #expect(noPhase.mode == .beat && noPhase.fadeSeconds >= 6 && noPhase.bassSwapAtSec != nil)
        }
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

    // MARK: Low-confidence pairs (follow-up 1), Tier 4c rule

    @Test("a cut or an echo is never ranked without a hard ending, a matched tempo and a phrase end; a blend always is")
    func cutNeedsAHardEnding() {
        let soft = MusicTransitionStyleInputs(tempoError: 0.0, energyJump: 0.5, keyDistance: 5, gridTrusted: false)
        let ranked = MusicTransitionStylePicker.ranked(soft, previous: .longBlend)
        #expect(!ranked.contains(.quickCut) && !ranked.contains(.echoOut) && ranked.contains(.longBlend))
        var hard = soft
        hard.tailDropDb = 2
        hard.mixOutOnPhrase = true
        let cuts = MusicTransitionStylePicker.ranked(hard, previous: .longBlend)
        #expect(cuts.contains(.quickCut) && cuts.contains(.echoOut))
        hard.tempoError = 0.4
        let clash = MusicTransitionStylePicker.ranked(hard, previous: nil)
        #expect(!clash.contains(.quickCut) && !clash.contains(.echoOut))
    }

    @Test("the picker judges the outgoing deck's heard tempo: 120 bpm at 1.05 meets 126 bpm")
    func deckRateCountsInTempoError() throws {
        var i = BT.inputs(b: BT.grid(period: 60.0 / 126, anchor: 0.1, phase: 1, span: 0.1...236))
        let file = try #require(MusicTransitionStylePicker.inputs(for: i).tempoError)
        #expect(abs(file - 0.05) < 0.005)
        i.outgoing.deckRate = 1.05
        let heard = try #require(MusicTransitionStylePicker.inputs(for: i).tempoError)
        #expect(heard < 0.005)
    }
}
