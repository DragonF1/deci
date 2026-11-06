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

    private static func fixed(_ value: Double, _ digits: Int) -> String {
        guard value.isFinite else { return "0" }
        let text = String(format: "%.\(digits)f", value)
        // Avoid "-0.0" for tiny negatives and negative zero.
        return text.hasPrefix("-") && Double(text) == 0 ? String(text.dropFirst()) : text
    }
}
