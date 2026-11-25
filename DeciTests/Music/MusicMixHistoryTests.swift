// DeciTests/Music/MusicMixHistoryTests.swift
// What a set has already heard, and what that does to the next pick.

import Foundation
import Testing
@testable import Deci

@Suite("MusicMixHistory")
struct MusicMixHistoryTests {
    typealias H = MusicMixHistory
    typealias P = MusicTransitionStylePicker
    typealias S = MusicTransitionStyleInputs

    static func blends(_ count: Int, then: [MusicTransitionStyle] = []) -> H {
        H(Array(repeating: .longBlend, count: count) + then)
    }

    @Test("the newest is first and only the last few are kept")
    func order() {
        var h = H()
        #expect(h.previous == nil && h.styles.isEmpty && h.sinceEffect == 0 && h.blendRun == 0)
        h.add(.longBlend)
        h.add(.quickCut)
        #expect(h.styles == [.quickCut, .longBlend] && h.previous == .quickCut)
        #expect(h.adding(.echoOut).styles == [.echoOut, .quickCut, .longBlend] && h.previous == .quickCut)
        for _ in 0..<20 { h.add(.longBlend) }
        #expect(h.styles.count == H.depth && H(Array(repeating: .echoOut, count: 20)).styles.count == H.depth)
    }

    @Test("after an effect three transitions pass before another one is allowed, whichever it is")
    func spacing() {
        for effect in [MusicTransitionStyle.filterSweep, .echoOut] {
            for count in 0..<6 {
                let h = Self.blends(count, then: [effect])
                for next in [MusicTransitionStyle.filterSweep, .echoOut] { #expect(h.allows(next) == (count >= 3), "\(count)") }
                for next in [MusicTransitionStyle.longBlend, .quickCut, .dropSwap, .loopExtend] { #expect(h.allows(next)) }
            }
        }
        #expect(H().allows(.filterSweep) && Self.blends(1).allows(.echoOut))
    }

    @Test("an effect is more and more due from the fourth song on")
    func due() {
        for (count, bonus) in [(0, 0), (2, 0), (3, H.dueBonus), (4, 2 * H.dueBonus), (5, H.mostDueBonus), (8, H.mostDueBonus)] {
            #expect(abs(Self.blends(count).bonus(for: .filterSweep) - bonus) < 1e-9 && abs(Self.blends(count).bonus(for: .echoOut) - bonus) < 1e-9)
        }
        #expect(Self.blends(6).bonus(for: .quickCut) == 0 && Self.blends(6).bonus(for: .dropSwap) == 0)
        // The two take turns.
        let swept = Self.blends(4, then: [.filterSweep])
        #expect(swept.bonus(for: .filterSweep) < swept.bonus(for: .echoOut))
    }

    @Test("two blends in a row cost nothing, more of them a little each, up to a limit")
    func blendRuns() {
        #expect(Self.blends(0).bonus(for: .longBlend) == 0 && Self.blends(2).bonus(for: .longBlend) == 0)
        #expect(abs(Self.blends(3).bonus(for: .longBlend) + H.blendPenalty) < 1e-9)
        #expect(abs(Self.blends(8).bonus(for: .loopExtend) + H.mostBlendPenalty) < 1e-9)
        #expect(H([.quickCut, .longBlend, .longBlend, .longBlend]).bonus(for: .longBlend) == 0)
    }

    @Test("a move loses for being the last one and half of that for the one before; a cut and an echo count as one move, twice as hard")
    func repeats() {
        #expect(H([.dropSwap]).bonus(for: .dropSwap) == -H.repeatPenalty)
        #expect(H([.longBlend, .dropSwap]).bonus(for: .dropSwap) == -H.repeatPenalty / 2)
        #expect(H([.longBlend, .longBlend, .dropSwap]).bonus(for: .dropSwap) == 0)
        #expect(H([.quickCut]).bonus(for: .quickCut) == -2 * H.repeatPenalty)
        #expect(H([.echoOut]).bonus(for: .quickCut) == -2 * H.repeatPenalty)
        #expect(H([.longBlend, .quickCut]).bonus(for: .quickCut) == -H.repeatPenalty)
        #expect(H([.quickCut]).bonus(for: .dropSwap) == 0)
    }

    @Test("a set where every move is open never hears an effect twice within four songs, nor one move three times running but a blend")
    func everythingOpen() {
        let all = S(tempoError: 0.01, energyJump: 0.3, keyDistance: 1, gridTrusted: true, atDJExit: true, dropConfidence: 0.8,
                    tailDropDb: 2, mixOutOnPhrase: true)
        // Two pop songs like a cut or an echo at a section end too.
        var pop = all
        pop.habits = MusicMixIntentTests.habits(.pop, .pop)
        for (inputs, moves) in [(all, 3), (pop, 4)] { for start in [H(), H([.filterSweep]), H([.echoOut, .longBlend]), Self.blends(8)] {
            var h = start
            var heard: [MusicTransitionStyle] = []
            for _ in 0..<60 {
                let pick = P.pick(inputs, history: h)
                heard.append(pick)
                h.add(pick)
            }
            let effects = heard.indices.filter { heard[$0].isEffect }
            for (a, b) in zip(effects, effects.dropFirst()) { #expect(b - a >= 4, "\(heard.map(\.rawValue))") }
            for k in 2..<heard.count where !heard[k].isPlainBlend {
                #expect(!(heard[k] == heard[k - 1] && heard[k] == heard[k - 2]), "\(heard.map(\.rawValue))")
            }
            #expect(Set(heard).count >= moves, "\(Set(heard))")
            #expect(effects.count >= 8, "an effect about every fourth or fifth song: \(effects.count) of 60")
        } }
    }

    @Test("pairs whose tempos clash are handed over, with a sweep every so often where the keys and the energy allow it")
    func clashSet() {
        let clash = S(tempoError: 0.2, energyJump: 0.1, keyDistance: 1, gridTrusted: true)
        var h = H()
        var sweeps = 0
        for _ in 0..<40 {
            let pick = P.pick(clash, history: h)
            #expect(pick == .longBlend || pick.isSweep)
            if pick.isSweep { sweeps += 1 }
            h.add(pick)
        }
        #expect((6...11).contains(sweeps), "\(sweeps)")
        // A far key is never swept; a quieter song is swept down, never up.
        #expect(P.pick(S(tempoError: 0.2, energyJump: 0.3, keyDistance: 5, gridTrusted: true), history: Self.blends(8)) == .longBlend)
        #expect(P.pick(S(tempoError: 0.2, energyJump: -0.3, keyDistance: 0, gridTrusted: true), history: Self.blends(8)) == .lowpassSweep)
    }

    @Test("the planner says what a pair is mixed for, and whether only variety chose the move")
    func planSaysWhy() {
        var i = MusicStyleNoRepeatTests.matched(previous: nil)
        let first = MusicTransitionPlanner.plan(i)
        #expect(first.intent == .ride && !first.forVariety && first.style == .longBlend)
        i.outgoing.analysis?.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.5).encode()
        i.incoming.analysis?.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.6).encode()
        i.history = Self.blends(8)
        let later = MusicTransitionPlanner.plan(i)
        #expect(later.style == .filterSweep && later.forVariety, "\(later.style) \(later.forVariety)")
        i.history = H()
        let plain = MusicTransitionPlanner.plan(i)
        #expect(plain.style == .longBlend && !plain.forVariety)
    }
}
