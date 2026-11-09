// DeciTests/Music/MusicPlainFadeTests.swift
// Crossfade without Mix is a plain equal-power fade of the Settings length at the song's real end (or its trailing digital
// silence): no beat plan, no style, no smart start from the outro, no vocal guard. Beat mix and the styles apply in Mix only.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Plain fade (Crossfade without Mix)")
struct MusicPlainFadeTests {
    private typealias B = MusicBeatPlannerTests

    private func inputs(
        bPeriod: Double = 0.4, aEnd: Double = 236, duration: Double = 240, plain: Bool
    ) -> MusicTransitionInputs {
        var i = B.inputs(
            a: B.grid(period: 0.5), b: B.grid(period: bPeriod, anchor: 0.1, phase: 1, span: 0.1...236),
            aDuration: duration, aEnd: aEnd
        )
        i.beatMixEnabled = true
        i.bassSwapAvailable = true
        i.vocalGuardEnabled = true
        i.plainFade = plain
        return i
    }

    @Test("trusted grids and a tempo clash still plan a plain fade at the trimmed end, at rate 1, with no style")
    func plainFadeWithClash() {
        let plan = MusicTransitionPlanner.plan(inputs(plain: true))
        #expect(plan.mode == .fixed)
        #expect(plan.fadeSeconds == 6)
        #expect(plan.fadeStartSec == nil, "no early start from the outro")
        #expect(plan.outgoingEndSec == 236, "trailing silence trim kept")
        #expect(plan.incomingRate == 1)
        #expect(plan.style == .longBlend)
        #expect(plan.mixOutSec == nil && plan.mixInSec == nil && plan.bassSwapAtSec == nil)
        #expect(plan.vocalAction == nil)
    }

    @Test("trusted grids with matching tempo are a plain fade too when Mix is off")
    func plainFadeWithMatch() {
        let plan = MusicTransitionPlanner.plan(inputs(bPeriod: 0.48, plain: true))
        #expect(plan.mode == .fixed)
        #expect(plan.incomingRate == 1)
        #expect(plan.style == .longBlend)
    }

    @Test("the same pair in Mix still plans a beat mix, and a clash gets a style")
    func mixKeepsBeatPlans() {
        let match = MusicTransitionPlanner.plan(inputs(bPeriod: 0.48, plain: false))
        #expect(match.mode == .beat)
        let clash = MusicTransitionPlanner.plan(inputs(plain: false))
        #expect(clash.mode == .beat || clash.mode == .smart)
        #expect(clash.fadeStartSec != nil)
    }

    @Test("with no trailing silence the fade ends at the real end")
    func realEnd() {
        let plan = MusicTransitionPlanner.plan(inputs(aEnd: 240, plain: true))
        #expect(plan.outgoingEndSec == nil)
        #expect(plan.fadeSeconds == 6)
    }

    @Test("the setting's length is held to half of a short song")
    func shortSongClamp() {
        var i = inputs(duration: 8, plain: true)
        i.outgoing.analysis = nil
        i.settingSeconds = 12
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.fadeSeconds == 4)
        #expect(plan.mode == .fixed)
    }

    @Test("the loudness match stays")
    func loudnessMatch() {
        var i = inputs(plain: true)
        i.outgoing.analysis?.integratedLUFS = -8
        i.incoming.analysis?.integratedLUFS = -14
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.incomingRate == 1)
        #expect(plan.incomingGainDb != 0 || plan.outgoingGainDb != 0)
    }

    @Test("a manual skip is still the 0.3 s quick fade")
    func manualSkip() {
        var i = inputs(plain: true)
        i.manualSkip = true
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.fadeSeconds == MusicTransitionInputs.skipFadeSeconds)
        #expect(plan.mode == .fixed)
    }

    // MARK: Service

    @Test("Beat mix is off whatever the setting says when Mix is off, and on in Mix")
    func beatMixNeedsMix() {
        let off = BeatHarness(beatMix: true, mix: false)
        #expect(!off.service.isBeatMixOn)
        let on = BeatHarness(beatMix: true, mix: true)
        #expect(on.service.isBeatMixOn)
        let mixNoBeat = BeatHarness(beatMix: false, mix: true)
        #expect(!mixNoBeat.service.isBeatMixOn)
    }

    @Test("Crossfade on with Mix off: the engine is offered a plain fade, never a beat plan or a style")
    func serviceOffersPlainFade() async throws {
        let h = BeatHarness(crossfade: true, beatMix: true, mix: false)
        await h.reader.set(BeatHarness.row("a", period: 0.5))
        await h.reader.set(BeatHarness.row("b", period: 0.48))
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(220)
        let plan = try #require(h.lastPlan, "lines: \(h.service.transitionLines)")
        #expect(plan.mode == .fixed, "plan: \(plan)")
        #expect(plan.style == .longBlend)
        #expect(plan.incomingRate == 1)
        #expect(plan.fadeStartSec == nil)
        #expect(plan.fadeSeconds == 6)
        #expect(!h.service.transitionLines.contains { $0.hasPrefix("transition_beat") })
    }

    @Test("the plain fade's preload window is the ordinary one, not the smart 37 s")
    func plainWindow() async {
        let h = BeatHarness(crossfade: true, beatMix: true, mix: false)
        await h.reader.set(BeatHarness.row("a", period: 0.5))
        await h.reader.set(BeatHarness.row("b", period: 0.48))
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(180)
        #expect(h.engine.preloads.isEmpty, "236 - 180 = 56 s left: outside the ordinary window")
    }
}
