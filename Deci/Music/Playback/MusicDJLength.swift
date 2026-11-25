// Deci/Music/Playback/MusicDJLength.swift
// Where a DJ leaves a song. Not at its last second: after its second chorus or drop, when it has one in the middle part of the
// song, and at its usual mix-out when it has not. Always part of Mixing. Pure and derived on demand.

import Foundation

/// The song section a DJ exit was made at.
nonisolated enum DJSection: String, Sendable {
    /// The end of the second (or a later) chorus, found in the level.
    case chorus2
    /// The end of the second (or a later) hook, found in the lyrics.
    case hook2
    /// The end of the loud stretch after the second (or a later) drop.
    case drop2
}

nonisolated enum MusicDJLength {
    /// Never leave a song before this many seconds of it have played: a song left at its second chorus must still be a song.
    static let minPlayedSec = 60.0
    /// Where in a song it may be left, as a share of its length. A second chorus before it is not the one a DJ leaves on, and
    /// after it the song may as well end.
    static let window = 0.45...0.90
    /// A sung line that spans the mix-out moves it later by whole bars, at most this many.
    static let maxVocalShiftBars = 3
    /// A drop before this share of the song is its intro ending, not one of its drops.
    static let introDropShare = 0.25
    /// The loud stretch after a drop is looked for in this many bars, in steps of `dropStepBars`.
    static let dropBars = 8...32
    static let dropStepBars = 4
    /// The loud stretch is over where the two bars after a phrase are this much (dB) below it.
    static let dropEndDb: Float = 3
    /// A bar of a song whose beat is not known.
    static let nominalBarSec = 2.0

    struct Exit: Equatable, Sendable {
        /// The outgoing item time the mix starts at.
        var point: Double
        /// The mix-out the plan would have had instead.
        var normal: Double
        var section: DJSection
    }

    /// A brake starts in wall seconds before the exit; a deck off its file's tempo makes them a little more or less song.
    static let brakeSlackSec = 0.1

    /// How far before and after an exit a floor blend may start (it looks for a beat and a gap between two sung lines, and a short
    /// handover starts up to a bar early so the new song's "1" is the exit).
    static let floorSlack = -3.4...10.0

    /// The places to leave the outgoing song, best first, at most one a source. Empty when the plan must stay as it is: it is off,
    /// a rule keeps the pair from mixing, the song has no second chorus, hook or drop in the window, less than `minPlayedSec` would
    /// have played, a singer never stops there, or leaving there would not be a bar earlier than the mix-out the pair has
    /// anyway (`normal`, estimated when it is not given).
    static func exits(_ inputs: MusicTransitionInputs, smartEnd: Double?, normal known: Double? = nil) -> [Exit] {
        guard inputs.djLength, inputs.beatMixEnabled, inputs.crossfadeOn,
              !inputs.albumInOrder, !inputs.loopSong, !inputs.manualSkip, !inputs.cleanStartFlag, !inputs.cleanPairFlag,
              inputs.outgoing.videoId != inputs.incoming.videoId,
              let duration = MusicBeatPlanner.valid(inputs.outgoing.durationSeconds),
              let a = inputs.outgoing.analysis else { return [] }
        let grid = trustedGrid(inputs.outgoing, a)
        let barSec = grid.map { 4 * $0.periodSec } ?? nominalBarSec
        let end = smartEnd ?? duration
        // The mix-out has to be beaten by a bar. The planner passes the real one; without it, it is estimated at the overlap the
        // beat planner tries first when both downbeats are known, or at a floor blend's.
        let estimateBars = MusicBeatPlanner.overlapLengths(inputs, barSec: barSec, phrased: true).first ?? MusicBeatPlanner.phraseBars
        let estimate = grid.flatMap { MusicBeatPlanner.mixOutTime(grid: $0, analysis: a, bars: estimateBars, barSec: barSec, end: end) }
        let normal = known ?? estimate ?? (end - MusicBeatPlanner.floorFadeSeconds)
        guard normal.isFinite else { return [] }
        // A song that was itself brought in late still plays for `minPlayedSec`.
        let entered = MusicDJEntry.pick(inputs.outgoing, start: 0)?.targetSec ?? 0
        let earliest = max(entered + minPlayedSec, inputs.earliestMixOutSec ?? 0)
        func usable(_ point: Double) -> Bool { point >= earliest - 1e-9 && point <= normal - barSec + 1e-9 }
        func sung(_ point: Double) -> Bool { inputs.vocalGuardEnabled && Self.sung(inputs.outgoing, at: point) }

        return candidates(inputs.outgoing, analysis: a, grid: grid, duration: duration).compactMap { source in
            for base in source.ends where window.contains(base / duration) {
                // The first bar line from there that no sung line spans.
                let point = (0...maxVocalShiftBars).map { base + Double($0) * barSec }.first { usable($0) && !sung($0) }
                if let point { return Exit(point: point, normal: normal, section: source.section) }
            }
            return nil
        }
    }

    /// A plan made for `exit` really leaves there: a mix at the point, a drop swap or a double drop whose outgoing song is
    /// gone at or before the point, a brake just before it, or a floor blend that starts beside it; never one that puts two
    /// singers together, and always earlier than the usual mix-out.
    static func leaves(_ plan: TransitionPlan, at exit: Exit) -> Bool {
        guard plan.mode == .beat, plan.vocalAction != "min", let out = plan.mixOutSec, out <= exit.normal - nominalBarSec / 2
        else { return false }
        if abs(out - exit.point) < 1e-6 { return true }
        if plan.style == .dropSwap { return plan.outgoingEndSec.map { abs($0 - exit.point) < 1e-6 } ?? false }
        // A double drop leaves after a drop before the exit, a brake a beat before it.
        if plan.style == .doubleDrop { return plan.outgoingEndSec.map { $0 <= exit.point + 1e-6 } ?? false }
        if plan.style == .brake { return abs(out + plan.brakeLeadSec - exit.point) < brakeSlackSec }
        return plan.overlapBars == 0 && plan.overlapSec >= 1 && floorSlack.contains(out - exit.point)
    }

    private static func trustedGrid(_ side: MusicTransitionSide, _ analysis: MusicAnalysis) -> MusicBeatGrid? {
        guard let grid = side.grid ?? analysis.usableGrid, MusicBeatPlanner.trusted(grid), grid.downbeatPhase != nil else { return nil }
        return grid
    }

    /// The places the song could be left, best source first, each in song order.
    private static func candidates(
        _ side: MusicTransitionSide, analysis: MusicAnalysis, grid: MusicBeatGrid?, duration: Double
    ) -> [(section: DJSection, ends: [Double])] {
        var out: [(section: DJSection, ends: [Double])] = []
        if let grid { out.append((.chorus2, Array(MusicSectionMap.derive(analysis: analysis, grid: grid).chorusEnds.dropFirst()))) }
        if let hooks = side.lyricCues?.hooks { out.append((.hook2, hooks.dropFirst().map { barLine(nearest: $0.upperBound, grid) })) }
        if let grid { out.append((.drop2, dropEnds(energy: analysis.energy, grid: grid, duration: duration))) }
        return out
    }

    private static func barLine(nearest time: Double, _ grid: MusicBeatGrid?) -> Double {
        guard let grid, let origin = grid.barTime(0) else { return time }
        let bar = 4 * grid.periodSec
        return origin + ((time - origin) / bar).rounded() * bar
    }

    /// Where the loud stretch after each of the song's drops ends, from its second drop on.
    static func dropEnds(energy: [UInt8], grid: MusicBeatGrid, duration: Double) -> [Double] {
        guard let drops = MusicDropDetector.drops(energy: energy, grid: grid) else { return [] }
        let bar = 4 * grid.periodSec
        return drops.filter { $0.timeSec >= introDropShare * duration }.dropFirst().compactMap { drop in
            stride(from: dropBars.lowerBound, through: dropBars.upperBound, by: dropStepBars).lazy
                .map { drop.timeSec + Double($0) * bar }
                .first { at in
                    guard let loud = level(energy, from: drop.timeSec, to: at), let after = level(energy, from: at, to: at + 2 * bar)
                    else { return false }
                    return loud - after >= dropEndDb
                }
        }
    }

    /// The mean level (dB) of a stretch of an energy curve; nil when it does not hold one.
    static func level(_ energy: [UInt8], from start: Double, to end: Double) -> Float? {
        let block = MusicAnalysis.energyBlockSeconds
        guard start.isFinite, end.isFinite, start >= 0, end > start, end / block < 1e7 else { return nil }
        let lo = Int((start / block).rounded()), hi = Int((end / block).rounded())
        guard hi <= energy.count, hi > lo else { return nil }
        let sum = energy[lo..<hi].reduce(Float(0)) { $0 + Float($1) * MusicAnalysis.energyStepDb + MusicAnalysis.energyFloorDb }
        return sum / Float(hi - lo)
    }

    /// A lyric line spans `time`. Line by line when the lines are known (`MusicVocalGuard.splitsLine`); else by the intervals, where
    /// a margin of 50 ms either side keeps a line that ends on the bar from counting.
    static func sung(_ side: MusicTransitionSide, at time: Double) -> Bool {
        if let lines = side.lyricCues?.lines, !lines.isEmpty { return MusicVocalGuard.splitsLine(lines, at: time) }
        guard let intervals = side.vocalIntervals else { return false }
        return intervals.contains { $0.lowerBound < time - 0.05 && $0.upperBound > time + 0.05 }
    }
}
