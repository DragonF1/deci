// DeciTests/Music/MusicStylePickerP2Tests.swift
// Tier 4b P2: the picker rules for the filter sweep and the drop swap, and the never-repeat property across every style.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicStylePickerP2")
struct MusicStylePickerP2Tests {
    typealias P = MusicTransitionStylePicker
    typealias S = MusicTransitionStyleInputs

    static let samples: [S] = MusicTransitionStyleTests.samples + [
        S(tempoError: 0.01, energyJump: 0.3, keyDistance: 1, gridTrusted: true),
        S(tempoError: 0.01, energyJump: 0.0, keyDistance: 0, gridTrusted: true),
        S(tempoError: 0.01, energyJump: -0.05, keyDistance: 2, gridTrusted: true, dropConfidence: 0.9),
        S(tempoError: 0.01, energyJump: 0.1, keyDistance: 6, gridTrusted: true, dropConfidence: 0.5),
        S(tempoError: 0.3, energyJump: 0.4, gridTrusted: true, dropConfidence: 1),
        S(tempoError: 0.0, gridTrusted: true, dropConfidence: .nan),
        S(tempoError: 0.0, energyJump: .nan, gridTrusted: true, dropConfidence: 0.2),
        S(tempoError: 0.0, energyJump: 0.5, keyDistance: 0, gridTrusted: false, dropConfidence: 1),
    ]

    @Test("the picker never repeats any previous value, and only returns pickable styles")
    func neverRepeats() {
        for signals in Self.samples {
            for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
                let ranked = P.ranked(signals, previous: previous)
                #expect(!ranked.contains { $0 == previous })
                #expect(ranked.allSatisfy { MusicTransitionStyle.pickable.contains($0) })
                #expect(P.pick(signals, previous: previous) != previous)
                #expect(Set(ranked).count == ranked.count)
            }
        }
    }

    @Test("a chain of picks, each given the one before, never repeats and visits more than one style")
    func chain() {
        for signals in Self.samples {
            var previous: MusicTransitionStyle?
            var seen = Set<MusicTransitionStyle>()
            for _ in 0..<12 {
                let next = P.pick(signals, previous: previous)
                #expect(next != previous)
                seen.insert(next)
                previous = next
            }
            #expect(seen.count >= 2)
        }
    }

    @Test("both new styles are pickable and labelled")
    func pickable() {
        #expect(MusicTransitionStyle.pickable.contains(.filterSweep) && MusicTransitionStyle.pickable.contains(.dropSwap))
        #expect(MusicTransitionStyle.filterSweep.label == "Filter sweep" && MusicTransitionStyle.dropSwap.label == "Drop swap")
        #expect(!MusicTransitionStyle.filterSweep.isCutLike && !MusicTransitionStyle.dropSwap.isCutLike)
        #expect(MusicTransitionStyle.quickCut.isCutLike && MusicTransitionStyle.echoOut.isCutLike && !MusicTransitionStyle.longBlend.isCutLike)
    }

    @Test("a beat-mixable pair with a trusted grid, a similar or rising energy and agreeing keys can sweep")
    func sweepCandidate() {
        let rising = S(tempoError: 0.01, energyJump: 0.25, keyDistance: 1, gridTrusted: true)
        #expect(P.ranked(rising, previous: .longBlend).first == .filterSweep)
        #expect(P.ranked(rising, previous: nil).contains(.filterSweep))
        let similar = S(tempoError: 0.01, energyJump: -0.05, keyDistance: 0, gridTrusted: true)
        #expect(P.ranked(similar, previous: .longBlend).contains(.filterSweep))
    }

    @Test("no sweep without a trusted grid, with a tempo clash, a far key, a falling song or unknown energy")
    func sweepRefused() {
        let base = S(tempoError: 0.01, energyJump: 0.25, keyDistance: 1, gridTrusted: true)
        var untrusted = base; untrusted.gridTrusted = false
        var clash = base; clash.tempoError = 0.3
        var far = base; far.keyDistance = 4
        var falling = base; falling.energyJump = -0.3
        var unknown = base; unknown.energyJump = nil
        for signals in [untrusted, clash, far, falling, unknown] {
            #expect(!P.ranked(signals, previous: nil).contains(.filterSweep))
        }
    }

    @Test("a confident drop makes a drop swap the best pick after a blend; a weak or missing one does not")
    func dropCandidate() {
        let strong = S(tempoError: 0.01, energyJump: 0.0, keyDistance: 0, gridTrusted: true, dropConfidence: 0.9)
        #expect(P.ranked(strong, previous: .longBlend).first == .dropSwap)
        #expect(P.ranked(strong, previous: nil).first == .longBlend, "only a repeat sends a pristine blend away")
        var weak = strong; weak.dropConfidence = 0.2
        var none = strong; none.dropConfidence = nil
        var untrusted = strong; untrusted.gridTrusted = false
        var clash = strong; clash.tempoError = 0.3
        for signals in [weak, none, untrusted, clash] {
            #expect(!P.ranked(signals, previous: nil).contains(.dropSwap))
        }
    }

    @Test("a drop swap needs agreeing keys like the sweep: a far key never gets one, even with a perfect drop")
    func dropSwapRefusesFarKeys() {
        let near = S(tempoError: 0.01, energyJump: 0.1, keyDistance: 2, gridTrusted: true, dropConfidence: 1)
        #expect(P.ranked(near, previous: .longBlend).first == .dropSwap)
        for distance in [3, 4, 6] {
            var far = near
            far.keyDistance = distance
            for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
                #expect(!P.ranked(far, previous: previous).contains(.dropSwap), "key distance \(distance)")
            }
        }
        var unknownKey = near
        unknownKey.keyDistance = nil
        #expect(P.ranked(unknownKey, previous: .longBlend).contains(.dropSwap))
    }

    @Test("a higher drop confidence ranks the drop swap higher")
    func dropConfidenceOrders() {
        let low = S(tempoError: 0.01, gridTrusted: true, dropConfidence: 0.45)
        let high = S(tempoError: 0.01, gridTrusted: true, dropConfidence: 1)
        let lowRank = P.ranked(low, previous: .longBlend).firstIndex(of: .dropSwap)
        let highRank = P.ranked(high, previous: .longBlend).firstIndex(of: .dropSwap)
        #expect(highRank != nil && lowRank != nil && highRank! <= lowRank!)
    }

    @Test("tempo clash behaviour is unchanged: a cut or an echo, the new styles stay out")
    func clashUnchanged() {
        for signals in [S(tempoError: 0.3, gridTrusted: true, dropConfidence: 1), S(tempoError: 0.3, energyJump: 0.4, keyDistance: 0, gridTrusted: true)] {
            for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
                let ranked = P.ranked(signals, previous: previous)
                #expect(!ranked.contains(.filterSweep) && !ranked.contains(.dropSwap))
            }
        }
        #expect(P.pick(S(tempoError: 0.3), previous: .quickCut) == .echoOut)
        #expect(P.pick(S(tempoError: 0.3), previous: .echoOut) == .quickCut)
    }

    @Test("a quick cut stays a candidate for a trusted grid beside the new styles")
    func cutStillThere() {
        let all = S(tempoError: 0.01, energyJump: 0.3, keyDistance: 1, gridTrusted: true, dropConfidence: 0.8)
        let ranked = P.ranked(all, previous: nil)
        #expect(Set(ranked) == [.longBlend, .quickCut, .echoOut, .filterSweep, .dropSwap])
    }
}
