// Deci/Music/Playback/MusicTransitionPlanner.swift
// Tier 2b: the pure transition planner. One plan per song-to-song transition, built once at preload
// time from the analyses of both songs. Foundation only, no I/O, nonisolated value types.

import Foundation

struct TransitionPlan: Equatable, Sendable {
    enum Mode: String, Sendable { case smart, fixed, gapless, clean, beat }
    enum Reason: String, Sendable {
        case ok, noAnalysis, partialAnalysis, albumInOrder, loopSong, noDuration, noMix, off, tooShort, late
    }

    var mode: Mode
    /// Item time the incoming deck is parked at before preroll. 0 = untouched.
    var incomingStartSec: Double
    /// Item time the outgoing item ends at. nil = its natural end (stream duration).
    var outgoingEndSec: Double?
    /// Item time on the outgoing item where the overlap starts. nil = the engine anchors it at end - fade.
    var fadeStartSec: Double?
    /// 0 for .gapless and .clean.
    var fadeSeconds: Double
    /// <= 0 dB, applied to the incoming at the overlap start; 0 = none.
    var incomingGainDb: Double
    /// Seconds of the glide back to 0 dB, run from finishDrain. 8 when incomingGainDb < 0.
    var incomingGlideSeconds: Double
    /// <= 0 dB, ramped onto the outgoing over outgoingRampSeconds from the overlap start.
    var outgoingGainDb: Double
    var outgoingRampSeconds: Double
    var reason: Reason

    // Tier 3b (beat mix). All defaulted, so every plan built before 3b means what it meant.
    /// Playback rate of the incoming deck during the overlap (pitch kept); 1 outside beat mode.
    var incomingRate: Double = 1
    /// Outgoing item time where the overlap starts (beat mode).
    var mixOutSec: Double? = nil
    /// Incoming item time that lands on `mixOutSec` (beat mode).
    var mixInSec: Double? = nil
    var overlapBars: Int = 0
    var overlapSec: Double = 0
    /// One outgoing bar (4 beats) in seconds.
    var barSec: Double = 0
    /// Offset from the overlap start where the bass hands over; nil when there is no swap.
    var bassSwapAtSec: Double? = nil
    var bassHandoverSec: Double = 0
    /// Seconds the incoming rate takes to glide back to 1 after the outgoing song has gone.
    var glideBackSec: Double = 0
    /// Why beat mode was refused, when it was (a `MusicBeatPlanner.Fallback` raw value).
    var fallbackReason: String? = nil

    /// Exactly the behaviour of tier 1 without a crossfade: no trims, no fade, no gains.
    static let tier1Gapless = TransitionPlan(
        mode: .gapless, incomingStartSec: 0, outgoingEndSec: nil, fadeStartSec: nil, fadeSeconds: 0,
        incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .off
    )
}

struct MusicTransitionSide: Equatable, Sendable {
    var videoId: String
    /// Exact stream duration (never the AVPlayerItem's).
    var durationSeconds: Double?
    /// Already filtered by isFresh; nil = missing or stale.
    var analysis: MusicAnalysis?
    var youtubeLoudnessDb: Double?
    /// The beat grid, when known. Without it the planner reads `analysis.usableGrid` (version 2 rows only).
    var grid: MusicBeatGrid? = nil
}

struct MusicTransitionInputs: Equatable, Sendable {
    var outgoing: MusicTransitionSide
    var incoming: MusicTransitionSide
    var crossfadeOn: Bool
    /// 1...12, the tier 1 fallback length.
    var settingSeconds: Double
    var albumInOrder: Bool
    var loopSong: Bool
    /// Incoming song flagged "always start clean".
    var cleanStartFlag: Bool
    /// The pair outgoing -> incoming flagged.
    var cleanPairFlag: Bool
    /// Quick fade (fadeSeconds 0.3, mode .fixed).
    var manualSkip: Bool
    /// Tier 3b: false keeps the plan exactly the tier 2 plan (the app passes false until the engine can mix on beats).
    var beatMixEnabled: Bool = true
    /// True once the bass swap exists: only then may an overlap be 16 bars.
    var bassSwapAvailable: Bool = false
    static let skipFadeSeconds = 0.3

    init(
        outgoing: MusicTransitionSide, incoming: MusicTransitionSide, crossfadeOn: Bool,
        settingSeconds: Double, albumInOrder: Bool = false, loopSong: Bool = false,
        cleanStartFlag: Bool = false, cleanPairFlag: Bool = false, manualSkip: Bool = false,
        beatMixEnabled: Bool = true, bassSwapAvailable: Bool = false
    ) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.crossfadeOn = crossfadeOn
        self.settingSeconds = settingSeconds
        self.albumInOrder = albumInOrder
        self.loopSong = loopSong
        self.cleanStartFlag = cleanStartFlag
        self.cleanPairFlag = cleanPairFlag
        self.manualSkip = manualSkip
        self.beatMixEnabled = beatMixEnabled
        self.bassSwapAvailable = bassSwapAvailable
    }
}

enum MusicTransitionPlanner {
    static let minTrim = 0.25, maxTrimIn = 15.0, minSpan = 10.0
    static let minFade = 2.0, maxFade = 12.0, skipCap = 10.0
    static let loudnessClampDb = 6.0, loudnessDeadbandDb = 1.0, glideSeconds = 8.0
    /// maxFade + skipCap, used for the preload window.
    static let maxLead = 22.0

    // MARK: Plan

    /// The tier 2 plan, upgraded to a beat mix when `MusicBeatPlanner` finds one. A refusal because a song has no grid
    /// at all leaves the plan untouched (that is every song until 3b is on); any other refusal keeps the smart plan and
    /// records `fallbackReason`.
    static func plan(_ inputs: MusicTransitionInputs) -> TransitionPlan {
        let base = smartPlan(inputs)
        guard inputs.beatMixEnabled, base.mode == .smart else { return base }
        let beat = MusicBeatPlanner.plan(inputs, smart: base)
        if beat.mode == .beat || beat.fallbackReason != MusicBeatPlanner.Fallback.gridMissing.rawValue { return beat }
        return base
    }

    /// The tier 2 plan alone.
    static func smartPlan(_ inputs: MusicTransitionInputs) -> TransitionPlan {
        func tier1(_ reason: TransitionPlan.Reason) -> TransitionPlan {
            var plan = TransitionPlan.tier1Gapless
            plan.reason = reason
            return plan
        }
        if inputs.albumInOrder { return tier1(.albumInOrder) }
        if inputs.loopSong || inputs.outgoing.videoId == inputs.incoming.videoId { return tier1(.loopSong) }
        guard let aDuration = validDuration(inputs.outgoing.durationSeconds),
              let bDuration = validDuration(inputs.incoming.durationSeconds) else { return tier1(.noDuration) }

        let aAnalysis = inputs.outgoing.analysis.flatMap { usable($0) ? $0 : nil }
        let bAnalysis = inputs.incoming.analysis.flatMap { usable($0) ? $0 : nil }
        let incomingStart = bAnalysis.map { trimIn($0, duration: bDuration) } ?? 0
        let outgoingEnd = aAnalysis.flatMap { trimOut($0, duration: aDuration) }
        let aEnd = outgoingEnd ?? aDuration
        let bSpan = bDuration - incomingStart

        var plan = TransitionPlan.tier1Gapless
        plan.incomingStartSec = incomingStart
        plan.outgoingEndSec = outgoingEnd

        if inputs.manualSkip {
            plan.mode = .fixed
            plan.outgoingEndSec = nil
            plan.fadeSeconds = MusicTransitionInputs.skipFadeSeconds
            plan.reason = .ok
            if let d = offsetDb(outgoing: inputs.outgoing, incoming: inputs.incoming), d > 0 {
                plan.incomingGainDb = -d
                plan.incomingGlideSeconds = glideSeconds
            }
            return plan
        }
        if inputs.cleanStartFlag || inputs.cleanPairFlag {
            plan.mode = .clean
            plan.reason = .noMix
            return plan
        }
        guard inputs.crossfadeOn else {
            plan.reason = .off
            return plan
        }
        guard inputs.settingSeconds.isFinite else {
            plan.reason = .off
            return plan
        }

        func tooShort() -> TransitionPlan {
            plan.mode = .gapless
            plan.fadeSeconds = 0
            plan.fadeStartSec = nil
            plan.reason = .tooShort
            return plan
        }

        if let a = aAnalysis, let b = bAnalysis {
            let outroLen = max(0, aEnd - a.outroStart)
            let introLen = max(0, b.introEnd - b.silenceStart)
            let fade0 = min(max(min(outroLen, introLen), minFade), maxFade)
            let fade = min(fade0, aEnd / 2, bSpan / 2)
            guard fade >= 1 else { return tooShort() }
            var fadeStart = max(a.outroStart, aEnd - fade - skipCap)
            fadeStart = min(fadeStart, aEnd - fade)
            fadeStart = max(fadeStart, 0)
            plan.mode = .smart
            plan.fadeSeconds = fade
            plan.fadeStartSec = fadeStart
            plan.reason = .ok
            if let d = offsetDb(outgoing: inputs.outgoing, incoming: inputs.incoming) {
                if d > 0 {
                    plan.incomingGainDb = -d
                    plan.incomingGlideSeconds = glideSeconds
                } else if d < 0 {
                    plan.outgoingGainDb = d
                    plan.outgoingRampSeconds = min(2, fade / 3)
                }
            }
            return plan
        }

        let fade = min(inputs.settingSeconds, aEnd / 2, bSpan / 2)
        guard fade >= 1 else { return tooShort() }
        plan.mode = .fixed
        plan.fadeSeconds = fade
        plan.reason = (aAnalysis == nil && bAnalysis == nil) ? .noAnalysis : .partialAnalysis
        return plan
    }

    // MARK: Freshness

    /// The row's beat grid when the row is version 2 or newer and the grid decodes; nil otherwise (tier 3b).
    static func usableGrid(_ analysis: MusicAnalysis) -> MusicBeatGrid? { analysis.usableGrid }

    /// True when the row describes exactly the audio of `stream` and is usable for planning.
    static func isFresh(_ analysis: MusicAnalysis, for stream: ResolvedStream) -> Bool {
        guard analysis.version >= 1, analysis.version <= MusicAnalysis.currentVersion,
              analysis.videoId == stream.videoId,
              let duration = validDuration(stream.durationSeconds) else { return false }
        let format = MusicAnalysis.Format(
            codec: stream.audioCodec ?? "", itag: stream.itag, durationMs: Int((duration * 1000).rounded())
        )
        guard analysis.format.matches(format), usable(analysis), !analysis.integratedLUFS.isNaN,
              analysis.integratedLUFS < .infinity else { return false }
        guard analysis.silenceEnd - analysis.silenceStart >= minSpan else { return false }
        let allSilent = !analysis.integratedLUFS.isFinite && analysis.silenceStart == 0
            && abs(analysis.silenceEnd - duration) <= 0.001
        return !allSilent
    }

    /// The item time the outgoing song ends at when its dead air is trimmed (the plan's `outgoingEndSec`); nil when it
    /// plays to its natural end. The service uses it to measure the preload window to the audible end.
    static func trimmedEnd(of analysis: MusicAnalysis, duration: Double) -> Double? {
        guard let duration = validDuration(duration), usable(analysis) else { return nil }
        return trimOut(analysis, duration: duration)
    }

    /// The item time the incoming song starts at when its leading silence is trimmed; nil when it plays from its start. The
    /// Song data panel shows it next to `trimmedEnd`.
    static func trimmedStart(of analysis: MusicAnalysis, duration: Double) -> Double? {
        guard let duration = validDuration(duration), usable(analysis) else { return nil }
        let value = trimIn(analysis, duration: duration)
        return value > 0 ? value : nil
    }

    // MARK: Loudness

    /// dB the incoming sits above (+) or below (-) the outgoing, clamped to +-6. nil when the sources
    /// do not match or the gap is inside the 1 dB deadband.
    static func offsetDb(outgoing: MusicTransitionSide, incoming: MusicTransitionSide) -> Double? {
        let d: Double
        if let a = finiteLUFS(outgoing), let b = finiteLUFS(incoming) {
            d = b - a
        } else if let a = youtube(outgoing), let b = youtube(incoming) {
            d = b - a
        } else {
            return nil
        }
        guard d.isFinite, abs(d) >= loudnessDeadbandDb else { return nil }
        return min(max(d, -loudnessClampDb), loudnessClampDb)
    }

    // MARK: Helpers

    private static func finiteLUFS(_ side: MusicTransitionSide) -> Double? {
        guard let value = side.analysis?.integratedLUFS, value.isFinite else { return nil }
        return value
    }

    private static func youtube(_ side: MusicTransitionSide) -> Double? {
        guard let value = side.youtubeLoudnessDb ?? side.analysis?.youtubeLoudnessDb, value.isFinite else { return nil }
        return value
    }

    private static func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func usable(_ a: MusicAnalysis) -> Bool {
        [a.silenceStart, a.silenceEnd, a.introEnd, a.outroStart].allSatisfy(\.isFinite)
            && a.silenceStart >= 0 && a.silenceStart < a.silenceEnd
    }

    private static func trimIn(_ a: MusicAnalysis, duration: Double) -> Double {
        let value = min(a.silenceStart, maxTrimIn)
        guard value >= minTrim, value < duration else { return 0 }
        return value
    }

    private static func trimOut(_ a: MusicAnalysis, duration: Double) -> Double? {
        let end = min(a.silenceEnd, duration)
        guard duration - end >= minTrim, end >= 0.5 * duration else { return nil }
        return end
    }
}
