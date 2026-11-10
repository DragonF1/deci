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

    // MARK: - Tier 3b P3 beat lines

    private func beatPlan() -> TransitionPlan {
        var plan = TransitionPlan(
            mode: .beat, incomingStartSec: 12.5, outgoingEndSec: 139.4, fadeStartSec: 123.4, fadeSeconds: 16,
            incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok)
        plan.incomingRate = 0.952381
        plan.mixOutSec = 123.4
        plan.mixInSec = 12.5
        plan.overlapBars = 8
        plan.overlapSec = 16
        return plan
    }

    @Test func beatPlanLineGolden() {
        #expect(MusicTransitionLog.beatPlanLine(from: "aaaaaaaaaaa", to: "bbbbbbbbbbb", plan: beatPlan(), bpmA: 126, bpmB: 120)
            == "transition_beat_plan from=aaaaaaaaaaa to=bbbbbbbbbbb bpmA=126.00 bpmB=120.00 rate=0.9524 bars=8 mixOut=123.40 mixIn=12.50 swapAt=- handover=0.00")
        var swap = beatPlan()
        swap.bassSwapAtSec = 8
        swap.bassHandoverSec = 0.25
        let line = MusicTransitionLog.beatPlanLine(from: "a", to: "b", plan: swap, bpmA: nil, bpmB: .nan)
        #expect(line.contains("bpmA=- bpmB=-"))
        #expect(line.hasSuffix("swapAt=8.00 handover=0.25"))
        #expect(line == "transition_beat_plan from=a to=b bpmA=- bpmB=- rate=0.9524 bars=8 mixOut=123.40 mixIn=12.50 swapAt=8.00 handover=0.25")
    }

    @Test func beatFallbackLineCarriesGridFail() {
        let line = MusicTransitionLog.beatFallbackLine(
            from: "a", to: "b", reason: "gridLowConf", bpmA: 141.2, bpmB: 141.7, gridFail: "out:ok;in:spread=0.090>0.070")
        #expect(line == "transition_beat_fallback from=a to=b reason=gridLowConf bpmA=141.20 bpmB=141.70 gridFail=out:ok;in:spread=0.090>0.070")
    }

    @Test func beatFallbackLineGolden() {
        #expect(MusicTransitionLog.beatFallbackLine(from: "a", to: "b", reason: "tempoClash", bpmA: 120, bpmB: nil)
            == "transition_beat_fallback from=a to=b reason=tempoClash bpmA=120.00 bpmB=-")
    }

    @Test func beatAppliedLineGolden() {
        #expect(MusicTransitionLog.beatAppliedLine(from: "a", to: "b", rate: 0.952381, calibrationSec: -0.007)
            == "transition_beat_applied from=a to=b rate=0.9524 calib=-7.0ms")
    }

    @Test func beatLinesCarryNoUrlsAndNoDashes() {
        let lines = [
            MusicTransitionLog.beatPlanLine(from: "a", to: "b", plan: beatPlan(), bpmA: 120, bpmB: 126),
            MusicTransitionLog.beatFallbackLine(from: "a", to: "b", reason: "notReady", bpmA: 120, bpmB: 126),
            MusicTransitionLog.beatAppliedLine(from: "a", to: "b", rate: 1.04, calibrationSec: -0.007),
        ]
        for line in lines {
            #expect(!line.contains("http"))
            #expect(!line.contains("\u{2014}"))
            #expect(!line.contains("nan"))
        }
    }

    @Test func loggerExists() {
        _ = MusicTransitionLog.logger
    }
}
