// DeciTests/Music/AVPlaybackEngineStyleTests.swift
// Tier 4b P1: the engine accepts a cut and an echo where a one second fade floor would have refused them.

import Foundation
import Testing
@testable import Deci

@Suite("AVPlaybackEngineStyle")
struct AVPlaybackEngineStyleTests {
    @Test("a cut or an echo accepts a fade far under the one second floor of a blend")
    func minimumFade() {
        #expect(AVPlaybackEngine.minimumFade(for: nil) == 1)
        #expect(AVPlaybackEngine.minimumFade(for: .longBlend) == 1)
        #expect(AVPlaybackEngine.minimumFade(for: .quickCut) < 0.05)
        #expect(AVPlaybackEngine.minimumFade(for: .echoOut) < 0.05)
        #expect(MusicBeatPlanner.cutFadeSeconds >= AVPlaybackEngine.minimumFade(for: .quickCut))
    }

    @Test("a cut plan fades the outgoing song for less than the blend floor, so the old guard would have refused it")
    func planBelowOldFloor() throws {
        let a = MusicBeatPlannerTests.grid(period: 0.5)
        let b = MusicBeatPlannerTests.grid(period: 60 / 150, anchor: 0.1, phase: 1, span: 0.1...236)
        let i = MusicBeatPlannerTests.inputs(a: a, b: b)
        let plan = try #require(MusicBeatPlanner.styledPlan(i, smart: MusicTransitionPlanner.smartPlan(i), style: .quickCut))
        #expect(plan.fadeSeconds < 1)
        #expect(plan.fadeSeconds >= AVPlaybackEngine.minimumFade(for: plan.style))
    }
}
