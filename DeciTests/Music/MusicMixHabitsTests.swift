// DeciTests/Music/MusicMixHabitsTests.swift
// How a pair of genres is mixed, and that the planner goes by it.

import Testing
@testable import Deci

@Suite("Music mix habits")
struct MusicMixHabitsTests {
    private typealias H = MusicMixHabits
    private typealias BT = MusicBeatPlannerTests

    private func tagged(_ family: MusicGenreFamily) -> MusicGenre { MusicGenre(family: family, isGuess: false) }

    @Test("two songs nothing is known about are mixed as before")
    func unknown() {
        #expect(H.pair(.unknown, .unknown) == .neutral)
    }

    @Test("the song that wants the shorter overlap has its way")
    func lengths() {
        #expect(H.pair(tagged(.house), tagged(.techno)).lengths == [16, 8])
        #expect(H.pair(tagged(.house), tagged(.hipHop)).lengths == [4, 8])
        #expect(H.pair(tagged(.hipHop), tagged(.house)).lengths == [4, 8])
        #expect(H.pair(tagged(.house), tagged(.pop)).lengths == [8, 4])
        #expect(H.pair(tagged(.pop), .unknown).lengths == [8, 4])
        #expect(H.pair(MusicGenre(family: .hipHop, isGuess: true), tagged(.house)).lengths == [8])
    }

    @Test("every family keeps a blend to fall back on")
    func everyLength() {
        for family in MusicGenreFamily.allCases {
            for guess in [true, false] {
                #expect(H.lengths(MusicGenre(family: family, isGuess: guess)).contains(8))
            }
        }
    }

    @Test("a guess pulls half as hard as a tag, and never opens the section cuts")
    func guessesAreWeak() throws {
        let sure = H.pair(tagged(.hipHop), tagged(.hipHop))
        let guess = H.pair(MusicGenre(family: .hipHop, isGuess: true), MusicGenre(family: .hipHop, isGuess: true))
        let a = try #require(sure.bonus[.quickCut]), b = try #require(guess.bonus[.quickCut])
        #expect(abs(b - a * H.guessShare) < 1e-9)
        #expect(sure.cutsOnSections && !guess.cutsOnSections)
        #expect(!H.pair(tagged(.hipHop), MusicGenre(family: .hipHop, isGuess: true)).cutsOnSections)
    }

    @Test("a change of genre is an echo or a cut rather than a long blend")
    func genreChange() {
        let same = H.pair(tagged(.hipHop), tagged(.pop)), change = H.pair(tagged(.hipHop), tagged(.house))
        #expect(same.bonus(for: .echoOut) > 0)
        #expect(change.bonus(for: .longBlend) < H.pair(tagged(.house), tagged(.house)).bonus(for: .longBlend))
        #expect(change.bonus(for: .echoOut) > change.bonus(for: .longBlend))
    }

    @Test("a side's genre comes from its tags and its trusted tempo")
    func sides() {
        var i = BT.inputs()
        #expect(MusicGenre(of: i.outgoing) == MusicGenre(family: .house, isGuess: true), "120 bpm, no tag")
        i.outgoing.genres = ["Hip-Hop"]
        #expect(MusicGenre(of: i.outgoing) == tagged(.hipHop))
        i.outgoing.genres = []
        i.outgoing.grid = BT.grid(confidence: 0.2)
        #expect(MusicGenre(of: i.outgoing) == .unknown, "a tempo nobody trusts says nothing")
    }

    @Test("the planner overlaps two house songs for 16 bars, two pop songs for 8, two rap songs for 4")
    func plannedBars() {
        func bars(_ tag: String) -> Int? {
            var i = BT.inputs(swap: true)
            i.outgoing.genres = [tag]
            i.incoming.genres = [tag]
            let plan = MusicTransitionPlanner.plan(i)
            return plan.mode == .beat ? plan.overlapBars : nil
        }
        #expect(bars("House") == 16)
        #expect(bars("Pop") == 8)
        #expect(bars("Hip-Hop") == 4)
    }

    @Test("4 bars that are over before a blend can be are not tried, and without a bass swap it is always 8")
    func shortBars() {
        var i = BT.inputs(swap: true)
        i.outgoing.genres = ["Hip-Hop"]
        i.incoming.genres = ["Hip-Hop"]
        #expect(MusicBeatPlanner.overlapLengths(i, barSec: 2, phrased: true) == [4, 8])
        #expect(MusicBeatPlanner.overlapLengths(i, barSec: 1.4, phrased: true) == [8])
        #expect(MusicBeatPlanner.overlapLengths(i, barSec: 2, phrased: false) == [8])
        i.bassSwapAvailable = false
        #expect(MusicBeatPlanner.overlapLengths(i, barSec: 2, phrased: true) == [8])
    }

    @Test("the log line names both genres, how they were known and the lengths")
    func logLine() {
        var i = BT.inputs(swap: true)
        i.outgoing.genres = ["Hip-Hop"]
        let line = MusicTransitionLog.genreLine(i)
        #expect(line == "transition_genre from=aaaaaaaaaaa to=bbbbbbbbbbb out=hipHop/tag in=house/guess bars=4,8 cuts=no")
    }
}
