// DeciTests/Music/MusicDJEntryTests.swift
// Where a DJ brings a song in: which thing that happens in it counts, how far in is too far, and where each kind of mix parks it
// (a blend is over as the song gets going, a cut lands on it).

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music DJ entry")
struct MusicDJEntryTests {
    typealias B = MusicBeatPlanner
    typealias BT = MusicBeatPlannerTests

    /// A 240 s song: bars of 2 s with downbeats at 0.2 + 2k.
    private func side(
        words: [ClosedRange<Double>]? = [], hooks: [ClosedRange<Double>] = [], first: Double? = nil, energy: [UInt8] = [],
        introEnd: Double = 8, grid: MusicBeatGrid? = BT.grid(), duration: Double = 240
    ) -> MusicTransitionSide {
        var analysis = MusicTransitionPlannerTests.analysis("bbbbbbbbbbb", duration: duration, introEnd: introEnd)
        analysis.energy = energy
        var side = MusicTransitionPlannerTests.side("bbbbbbbbbbb", duration: duration, analysis: analysis)
        side.grid = grid
        side.vocalIntervals = words
        if first != nil || !hooks.isEmpty { side.lyricCues = MusicLyricCues(hooks: hooks, firstLineSec: first) }
        return side
    }

    private func pick(_ side: MusicTransitionSide, start: Double = 0) -> MusicDJEntry? { MusicDJEntry.pick(side, start: start) }

    // MARK: Pick

    @Test("the first words, on the bar line at or before them")
    func verse() {
        #expect(pick(side(first: 33)) == MusicDJEntry(kind: .verse, targetSec: 32.2))
        #expect(pick(side(words: [33...36, 40...42])) == MusicDJEntry(kind: .verse, targetSec: 32.2), "the sung line when there are no cues")
        // A word a hair before its bar line is on it.
        #expect(abs((pick(side(first: 32.16))?.targetSec ?? 0) - 32.2) < 1e-9)
        #expect(abs((pick(side(first: 32.1))?.targetSec ?? 0) - 30.2) < 1e-9)
    }

    @Test("the hook when it comes before any other words, and the chorus the level shows")
    func hook() {
        #expect(pick(side(hooks: [24...40, 90...110]))?.kind == .hook)
        let chorus = pick(side(energy: SectionFixtures.envelope(seconds: 240, high: [2, 6, 9])))
        #expect(chorus?.kind == .hook || chorus?.kind == .drop)
        #expect(abs((chorus?.targetSec ?? 0) - 32.2) < 1e-6, "\(String(describing: chorus))")
    }

    @Test("the drop of a song nobody sings in")
    func drop() {
        let energy = SectionFixtures.bars((0..<120).map { $0 >= 20 ? -14 : -30 })
        let entry = pick(side(energy: energy))
        #expect(entry?.kind == .drop && abs((entry?.targetSec ?? 0) - 40.2) < 1e-6, "\(String(describing: entry))")
    }

    @Test("the first of them wins")
    func earliest() {
        let energy = SectionFixtures.bars((0..<120).map { $0 >= 20 ? -14 : -30 })
        #expect(pick(side(first: 17, energy: energy))?.kind == .verse)
        #expect(pick(side(first: 55, energy: energy))?.kind == .drop)
    }

    @Test("without lyrics the end of the intro is the first words; a song known to be sung nowhere has none")
    func introEnd() {
        #expect(pick(side(words: nil, introEnd: 20.5)) == MusicDJEntry(kind: .verse, targetSec: 20.2))
        #expect(pick(side(words: [], introEnd: 20.5)) == nil)
    }

    @Test("without a trusted grid the target is a breath before the word")
    func gridless() {
        let entry = pick(side(first: 33, grid: nil))
        #expect(entry?.kind == .verse && abs((entry?.targetSec ?? 0) - (33 - MusicVocalIntervals.padSec)) < 1e-9)
        let weak = pick(side(first: 33, grid: BT.grid(confidence: 0.1)))
        #expect(abs((weak?.targetSec ?? 0) - (33 - MusicVocalIntervals.padSec)) < 1e-9, "a grid that failed the trust checks")
    }

    @Test("never more than a minute in, nor three tenths of the song, nor before its start")
    func limits() {
        #expect(pick(side(first: 60))?.targetSec == 58.2)
        #expect(pick(side(first: 62.5)) == nil, "62.2 s is more than a minute")
        #expect(pick(side(first: 40, duration: 120)) == nil, "38.2 is more than 36")
        #expect(pick(side(first: 36, duration: 120))?.targetSec == 34.2)
        #expect(pick(side(first: 1.5), start: 0.5) == nil, "its bar line is before the start")
        #expect(pick(side(first: 5), start: 6) == nil)
        #expect(pick(side(first: 66), start: 10)?.targetSec == 64.2, "counted from where the song starts")
    }

    @Test("what is not known is not guessed")
    func unknown() {
        var none = side(first: 33)
        none.analysis = nil
        #expect(pick(none) == nil)
        var noLength = side(first: 33)
        noLength.durationSeconds = nil
        #expect(pick(noLength) == nil)
        #expect(pick(side(first: 33), start: .nan) == nil)
        #expect(pick(side(first: .infinity)) == nil)
    }

    @Test("a lead is taken off the target, down to the plain start")
    func start() {
        let entry = MusicDJEntry(kind: .verse, targetSec: 32.2)
        #expect(abs(entry.start(lead: 16, notBefore: 0) - 16.2) < 1e-9)
        #expect(entry.start(lead: 40, notBefore: 1) == 1)
        #expect(entry.start(lead: .nan, notBefore: 1) == 1)
        #expect(abs(entry.barStart(lead: 16, barSec: 2, notBefore: 0) - 14.25) < 1e-9)
    }

    // MARK: Plans

    /// BT's pair with words in the incoming song (downbeats at 0.6 + 2k) from `words` on.
    private func inputs(words: Double, djLength: Bool = true) -> MusicTransitionInputs {
        var i = BT.inputs()
        i.incoming.vocalIntervals = [words...(words + 3), 60...64]
        i.djLength = djLength
        return i
    }

    private func firstDownbeat(_ i: MusicTransitionInputs, atOrBefore time: Double) throws -> Double {
        let grid = try #require(i.incoming.grid)
        let origin = try #require(grid.barTime(0))
        return origin + ((time - origin) / 2).rounded(.down) * 2
    }

    @Test("a beat blend is over exactly as the song gets going")
    func blendEndsAtTheVerse() throws {
        let i = inputs(words: 41)
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.mode == .beat && plan.style == .longBlend && plan.overlapBars == 8, "\(plan)")
        #expect(plan.djEntry == .verse && plan.entersDeep)
        let verse = try firstDownbeat(i, atOrBefore: 41)
        let mixIn = try #require(plan.mixInSec)
        #expect(abs(mixIn + plan.overlapSec - verse) < 0.02, "mixIn \(mixIn) overlap \(plan.overlapSec) verse \(verse)")
        #expect(plan.fallbackIncomingStartSec == 0 && plan.incomingStartSec == mixIn)
        // The same pair without an entry starts at the first bar.
        let plain = MusicTransitionPlanner.plan(inputs(words: 41, djLength: false))
        #expect(plain.djEntry == nil && !plain.entersDeep && (plain.mixInSec ?? 99) < 2.5)
    }

    @Test("an intro no longer than the blend is not skipped")
    func shortIntro() {
        let plan = MusicTransitionPlanner.plan(inputs(words: 9))
        #expect(plan.djEntry == nil && !plan.entersDeep)
        #expect(plan == MusicTransitionPlanner.plan(inputs(words: 9, djLength: false)))
    }

    @Test("a cut and an echo out land on the verse")
    func cutsLandOnTheVerse() throws {
        for style in [MusicTransitionStyle.quickCut, .echoOut] {
            let i = inputs(words: 41)
            let plan = MusicTransitionStylePicker.$debugScopedStyle.withValue(style) { MusicTransitionPlanner.plan(i) }
            #expect(plan.style == style)
            #expect(plan.djEntry == .verse)
            let mixIn = try #require(plan.mixInSec)
            #expect(abs(mixIn - (try firstDownbeat(i, atOrBefore: 41))) < 1e-6, "\(style) \(mixIn)")
        }
    }

    @Test("a cut with no grid lands a breath before the word")
    func gridlessCut() throws {
        var i = inputs(words: 41)
        i.outgoing.grid = nil
        i.incoming.grid = nil
        let smart = MusicTransitionPlanner.smartPlan(i)
        i.djEntry = try #require(MusicDJEntry.pick(i.incoming, start: smart.incomingStartSec))
        let plan = try #require(B.styledPlan(i, smart: smart, style: .quickCut))
        #expect(abs((plan.mixInSec ?? 0) - (41 - MusicVocalIntervals.padSec)) < 1e-9)
        #expect(plan.fallbackIncomingStartSec == smart.incomingStartSec && plan.entersDeep)
    }

    @Test("a floor blend with no grid is over at the verse")
    func gridlessFloor() throws {
        var i = inputs(words: 41)
        i.outgoing.grid = nil
        i.incoming.grid = nil
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.mode == .beat && plan.overlapBars == 0 && plan.djEntry == .verse, "\(plan)")
        let start = try #require(plan.mixInSec)
        #expect(abs(start + B.floorFadeSeconds - (41 - MusicVocalIntervals.padSec)) < 1e-6, "start \(start)")
        #expect(plan.fallbackIncomingStartSec == 0)
    }

    @Test("a tempo matched blend still ends at the verse, by the song's own clock")
    func tempoMatched() throws {
        var i = inputs(words: 41)
        i.outgoing.grid = BT.grid(period: 60 / 122.0)
        i.incoming.grid = BT.grid(period: 0.5, anchor: 0.1, phase: 1, span: 0.1...236)
        let plan = MusicTransitionPlanner.plan(i)
        guard plan.style == .longBlend, plan.mode == .beat, plan.overlapBars > 0 else { return }
        let mixIn = try #require(plan.mixInSec)
        let verse = try firstDownbeat(i, atOrBefore: 41)
        let consumed = plan.overlapSec * plan.stretchRate
        #expect(mixIn + consumed <= verse + 0.05, "never over the first words: \(plan)")
        #expect(mixIn + consumed > verse - 2.1, "within a bar of it: \(plan)")
    }

    @Test("the song that is left early and the one that is brought in late, in one plan")
    func both() {
        var i = inputs(words: 41)
        i.outgoing.analysis?.energy = SectionFixtures.envelope(seconds: 240, high: [2, 6, 9])
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.djSection == .chorus2 && plan.djEntry == .verse, "\(plan)")
        #expect(abs((plan.mixOutSec ?? 0) - 112.2) < 0.001)
    }

    @Test("an entry that leaves nothing to build falls back to the plain plan")
    func nothingToBuild() {
        // A 70 s song with words at 20 s: the entry is inside the limits, but 16 s of overlap from there may not fit its end.
        var i = BT.inputs(b: BT.grid(anchor: 0.1, phase: 1, span: 0.1...66), bDuration: 70, bSilenceEnd: 66)
        i.incoming.vocalIntervals = [20...23]
        i.djLength = true
        var off = i
        off.djLength = false
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.mode == .beat)
        #expect((plan.mixInSec ?? 0) >= (MusicTransitionPlanner.plan(off).mixInSec ?? 0) - 1e-9)
    }
}
