// Deci/Music/Playback/MusicBeatPlanner+Floor.swift
// Tier 4c: the floor of every Mix transition. When no beat grid can be trusted (or the tempos, the phrase room or two singers
// refuse a beat blend), the pair still gets a blend: a beat-mode plan at rate 1 that starts at the smart plan's start and hands
// the bass over on the way, so the engine runs it through its beat path like any blend. The incoming song always plays at rate 1
// (wjyijr). When both songs have a grid and the tempos meet within `floorTempoError` (the outgoing deck's own rate counted) its
// start is snapped beat on beat (downbeat on downbeat when both are known) and moved so the beats drift evenly around the outgoing
// ones, for 6 to 8 s. Otherwise two drum parts would run apart, so the songs are handed over the way a DJ does it: quickly, and
// with the EQ (see `floorBlendPlan`). Pure.

import Foundation

extension MusicBeatPlanner {
    /// The overlap of a floor blend, and the shortest one a pair with little room still gets.
    static let floorFadeSeconds = 8.0
    static let floorMinFadeSeconds = 6.0
    /// The bass hands over across this many seconds in a floor blend.
    static let floorBassHandoverSec = 2.0
    /// Tempos closer than this (a fraction, half and double time folded in) count as matched: the incoming song plays at rate 1,
    /// and across the longest floor overlap its beats stay within `maxBeatDriftSec` of the outgoing ones (0.75%).
    static let floorTempoError = 2 * maxBeatDriftSec / floorFadeSeconds
    /// The incoming song must still have this much left after the overlap.
    static let floorMinIncomingRemainingSec = 10.0
    /// A handover between tempos that do not meet is the first of these numbers of outgoing bars that is at least this long.
    static let handoverBars = [1.0, 2.0, 4.0]
    static let handoverMinSec = 3.2
    /// Where the bass changes hands (a share of the overlap) and how fast, when there is no beat to land it on.
    static let quickSwapShare = 0.25
    static let quickHandoverSec = 0.5
    /// How far (whole seconds, each way) a floor blend may move off the smart start to keep two singers apart.
    static let floorShiftSearchSec = 10

    /// What a floor blend is made of.
    private enum Shape {
        /// 6 to 8 s, beat on beat, the bass handing over at the middle.
        case aligned
        /// The same with nothing lined up: one of the songs has no drums there.
        case open
        /// 6 to 8 s with the high-pass on the outgoing song.
        case sweep
        /// A few bars, the bass changing hands on the "1" of both songs.
        case step(Step)
        /// 6 s with an early, quick bass change: there is no beat to land it on.
        case quick
    }

    /// A handover at tempos that do not meet: `fade` is whole bars of the outgoing song and `land` is where the bass changes hands
    /// (wall seconds into it), a downbeat of both songs.
    struct Step: Equatable {
        let out: MusicBeatGrid
        let incoming: MusicBeatGrid
        let fade: Double
        let land: Double
    }

    /// The blend that is never refused: beat mode, rate 1, from the smart start. Matched tempos run beat on beat for 6 to 8 s. When
    /// the tempos differ by more than `floorTempoError` (or are unknown) two kick drums would pound out of time, so unless one of
    /// the songs has no drums there the old song is taken away with the EQ as the new bass comes in: on the "1" of both songs where
    /// their bars are known, else early in a 6 s fade. nil only when a song is too short to hold the fade (then the plain smart fade
    /// stays).
    static func floorBlendPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan) -> TransitionPlan? {
        if floorTempoMatched(inputs), let plan = gridlessBlendPlan(inputs, smart: smart, shape: .aligned) { return plan }
        if MusicTransitionStylePicker.hasQuietEdge(inputs), let plan = gridlessBlendPlan(inputs, smart: smart, shape: .open) { return plan }
        if let step = handoverStep(inputs), let plan = gridlessBlendPlan(inputs, smart: smart, shape: .step(step)) { return plan }
        return gridlessBlendPlan(inputs, smart: smart, shape: .quick)
    }

    /// The filter sweep without a trusted grid: an 8 s floor blend whose outgoing song always gets the high-pass.
    static func gridlessSweepPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan) -> TransitionPlan? {
        gridlessBlendPlan(inputs, smart: smart, shape: .sweep)
    }

    /// The handover two songs with known bars get. nil when a grid is not trusted or has no downbeat.
    static func handoverStep(_ inputs: MusicTransitionInputs) -> Step? {
        guard let a = floorGrid(inputs.outgoing), let b = floorGrid(inputs.incoming), a.barTime(0) != nil, b.barTime(0) != nil else { return nil }
        let bar = 4 * a.periodSec / outgoingRate(inputs)
        guard bar.isFinite, bar > 0, b.periodSec.isFinite, b.periodSec > 0,
              let bars = handoverBars.first(where: { $0 * bar >= handoverMinSec - 1e-9 }) else { return nil }
        return Step(out: a, incoming: b, fade: bars * bar, land: bars > 1 ? bar : bar / 2)
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

    /// The grids a floor blend can be snapped onto: both songs have one and their tempos meet within `floorTempoError`. `bars` is true when both
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

    private static func gridlessBlendPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan, shape: Shape) -> TransitionPlan? {
        guard inputs.beatMixEnabled, inputs.crossfadeOn, smart.mode == .smart, !inputs.manualSkip, !inputs.albumInOrder,
              !inputs.loopSong, !inputs.cleanStartFlag, !inputs.cleanPairFlag,
              inputs.outgoing.videoId != inputs.incoming.videoId,
              let aDuration = valid(inputs.outgoing.durationSeconds), let bDuration = valid(inputs.incoming.durationSeconds),
              let smartStart = smart.fadeStartSec, smartStart.isFinite, smartStart >= 0,
              smart.incomingStartSec.isFinite, smart.incomingStartSec >= 0 else { return nil }
        let aEnd = smart.outgoingEndSec ?? aDuration
        let bEnd = inputs.incoming.analysis.flatMap { MusicTransitionPlanner.trimmedEnd(of: $0, duration: bDuration) } ?? bDuration
        var step: Step?, alignment: (out: MusicBeatGrid, incoming: MusicBeatGrid, bars: Bool)?
        switch shape {
        case .aligned, .sweep: alignment = floorAlignment(inputs)
        case .step(let built): step = built
        case .open, .quick: break
        }
        let fades = switch shape {
        case .step(let built): [built.fade]
        case .quick: [floorMinFadeSeconds]
        default: [floorFadeSeconds, floorMinFadeSeconds]
        }
        let outRate = outgoingRate(inputs)
        // The incoming song always plays at its own tempo; a match only places its start.
        let inRate = 1.0
        // The incoming start moves to its next beat (downbeat) so it can land on one of the outgoing song's.
        let entryUnit = alignment.map { ($0.bars ? 4 : 1) * $0.incoming.periodSec } ?? 0
        var inStart = entryStart(inputs, smart: smart, lead: fades[0] + entryUnit)
        var inSnapped = false
        if let step {
            // The bass lands on the downbeat the song gets going with, or the first one that leaves room for the lead before it.
            let from = entryBarStart(inputs, smart: smart, lead: step.land, grid: step.incoming)
            inStart = snap(step.incoming, from + step.land, bars: true, atOrAfter: true).time - step.land
            inSnapped = inStart.isFinite && inStart >= 0
            guard inSnapped else { return nil }
        } else if let alignment {
            let snapped = snap(alignment.incoming, inStart, bars: alignment.bars, atOrAfter: true).time
            if snapped.isFinite, bEnd - snapped - floorMinFadeSeconds * inRate >= floorMinIncomingRemainingSec { inStart = snapped; inSnapped = true }
        }
        let earliest = max(0, inputs.earliestMixOutSec ?? 0)
        let guardOn = inputs.vocalGuardEnabled
        let outIntervals = inputs.outgoing.vocalIntervals

        // Where the outgoing song's line is in the overlap: the bass change of a handover, else its start.
        let line = step.map { (grid: $0.out, bars: true, lead: $0.land * outRate) } ?? alignment.map { (grid: $0.out, bars: $0.bars, lead: 0) }

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
            if inSnapped, let line {
                var (time, unit) = snap(line.grid, start + line.lead, bars: line.bars, atOrAfter: false)
                time -= line.lead
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
        // A handover lands on a DJ exit; everything else starts there.
        let wanted = step == nil ? smartStart : inputs.djMixOutSec.map { $0 - (line?.lead ?? 0) } ?? smartStart
        search: for fade in fades {
            let fadeItem = fade * outRate
            guard bEnd - inStart - fade * inRate >= floorMinIncomingRemainingSec, aEnd - fadeItem >= earliest else { continue }
            let base = min(wanted, aEnd - fadeItem)
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
        let landed = chosen.aligned && inSnapped
        switch shape {
        case .aligned, .step: guard landed else { return nil }
        case .open, .quick, .sweep: break
        }

        let fade = chosen.fade
        var plan = smart
        plan.mode = .beat
        plan.reason = .ok
        plan.fallbackReason = nil
        plan.incomingRate = inRate
        plan.floorAligned = landed
        // An aligned start moves so the beats sit exactly together half way and drift evenly before and after (wjyijr).
        // A start too close to the top of the song to move far enough back would drift past `maxBeatDriftSec`: that pair is
        // handed over instead of blended with its beats apart. A sweep covers it.
        var start = inStart
        if landed, step == nil, let tempo = floorTempo(inputs) {
            if let centred = unityStart(mixIn: inStart, rate: tempo.rate, wallLength: fade) {
                start = centred
            } else if case .aligned = shape {
                return nil
            }
        }
        plan.mixOutSec = chosen.mixOut
        plan.mixInSec = start
        // An entry skipped part of the song: a plain start still begins at its top.
        plan.fallbackIncomingStartSec = inputs.djEntry == nil ? start : min(start, smart.incomingStartSec)
        plan.incomingStartSec = start
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
        switch shape {
        case .sweep:
            plan.style = .filterSweep
            plan.sweepFromHz = Double(MusicSweepSettings.defaultFromHz)
            plan.sweepToHz = Double(MusicSweepSettings.defaultToHz)
            let swap = sweepBassSwapSec(overlap: fade, fromHz: plan.sweepFromHz, toHz: plan.sweepToHz)
            plan.bassSwapAtSec = swap
            plan.bassHandoverSec = min(floorBassHandoverSec, max(0.05, fade - swap))
        case .quick:
            plan.style = .longBlend
            plan.handsOverByEQ = true
            plan.bassSwapAtSec = fade * quickSwapShare
            plan.bassHandoverSec = quickHandoverSec
        case .step(let step):
            plan.style = .longBlend
            plan.handsOverByEQ = true
            landBass(&plan, on: step.land, beat: step.out.periodSec / outRate)
        case .aligned, .open:
            plan.style = .longBlend
            plan.bassSwapAtSec = fade / 2
            plan.bassHandoverSec = floorBassHandoverSec
        }
        if landed, let alignment, let swap = plan.bassSwapAtSec {
            // The mix-out is on a beat (a downbeat) of the outgoing song, so the lines after it are whole units away.
            let beat = alignment.out.periodSec / outRate
            if let line = nearestLine(to: swap, unit: (alignment.bars ? 4 : 1) * beat, length: fade) {
                landBass(&plan, on: line, beat: beat)
            }
        }
        return plan
    }
}
