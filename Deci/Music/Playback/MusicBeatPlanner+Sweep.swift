// Deci/Music/Playback/MusicBeatPlanner+Sweep.swift
// Tier 4b P2: the plans of the filter sweep and the drop swap. Both are beat-mode plans with an overlap, so the engine
// runs them like a long blend; the style only changes what is heard inside the overlap.

import Foundation

extension MusicBeatPlanner {
    /// Bars of lead before the outgoing phrase end: 8, or 4 when the incoming song does not have 8 bars before its drop.
    static let dropLeadBars = [8, 4]

    // MARK: Filter sweep

    /// The beat blend `beat` with a high-pass sweep on the outgoing song: same timing, rate nudge and overlap. nil when
    /// `beat` is not a beat blend with an overlap (a floor blend has no bars, a cut has no overlap to speak of).
    static func filterSweepPlan(from beat: TransitionPlan) -> TransitionPlan? {
        guard beat.mode == .beat, beat.style == .longBlend, beat.overlapSec >= 1 else { return nil }
        var plan = beat
        plan.style = .filterSweep
        plan.sweepFromHz = Double(MusicSweepSettings.defaultFromHz)
        plan.sweepToHz = Double(MusicSweepSettings.defaultToHz)
        if plan.bassSwapAtSec != nil {
            // The outgoing high-pass thins the lows as it rises, so the incoming lows come in where it passes 80 Hz (about a
            // quarter of the overlap), not at the middle: otherwise both songs would have no bass for a stretch.
            let swap = sweepBassSwapSec(overlap: beat.overlapSec, fromHz: plan.sweepFromHz, toHz: plan.sweepToHz)
            plan.bassSwapAtSec = swap
            plan.bassHandoverSec = min(beat.bassHandoverSec, max(0.05, beat.overlapSec - swap))
        }
        return plan
    }

    /// The frequency below which the outgoing lows count as gone.
    static let sweepBassHandoverHz = 80.0

    /// When, `overlap` seconds long, a log sweep from `fromHz` to `toHz` passes `sweepBassHandoverHz`.
    static func sweepBassSwapSec(overlap: Double, fromHz: Double, toHz: Double) -> Double {
        guard fromHz > 0, toHz > fromHz, overlap > 0 else { return overlap / 2 }
        let progress = log(min(max(sweepBassHandoverHz, fromHz), toHz) / fromHz) / log(toHz / fromHz)
        return overlap * progress
    }

    // MARK: Drop swap

    /// The incoming song's drop lands exactly where the outgoing song's phrase ends. The overlap is `lead` bars before that
    /// phrase end `P`: the incoming starts `lead` bars before its drop `D` (the rate nudge counted, so its beats sit on the
    /// outgoing beats), fades in across the lead, and the outgoing song fades out so it is gone at `P`. nil when either grid
    /// is not trusted or has no downbeat, the tempos do not meet at the same bar length, there is no confident drop with
    /// 4 bars before it, or no phrase end has room.
    static func dropSwapPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan) -> TransitionPlan? {
        guard inputs.beatMixEnabled, inputs.crossfadeOn, smart.mode == .smart, smart.reason != .tooShort,
              !inputs.manualSkip, !inputs.albumInOrder, !inputs.loopSong, !inputs.cleanStartFlag, !inputs.cleanPairFlag,
              inputs.outgoing.videoId != inputs.incoming.videoId,
              let aDuration = valid(inputs.outgoing.durationSeconds), let bDuration = valid(inputs.incoming.durationSeconds),
              let a = inputs.outgoing.analysis, let b = inputs.incoming.analysis,
              let aGrid = inputs.outgoing.grid ?? a.usableGrid, let bGrid = inputs.incoming.grid ?? b.usableGrid,
              trusted(aGrid), trusted(bGrid), aGrid.downbeatPhase != nil, bGrid.downbeatPhase != nil,
              let tempo = tempoMatch(outBpm: aGrid.bpm * outgoingRate(inputs), inBpm: bGrid.bpm), tempo.multiple == 1,
              let drop = MusicDropDetector.best(in: b, grid: bGrid) else { return nil }

        let outRate = outgoingRate(inputs)
        let aEnd = smart.outgoingEndSec ?? aDuration
        let barOut = 4 * aGrid.periodSec
        let bEnd = MusicTransitionPlanner.trimmedEnd(of: b, duration: bDuration) ?? bDuration
        // The outgoing phrase end: the latest phrase boundary the existing mix-out logic accepts (no overlap yet).
        guard let phraseEnd = mixOutTime(grid: aGrid, analysis: a, bars: 0, barSec: barOut, end: aEnd) else { return nil }
        let earliestOut = max(0, aGrid.spanStartSec, a.outroStart - Double(outroSlackBars) * barOut)
        let earliestIn = max(0, smart.incomingStartSec, bGrid.spanStartSec - spanSlackBeats * bGrid.periodSec)
        // After the drop the incoming song still has to play, inside the part of the grid that was validated.
        guard bEnd - drop.timeSec >= minIncomingRemainingSec,
              drop.timeSec <= bGrid.spanEndSec + spanSlackBeats * bGrid.periodSec else { return nil }

        for lead in dropLeadBars {
            // Bars are the outgoing song's own seconds; the overlap is heard in wall seconds.
            let overlapItem = Double(lead) * barOut
            let overlap = overlapItem / outRate
            let mixOut = phraseEnd - overlapItem
            // The incoming song advances `rate` item seconds per wall second.
            let mixIn = drop.timeSec - overlap * tempo.rate
            guard overlap <= maxOverlapSec, mixOut >= earliestOut - 1e-9, mixIn >= earliestIn - 1e-9 else { continue }
            if let earliest = inputs.earliestMixOutSec, mixOut < earliest { continue }
            if inputs.vocalGuardEnabled,
               let collision = guardCollision(inputs, outStart: mixOut, inStart: mixIn, rate: tempo.rate, wallLength: overlap),
               collision > MusicVocalGuard.budgetSec {
                continue
            }
            var plan = smart
            plan.mode = .beat
            plan.reason = .ok
            plan.style = .dropSwap
            plan.fallbackReason = nil
            plan.incomingRate = tempo.rate
            plan.mixOutSec = mixOut
            plan.mixInSec = mixIn
            plan.fallbackIncomingStartSec = smart.incomingStartSec
            plan.incomingStartSec = mixIn
            plan.fadeStartSec = mixOut
            plan.fadeSeconds = overlap
            plan.outgoingEndSec = phraseEnd
            plan.overlapBars = lead
            plan.overlapSec = overlap
            plan.barSec = barOut
            if inputs.bassSwapAvailable {
                // The lows of the new song come in over the last two beats, so they are full on the drop itself.
                let handover = min(bassHandoverBeats * aGrid.periodSec / outRate, overlap / 2)
                plan.bassSwapAtSec = overlap - handover
                plan.bassHandoverSec = handover
            }
            return plan
        }
        return nil
    }
}
