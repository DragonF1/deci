// DeciTests/Music/MusicDJLengthPlanTests.swift
// Tier 4b P3: DJ-length songs in the planner. Off by default and for calm runs the plan is untouched; on with an energetic run
// the mix-out moves to the outgoing song's second chorus end (within 1 ms of the bar), held back by the floor, by a sung line
// at the cut and by a cut that would not be earlier than the usual one.

import Foundation
import Testing
@testable import Deci

@Suite("Music DJ-length plan")
struct MusicDJLengthPlanTests {
    typealias BT = MusicBeatPlannerTests

    /// Outgoing 240 s song at 120 bpm (bars of 2 s, phrases of 16 s) with choruses in `high` phrases. Its usual mix-out is
    /// 208.2 (the 8 bar overlap at the last phrase boundary that fits).
    private func inputs(
        high: Set<Int> = [2, 5, 8], period: Double = 0.5, bPeriod: Double = 0.5, djLength: Bool = true,
        runEnergy: Float? = 0.7, intervals: [ClosedRange<Double>]? = nil, vocalGuard: Bool = false
    ) -> MusicTransitionInputs {
        var i = BT.inputs(
            a: BT.grid(period: period), b: BT.grid(period: bPeriod, anchor: 0.1, phase: 1, span: 0.1...236)
        )
        i.outgoing.analysis?.energy = SectionFixtures.envelope(seconds: 240, phraseSec: 32 * period, high: high)
        i.djLength = djLength
        i.runEnergy = runEnergy
        i.vocalGuardEnabled = vocalGuard
        i.outgoing.vocalIntervals = intervals
        return i
    }

    private var baseline: TransitionPlan { MusicTransitionPlanner.plan(inputs(djLength: false)) }

    @Test("the baseline mixes out at the last phrase boundary")
    func baselineIsLate() {
        #expect(abs((baseline.mixOutSec ?? 0) - 208.2) < 0.001)
        #expect(baseline.djSection == nil)
    }

    @Test("off by default: nothing changes, however energetic the run")
    func offByDefault() {
        #expect(MusicTransitionInputs(
            outgoing: BT.inputs().outgoing, incoming: BT.inputs().incoming, crossfadeOn: true, settingSeconds: 6
        ).djLength == false)
        #expect(MusicTransitionPlanner.plan(inputs(djLength: false, runEnergy: 0.95)) == baseline)
    }

    @Test("on with an energetic run: the mix-out is the second chorus end, within 1 ms of the bar")
    func cutsAtSecondChorus() throws {
        let plan = MusicTransitionPlanner.plan(inputs())
        #expect(plan.mode == .beat)
        let out = try #require(plan.mixOutSec)
        #expect(abs(out - 96.2) < 0.001, "mixOut \(out)")
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
            #expect(abs((plan.mixOutSec ?? 0) - 96.2) < 0.001, "\(style)")
            #expect(plan.djSection == .chorus2)
        }
    }

    @Test("on with a calm run, no run energy or an unknown one: the song plays out")
    func calmPlaysOut() {
        #expect(MusicTransitionPlanner.plan(inputs(runEnergy: 0.5)) == baseline)
        #expect(MusicTransitionPlanner.plan(inputs(runEnergy: nil)) == baseline)
        #expect(MusicTransitionPlanner.plan(inputs(runEnergy: MusicDJLength.highEnergy - 0.001)) == baseline)
        #expect(MusicTransitionPlanner.plan(inputs(runEnergy: MusicDJLength.highEnergy)).djSection == .chorus2, "the threshold itself is high")
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
        // The singer holds a line from 90 s to 97.5 s, across the chorus end at 96.2: the next bar line is 98.2.
        let plan = MusicTransitionPlanner.plan(inputs(intervals: [90...97.5], vocalGuard: true))
        #expect(plan.djSection == .chorus2)
        #expect(abs((plan.mixOutSec ?? 0) - 98.2) < 0.001, "mixOut \(plan.mixOutSec ?? -1)")
        // With the guard off the line does not matter.
        let unguarded = MusicTransitionPlanner.plan(inputs(intervals: [90...97.5], vocalGuard: false))
        #expect(abs((unguarded.mixOutSec ?? 0) - 96.2) < 0.001)
    }

    @Test("a singer who never stops keeps the normal plan")
    func vocalFallsBack() {
        let plan = MusicTransitionPlanner.plan(inputs(intervals: [60...150], vocalGuard: true))
        #expect(plan.djSection == nil)
        #expect(abs((plan.mixOutSec ?? 0) - 208.2) < 0.001)
    }

    @Test("a second chorus that ends before a minute has played is left alone")
    func floor() {
        // 160 bpm: bars of 1.5 s, phrases of 12 s. Choruses at phrases 1 and 3 end at 24.2 and 48.2: under the 60 s floor.
        let early = inputs(high: [1, 3], period: 0.375, bPeriod: 0.375)
        #expect(MusicTransitionPlanner.plan(early).djSection == nil)
        #expect(MusicTransitionPlanner.plan(early) == MusicTransitionPlanner.plan({ var i = early; i.djLength = false; return i }()))
        // The same shape one phrase later ends at 60.2 and is allowed.
        let later = inputs(high: [2, 4], period: 0.375, bPeriod: 0.375)
        #expect(MusicTransitionPlanner.plan(later).djSection == .chorus2)
    }

    @Test("a second chorus no earlier than the usual mix-out changes nothing")
    func notEarlier() {
        // Choruses at phrases 6 and 12: the second ends at 208.2, where the usual mix-out already is.
        #expect(MusicTransitionPlanner.plan(inputs(high: [6, 12])) == baseline)
    }

    @Test("a cut the playhead has already passed is left alone")
    func tooLate() {
        var i = inputs()
        i.earliestMixOutSec = 100
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

    @Test("run energy is the mean of what is known; nothing known is nil")
    func runEnergy() {
        #expect(abs((MusicDJLength.runEnergy([0.6, 0.8, nil]) ?? 0) - 0.7) < 1e-6)
        #expect(MusicDJLength.runEnergy([nil, nil]) == nil)
        #expect(MusicDJLength.runEnergy([]) == nil)
        #expect(MusicDJLength.runEnergy([.nan, 0.5]) == 0.5)
        #expect(MusicDJLength.isHigh(0.9) && !MusicDJLength.isHigh(0.3) && !MusicDJLength.isHigh(nil))
    }

    @Test("the log line carries ids and numbers only")
    func logLine() {
        #expect(MusicTransitionLog.djLine(from: "a", to: "b", section: .chorus2, outAt: 96.2)
            == "transition_dj from=a to=b section=chorus2 outAt=96.20")
    }

    @Test("with the vocal guard on and no lyric timings for the outgoing song there is no DJ point, whatever the style")
    func unknownLyricsKeepNormalPlan() {
        let normal = MusicTransitionPlanner.plan(inputs(intervals: nil, vocalGuard: true).with { $0.djLength = false })
        #expect(MusicTransitionPlanner.plan(inputs(intervals: nil, vocalGuard: true)) == normal)
        for style in [MusicTransitionStyle.quickCut, .echoOut] {
            let plan = MusicTransitionStylePicker.$debugScopedStyle.withValue(style) {
                MusicTransitionPlanner.plan(inputs(intervals: nil, vocalGuard: true))
            }
            #expect(plan.djSection == nil, "\(style)")
            #expect((plan.mixOutSec ?? 0) > 150, "\(style) keeps the usual mix-out: \(plan.mixOutSec ?? -1)")
        }
        // Timings that say nothing is sung (an empty list) are known timings: the cut stands.
        #expect(MusicTransitionPlanner.plan(inputs(intervals: [], vocalGuard: true)).djSection == .chorus2)
        // The guard off does not need timings.
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

private extension MusicTransitionInputs {
    func with(_ edit: (inout MusicTransitionInputs) -> Void) -> MusicTransitionInputs {
        var copy = self
        edit(&copy)
        return copy
    }
}
