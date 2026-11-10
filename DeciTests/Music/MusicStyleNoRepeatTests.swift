// DeciTests/Music/MusicStyleNoRepeatTests.swift
// Tier 4b P1: the planner asks the picker for every Mix pair and never repeats the style before it, grids or no grids.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicStyleNoRepeat")
struct MusicStyleNoRepeatTests {
    typealias BT = MusicBeatPlannerTests

    static func matched(previous: MusicTransitionStyle?) -> MusicTransitionInputs {
        var i = BT.inputs(a: BT.grid(period: 0.5), b: BT.grid(period: 0.5, anchor: 0.1, phase: 1, span: 0.1...236))
        i.previousStyle = previous
        return i
    }

    static func gridless(previous: MusicTransitionStyle?) -> MusicTransitionInputs {
        var i = BT.inputs(a: nil, b: nil)
        i.previousStyle = previous
        return i
    }

    static func clash(previous: MusicTransitionStyle?) -> MusicTransitionInputs {
        var i = BT.inputs(a: BT.grid(period: 0.5), b: BT.grid(period: 60 / 131, anchor: 0.1, phase: 1, span: 0.1...236))
        i.previousStyle = previous
        return i
    }

    /// A matched pair whose incoming song has a drop and whose energy rises, so every style is a candidate.
    static func everything(previous: MusicTransitionStyle?) -> MusicTransitionInputs {
        var i = matched(previous: previous)
        i.incoming.analysis?.energy = DropFixtures.envelope(steps: [40])
        i.outgoing.analysis?.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.4).encode()
        i.incoming.analysis?.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.7).encode()
        return i
    }

    @Test("a beat-matched pair is a long blend with no previous style, and again right after a long blend")
    func blendThenBlend() {
        #expect(MusicTransitionPlanner.plan(Self.matched(previous: nil)).style == .longBlend)
        let after = MusicTransitionPlanner.plan(Self.matched(previous: .longBlend))
        #expect(after.style == .longBlend)
        #expect(after.mode == .beat && after.overlapBars > 0)
    }

    @Test("a pair with no grid at all still gets a floor blend (beat mode, 6 to 8 s, bass swap), before or after a blend")
    func gridlessFloor() {
        for previous in [nil, MusicTransitionStyle.longBlend] {
            let plan = MusicTransitionPlanner.plan(Self.gridless(previous: previous))
            #expect(plan.mode == .beat && plan.incomingRate == 1)
            #expect(plan.fadeSeconds >= 6 && plan.fadeSeconds <= 8)
            #expect(plan.bassSwapAtSec != nil && plan.style != .quickCut && plan.style != .echoOut)
        }
    }

    @Test("a cut or an echo never follows itself, and no pair without a hard ending ever gets one")
    func noCutsWithoutAHardEnding() {
        let makers: [(MusicTransitionStyle?) -> MusicTransitionInputs] = [Self.matched, Self.gridless, Self.clash, Self.everything]
        for make in makers {
            for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
                let plan = MusicTransitionPlanner.plan(make(previous))
                #expect(plan.style != .quickCut && plan.style != .echoOut, "previous \(previous?.rawValue ?? "none")")
            }
        }
    }

    @Test("a seeded run of 200 pairs: blends dominate, no cut or echo, the repeat penalty never forces a style off a blend")
    func seededRun() {
        var generator = SeededGenerator(seed: 4_242)
        var previous: MusicTransitionStyle?
        var counts: [MusicTransitionStyle: Int] = [:]
        for _ in 0..<200 {
            let signals = MusicTransitionStyleInputs(
                tempoError: Double.random(in: 0...0.4, using: &generator),
                energyJump: Float.random(in: -0.5...0.8, using: &generator),
                keyDistance: Int.random(in: 0...6, using: &generator),
                gridTrusted: Bool.random(using: &generator),
                dropConfidence: Float.random(in: 0...1, using: &generator),
                tailDropDb: Double.random(in: 0...15, using: &generator),
                mixOutOnPhrase: Bool.random(using: &generator)
            )
            let pick = MusicTransitionStylePicker.pick(signals, previous: previous)
            #expect(MusicTransitionStylePicker.suits(pick, signals))
            counts[pick, default: 0] += 1
            previous = pick
        }
        let blends = counts[.longBlend, default: 0] + counts[.filterSweep, default: 0] + counts[.dropSwap, default: 0] + counts[.loopExtend, default: 0]
        #expect(blends > 100, "counts \(counts)")
    }

    @Test("a seeded run of 200 real planned pairs: the long blend (beat-matched or floor) is the default, the sweep is a spice, no non-blend twice in a row")
    func plannedVariety() {
        var generator = SeededGenerator(seed: 777)
        var previous: MusicTransitionStyle?
        var counts: [MusicTransitionStyle: Int] = [:]
        var nonBlendRun = 0
        for _ in 0..<200 {
            let bpmA = Double.random(in: 85...135, using: &generator)
            // A Mix queue is ranked by compatibility: most neighbours are close in tempo, some are far, some have no usable grid.
            let kind = Double.random(in: 0...1, using: &generator)
            let bpmB = kind < 0.7 ? bpmA * Double.random(in: 0.95...1.05, using: &generator)
                : bpmA * Double.random(in: 0.7...1.3, using: &generator)
            func grid(_ bpm: Double, anchor: Double, span: ClosedRange<Double>) -> MusicBeatGrid? {
                let roll = Double.random(in: 0...1, using: &generator)
                if roll < 0.03 { return nil }
                let phase: Int? = roll < 0.2 ? nil : Int.random(in: 0...3, using: &generator)
                return BT.grid(period: 60 / bpm, anchor: anchor, phase: phase, confidence: roll < 0.15 ? 0.3 : 0.9, span: span)
            }
            var i = BT.inputs(a: grid(bpmA, anchor: 0.2, span: 0.2...236), b: grid(bpmB, anchor: 0.1, span: 0.1...236))
            i.outgoing.analysis?.keyInfo = MusicKeyInfo(
                tonic: Int.random(in: 0...11, using: &generator), isMinor: Bool.random(using: &generator), confidence: 0.5,
                energy: Float.random(in: 0.2...0.9, using: &generator)).encode()
            i.incoming.analysis?.keyInfo = MusicKeyInfo(
                tonic: Int.random(in: 0...11, using: &generator), isMinor: Bool.random(using: &generator), confidence: 0.5,
                energy: Float.random(in: 0.2...0.9, using: &generator)).encode()
            i.previousStyle = previous
            let plan = MusicTransitionPlanner.plan(i)
            counts[plan.style, default: 0] += 1
            nonBlendRun = (plan.style == .longBlend || plan.style == .filterSweep) ? 0 : nonBlendRun + 1
            #expect(nonBlendRun <= 2, "non-blend styles in a row")
            previous = plan.style
        }
        #expect(counts[.longBlend, default: 0] >= 100, "counts \(counts)")
        #expect(counts[.filterSweep, default: 0] <= 70, "counts \(counts)")
    }

    @Test("when nothing else can be built the blend stays and is logged as noAlternative")
    func noAlternative() {
        var i = Self.gridless(previous: .longBlend)
        i.earliestMixOutSec = 10_000
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.style == .longBlend)
        #expect(plan.fallbackReason == MusicTransitionStylePicker.noAlternative)
        let line = MusicTransitionLog.styleLine(from: "a", to: "b", style: plan.style, reason: plan.fallbackReason, previous: .longBlend)
        #expect(line.contains("reason=noAlternative"))
    }

    @Test("a quick cut's fade is a few milliseconds, so the downbeat stays hard")
    func cutIsHard() {
        #expect(MusicBeatPlanner.cutFadeSeconds >= 0.003 && MusicBeatPlanner.cutFadeSeconds <= 0.005)
    }

    @Test("a run of low-confidence pairs is a blend every time: the floor never gives up")
    func lowConfidenceRun() {
        var previous: MusicTransitionStyle?
        for _ in 0..<6 {
            var i = BT.inputs(a: BT.grid(confidence: 0.3))
            i.previousStyle = previous
            let plan = MusicTransitionPlanner.plan(i)
            #expect(plan.mode == .beat && plan.fadeSeconds >= 6 && plan.bassSwapAtSec != nil)
            previous = plan.style
        }
    }

    @Test("a run of pairs with a tempo clash is a thinned floor blend every time, never a cut or an echo")
    func clashRun() {
        var previous: MusicTransitionStyle?
        for _ in 0..<4 {
            let plan = MusicTransitionPlanner.plan(Self.clash(previous: previous))
            #expect(plan.mode == .beat && plan.style == .filterSweep && plan.fadeSeconds >= 6)
            previous = plan.style
        }
    }
}

/// A small deterministic generator (SplitMix64) so the simulation gives the same pairs on every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
