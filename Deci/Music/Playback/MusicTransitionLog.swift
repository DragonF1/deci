// Deci/Music/Playback/MusicTransitionLog.swift
// Tier 2b: the log line for a transition plan. Pure formatting, ids only (never URLs, titles or paths).

import Foundation
import os

enum MusicTransitionLog {
    static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicTransitions")

    /// transition_plan from=<id> to=<id> mode=smart fade=6.40 start=211.30 trimIn=0.42 trimOut=1.80
    /// gain=in:-3.1/glide:8/out:0.0 reason=ok
    static func planLine(
        from: String, to: String, plan: TransitionPlan, outgoingDuration: Double?,
        vocal: (outgoing: Bool, incoming: Bool)? = nil
    ) -> String {
        let start = plan.fadeStartSec.map { fixed($0, 2) } ?? "end"
        var trimOut = 0.0
        if let end = plan.outgoingEndSec, let duration = outgoingDuration, duration.isFinite {
            trimOut = max(0, duration - end)
        }
        let gain = "in:\(fixed(plan.incomingGainDb, 1))/glide:\(fixed(plan.incomingGlideSeconds, 0))/out:\(fixed(plan.outgoingGainDb, 1))"
        return "transition_plan from=\(from) to=\(to) mode=\(plan.mode.rawValue) fade=\(fixed(plan.fadeSeconds, 2))"
            + " start=\(start) trimIn=\(fixed(plan.incomingStartSec, 2)) trimOut=\(fixed(trimOut, 2))"
            + " gain=\(gain) reason=\(plan.reason.rawValue)" + vocalSuffix(vocal)
    }

    /// " vocal=lyrics/proxy": per side (outgoing/incoming), whether the guard measures singing from lyrics or the proxy.
    private static func vocalSuffix(_ vocal: (outgoing: Bool, incoming: Bool)?) -> String {
        guard let vocal else { return "" }
        return " vocal=\(vocal.outgoing ? "lyrics" : "proxy")/\(vocal.incoming ? "lyrics" : "proxy")"
    }

    /// transition_applied from=<id> to=<id> mode=smart fade=6.40 lead=13.30 skipped=4.00
    /// Engine side, at the hand-over. `lead` is how long before the outgoing item's end the overlap started, `skipped` the
    /// audible tail of the outgoing item that was never played (lead - fade).
    static func appliedLine(
        from: String, to: String, mode: TransitionPlan.Mode, fade: Double, lead: Double, skipped: Double
    ) -> String {
        "transition_applied from=\(from) to=\(to) mode=\(mode.rawValue) fade=\(fixed(fade, 2))"
            + " lead=\(fixed(lead, 2)) skipped=\(fixed(skipped, 2))"
    }

    /// transition_fallback from=<id> to=<id> mode=smart reason=late|noLease|prerollFailed|seekFailed
    /// A plan (or part of it) that could not run as planned. `mode` nil (no plan) prints "none".
    static func fallbackLine(from: String, to: String, mode: TransitionPlan.Mode?, reason: String) -> String {
        "transition_fallback from=\(from) to=\(to) mode=\(mode?.rawValue ?? "none") reason=\(reason)"
    }

    /// transition_replan mode=smart->fixed reason=crossfadeToggled
    static func replanLine(from: String, to: String, old: TransitionPlan.Mode?, new: TransitionPlan.Mode?, reason: String) -> String {
        "transition_replan from=\(from) to=\(to) mode=\(old?.rawValue ?? "none")->\(new?.rawValue ?? "none") reason=\(reason)"
    }

    /// transition_late from=<id> to=<id> reason=late
    /// A song's analysis landed after the transition was planned: nothing changes for that transition.
    static func lateLine(from: String, to: String, late: String) -> String {
        "transition_late from=\(from) to=\(to) song=\(late) reason=late"
    }

    /// transition_beat_plan from=<id> to=<id> bpmA=120.00 bpmB=126.00 rate=0.9524 bars=8 mixOut=123.40 mixIn=12.50
    /// swapAt=- handover=0.00 (service side, at the offer). `bpmA` is the playing song, `bpmB` the next one.
    static func beatPlanLine(from: String, to: String, plan: TransitionPlan, bpmA: Double?, bpmB: Double?) -> String {
        let swap = plan.bassSwapAtSec.map { fixed($0, 2) } ?? "-"
        return "transition_beat_plan from=\(from) to=\(to) bpmA=\(bpm(bpmA)) bpmB=\(bpm(bpmB))"
            + " rate=\(fixed(plan.incomingRate, 4)) bars=\(plan.overlapBars)"
            + " mixOut=\(fixed(plan.mixOutSec ?? 0, 2)) mixIn=\(fixed(plan.mixInSec ?? 0, 2))"
            + " swapAt=\(swap) handover=\(fixed(plan.bassHandoverSec, 2))"
    }

    /// transition_vocal_guard from=<id> to=<id> action=shorten before=6.20 after=0.00 fade=5.00
    /// The structural vocal guard changed a plan (or found nothing clean): nil when the guard left the plan alone.
    static func vocalGuardLine(from: String, to: String, plan: TransitionPlan) -> String? {
        guard let action = plan.vocalAction else { return nil }
        return "transition_vocal_guard from=\(from) to=\(to) action=\(action)"
            + " before=\(fixed(plan.vocalBeforeSec ?? 0, 2)) after=\(fixed(plan.vocalCollisionSec ?? 0, 2))"
            + " fade=\(fixed(plan.fadeSeconds, 2))"
    }

    /// transition_beat_fallback from=<id> to=<id> reason=tempoClash bpmA=120.00 bpmB=-
    /// A pair that is mixed the smart way though beat mixing was on: the planner's reason, or `notReady` when the next
    /// song was not parked in time. A bpm that is not known prints "-".
    /// `gridFail` (a gridLowConf refusal) adds which song failed which check: gridFail=out:spread=0.090>0.070;in:ok
    static func beatFallbackLine(
        from: String, to: String, reason: String, bpmA: Double?, bpmB: Double?, gridFail: String? = nil
    ) -> String {
        "transition_beat_fallback from=\(from) to=\(to) reason=\(reason) bpmA=\(bpm(bpmA)) bpmB=\(bpm(bpmB))"
            + (gridFail.map { " gridFail=\($0)" } ?? "")
    }

    /// transition_beat_applied from=<id> to=<id> rate=0.9524 calib=-7.0ms (engine side, at the flip)
    static func beatAppliedLine(from: String, to: String, rate: Double, calibrationSec: Double) -> String {
        "transition_beat_applied from=\(from) to=\(to) rate=\(fixed(rate, 4)) calib=\(fixed(calibrationSec * 1000, 1))ms"
    }

    enum GlideEvent: Equatable {
        case start
        case end
        case cancel(why: String)
    }

    /// transition_glide start rate=0.9524 over=10.0 | transition_glide end | transition_glide cancel why=seek rate=0.9810
    /// The incoming song's rate on its way back to 1 after a beat mix. `cancel` is a seek, a skip or an output change.
    static func glideLine(event: GlideEvent, rate: Double, seconds: Double) -> String {
        switch event {
        case .start: return "transition_glide start rate=\(fixed(rate, 4)) over=\(fixed(seconds, 1))"
        case .end: return "transition_glide end"
        case .cancel(let why): return "transition_glide cancel why=\(why) rate=\(fixed(rate, 4))"
        }
    }

    private static func bpm(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        return fixed(value, 2)
    }

    private static func fixed(_ value: Double, _ digits: Int) -> String {
        guard value.isFinite else { return "0" }
        let text = String(format: "%.\(digits)f", value)
        // Avoid "-0.0" for tiny negatives and negative zero.
        return text.hasPrefix("-") && Double(text) == 0 ? String(text.dropFirst()) : text
    }

    /// Tier 4b: which style a planned or applied transition used. Ids and plain words only.
    static func styleLine(from: String, to: String, style: MusicTransitionStyle, reason: String?, previous: MusicTransitionStyle?) -> String {
        "transition_style from=\(from) to=\(to) style=\(style.rawValue) reason=\(reason ?? "none") prev=\(previous?.rawValue ?? "none")"
    }

    /// Tier 4b P3: transition_dj from=<id> to=<id> section=chorus2 outAt=123.40. A DJ-length mix-out was planned at the
    /// outgoing song's second chorus end. Ids and numbers only.
    static func djLine(from: String, to: String, section: DJSection, outAt: Double) -> String {
        "transition_dj from=\(from) to=\(to) section=\(section.rawValue) outAt=\(fixed(outAt, 2))"
    }
}
