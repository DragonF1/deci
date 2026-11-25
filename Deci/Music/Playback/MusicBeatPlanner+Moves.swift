// Deci/Music/Playback/MusicBeatPlanner+Moves.swift
// The plans of the moves that go on top of a blend or a cut: the low-pass sweep, the echo throw, the loop roll, the tails of a cut
// (echo, reverb, brake) and the double drop. Pure, like every planner: what cannot be built is nil, and the next style has its turn.

import Foundation

extension MusicBeatPlanner {
    // MARK: Moves on a blend

    static let lowpassFromHz = 18_000.0
    static let lowpassToHz = 300.0
    /// Where in the overlap an echo throw takes the outgoing song away, before it goes to the nearest bar line.
    static let throwShare = 0.75
    /// A throw with fewer repeats than this is a mistake, not an effect.
    static let fewestThrowRepeats = 2.0
    /// A roll needs an overlap of at least this many bars.
    static let rollMinBars = 4

    /// The beat blend `beat` with a low-pass on the outgoing song: same timing, tempo and bass swap, and it goes dull and sinks. nil
    /// when `beat` is not a beat blend with an overlap.
    static func lowpassSweepPlan(from beat: TransitionPlan) -> TransitionPlan? {
        guard beat.mode == .beat, beat.style == .longBlend, beat.overlapSec >= 1 else { return nil }
        var plan = beat
        plan.style = .lowpassSweep
        plan.sweepHighpass = false
        plan.sweepFromHz = lowpassFromHz
        plan.sweepToHz = lowpassToHz
        return plan
    }

    /// The beat blend `beat`, whose outgoing song is taken away on a bar line near the end with its last beat echoing on. nil when the
    /// blend has no bars, a bar line for it comes before the new bass, or the song is over before it could echo.
    static func echoThrowPlan(from beat: TransitionPlan, _ inputs: MusicTransitionInputs, smart: TransitionPlan) -> TransitionPlan? {
        guard let blend = barred(beat, inputs) else { return nil }
        let bar = 4 * blend.beat
        guard blend.beat <= MusicEchoSettings.maxDelaySeconds,
              let at = nearestLine(to: beat.overlapSec * throwShare, unit: bar, length: beat.overlapSec),
              at > blend.line + 1e-6, let mixOut = beat.mixOutSec else { return nil }
        let rate = outgoingRate(inputs)
        guard let end = smart.outgoingEndSec ?? valid(inputs.outgoing.durationSeconds) else { return nil }
        let tail = min(blend.beat * echoRepeats, maxEchoTailSec, (end - mixOut) / rate - at)
        guard tail.isFinite, tail >= fewestThrowRepeats * blend.beat else { return nil }
        var plan = beat
        plan.style = .echoThrow
        plan.echoThrowAtSec = at
        plan.echoDelaySec = blend.beat
        plan.echoTailSec = tail
        // The deck has to play on for as long as the tail is heard.
        plan.outgoingEndSec = max(beat.outgoingEndSec ?? 0, mixOut + (at + tail) * rate)
        return plan
    }

    /// The beat blend `beat`, whose outgoing song rolls its way through the bar before the bass changes hands. nil when the blend
    /// has no bars or that bar is not inside it.
    static func loopRollPlan(from beat: TransitionPlan, _ inputs: MusicTransitionInputs) -> TransitionPlan? {
        guard let blend = barred(beat, inputs), beat.overlapBars >= rollMinBars, blend.beat <= MusicRollSettings.maxBeatSeconds else { return nil }
        let at = blend.line - Double(MusicRollSettings.beats) * blend.beat
        guard at >= blend.beat else { return nil }
        var plan = beat
        plan.style = .loopRoll
        plan.rollAtSec = at
        plan.rollBeatSec = blend.beat
        return plan
    }

    /// One beat of the outgoing song and the downbeat the bass lands on, in wall seconds of the blend. nil for anything but a
    /// beat-matched blend with a bass swap on a known downbeat.
    private static func barred(_ plan: TransitionPlan, _ inputs: MusicTransitionInputs) -> (beat: Double, line: Double)? {
        guard plan.mode == .beat, plan.style == .longBlend, plan.overlapBars > 0, let swap = plan.bassSwapAtSec,
              let grid = inputs.outgoing.grid ?? inputs.outgoing.analysis?.usableGrid, trusted(grid), grid.downbeatPhase != nil else { return nil }
        let beat = grid.periodSec / outgoingRate(inputs)
        let line = swap + plan.bassHandoverSec
        guard beat.isFinite, beat > 0, line.isFinite, line > 0, line < plan.overlapSec else { return nil }
        return (beat, line)
    }

    // MARK: Tails of a cut

    static let reverbTailSec = 2.5
    /// Less than this is no room, only a click.
    static let shortestReverbTailSec = 1.0
    static let shortestBrakeSec = 0.3
    /// How long a record takes to stop in a song whose beat is not known.
    static let nominalBrakeSec = 0.5

    /// How long before the cut's bar line a brake starts: a beat, so the song has stopped as the new one reaches its "1". Never
    /// more than the incoming song has before that.
    static func brakeLead(_ style: MusicTransitionStyle, beat: Double?, mixIn: Double) -> Double {
        style == .brake ? min(brakeLength(beat), max(0, mixIn)) : 0
    }

    static func brakeLength(_ beat: Double?) -> Double {
        min(max(beat ?? nominalBrakeSec, MusicBrakeSettings.minSeconds), MusicBrakeSettings.maxSeconds)
    }

    /// Fills in what the outgoing song does from `cut` on, and where its item ends. `beat` is one of its beats in wall seconds, when
    /// that is known. False when the song has too little left for it.
    static func applyTail(_ plan: inout TransitionPlan, style: MusicTransitionStyle, cut: Double, end: Double, rate: Double, beat: Double?) -> Bool {
        let left = max(0, (end - cut) / rate)
        guard left.isFinite else { return false }
        let tail: Double
        switch style {
        case .echoOut:
            plan.echoDelaySec = beat.map { min($0, MusicEchoSettings.maxDelaySeconds) } ?? MusicEchoSettings.untrustedDelaySeconds
            tail = min(plan.echoDelaySec * echoRepeats, maxEchoTailSec, left)
        case .reverbOut:
            tail = min(reverbTailSec, left)
            guard tail >= shortestReverbTailSec else { return false }
        case .brake:
            tail = min(brakeLength(beat), left)
            guard tail >= shortestBrakeSec else { return false }
        default:
            plan.outgoingEndSec = cut
            return true
        }
        plan.echoTailSec = tail
        plan.outgoingEndSec = cut + tail * rate
        return true
    }

    // MARK: Double drop

    /// Bars before and after the two drops: 8, or 4 where one of the songs has no 8 bars there.
    static let doubleDropBars = [8, 4]
    /// With a DJ exit the outgoing drop is one of those this many bars or fewer before it.
    static let doubleDropReachBars = 32

    /// Both songs' drops land on one downbeat in the middle of the overlap: the incoming song builds up under the outgoing build-up,
    /// they drop together, the bass changes hands on the drop and the outgoing song is gone a phrase later. nil when either grid
    /// is not trusted or has no downbeat, the tempos do not meet at the same bar length, either song has no drop it could land on, or
    /// there is no room around them.
    static func doubleDropPlan(_ inputs: MusicTransitionInputs, smart: TransitionPlan) -> TransitionPlan? {
        guard inputs.beatMixEnabled, inputs.crossfadeOn, inputs.bassSwapAvailable, smart.mode == .smart, smart.reason != .tooShort,
              !inputs.manualSkip, !inputs.albumInOrder, !inputs.loopSong, !inputs.cleanStartFlag, !inputs.cleanPairFlag,
              inputs.outgoing.videoId != inputs.incoming.videoId,
              let aDuration = valid(inputs.outgoing.durationSeconds), let bDuration = valid(inputs.incoming.durationSeconds),
              let a = inputs.outgoing.analysis, let b = inputs.incoming.analysis,
              let aGrid = inputs.outgoing.grid ?? a.usableGrid, let bGrid = inputs.incoming.grid ?? b.usableGrid,
              trusted(aGrid), trusted(bGrid), aGrid.downbeatPhase != nil, bGrid.downbeatPhase != nil,
              let tempo = tempoMatch(outBpm: aGrid.bpm * outgoingRate(inputs), inBpm: bGrid.bpm), tempo.multiple == 1,
              let drop = MusicDropDetector.best(in: b, grid: bGrid),
              let leaving = MusicDropDetector.drops(in: a, grid: aGrid) else { return nil }

        let rate = outgoingRate(inputs)
        let bar = 4 * aGrid.periodSec
        let aEnd = min(smart.outgoingEndSec ?? aDuration, aGrid.spanEndSec + spanSlackBeats * aGrid.periodSec)
        let bEnd = MusicTransitionPlanner.trimmedEnd(of: b, duration: bDuration) ?? bDuration
        // A song that came in late still plays for its minute.
        let entered = MusicDJEntry.pick(inputs.outgoing, start: 0)?.targetSec ?? 0
        let earliestOut = max(entered + MusicDJLength.minPlayedSec, inputs.earliestMixOutSec ?? 0, aGrid.spanStartSec)
        let earliestIn = max(0, smart.incomingStartSec, bGrid.spanStartSec - spanSlackBeats * bGrid.periodSec)

        for bars in doubleDropBars {
            let half = Double(bars) * bar
            let overlap = 2 * half / rate
            guard overlap <= maxOverlapSec,
                  let mixIn = unityStart(mixIn: drop.timeSec - overlap / 2 * tempo.rate, rate: tempo.rate, wallLength: overlap),
                  mixIn >= earliestIn - 1e-9, bEnd - (mixIn + overlap) >= minIncomingRemainingSec,
                  mixIn + overlap <= bGrid.spanEndSec + spanSlackBeats * bGrid.periodSec else { continue }
            // The latest drop that has room: a later one leaves more of the song played.
            for leave in leaving.reversed() where leave.confidence >= MusicDropDetector.confidenceFloor {
                let mixOut = leave.timeSec - half, end = leave.timeSec + half
                guard mixOut >= earliestOut - 1e-9, end <= aEnd + 1e-9 else { continue }
                if let exit = inputs.djMixOutSec {
                    guard end <= exit + 1e-6, exit - leave.timeSec <= Double(doubleDropReachBars) * bar + 1e-6 else { continue }
                } else {
                    guard mixOut >= a.outroStart - Double(outroSlackBars) * bar - 1e-9 else { continue }
                }
                if inputs.vocalGuardEnabled,
                   let collision = guardCollision(inputs, outStart: mixOut, inStart: mixIn, rate: 1, wallLength: overlap),
                   collision > MusicVocalGuard.budgetSec {
                    continue
                }
                var plan = smart
                plan.mode = .beat
                plan.reason = .ok
                plan.style = .doubleDrop
                plan.fallbackReason = nil
                plan.incomingRate = 1
                plan.mixOutSec = mixOut
                plan.mixInSec = mixIn
                plan.fallbackIncomingStartSec = smart.incomingStartSec
                plan.incomingStartSec = mixIn
                plan.fadeStartSec = mixOut
                plan.fadeSeconds = overlap
                plan.outgoingEndSec = end
                plan.overlapBars = 2 * bars
                plan.overlapSec = overlap
                plan.barSec = bar
                // One bassline at a time: the new one takes over on the drop itself.
                landBass(&plan, on: overlap / 2, beat: aGrid.periodSec / rate)
                return plan
            }
        }
        return nil
    }
}
