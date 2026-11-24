// DeciTests/Music/MusicDJExitTests.swift
// The sources a DJ exit comes from (second chorus, second hook, second drop), the order they are tried in, what makes a plan
// one that really leaves there, and the drop swap that ends at it.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music DJ exits")
struct MusicDJExitTests {
    typealias BT = MusicBeatPlannerTests
    typealias D = MusicDJLength

    /// Levels a 2 s bar from 0.2 s: quiet with loud stretches of 16 bars from each bar in `drops`.
    static func dropLevels(_ drops: [Int], length: Int = 16) -> [Float] {
        (0..<120).map { bar in drops.contains { bar >= $0 && bar < $0 + length } ? -14 : -28 }
    }

    static let emptyPlan = TransitionPlan(
        mode: .smart, incomingStartSec: 0, outgoingEndSec: nil, fadeStartSec: nil, fadeSeconds: 6, incomingGainDb: 0,
        incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok)

    private func inputs(energy: [UInt8] = [], hooks: [ClosedRange<Double>]? = nil) -> MusicTransitionInputs {
        var i = BT.inputs()
        i.outgoing.analysis?.energy = energy
        if let hooks { i.outgoing.lyricCues = MusicLyricCues(hooks: hooks, firstLineSec: nil) }
        i.incoming.vocalIntervals = []
        i.djLength = true
        return i
    }

    @Test("off, or with a rule that keeps the pair from mixing, there are none")
    func rules() {
        let on = inputs(hooks: [40...60, 100...120])
        #expect(D.exits(on, smartEnd: 236, normal: 208.2).isEmpty == false)
        for edit: (inout MusicTransitionInputs) -> Void in [
            { $0.djLength = false }, { $0.beatMixEnabled = false }, { $0.crossfadeOn = false }, { $0.albumInOrder = true },
            { $0.loopSong = true }, { $0.manualSkip = true }, { $0.cleanStartFlag = true }, { $0.cleanPairFlag = true },
            { $0.outgoing.durationSeconds = nil }, { $0.outgoing.analysis = nil },
        ] {
            var i = on
            edit(&i)
            #expect(D.exits(i, smartEnd: 236, normal: 208.2).isEmpty)
        }
    }

    @Test("the second hook, on the bar line nearest its end")
    func hook() throws {
        let exits = D.exits(inputs(hooks: [40...60, 100...120.9, 150...170]), smartEnd: 236, normal: 208.2)
        #expect(exits.count == 1)
        let exit = try #require(exits.first)
        #expect(exit.section == .hook2)
        #expect(abs(exit.point - 120.2) < 1e-9)
        #expect(exit.normal == 208.2)
    }

    @Test("the second hook of a song with no grid, where it ends")
    func gridlessHook() throws {
        var i = inputs(hooks: [40...60, 100...120.9])
        i.outgoing.grid = nil
        let exit = try #require(D.exits(i, smartEnd: 236, normal: 230).first)
        #expect(exit.section == .hook2 && abs(exit.point - 120.9) < 1e-9)
    }

    @Test("a hook outside the middle of the song is passed over for the next one")
    func hookWindow() throws {
        let exit = try #require(D.exits(inputs(hooks: [20...40, 70...90, 130...150]), smartEnd: 236, normal: 208.2).first)
        #expect(abs(exit.point - 150.2) < 1e-9, "90 is 37% in")
        #expect(D.exits(inputs(hooks: [20...40, 200...220]), smartEnd: 236, normal: 230).isEmpty, "220 is 92% in")
    }

    @Test("the second drop, where its loud stretch ends")
    func drop() throws {
        // Drops at bars 20 (40.2 s), 34 (68.2 s) and 60 (120.2 s), each 10 bars of loud after 4 quiet ones or more. A drop in the
        // first quarter of the song is its intro ending.
        let energy = SectionFixtures.bars(Self.dropLevels([20, 34, 64], length: 8))
        let ends = D.dropEnds(energy: energy, grid: BT.grid(), duration: 240)
        #expect(ends.count == 1, "\(ends)")
        #expect(abs((ends.first ?? 0) - 144.2) < 1e-6, "72 bars in: \(ends)")
        let exits = D.exits(inputs(energy: energy), smartEnd: 236, normal: 208.2)
        #expect(exits.contains { $0.section == .drop2 && abs($0.point - 144.2) < 1e-6 }, "\(exits)")
    }

    @Test("a drop whose loud stretch never ends is not one to leave on")
    func endlessDrop() {
        let energy = SectionFixtures.bars((0..<120).map { $0 >= 34 && $0 < 44 || $0 >= 60 ? -14 : -28 })
        #expect(D.dropEnds(energy: energy, grid: BT.grid(), duration: 240).isEmpty)
        #expect(D.dropEnds(energy: [], grid: BT.grid(), duration: 240).isEmpty)
    }

    @Test("a mean level is only given for a stretch the curve holds")
    func level() {
        let codes = [UInt8](repeating: MusicAnalysis.energyCode(forDb: -20), count: 100)
        #expect(abs((D.level(codes, from: 2, to: 5) ?? 0) + 20) < 0.3)
        #expect(D.level(codes, from: 5, to: 5) == nil)
        #expect(D.level(codes, from: 8, to: 12) == nil)
        #expect(D.level(codes, from: -1, to: 5) == nil)
        #expect(D.level(codes, from: 0, to: .nan) == nil)
        #expect(D.level(codes, from: 0, to: 1e12) == nil)
    }

    @Test("chorus before hook before drop, one of each at most")
    func order() {
        var i = inputs(energy: SectionFixtures.envelope(seconds: 240, high: [2, 6, 9]), hooks: [40...60, 120...140, 150...160])
        let exits = D.exits(i, smartEnd: 236, normal: 208.2)
        #expect(exits.prefix(2).map(\.section) == [.chorus2, .hook2])
        #expect(Set(exits.map(\.section)).count == exits.count)
        i.outgoing.analysis?.energy = []
        #expect(D.exits(i, smartEnd: 236, normal: 208.2).map(\.section) == [.hook2])
    }

    @Test("an exit beats the usual mix-out by a bar")
    func beatsNormal() {
        let i = inputs(hooks: [40...60, 100...120.2])
        #expect(D.exits(i, smartEnd: 236, normal: 122.2).count == 1)
        #expect(D.exits(i, smartEnd: 236, normal: 122.1).isEmpty)
        #expect(D.exits(i, smartEnd: 236, normal: .nan).isEmpty)
    }

    @Test("the vocal guard off ignores sung lines, on moves past them")
    func sungOver() {
        var i = inputs(hooks: [40...60, 100...120.2])
        i.outgoing.vocalIntervals = [118...123]
        #expect(abs((D.exits(i, smartEnd: 236, normal: 208.2).first?.point ?? 0) - 120.2) < 1e-9)
        i.vocalGuardEnabled = true
        #expect(abs((D.exits(i, smartEnd: 236, normal: 208.2).first?.point ?? 0) - 124.2) < 1e-9)
        #expect(D.sung([10...20], at: 20) == false && D.sung([10...20], at: 15) && D.sung(nil, at: 15) == false)
    }

    // MARK: What counts as leaving there

    @Test("a plan leaves at its exit, a drop swap ends at it, a floor blend starts beside it")
    func leaves() {
        let exit = D.Exit(point: 120, normal: 200, section: .chorus2)
        var plan = Self.emptyPlan
        plan.mode = .beat
        plan.style = .longBlend
        plan.mixOutSec = 120
        #expect(D.leaves(plan, at: exit))
        plan.mixOutSec = 121
        plan.overlapBars = 8
        plan.overlapSec = 16
        #expect(!D.leaves(plan, at: exit), "a beat blend somewhere else")
        plan.overlapBars = 0
        plan.overlapSec = 6
        #expect(D.leaves(plan, at: exit), "a floor blend on its own beat")
        plan.mixOutSec = 131
        #expect(!D.leaves(plan, at: exit))
        plan.mixOutSec = 117
        #expect(!D.leaves(plan, at: exit))
        plan.overlapSec = 0.1
        plan.mixOutSec = 121
        #expect(!D.leaves(plan, at: exit), "a cut somewhere else")
        plan.style = .dropSwap
        plan.overlapBars = 8
        plan.overlapSec = 16
        plan.mixOutSec = 104
        plan.outgoingEndSec = 120
        #expect(D.leaves(plan, at: exit))
        plan.outgoingEndSec = 136
        #expect(!D.leaves(plan, at: exit))
    }

    @Test("never two singers together, never at the usual mix-out, never a plan off the grid")
    func refuses() {
        let exit = D.Exit(point: 120, normal: 200, section: .chorus2)
        var plan = Self.emptyPlan
        plan.mode = .beat
        plan.mixOutSec = 120
        plan.vocalAction = "min"
        #expect(!D.leaves(plan, at: exit))
        plan.vocalAction = nil
        plan.mode = .smart
        #expect(!D.leaves(plan, at: exit))
        plan.mode = .beat
        plan.mixOutSec = nil
        #expect(!D.leaves(plan, at: exit))
        plan.mixOutSec = 120
        #expect(!D.leaves(plan, at: D.Exit(point: 120, normal: 120.5, section: .chorus2)))
    }

    // MARK: Drop swap

    @Test("a drop swap's outgoing song is gone at the exit, and the drop lands there")
    func dropSwapEndsAtExit() throws {
        var i = MusicDropSwapPlanTests.inputs()
        i.djMixOutSec = 144.2
        let row = try #require(i.incoming.analysis)
        let drop = try #require(MusicDropDetector.best(in: row, grid: i.incoming.grid))
        let plan = try #require(MusicDropSwapPlanTests.dropPlan(i))
        #expect(abs((plan.outgoingEndSec ?? 0) - 144.2) < 1e-6)
        let heard = try MusicDropSwapPlanTests.dropOnTimeline(plan, drop: drop.timeSec)
        #expect(abs(heard - 144.2) < 0.001)
        #expect(D.leaves(plan, at: D.Exit(point: 144.2, normal: 208.2, section: .chorus2)))
    }

    @Test("through the planner: a hook exit and a drop exit are taken and named")
    func planned() {
        let hook = MusicTransitionPlanner.plan(inputs(hooks: [40...60, 100...120.2]))
        #expect(hook.djSection == .hook2 && abs((hook.mixOutSec ?? 0) - 120.2) < 0.001, "\(hook)")
        let drop = MusicTransitionPlanner.plan(inputs(energy: SectionFixtures.bars(Self.dropLevels([34, 64], length: 8))))
        #expect(drop.djSection == .drop2 || drop.djSection == .chorus2, "\(drop)")
        #expect(abs((drop.mixOutSec ?? 0) - 144.2) < 0.001, "\(drop)")
    }

    @Test("with no grid at all the pair still leaves at the hook, as a floor blend")
    func plannedGridless() throws {
        var i = inputs(hooks: [40...60, 100...120.2])
        i.outgoing.grid = nil
        i.incoming.grid = nil
        let plan = MusicTransitionPlanner.plan(i)
        #expect(plan.mode == .beat && plan.djSection == .hook2, "\(plan)")
        #expect(D.floorSlack.contains(try #require(plan.mixOutSec) - 120.2), "\(plan)")
    }
}
