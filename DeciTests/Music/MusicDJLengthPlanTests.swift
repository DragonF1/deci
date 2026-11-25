// DeciTests/Music/MusicDJLengthPlanTests.swift
// Where a DJ leaves a song, in the planner: the mix-out moves to the outgoing song's second chorus end (within 1 ms of the bar),
// held back by the minute that must have played, by the window, by a sung line at the exit and by an exit that would not be
// earlier than the usual mix-out. Off (no Mixing) the plan is untouched. The sources are covered in MusicDJExitTests.

import Foundation
import Testing
@testable import Deci

@Suite("Music DJ-length plan")
struct MusicDJLengthPlanTests {
    typealias BT = MusicBeatPlannerTests

    /// Outgoing 240 s song at 120 bpm (bars of 2 s, phrases of 16 s) with choruses in `high` phrases. Its usual mix-out is
    /// 208.2 (the 8 bar overlap at the last phrase boundary that fits). The second chorus of the default ends at 112.2. Nothing
    /// is sung in the incoming song and its level never moves, so it is brought in as it always was.
    private func inputs(
        high: Set<Int> = [2, 6, 9], period: Double = 0.5, bPeriod: Double = 0.5, djLength: Bool = true,
        intervals: [ClosedRange<Double>]? = nil, vocalGuard: Bool = false
    ) -> MusicTransitionInputs {
        var i = BT.inputs(
            a: BT.grid(period: period), b: BT.grid(period: bPeriod, anchor: 0.1, phase: 1, span: 0.1...236)
        )
        i.outgoing.analysis?.energy = SectionFixtures.envelope(seconds: 240, phraseSec: 32 * period, high: high)
        i.djLength = djLength
        i.vocalGuardEnabled = vocalGuard
        i.outgoing.vocalIntervals = intervals
        i.incoming.vocalIntervals = []
        return i
    }

    private var baseline: TransitionPlan { MusicTransitionPlanner.plan(inputs(djLength: false)) }

    @Test("the baseline mixes out at the last phrase boundary")
    func baselineIsLate() {
        #expect(abs((baseline.mixOutSec ?? 0) - 208.2) < 0.001)
        #expect(baseline.djSection == nil)
    }

    @Test("off by default")
    func offByDefault() {
        #expect(MusicTransitionInputs(
            outgoing: BT.inputs().outgoing, incoming: BT.inputs().incoming, crossfadeOn: true, settingSeconds: 6
        ).djLength == false)
    }

    @Test("on: the mix-out is the second chorus end, within 1 ms of the bar")
    func cutsAtSecondChorus() throws {
        let plan = MusicTransitionPlanner.plan(inputs())
        #expect(plan.mode == .beat)
        let out = try #require(plan.mixOutSec)
        #expect(abs(out - 112.2) < 0.001, "mixOut \(out)")
        let bars = (out - 0.2) / 2
        #expect(abs(bars - bars.rounded()) * 2 < 0.001, "on a downbeat")
        #expect(plan.djSection == .chorus2)
        #expect(plan.fadeStartSec == plan.mixOutSec)
        #expect((plan.outgoingEndSec ?? 0) > out, "the overlap plays out after the cut")
        #expect(plan.outgoingEndSec ?? 999 < 240)
    }

    @Test("a cut plan from the style picker keeps the DJ point too")
    func styleStillPicked() throws {
        for style in [MusicTransitionStyle.quickCut, .echoOut] {
            let plan = MusicTransitionStylePicker.$debugScopedStyle.withValue(style) { MusicTransitionPlanner.plan(inputs()) }
            #expect(plan.style == style, "\(style)")
            #expect(abs((plan.mixOutSec ?? 0) - 112.2) < 0.001, "\(style)")
            #expect(plan.djSection == .chorus2)
        }
    }

    @Test("no sections: the normal plan")
    func noSections() {
        #expect(MusicTransitionPlanner.plan(inputs(high: [])) == baseline)
        #expect(MusicTransitionPlanner.plan(inputs(high: [4])) == baseline, "one chorus is ambiguous")
        var noGrid = inputs()
        noGrid.outgoing.grid = BT.grid(phase: nil)
        #expect(MusicTransitionPlanner.plan(noGrid).djSection == nil)
    }

    @Test("a sung line over the cut moves it to the next clean bar")
    func vocalShifts() throws {
        // The singer holds a line from 106 s to 113.5 s, across the chorus end at 112.2: the next bar line is 114.2.
        let plan = MusicTransitionPlanner.plan(inputs(intervals: [106...113.5], vocalGuard: true))
        #expect(plan.djSection == .chorus2)
        #expect(abs((plan.mixOutSec ?? 0) - 114.2) < 0.001, "mixOut \(plan.mixOutSec ?? -1)")
        // With the guard off the line does not matter.
        let unguarded = MusicTransitionPlanner.plan(inputs(intervals: [106...113.5], vocalGuard: false))
        #expect(abs((unguarded.mixOutSec ?? 0) - 112.2) < 0.001)
    }

    @Test("two songs whose tempos clash: the section end is left with a tail once one is due, on the bar line")
    func tailAtTheSectionEnd() {
        var i = inputs(bPeriod: 60.0 / 131)
        i.history = MusicMixHistory(Array(repeating: .longBlend, count: 4))
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.style.hasTail, "\(plan.style)")
        #expect(plan.djSection == .chorus2)
        #expect(abs((plan.mixOutSec ?? 0) + plan.brakeLeadSec - 112.2) < 0.001, "mixOut \(plan.mixOutSec ?? -1)")
        // Right after an effect it is a handover, at the same place.
        i.history = MusicMixHistory([.longBlend, .echoOut])
        let next = MusicTransitionPlanner.plan(i)
        #expect(next.style == .longBlend && next.djSection == .chorus2)
    }

    @Test("between two lines of a verse sung without a break the exit stays where it is")
    func betweenTwoLines() {
        // The intervals join the two lines into one block across the chorus end at 112.2; line by line nothing is split there.
        var i = inputs(intervals: [100...124], vocalGuard: true)
        i.outgoing.lyricCues = MusicLyricCues(lines: [100...106, 106...112, 112.4...118, 118...124])
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.djSection == .chorus2)
        #expect(abs((plan.mixOutSec ?? 0) - 112.2) < 0.001, "mixOut \(plan.mixOutSec ?? -1)")
        // A line across it moves it on by a bar, which the next line has only just begun at.
        i.outgoing.lyricCues = MusicLyricCues(lines: [100...106, 106...113.5, 113.8...118, 118...124])
        #expect(abs((MusicTransitionPlanner.plan(i).mixOutSec ?? 0) - 114.2) < 0.001)
    }

    @Test("a singer who never stops moves the exit to the next chorus, and with none clear keeps the normal plan")
    func vocalFallsBack() {
        // Every bar line the second chorus could be left at is sung over; the third one ends at 160.2.
        let third = MusicTransitionPlanner.plan(inputs(intervals: [60...150], vocalGuard: true))
        #expect(third.djSection == .chorus2)
        #expect(abs((third.mixOutSec ?? 0) - 160.2) < 0.001, "mixOut \(third.mixOutSec ?? -1)")
        let none = MusicTransitionPlanner.plan(inputs(intervals: [60...200], vocalGuard: true))
        #expect(none.djSection == nil)
        #expect(abs((none.mixOutSec ?? 0) - 208.2) < 0.001)
    }

    @Test("a second chorus outside the middle of the song is left alone")
    func window() {
        // It ends at 96.2, 40% in: not the one a DJ leaves on. The third ends at 144.2 and is.
        #expect(abs((MusicTransitionPlanner.plan(inputs(high: [2, 5, 8])).mixOutSec ?? 0) - 144.2) < 0.001)
        #expect(MusicTransitionPlanner.plan(inputs(high: [2, 5])) == MusicTransitionPlanner.plan(inputs(high: [2, 5], djLength: false)))
    }

    @Test("a song is never left before it has played for a minute, counted from where it was brought in")
    func floor() {
        // The outgoing song's first words are in the bar at 54.2, so it was brought in there: the first bar line a minute later
        // is 114.2, one after the chorus end.
        var i = inputs(high: [4, 6, 9], intervals: [56...58])
        #expect(abs((MusicTransitionPlanner.plan(i).mixOutSec ?? 0) - 114.2) < 0.001, "mixOut \(MusicTransitionPlanner.plan(i).mixOutSec ?? -1)")
        i.outgoing.vocalIntervals = [20...22]
        #expect(abs((MusicTransitionPlanner.plan(i).mixOutSec ?? 0) - 112.2) < 0.001, "92 s of it")
    }

    @Test("a second chorus no earlier than the usual mix-out changes nothing")
    func notEarlier() {
        // Choruses at phrases 6 and 12: the second ends at 208.2, where the usual mix-out already is.
        #expect(MusicTransitionPlanner.plan(inputs(high: [6, 12])) == baseline)
    }

    @Test("a cut the playhead has already passed is left alone")
    func tooLate() {
        var i = inputs()
        i.earliestMixOutSec = 113
        #expect(abs((MusicTransitionPlanner.plan(i).mixOutSec ?? 0) - 114.2) < 0.001, "the next bar line is still ahead")
        i.earliestMixOutSec = 120
        #expect(abs((MusicTransitionPlanner.plan(i).mixOutSec ?? 0) - 160.2) < 0.001, "the next chorus is")
        i.earliestMixOutSec = 170
        #expect(MusicTransitionPlanner.plan(i).djSection == nil)
    }

    @Test("rules that keep a pair from mixing keep it from being cut short")
    func rules() {
        for edit: (inout MusicTransitionInputs) -> Void in [
            { $0.albumInOrder = true }, { $0.loopSong = true }, { $0.manualSkip = true }, { $0.beatMixEnabled = false },
            { $0.crossfadeOn = false }, { $0.cleanPairFlag = true },
        ] {
            var i = inputs()
            edit(&i)
            #expect(MusicTransitionPlanner.plan(i).djSection == nil)
        }
    }

    @Test("the log line carries ids and numbers only")
    func logLine() {
        #expect(MusicTransitionLog.djLine(from: "a", to: "b", section: .chorus2, outAt: 96.2)
            == "transition_dj from=a to=b section=chorus2 outAt=96.20")
        #expect(MusicTransitionLog.djLine(from: "a", to: "b", section: .drop2, outAt: 96.2, entry: .verse, inAt: 12.3)
            == "transition_dj from=a to=b section=drop2 outAt=96.20 entry=verse inAt=12.30")
        #expect(MusicTransitionLog.djLine(from: "a", to: "b", section: nil, outAt: 208.2, entry: .hook, inAt: 12.3)
            == "transition_dj from=a to=b section=end outAt=208.20 entry=hook inAt=12.30", "left at its end, brought in late")
    }

    @Test("a song whose words are not known is left there too, with the vocal guard on")
    func unknownLyricsStillLeave() {
        #expect(MusicTransitionPlanner.plan(inputs(intervals: nil, vocalGuard: true)).djSection == .chorus2)
        #expect(MusicTransitionPlanner.plan(inputs(intervals: [], vocalGuard: true)).djSection == .chorus2)
        #expect(MusicTransitionPlanner.plan(inputs(intervals: nil, vocalGuard: false)).djSection == .chorus2)
    }

    @Test("the cut is held against the mix-out the real plan has: 16 bars with the bass swap, 8 without")
    func normalIsTheRealPlan() {
        // Choruses end at 96.2 and 192.2. Without the swap the usual mix-out is 208.2 and the cut is 16 s earlier. With it
        // the 16 bar overlap puts the usual mix-out at 192.2 already: no earlier, so the song plays on.
        func plan(swap: Bool, dj: Bool) -> TransitionPlan {
            var i = inputs(high: [5, 11], djLength: dj)
            i.bassSwapAvailable = swap
            return MusicTransitionPlanner.plan(i)
        }
        #expect(plan(swap: false, dj: true).djSection == .chorus2)
        let withSwapNormal = plan(swap: true, dj: false)
        #expect(abs((withSwapNormal.mixOutSec ?? 0) - 192.2) < 0.001, "usual mix-out \(withSwapNormal.mixOutSec ?? -1)")
        #expect(plan(swap: true, dj: true) == withSwapNormal)
    }
}
