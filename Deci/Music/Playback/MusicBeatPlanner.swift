// Deci/Music/Playback/MusicBeatPlanner.swift
// Tier 3b P2: upgrades a tier 2 smart plan to a beat-matched mix, or refuses and hands the smart plan back with the
// reason. Pure: value types in, value type out, no clock and no I/O.
//
// Tempo: the incoming song may play up to 8% faster or slower (pitch kept), also against half or double the outgoing
// tempo. The overlap is 8 bars (16 once the bass swap exists and both songs have room) of the outgoing song, starting on
// one of its phrase boundaries (8-bar multiples counted from its first downbeat). The incoming song starts on one of its
// own bar boundaries at or after its leading silence, so its beats land on the outgoing beats.

import Foundation

enum MusicBeatPlanner {
    /// Why beat mode was refused; the raw value goes into `TransitionPlan.fallbackReason` and the log.
    enum Fallback: String, Sendable {
        case disabled, albumInOrder, loopSong, noMixFlag, manualSkip, tooShort, noDuration
        case gridMissing, gridLowConf, tempoClash, noPhraseRoom
    }

    static let tempoTolerance = 0.08
    static let minConfidence: Float = 0.5
    static let maxIntervalSpread: Float = 0.04
    static let maxDriftSec: Float = 0.003
    static let phraseBars = 8
    /// How far before the outgoing outro start a phrase boundary may be.
    static let outroSlackBars = 8
    /// The incoming song must still have this much left after the overlap.
    static let minIncomingRemainingSec = 20.0
    static let glideBackSeconds = 10.0
    /// The bass hands over across this many outgoing beats.
    static let bassHandoverBeats = 2.0

    // MARK: Tempo

    /// The incoming rate that puts the incoming beats on the outgoing beats. `multiple` is how many incoming beats
    /// fit in one outgoing beat at the same tempo: 1 same, 2 the incoming is double time, 0.5 half time. The match with
    /// the smallest rate error wins; nil when none is within `tolerance`.
    static func tempoMatch(
        outBpm: Double, inBpm: Double, tolerance: Double = tempoTolerance
    ) -> (rate: Double, multiple: Double)? {
        guard outBpm.isFinite, inBpm.isFinite, outBpm > 0, inBpm > 0 else { return nil }
        var best: (rate: Double, multiple: Double)?
        for multiple in [1.0, 2.0, 0.5] {
            let rate = outBpm * multiple / inBpm
            guard abs(rate - 1) <= tolerance + 1e-9 else { continue }
            if best == nil || abs(rate - 1) < abs(best!.rate - 1) - 1e-12 { best = (rate, multiple) }
        }
        return best
    }

    // MARK: Plan

    /// `smart` is the tier 2 plan for the same inputs. Returns it unchanged plus `fallbackReason` on any refusal.
    static func plan(_ inputs: MusicTransitionInputs, smart: TransitionPlan) -> TransitionPlan {
        func refuse(_ reason: Fallback) -> TransitionPlan {
            var plan = smart
            plan.fallbackReason = reason.rawValue
            return plan
        }
        guard inputs.beatMixEnabled else { return refuse(.disabled) }
        if inputs.albumInOrder { return refuse(.albumInOrder) }
        if inputs.loopSong || inputs.outgoing.videoId == inputs.incoming.videoId { return refuse(.loopSong) }
        if inputs.cleanStartFlag || inputs.cleanPairFlag { return refuse(.noMixFlag) }
        if inputs.manualSkip { return refuse(.manualSkip) }
        guard inputs.crossfadeOn else { return refuse(.disabled) }
        if smart.reason == .tooShort { return refuse(.tooShort) }
        guard let aDuration = valid(inputs.outgoing.durationSeconds),
              let bDuration = valid(inputs.incoming.durationSeconds) else { return refuse(.noDuration) }
        guard smart.mode == .smart, let a = inputs.outgoing.analysis, let b = inputs.incoming.analysis,
              let aGrid = inputs.outgoing.grid ?? a.usableGrid,
              let bGrid = inputs.incoming.grid ?? b.usableGrid else { return refuse(.gridMissing) }
        guard trusted(aGrid), trusted(bGrid) else { return refuse(.gridLowConf) }
        guard let tempo = tempoMatch(outBpm: aGrid.bpm, inBpm: bGrid.bpm) else { return refuse(.tempoClash) }

        let aEnd = smart.outgoingEndSec ?? aDuration
        let barSec = 4 * aGrid.periodSec
        let bothPhrased = aGrid.downbeatPhase != nil && bGrid.downbeatPhase != nil
        let lengths = inputs.bassSwapAvailable && bothPhrased ? [16, 8] : [8]

        for bars in lengths {
            let overlap = Double(bars) * barSec
            guard let mixOut = mixOutTime(grid: aGrid, analysis: a, bars: bars, barSec: barSec, end: aEnd),
                  let mixIn = mixInTime(grid: bGrid, start: smart.incomingStartSec) else { continue }
            // The incoming song advances `rate` item seconds per outgoing second.
            let consumed = overlap * tempo.rate
            guard bDuration - (mixIn + consumed) >= minIncomingRemainingSec else { continue }

            var plan = smart
            plan.mode = .beat
            plan.reason = .ok
            plan.fallbackReason = nil
            plan.incomingRate = tempo.rate
            plan.mixOutSec = mixOut
            plan.mixInSec = mixIn
            plan.incomingStartSec = mixIn
            plan.fadeStartSec = mixOut
            plan.fadeSeconds = overlap
            plan.outgoingEndSec = mixOut + overlap
            plan.overlapBars = bars
            plan.overlapSec = overlap
            plan.barSec = barSec
            plan.glideBackSec = glideBackSeconds
            if inputs.bassSwapAvailable, bothPhrased {
                plan.bassSwapAtSec = overlap / 2
                plan.bassHandoverSec = bassHandoverBeats * aGrid.periodSec
            }
            return plan
        }
        return refuse(.noPhraseRoom)
    }

    // MARK: Pieces

    private static func trusted(_ grid: MusicBeatGrid) -> Bool {
        MusicBeatGrid.periodRange.contains(grid.periodSec) && grid.anchorSec.isFinite
            && grid.spanStartSec.isFinite && grid.spanEndSec.isFinite
            && grid.beatConfidence >= minConfidence && grid.intervalSpread <= maxIntervalSpread
            && abs(grid.driftSec) <= maxDriftSec
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The latest outgoing boundary (a phrase boundary when the downbeat is known, else a bar's worth of beats from the
    /// grid anchor) where `bars` bars fit before `end`, inside the validated span and not before the outro start minus
    /// `outroSlackBars` bars.
    static func mixOutTime(grid: MusicBeatGrid, analysis: MusicAnalysis, bars: Int, barSec: Double, end: Double) -> Double? {
        let limit = end - Double(bars) * barSec
        let earliest = max(0, grid.spanStartSec, analysis.outroStart - Double(outroSlackBars) * barSec)
        guard limit.isFinite, earliest.isFinite, limit >= earliest else { return nil }
        let latest = min(limit, grid.spanEndSec)
        var candidate: Double?
        if let first = grid.barTime(0) {
            let phrase = Double(phraseBars) * barSec
            let count = Int(((latest - first) / phrase + 1e-9).rounded(.down))
            if count >= 0 { candidate = first + Double(count) * phrase }
        } else {
            let index = Int(((latest - grid.anchorSec) / barSec + 1e-9).rounded(.down))
            candidate = grid.beatTime(4 * index)
        }
        guard let time = candidate, time >= earliest - 1e-9, time <= latest + 1e-9 else { return nil }
        return time
    }

    /// The first incoming bar boundary (any beat when the downbeat is unknown) at or after `start`.
    static func mixInTime(grid: MusicBeatGrid, start: Double) -> Double? {
        var k = grid.nextBeat(atOrAfter: start).index
        if let phase = grid.downbeatPhase { k += ((phase - k) % 4 + 4) % 4 }
        let time = grid.beatTime(k)
        return time.isFinite && time >= 0 ? time : nil
    }
}
