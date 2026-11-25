// DeciTests/Music/MusicTransitionStyleTests.swift
// Tier 4b P1: the style picker and the planner hook. A pair that cannot beat mix gets a short handover, or a cut with a tail where
// its outgoing song ends hard on a phrase or is left at a section end, and the picker never repeats the style before it.

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
        S(tempoError: 0.2, energyJump: -0.4, outroEnergy: 0.1, gridTrusted: true, habits: .pair(.init(family: .soft, isGuess: false), .unknown)),
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

    @Test("a blend follows a blend when nothing else fits")
    func blendFollowsBlend() {
        #expect(P.pick(S(tempoError: 0.0), previous: .longBlend) == .longBlend)
        #expect(P.pick(S(tempoError: 0.0), history: MusicMixHistory(Array(repeating: .longBlend, count: 8))) == .longBlend)
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

    @Test("a tempo clash is never a bare cut, and a blend unless the song ends hard on a phrase")
    func clashPicks() {
        for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
            for signals in [
                S(tempoError: 0.3, tailDropDb: 9, mixOutOnPhrase: true), S(tempoError: 0.3, tailDropDb: 1, mixOutOnPhrase: false),
                S(tempoError: 0.3, tailDropDb: nil, mixOutOnPhrase: true),
            ] {
                let ranked = P.ranked(signals, previous: previous)
                #expect(!ranked.contains { $0.isCutLike })
                #expect(ranked.first == .longBlend)
            }
            #expect(!P.ranked(S(tempoError: 0.3, tailDropDb: 1, mixOutOnPhrase: true), previous: previous).contains(.quickCut))
        }
        #expect(P.pick(S(tempoError: 0.02), previous: nil) == .longBlend)
    }

    @Test("two songs that cannot be beat matched: a tail at a hard phrase end beats the handover, then the handover has its turn")
    func tailsAcrossAClash() {
        let hard = S(tempoError: 0.3, outroEnergy: 0.6, introEnergy: 0.6, gridTrusted: true, tailDropDb: 2, mixOutOnPhrase: true)
        let first = P.pick(hard, history: MusicMixHistory(Array(repeating: .longBlend, count: 4)))
        #expect(first.hasTail)
        #expect(P.pick(hard, history: MusicMixHistory([first, .longBlend])) == .longBlend)
        // The grids are not both trusted, or a tempo is not known: the same pair, as far as a mix goes.
        #expect(P.cannotBeatMix(S(tempoError: 0.0)) && P.cannotBeatMix(S(gridTrusted: true)))
        #expect(!P.cannotBeatMix(S(tempoError: 0.0, gridTrusted: true)))
        for style in [MusicTransitionStyle.echoOut, .reverbOut, .brake] {
            #expect(P.suits(style, hard))
            #expect(P.suits(style, S(tempoError: 0.0, tailDropDb: 2, mixOutOnPhrase: true)))
            #expect(P.suits(style, S(tempoError: nil, gridTrusted: true, tailDropDb: 2, mixOutOnPhrase: true)))
        }
    }

    @Test("a sweep with no beats under it waits behind the tails and the handover")
    func floorSweepWaits() {
        let pair = S(tempoError: 0.3, energyJump: 0.15, keyDistance: 0, gridTrusted: true)
        #expect(P.pick(pair, history: MusicMixHistory(Array(repeating: .longBlend, count: 3))) == .longBlend)
        #expect(P.pick(pair, history: MusicMixHistory(Array(repeating: .longBlend, count: 5))) == .filterSweep)
    }

    @Test("between two songs that could be beat matched a cut or an echo needs a hard ending, matched tempo and a phrase end")
    func suitsRule() {
        let hard = S(tempoError: 0.01, gridTrusted: true, tailDropDb: 3, mixOutOnPhrase: true)
        for style in [MusicTransitionStyle.quickCut, .echoOut] {
            #expect(P.suits(style, hard))
            #expect(!P.suits(style, S(tempoError: 0.01, gridTrusted: true, tailDropDb: 9, mixOutOnPhrase: true)), "a fading tail")
            #expect(!P.suits(style, S(tempoError: 0.01, gridTrusted: true, tailDropDb: nil, mixOutOnPhrase: true)), "unknown tail")
            #expect(!P.suits(style, S(tempoError: 0.05, gridTrusted: true, tailDropDb: 3, mixOutOnPhrase: true)), "tempo off")
            #expect(!P.suits(style, S(tempoError: 0.01, gridTrusted: true, tailDropDb: 3, mixOutOnPhrase: false)), "off the phrase")
        }
        #expect(!P.suits(.quickCut, S(tempoError: nil, gridTrusted: true, tailDropDb: 3, mixOutOnPhrase: true)), "tempo unknown")
        #expect(P.suits(.longBlend, S()))
        #expect(P.ranked(hard, previous: nil).contains(.quickCut) || P.ranked(hard, previous: nil).contains(.echoOut))
    }

    /// The habits of two songs whose genre a service named.
    static func habits(_ out: MusicGenreFamily, _ into: MusicGenreFamily) -> MusicMixHabits {
        .pair(.init(family: out, isGuess: false), .init(family: into, isGuess: false))
    }

    @Test("two rap songs are cut at the end of a section in the middle, two house songs never")
    func sectionCuts() {
        func at(_ habits: MusicMixHabits, exit: Bool = true, error: Double? = 0.05, phrase: Bool = true, bar: Bool = true) -> S {
            S(tempoError: error, gridTrusted: true, habits: habits, atDJExit: exit, exitOnBar: bar, mixOutOnPhrase: phrase)
        }
        let rap = Self.habits(.hipHop, .hipHop), house = Self.habits(.house, .house)
        for style in [MusicTransitionStyle.quickCut, .echoOut] {
            #expect(P.suits(style, at(rap)))
            #expect(!P.suits(style, at(rap, exit: false)), "at its own end a cut still needs a hard ending")
            #expect(P.suits(style, at(rap, error: 0.2)) == (style == .echoOut), "only an echo gets across a tempo clash")
            #expect(P.suits(style, at(rap, error: nil)) == (style == .echoOut), "a tempo is unknown")
            #expect(!P.suits(style, at(rap, phrase: false)), "not at the end of a phrase")
            #expect(!P.suits(style, at(house)))
            #expect(P.suits(style, at(house, error: 0.2)) == (style == .echoOut))
            #expect(!P.suits(style, at(house, exit: false, error: 0.2)) && !P.suits(style, at(house, error: 0.2, bar: false)))
            #expect(P.suits(style, at(house, error: 0.2, phrase: false)) == (style == .echoOut), "a section end is phrase enough")
            let loose = S(tempoError: 0.2, habits: house, atDJExit: true, mixOutOnPhrase: true)
            #expect(!P.suits(style, loose), "a section end of a beat that is not trusted")
        }
        #expect(P.pick(at(rap), previous: .longBlend).isCutLike)
        #expect(P.pick(at(house), previous: .longBlend) == .longBlend)
    }

    @Test("a cut or an echo out never comes right after either of the two")
    func cutsDoNotPile() {
        let rap = Self.habits(.hipHop, .hipHop)
        let here = S(tempoError: 0.02, gridTrusted: true, habits: rap, atDJExit: true, mixOutOnPhrase: true)
        for previous in [MusicTransitionStyle.quickCut, .echoOut] {
            #expect(!P.pick(here, previous: previous).isCutLike)
        }
    }

    @Test("a loop extend still beats the blend it replaces, whatever the genres")
    func loopExtendKeepsPace() {
        for family in MusicGenreFamily.allCases {
            let habits = Self.habits(family, family)
            #expect(habits.bonus(for: .loopExtend) >= habits.bonus(for: .longBlend))
        }
    }

    @Test("the planner hands a tempo clash over in a few bars: beat mode, a bass swap, no cut")
    func plannerClash() throws {
        for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
            let plan = MusicTransitionPlanner.plan(Self.clash(previous: previous))
            #expect(plan.mode == .beat)
            #expect(plan.style != .quickCut && plan.style != .echoOut)
            #expect(plan.fadeSeconds >= MusicBeatPlanner.handoverMinSec && plan.incomingRate == 1)
            #expect(plan.handsOverByEQ || plan.style == .filterSweep)
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
        func why(_ intent: MusicMixIntent?, _ variety: Bool) -> String {
            MusicTransitionLog.styleLine(from: "a", to: "b", style: .dropSwap, reason: nil, previous: nil, intent: intent, forVariety: variety)
        }
        #expect(why(.lift, false).hasSuffix(" prev=none why=lift"))
        #expect(why(.lift, true).hasSuffix(" prev=none why=lift,variety"))
        #expect(why(nil, false).hasSuffix(" prev=none"))
    }

    // MARK: Low-confidence pairs (follow-up 1), Tier 4c rule

    @Test("a cut or an echo is never ranked without a hard ending and a phrase end, a bare cut never on a clash; a blend always is")
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
        #expect(!clash.contains(.quickCut) && clash.contains(.echoOut) && clash.contains(.longBlend))
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
