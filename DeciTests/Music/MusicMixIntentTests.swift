// DeciTests/Music/MusicMixIntentTests.swift
// Why a pair is mixed the way it is.

import Foundation
import Testing
@testable import Deci

@Suite("MusicMixIntent")
struct MusicMixIntentTests {
    typealias I = MusicMixIntent
    typealias S = MusicTransitionStyleInputs

    static func habits(_ out: MusicGenreFamily, _ into: MusicGenreFamily, guess: Bool = false) -> MusicMixHabits {
        .pair(.init(family: out, isGuess: guess), .init(family: into, isGuess: guess))
    }

    @Test("each reason has its pair, the hardest thing to get across first")
    func reasons() {
        #expect(I.pick(S()) == .ride)
        #expect(I.pick(S(atDJExit: true)) == .section)
        #expect(I.pick(S(energyJump: 0.3, atDJExit: true)) == .lift)
        #expect(I.pick(S(energyJump: -0.3, atDJExit: true)) == .breather)
        #expect(I.pick(S(energyJump: 0.3, gridTrusted: true, dropConfidence: 0.9)) == .drop)
        #expect(I.pick(S(energyJump: 0.3, gridTrusted: true, habits: Self.habits(.house, .hipHop), dropConfidence: 0.9)) == .genreChange)
        #expect(I.pick(S(tempoError: 0.3, gridTrusted: true, habits: Self.habits(.house, .hipHop), dropConfidence: 0.9)) == .tempoChange)
    }

    @Test("a drop into a quieter song, an untrusted grid, a weak drop and numbers that are not numbers do not count")
    func notADrop() {
        #expect(I.pick(S(energyJump: -0.3, gridTrusted: true, dropConfidence: 0.9)) == .breather)
        #expect(I.pick(S(gridTrusted: false, dropConfidence: 0.9)) == .ride)
        #expect(I.pick(S(gridTrusted: true, dropConfidence: 0.1)) == .ride)
        #expect(I.pick(S(tempoError: .nan, energyJump: .nan, gridTrusted: true, dropConfidence: .nan)) == .ride)
    }

    @Test("only named genres of two groups are a change of genre")
    func genreChange() {
        #expect(Self.habits(.house, .hipHop).changesGenre)
        #expect(!Self.habits(.house, .hipHop, guess: true).changesGenre && !Self.habits(.house, .techno).changesGenre)
        #expect(!Self.habits(.house, .open).changesGenre && !MusicMixHabits.neutral.changesGenre)
    }

    @Test("a reason only nudges: it never adds more than a sixth of a full score, and nothing to ride")
    func small() {
        for intent in I.allCases {
            for style in MusicTransitionStyle.allCases {
                #expect((0...0.15).contains(intent.bonus(for: style)))
            }
        }
        #expect(MusicTransitionStyle.allCases.allSatisfy { I.ride.bonus(for: $0) == 0 })
    }
}
