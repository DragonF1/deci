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
        case gridMissing, gridLowConf, tempoClash, noPhraseRoom, tooLate, vocalClash
    }

    static let tempoTolerance = 0.08
    static let minConfidence: Float = 0.5
    static let maxIntervalSpread: Float = 0.04
    static let maxDriftSec: Float = 0.003
    static let phraseBars = 8
    /// An overlap longer than this is never planned (very slow songs fall to a shorter length, then to the smart plan).
    static let maxOverlapSec = 40.0
    /// How far past the validated beat span a mix may reach, in beats of the song concerned.
    static let spanSlackBeats = 2.0
    /// Anchors and spans beyond this (seconds) are not believed even when they come in through `side.grid`.
    static let maxGridSeconds = 1e7
    /// How far before the outgoing outro start a phrase boundary may be.
    static let outroSlackBars = 8
    /// The incoming song must still have this much left after the overlap.
    static let minIncomingRemainingSec = 20.0
    static let glideBackSeconds = 10.0
    /// The bass hands over across this many outgoing beats.
    static let bassHandoverBeats = 2.0

    // MARK: Tempo

    /// The incoming rate that puts the incoming beats on the outgoing beats. `multiple` is how many incoming beats
    /// fit in one outgoing beat at the same tempo: 1 same, 2 the incoming is double time, 0.5 half time. For 2 and 0.5
    /// the beats align but the bars do not (an incoming bar is half or two outgoing bars long). The match with
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
        let bEnd = MusicTransitionPlanner.trimmedEnd(of: b, duration: bDuration) ?? bDuration
        let lengths = inputs.bassSwapAvailable && bothPhrased ? [16, 8] : [8]
        var late = false
        // Tier 3c: lengths skipped only because two singers would overlap, and the first and least of those collisions.
        var vocalSkipped = 0
        var firstCollision: Double?, leastCollision = Double.infinity

        // The 4-bar guard tier comes last, and only when a longer length had room and collided (a length with no room
        // does not stop it: a 16 bar overlap that never fits is no reason to refuse a clean 4 bar one).
        var index = 0
        while index < lengths.count + 1 {
            defer { index += 1 }
            let bars: Int
            if index < lengths.count {
                bars = lengths[index]
            } else {
                guard inputs.vocalGuardEnabled, vocalSkipped > 0, 4 * barSec >= MusicVocalGuard.minBeatTierSec
                else { break }
                bars = 4
            }
            // The 4 bar tier failing for a non-vocal reason keeps the vocal clash: the longer lengths were the ones refused.
            let guardTier = index >= lengths.count
            let overlap = Double(bars) * barSec
            guard overlap <= maxOverlapSec,
                  let mixOut = mixOutTime(grid: aGrid, analysis: a, bars: bars, barSec: barSec, end: aEnd, preferred: inputs.djMixOutSec),
                  let mixIn = mixInTime(grid: bGrid, start: smart.incomingStartSec) else {
                continue
            }
            if let earliest = inputs.earliestMixOutSec, mixOut < earliest {
                if !guardTier { late = true }
                continue
            }
            // The incoming song advances `rate` item seconds per outgoing second.
            let consumed = overlap * tempo.rate
            guard bEnd - (mixIn + consumed) >= minIncomingRemainingSec,
                  mixIn + consumed <= bGrid.spanEndSec + spanSlackBeats * bGrid.periodSec else {
                continue
            }
            var collision: Double?
            if inputs.vocalGuardEnabled {
                collision = MusicVocalGuard.collisionSec(
                    outgoing: a, incoming: b, outStart: mixOut, inStart: mixIn, rate: tempo.rate, length: overlap,
                    outgoingIntervals: inputs.outgoing.vocalIntervals, incomingIntervals: inputs.incoming.vocalIntervals
                )
                if let c = collision, c > MusicVocalGuard.budgetSec {
                    vocalSkipped += 1
                    if firstCollision == nil { firstCollision = c }
                    leastCollision = min(leastCollision, c)
                    continue
                }
            }

            var plan = smart
            plan.mode = .beat
            plan.reason = .ok
            plan.fallbackReason = nil
            plan.incomingRate = tempo.rate
            plan.mixOutSec = mixOut
            plan.mixInSec = mixIn
            plan.fallbackIncomingStartSec = smart.incomingStartSec
            plan.incomingStartSec = mixIn
            plan.fadeStartSec = mixOut
            plan.fadeSeconds = overlap
            plan.outgoingEndSec = mixOut + overlap
            plan.overlapBars = bars
            plan.overlapSec = overlap
            plan.barSec = barSec
            plan.glideBackSec = glideBackSeconds
            if let first = firstCollision, let c = collision {
                plan.vocalAction = "shorten"
                plan.vocalCollisionSec = c
                plan.vocalBeforeSec = first
            }
            if inputs.bassSwapAvailable, bothPhrased, bars != 4 {
                plan.bassSwapAtSec = overlap / 2
                plan.bassHandoverSec = bassHandoverBeats * aGrid.periodSec
            }
            return plan
        }
        if vocalSkipped > 0 {
            var plan = refuse(.vocalClash)
            plan.vocalBeforeSec = leastCollision
            return plan
        }
        return refuse(late ? .tooLate : .noPhraseRoom)
    }

    // MARK: Styled plans (Tier 4b)

    /// The cut fade: a few milliseconds, enough to take the click off the step and short enough that the downbeat stays hard.
    static let cutFadeSeconds = 0.004
    /// The echo tail is at most this long, however slow the song.
    static let maxEchoTailSec = 3.0
    /// Repeats the tail aims for: at feedback 0.5 six repeats are about -36 dB.
    static let echoRepeats = 6.0

    /// A quick cut or an echo out on the outgoing song's last bar line, for any tempo gap. The incoming song starts on its
    /// first bar line at or after its smart start, at rate 1. Beat mode with no overlap: the engine starts the incoming
    /// deck on the cut. nil when a grid is unusable, there is no bar line with room, or the incoming song is too short.
    static func styledPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan, style: MusicTransitionStyle) -> TransitionPlan? {
        griddedStyledPlan(inputs, smart: smart, style: style) ?? gridlessStyledPlan(inputs, smart: smart, style: style)
    }

    /// A cut or an echo with no beat grid to lean on (unanalysed songs, a missing or unusable grid): it lands where the smart
    /// plan's fade would start, the incoming song at the smart plan's start, and an echo uses the fixed delay. nil when the
    /// smart plan has no fade start or the incoming song is too short.
    private static func gridlessStyledPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan, style: MusicTransitionStyle) -> TransitionPlan? {
        guard style == .quickCut || style == .echoOut, inputs.beatMixEnabled, inputs.crossfadeOn, smart.mode == .smart,
              !inputs.manualSkip, !inputs.albumInOrder, !inputs.loopSong,
              let aDuration = valid(inputs.outgoing.durationSeconds), let bDuration = valid(inputs.incoming.durationSeconds),
              let cut = smart.fadeStartSec, cut.isFinite, cut > 0, smart.incomingStartSec.isFinite, smart.incomingStartSec >= 0
        else { return nil }
        if let earliest = inputs.earliestMixOutSec, cut < earliest { return nil }
        let bEnd = inputs.incoming.analysis.flatMap { MusicTransitionPlanner.trimmedEnd(of: $0, duration: bDuration) } ?? bDuration
        guard bEnd - smart.incomingStartSec >= minIncomingRemainingSec else { return nil }
        let aEnd = smart.outgoingEndSec ?? aDuration
        var plan = smart
        plan.mode = .beat
        plan.reason = .ok
        plan.style = style
        plan.incomingRate = 1
        plan.mixOutSec = cut
        plan.mixInSec = smart.incomingStartSec
        plan.fallbackIncomingStartSec = smart.incomingStartSec
        plan.fadeStartSec = cut
        plan.fadeSeconds = cutFadeSeconds
        plan.overlapBars = 0
        plan.overlapSec = cutFadeSeconds
        plan.barSec = 0
        plan.glideBackSec = 0
        plan.bassSwapAtSec = nil
        plan.bassHandoverSec = 0
        if style == .echoOut {
            let delay = MusicEchoSettings.untrustedDelaySeconds
            let tail = min(min(delay * echoRepeats, maxEchoTailSec), max(0, aEnd - cut))
            plan.echoDelaySec = delay
            plan.echoTailSec = tail
            plan.outgoingEndSec = cut + tail
        } else {
            plan.outgoingEndSec = cut
        }
        return plan
    }

    private static func griddedStyledPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan, style: MusicTransitionStyle) -> TransitionPlan? {
        guard style == .quickCut || style == .echoOut, inputs.beatMixEnabled, inputs.crossfadeOn, smart.mode == .smart,
              !inputs.manualSkip, !inputs.albumInOrder, !inputs.loopSong,
              let aDuration = valid(inputs.outgoing.durationSeconds), let bDuration = valid(inputs.incoming.durationSeconds),
              let a = inputs.outgoing.analysis, let b = inputs.incoming.analysis,
              let aGrid = inputs.outgoing.grid ?? a.usableGrid, let bGrid = inputs.incoming.grid ?? b.usableGrid,
              usable(aGrid), usable(bGrid) else { return nil }
        let bothTrusted = trusted(aGrid) && trusted(bGrid)
        // A grid that failed the trust checks is only good enough when it still knows where the bar lines are.
        guard bothTrusted || (aGrid.downbeatPhase != nil && bGrid.downbeatPhase != nil) else { return nil }
        let aEnd = smart.outgoingEndSec ?? aDuration
        let barSec = 4 * aGrid.periodSec
        guard let mixOut = mixOutTime(grid: aGrid, analysis: a, bars: 1, barSec: barSec, end: aEnd, preferred: inputs.djMixOutSec),
              let mixIn = mixInTime(grid: bGrid, start: smart.incomingStartSec) else { return nil }
        if let earliest = inputs.earliestMixOutSec, mixOut < earliest { return nil }
        let bEnd = MusicTransitionPlanner.trimmedEnd(of: b, duration: bDuration) ?? bDuration
        guard bEnd - mixIn >= minIncomingRemainingSec else { return nil }

        var plan = smart
        plan.mode = .beat
        plan.reason = .ok
        plan.style = style
        plan.incomingRate = 1
        plan.mixOutSec = mixOut
        plan.mixInSec = mixIn
        plan.fallbackIncomingStartSec = smart.incomingStartSec
        plan.incomingStartSec = mixIn
        plan.fadeStartSec = mixOut
        plan.fadeSeconds = cutFadeSeconds
        plan.overlapBars = 0
        plan.overlapSec = cutFadeSeconds
        plan.barSec = barSec
        plan.glideBackSec = 0
        plan.bassSwapAtSec = nil
        plan.bassHandoverSec = 0
        if style == .echoOut {
            let delay = bothTrusted ? min(aGrid.periodSec, MusicEchoSettings.maxDelaySeconds) : MusicEchoSettings.untrustedDelaySeconds
            let tail = min(min(delay * echoRepeats, maxEchoTailSec), max(0, aEnd - mixOut))
            plan.echoDelaySec = delay
            plan.echoTailSec = tail
            plan.outgoingEndSec = mixOut + tail
        } else {
            plan.outgoingEndSec = mixOut
        }
        return plan
    }

    /// A grid whose numbers can be believed at all (the trust checks are stricter).
    private static func usable(_ grid: MusicBeatGrid) -> Bool {
        MusicBeatGrid.periodRange.contains(grid.periodSec)
            && [grid.anchorSec, grid.spanStartSec, grid.spanEndSec].allSatisfy { $0.isFinite && abs($0) <= maxGridSeconds }
    }

    // MARK: Pieces

    static func trusted(_ grid: MusicBeatGrid) -> Bool {
        MusicBeatGrid.periodRange.contains(grid.periodSec)
            && [grid.anchorSec, grid.spanStartSec, grid.spanEndSec].allSatisfy({ $0.isFinite && abs($0) <= maxGridSeconds })
            && grid.beatConfidence >= minConfidence && grid.intervalSpread <= maxIntervalSpread
            && abs(grid.driftSec) <= maxDriftSec
    }

    static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The latest outgoing boundary (a phrase boundary when the downbeat is known, falling back to 4 bar and 1 bar boundaries, else a bar's worth of beats from the
    /// grid anchor) where `bars` bars fit before `end`, inside the validated span and not before the outro start minus
    /// `outroSlackBars` bars.
    ///
    /// `preferred` (DJ-length songs) is a mix-out the caller wants instead: it is returned when `bars` bars still fit after it
    /// inside the span (the outro limit does not apply to it), and nil when they do not.
    static func mixOutTime(
        grid: MusicBeatGrid, analysis: MusicAnalysis, bars: Int, barSec: Double, end: Double, preferred: Double? = nil
    ) -> Double? {
        if let preferred {
            let room = min(end - Double(bars) * barSec, grid.spanEndSec + spanSlackBeats * grid.periodSec - Double(bars) * barSec)
            guard preferred.isFinite, preferred >= max(0, grid.spanStartSec) - 1e-9, preferred <= room + 1e-9 else { return nil }
            return preferred
        }
        let limit = end - Double(bars) * barSec
        let earliest = max(0, grid.spanStartSec, analysis.outroStart - Double(outroSlackBars) * barSec)
        guard limit.isFinite, earliest.isFinite, limit >= earliest else { return nil }
        // The whole overlap stays inside the validated span, give or take two beats.
        let latest = min(limit, grid.spanEndSec + spanSlackBeats * grid.periodSec - Double(bars) * barSec)
        guard latest >= earliest else { return nil }
        var candidate: Double?
        if let first = grid.barTime(0) {
            // The latest 8 bar phrase boundary that fits wins; when none lands in the window, the latest 4 bar one, then
            // the latest bar. A known downbeat must never leave less room than the no-downbeat branch below.
            for stepBars in [phraseBars, 4, 1] {
                let step = Double(stepBars) * barSec
                let count = Int(((latest - first) / step + 1e-9).rounded(.down))
                guard count >= 0 else { continue }
                let time = first + Double(count) * step
                if time >= earliest - 1e-9, time <= latest + 1e-9 { candidate = time; break }
            }
        } else {
            let index = Int(((latest - grid.anchorSec) / barSec + 1e-9).rounded(.down))
            candidate = grid.beatTime(4 * index)
        }
        guard let time = candidate, time >= earliest - 1e-9, time <= latest + 1e-9 else { return nil }
        return time
    }

    /// The first incoming bar boundary (any beat when the downbeat is unknown) at or after `start`.
    static func mixInTime(grid: MusicBeatGrid, start: Double) -> Double? {
        let from = max(start, grid.spanStartSec - spanSlackBeats * grid.periodSec)
        var k = grid.nextBeat(atOrAfter: from).index
        if let phase = grid.downbeatPhase { k += ((phase - k) % 4 + 4) % 4 }
        let time = grid.beatTime(k)
        return time.isFinite && time >= 0 ? time : nil
    }
}
