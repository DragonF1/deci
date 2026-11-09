// Deci/Music/Playback/MusicBeatPlanner+Loop.swift
// Tier 4b P2b: the loop-extend plan. A beat blend whose incoming intro is shorter than the overlap would have two singers
// together (the vocal guard shortens it or refuses it). Instead the incoming intro is looped: 4 or 8 bars of it play again
// until the overlap fits inside it, and the song goes on from where the loop ended. Pure, like the rest of the planner.

import Foundation

extension MusicBeatPlanner {
    /// Repeats a plan may ask for (each is one more pass of the loop).
    static let maxPlannedRepeats = 3
    static let loopBarChoices = [8, 4]

    #if DEBUG
    /// Live checks only: a loop is planned for any pair that could beat-mix (4 bars, 1 repeat) even when its intro is long
    /// enough, so the real engine can be played through a loop on real songs. Never set outside the test target.
    nonisolated(unsafe) static var debugForceLoop = false
    #endif

    /// A sung line of the incoming song inside [start, end]: a loop must never repeat one (the guard maps each line once).
    static func loopSings(_ intervals: [ClosedRange<Double>]?, from start: Double, to end: Double) -> Bool {
        (intervals ?? []).contains { $0.lowerBound < end && $0.upperBound > start }
    }

    /// The beat blend with the incoming intro looped, or nil when the pair does not need it or cannot take it: the incoming
    /// song is not a local file, a grid is not trusted or has no downbeat, the tempos meet only at half or double time,
    /// the intro has fewer than 4 bars, or no repeat count makes the overlap clean. `smart` is the tier 2 plan.
    static func loopExtendPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan) -> TransitionPlan? {
        #if DEBUG
        let forced = debugForceLoop
        #else
        let forced = false
        #endif
        guard inputs.incomingLocal, inputs.vocalGuardEnabled || forced, inputs.beatMixEnabled, inputs.crossfadeOn,
              smart.mode == .smart, !inputs.manualSkip, !inputs.albumInOrder, !inputs.loopSong,
              !inputs.cleanStartFlag, !inputs.cleanPairFlag, inputs.outgoing.videoId != inputs.incoming.videoId,
              let bDuration = valid(inputs.incoming.durationSeconds),
              let a = inputs.outgoing.analysis, let b = inputs.incoming.analysis,
              let aGrid = inputs.outgoing.grid ?? a.usableGrid, let bGrid = inputs.incoming.grid ?? b.usableGrid,
              trusted(aGrid), trusted(bGrid), aGrid.downbeatPhase != nil, bGrid.downbeatPhase != nil,
              let tempo = tempoMatch(outBpm: aGrid.bpm, inBpm: bGrid.bpm), tempo.multiple == 1,
              b.introEnd.isFinite else { return nil }
        // The blend as it would be with no vocal guard: the overlap the intro has to cover.
        var open = inputs
        open.vocalGuardEnabled = false
        let base = MusicBeatPlanner.plan(open, smart: smart)
        guard base.mode == .beat, base.style == .longBlend, base.overlapSec > 0, let mixIn = base.mixInSec,
              let mixOut = base.mixOutSec else { return nil }
        let rate = base.incomingRate
        let consumed = base.overlapSec * rate
        let collisionBefore = MusicVocalGuard.collisionSec(
            outgoing: a, incoming: b, outStart: mixOut, inStart: mixIn, rate: rate, length: base.overlapSec,
            outgoingIntervals: inputs.outgoing.vocalIntervals, incomingIntervals: inputs.incoming.vocalIntervals
        )
        // Only an intro that is too short for the overlap needs a loop; a clean pair keeps its plain blend.
        if forced {
            let barIn = 4 * bGrid.periodSec
            let spec = MusicLoopExtend.Spec(loopStart: mixIn, loopLength: 4 * barIn, repeats: 1)
            guard spec.isValid, spec.loopEnd <= b.introEnd + 1e-9, spec.loopEnd < bDuration - minIncomingRemainingSec,
                  !loopSings(inputs.incoming.vocalIntervals, from: spec.loopStart, to: spec.loopEnd) else { return nil }
            var out = base
            out.style = .loopExtend
            out.loopStartSec = spec.loopStart
            out.loopBars = 4
            out.loopLengthSec = spec.loopLength
            out.loopRepeats = 1
            out.vocalAction = "loop"
            return out
        }
        guard let before = collisionBefore, before > MusicVocalGuard.budgetSec else { return nil }

        let barIn = 4 * bGrid.periodSec
        let introBars = Int(((b.introEnd - mixIn) / barIn + 1e-9).rounded(.down))
        guard let bars = loopBarChoices.first(where: { introBars >= $0 }) else { return nil }
        let length = MusicLoopExtend.snap(Double(bars) * barIn)
        let bEnd = MusicTransitionPlanner.trimmedEnd(of: b, duration: bDuration) ?? bDuration
        for repeats in 1...maxPlannedRepeats {
            let spec = MusicLoopExtend.Spec(loopStart: mixIn, loopLength: length, repeats: repeats)
            guard spec.isValid, spec.loopEnd <= b.introEnd + 1e-9, spec.loopEnd < bDuration,
                  !loopSings(inputs.incoming.vocalIntervals, from: spec.loopStart, to: spec.loopEnd) else { return nil }
            let map = MusicLoopMap(spec)
            // The song after the overlap still has its 20 seconds (the repeats count as song that is already gone).
            guard bEnd - (mixIn + consumed - spec.extensionSec) >= minIncomingRemainingSec else { continue }
            let collision = MusicVocalGuard.collisionSec(
                outgoing: a, incoming: b, outStart: mixOut, inStart: mixIn, rate: rate, length: base.overlapSec,
                outgoingIntervals: inputs.outgoing.vocalIntervals, incomingIntervals: inputs.incoming.vocalIntervals,
                incomingLoop: map
            )
            guard let c = collision, c <= MusicVocalGuard.budgetSec else { continue }
            var out = base
            out.style = .loopExtend
            out.loopStartSec = spec.loopStart
            out.loopBars = bars
            out.loopLengthSec = spec.loopLength
            out.loopRepeats = repeats
            out.vocalAction = "loop"
            out.vocalBeforeSec = before
            out.vocalCollisionSec = c
            return out
        }
        return nil
    }
}
