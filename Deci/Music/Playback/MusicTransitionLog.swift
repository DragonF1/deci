// Deci/Music/Playback/MusicTransitionLog.swift
// Tier 2b: the log line for a transition plan. Pure formatting, ids only (never URLs, titles or paths).

import Foundation
import os

enum MusicTransitionLog {
    static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicTransitions")

    /// transition_plan from=<id> to=<id> mode=smart fade=6.40 start=211.30 trimIn=0.42 trimOut=1.80
    /// gain=in:-3.1/glide:8/out:0.0 reason=ok
    static func planLine(from: String, to: String, plan: TransitionPlan, outgoingDuration: Double?) -> String {
        let start = plan.fadeStartSec.map { fixed($0, 2) } ?? "end"
        var trimOut = 0.0
        if let end = plan.outgoingEndSec, let duration = outgoingDuration, duration.isFinite {
            trimOut = max(0, duration - end)
        }
        let gain = "in:\(fixed(plan.incomingGainDb, 1))/glide:\(fixed(plan.incomingGlideSeconds, 0))/out:\(fixed(plan.outgoingGainDb, 1))"
        return "transition_plan from=\(from) to=\(to) mode=\(plan.mode.rawValue) fade=\(fixed(plan.fadeSeconds, 2))"
            + " start=\(start) trimIn=\(fixed(plan.incomingStartSec, 2)) trimOut=\(fixed(trimOut, 2))"
            + " gain=\(gain) reason=\(plan.reason.rawValue)"
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

    private static func fixed(_ value: Double, _ digits: Int) -> String {
        guard value.isFinite else { return "0" }
        let text = String(format: "%.\(digits)f", value)
        // Avoid "-0.0" for tiny negatives and negative zero.
        return text.hasPrefix("-") && Double(text) == 0 ? String(text.dropFirst()) : text
    }
}
