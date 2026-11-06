// DeciTests/Music/MusicTransitionLogTests.swift
// Tier 2b P1: golden strings for the transition plan log line.

import Foundation
import Testing
@testable import Deci

@Suite("MusicTransitionLog")
struct MusicTransitionLogTests {
    @Test func smartLineGolden() {
        let plan = TransitionPlan(
            mode: .smart, incomingStartSec: 0.42, outgoingEndSec: 198.2, fadeStartSec: 211.3, fadeSeconds: 6.4,
            incomingGainDb: -3.1, incomingGlideSeconds: 8, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok)
        #expect(MusicTransitionLog.planLine(from: "aaaaaaaaaaa", to: "bbbbbbbbbbb", plan: plan, outgoingDuration: 200)
            == "transition_plan from=aaaaaaaaaaa to=bbbbbbbbbbb mode=smart fade=6.40 start=211.30 trimIn=0.42 trimOut=1.80 gain=in:-3.1/glide:8/out:0.0 reason=ok")
    }

    @Test func tierOneLineGolden() {
        var plan = TransitionPlan.tier1Gapless
        plan.reason = .albumInOrder
        #expect(MusicTransitionLog.planLine(from: "a", to: "b", plan: plan, outgoingDuration: nil)
            == "transition_plan from=a to=b mode=gapless fade=0.00 start=end trimIn=0.00 trimOut=0.00 gain=in:0.0/glide:0/out:0.0 reason=albumInOrder")
    }

    @Test func outgoingGainAndFixedStartPrintsEnd() {
        var plan = TransitionPlan.tier1Gapless
        plan.mode = .fixed; plan.fadeSeconds = 5; plan.outgoingGainDb = -2.55; plan.reason = .partialAnalysis
        let line = MusicTransitionLog.planLine(from: "a", to: "b", plan: plan, outgoingDuration: 200)
        #expect(line.contains("start=end"))
        #expect(line.contains("out:-2.5") || line.contains("out:-2.6"))
        #expect(line.hasSuffix("reason=partialAnalysis"))
    }

    @Test func trimOutIsZeroWithoutDurationOrEnd() {
        var plan = TransitionPlan.tier1Gapless
        plan.outgoingEndSec = 190
        #expect(MusicTransitionLog.planLine(from: "a", to: "b", plan: plan, outgoingDuration: nil).contains("trimOut=0.00"))
        plan.outgoingEndSec = nil
        #expect(MusicTransitionLog.planLine(from: "a", to: "b", plan: plan, outgoingDuration: 200).contains("trimOut=0.00"))
    }

    @Test func negativeZeroAndNonFiniteNeverPrintMinus() {
        var plan = TransitionPlan.tier1Gapless
        plan.incomingGainDb = -0.0
        plan.outgoingGainDb = -0.04
        plan.fadeSeconds = .nan
        let line = MusicTransitionLog.planLine(from: "a", to: "b", plan: plan, outgoingDuration: 200)
        #expect(line.contains("gain=in:0.0/glide:0/out:0.0"))
        #expect(line.contains("fade=0 "))
        #expect(!line.contains("-0"))
    }

    @Test func lineCarriesNoUrlsOrSpaces() {
        let line = MusicTransitionLog.planLine(from: "aaaaaaaaaaa", to: "bbbbbbbbbbb", plan: .tier1Gapless, outgoingDuration: 1)
        #expect(!line.contains("http"))
        #expect(line.split(separator: " ").count == 10)
    }

    @Test func loggerExists() {
        _ = MusicTransitionLog.logger
    }
}
