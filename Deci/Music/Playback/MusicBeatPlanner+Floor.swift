// Deci/Music/Playback/MusicBeatPlanner+Floor.swift
// Tier 4c: the floor of every Mix transition. When no beat grid can be trusted (or the tempos, the phrase room or two singers
// refuse a beat blend), the pair still gets a blend: a beat-mode plan at rate 1 with a 6 to 8 s overlap that starts at the
// smart plan's start and hands the bass over mid-way, so the engine runs it through its beat path like any blend. When both
// songs have a grid and the tempos meet within `maxRateError` (8%, the outgoing deck's own rate counted) the incoming song
// starts at the matched rate, kept for the whole song, and its start is snapped beat on beat (downbeat on downbeat when both
// are known); otherwise nothing can be aligned and the outgoing song is thinned instead (see `floorBlendPlan`). Pure.

import Foundation

extension MusicBeatPlanner {
    /// The overlap of a floor blend, and the shortest one a pair with little room still gets.
    static let floorFadeSeconds = 8.0
    static let floorMinFadeSeconds = 6.0
    /// The bass hands over across this many seconds in a floor blend.
    static let floorBassHandoverSec = 2.0
    /// Tempos closer than this (a fraction, half and double time folded in) count as matched: the incoming song is played at
    /// the matching rate, so the kicks stay together for the whole overlap. The same 8% cap as every Mix rate.
    static let floorTempoError = maxRateError
    /// The incoming song must still have this much left after the overlap.
    static let floorMinIncomingRemainingSec = 10.0
    /// How far (whole seconds, each way) a floor blend may move off the smart start to keep two singers apart.
    static let floorShiftSearchSec = 10

    /// The blend that is never refused: beat mode, rate 1, a 6 to 8 s fade from the smart start, the bass handing over at the
    /// middle. When the tempos differ by more than 3% (or are unknown) two kick drums would pound out of time for the whole
    /// overlap, so the outgoing song is thinned instead, as a DJ's EQ would: the plan is a filter sweep (a high-pass on the
    /// outgoing song rising from `MusicSweepSettings`), and the incoming bass comes in where the sweep passes 80 Hz, about a
    /// quarter of the way in. nil only when a song is too short to hold the fade (then the plain smart fade stays).
    static func floorBlendPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan) -> TransitionPlan? {
        gridlessBlendPlan(inputs, smart: smart, forceSweep: false)
    }

    /// The filter sweep without a trusted grid: an 8 s floor blend whose outgoing song always gets the high-pass.
    static func gridlessSweepPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan) -> TransitionPlan? {
        gridlessBlendPlan(inputs, smart: smart, forceSweep: true)
    }

    /// A side's grid for the floor: the planner's own or the stored one, counted only when it passes `trusted` (a grid the planner
    /// refused must not set a rate or an alignment). `usableGrid` only checks the row version, so the check is made here.
    static func floorGrid(_ side: MusicTransitionSide) -> MusicBeatGrid? {
        guard let grid = side.grid ?? side.analysis?.usableGrid, trusted(grid) else { return nil }
        return grid
    }

    /// The incoming rate that puts the incoming beats on the outgoing deck's beats, when both songs have a tempo and they meet
    /// within `floorTempoError` (half and double time folded in). nil otherwise.
    static func floorTempo(_ inputs: MusicTransitionInputs) -> (rate: Double, multiple: Double)? {
        guard let a = floorGrid(inputs.outgoing)?.bpm, let b = floorGrid(inputs.incoming)?.bpm,
              a.isFinite, b.isFinite, a > 0, b > 0 else { return nil }
        return tempoMatch(outBpm: a * outgoingRate(inputs), inBpm: b, tolerance: floorTempoError)
    }

    /// True when both songs have a tempo and they meet within `floorTempoError`.
    static func floorTempoMatched(_ inputs: MusicTransitionInputs) -> Bool { floorTempo(inputs) != nil }

    /// The grids a floor blend can be snapped onto: both songs have one and their tempos meet within 3%. `bars` is true when both
    /// have a downbeat and the tempos are the same speed (not half or double time), so a downbeat can land on a downbeat.
    static func floorAlignment(_ inputs: MusicTransitionInputs) -> (out: MusicBeatGrid, incoming: MusicBeatGrid, bars: Bool)? {
        guard floorTempoMatched(inputs),
              let a = floorGrid(inputs.outgoing),
              let b = floorGrid(inputs.incoming),
              a.periodSec.isFinite, b.periodSec.isFinite, a.periodSec > 0, b.periodSec > 0,
              a.anchorSec.isFinite, b.anchorSec.isFinite else { return nil }
        let sameSpeed = floorTempo(inputs)?.multiple == 1
        return (a, b, sameSpeed && a.barTime(0) != nil && b.barTime(0) != nil)
    }

    /// The grid's beat (or downbeat) closest to `t`, or the first one at or after it.
    private static func snap(_ grid: MusicBeatGrid, _ t: Double, bars: Bool, atOrAfter: Bool) -> (time: Double, unit: Double) {
        let unit = bars ? 4 * grid.periodSec : grid.periodSec
        let origin = bars ? (grid.barTime(0) ?? grid.anchorSec) : grid.anchorSec
        let position = (t - origin) / unit
        let index = atOrAfter ? (position - 1e-9).rounded(.up) : position.rounded()
        return (origin + index * unit, unit)
    }

    private static func gridlessBlendPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan, forceSweep: Bool) -> TransitionPlan? {
        guard inputs.beatMixEnabled, inputs.crossfadeOn, smart.mode == .smart, !inputs.manualSkip, !inputs.albumInOrder,
              !inputs.loopSong, !inputs.cleanStartFlag, !inputs.cleanPairFlag,
              inputs.outgoing.videoId != inputs.incoming.videoId,
              let aDuration = valid(inputs.outgoing.durationSeconds), let bDuration = valid(inputs.incoming.durationSeconds),
              let smartStart = smart.fadeStartSec, smartStart.isFinite, smartStart >= 0,
              smart.incomingStartSec.isFinite, smart.incomingStartSec >= 0 else { return nil }
        let aEnd = smart.outgoingEndSec ?? aDuration
        let bEnd = inputs.incoming.analysis.flatMap { MusicTransitionPlanner.trimmedEnd(of: $0, duration: bDuration) } ?? bDuration
        let alignment = floorAlignment(inputs)
        let outRate = outgoingRate(inputs)
        // The rate the incoming song keeps for its whole song: the match when the tempos meet (3 to 8% included), else 1.
        let matchRate = floorTempo(inputs)?.rate ?? 1
        let inRate = abs(matchRate - 1) <= 1e-9 ? 1 : matchRate
        // The incoming start moves to its next beat (downbeat) so it can land on one of the outgoing song's.
        var inStart = smart.incomingStartSec
        var inSnapped = false
        if let alignment {
            let snapped = snap(alignment.incoming, inStart, bars: alignment.bars, atOrAfter: true).time
            if snapped.isFinite, bEnd - snapped - floorMinFadeSeconds * inRate >= floorMinIncomingRemainingSec { inStart = snapped; inSnapped = true }
        }
        let earliest = max(0, inputs.earliestMixOutSec ?? 0)
        let guardOn = inputs.vocalGuardEnabled
        let outIntervals = inputs.outgoing.vocalIntervals

        // The first (fade, mix-out) that neither clips the outgoing singer nor puts two singers together beyond the budget wins,
        // trying the smart start first, then a gap just past a line, then the start moved earlier or later by whole seconds
        // (nearest first, at most 10 s); when none is clean the least bad one is taken, so a blend is always planned while
        // there is room, and the guard's own "min" action is recorded on it.
        var best: (mixOut: Double, fade: Double, cost: Double, collision: Double, aligned: Bool)?
        var firstCollision: Double?
        func consider(_ mixOut: Double, _ fade: Double) -> Bool {
            var start = max(mixOut, earliest)
            // The fade is heard in wall seconds; the outgoing song spends `outRate` item seconds of it each.
            let fadeItem = fade * outRate
            guard start + fadeItem <= aEnd + 1e-9 else { return false }
            // Snap the mix-out onto an outgoing beat (downbeat), staying inside the song and after the earliest point.
            var aligned = false
            if inSnapped, let alignment {
                var (time, unit) = snap(alignment.out, start, bars: alignment.bars, atOrAfter: false)
                if time + fadeItem > aEnd + 1e-9 { time -= unit }
                if time < earliest - 1e-9 { time += unit }
                if time.isFinite, time >= earliest - 1e-9, time >= 0, time + fadeItem <= aEnd + 1e-9 { start = time; aligned = true }
            }
            let clips = guardOn && outIntervals.map { MusicVocalGuard.cutsOutgoingSinger($0, endSec: start + fadeItem) } == true
            let collision = guardOn ? (guardCollision(inputs, outStart: start, inStart: inStart, rate: inRate, wallLength: fade) ?? 0) : 0
            if firstCollision == nil { firstCollision = collision }
            let cost = collision + (clips ? 100 : 0)
            if best == nil || cost < best!.cost - 1e-12 { best = (start, fade, cost, collision, aligned) }
            return !clips && collision <= MusicVocalGuard.budgetSec
        }
        search: for fade in [floorFadeSeconds, floorMinFadeSeconds] {
            let fadeItem = fade * outRate
            guard bEnd - inStart - fade * inRate >= floorMinIncomingRemainingSec, aEnd - fadeItem >= earliest else { continue }
            let base = min(smartStart, aEnd - fadeItem)
            if consider(base, fade) { break search }
            guard guardOn else { continue }
            // The blend would end mid-word: move it so it ends in a gap between lines, within a few seconds.
            if let intervals = outIntervals, let gap = MusicVocalGuard.nearestGap(intervals, to: max(base, earliest) + fadeItem),
               consider(gap - fadeItem, fade) { break search }
            for step in 1...floorShiftSearchSec {
                for shifted in [base - Double(step), base + Double(step)] where shifted >= earliest && shifted <= aEnd - fadeItem {
                    if consider(shifted, fade) { break search }
                }
            }
        }
        guard let chosen = best else { return nil }

        let fade = chosen.fade
        var plan = smart
        plan.mode = .beat
        plan.reason = .ok
        plan.fallbackReason = nil
        // Tier 4c: the matched rate (3 to 8% included) is the incoming song's rate for its whole song; no match keeps 1.
        let sweeps = forceSweep || !floorTempoMatched(inputs)
        plan.incomingRate = inRate
        plan.mixOutSec = chosen.mixOut
        plan.mixInSec = inStart
        plan.floorAligned = chosen.aligned && inSnapped
        plan.fallbackIncomingStartSec = inStart
        plan.incomingStartSec = inStart
        plan.fadeStartSec = chosen.mixOut
        plan.fadeSeconds = fade
        plan.outgoingEndSec = chosen.mixOut + fade * outRate
        plan.overlapBars = 0
        plan.overlapSec = fade
        plan.barSec = 0
        if guardOn, chosen.collision > MusicVocalGuard.budgetSec {
            // No place within reach is clean: the least bad one, recorded the way the smart guard records its own fallback.
            plan.vocalAction = "min"
            plan.vocalCollisionSec = chosen.collision
            plan.vocalBeforeSec = firstCollision
        }
        if sweeps {
            plan.style = .filterSweep
            plan.sweepFromHz = Double(MusicSweepSettings.defaultFromHz)
            plan.sweepToHz = Double(MusicSweepSettings.defaultToHz)
            let swap = sweepBassSwapSec(overlap: fade, fromHz: plan.sweepFromHz, toHz: plan.sweepToHz)
            plan.bassSwapAtSec = swap
            plan.bassHandoverSec = min(floorBassHandoverSec, max(0.05, fade - swap))
        } else {
            plan.style = .longBlend
            plan.bassSwapAtSec = fade / 2
            plan.bassHandoverSec = floorBassHandoverSec
        }
        return plan
    }
}
