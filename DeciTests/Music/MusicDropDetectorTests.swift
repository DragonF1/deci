// DeciTests/Music/MusicDropDetectorTests.swift
// Tier 4b P2: drops from the energy curve and the beat grid, for the drop swap.

import Foundation
import Testing
@testable import Deci

/// Synthetic envelopes shared by the drop tests.
enum DropFixtures {
    /// One code per 100 ms: `low` dB up to `steps` (seconds) and `high` dB after each, a step at every entry.
    static func envelope(seconds: Double = 240, low: Float = -30, high: Float = -18, steps: [Double] = []) -> [UInt8] {
        let count = Int((seconds * 10).rounded())
        return (0..<count).map { block in
            let time = Double(block) / 10
            let loud = steps.contains { time >= $0 - 1e-9 }
            return MusicAnalysis.energyCode(forDb: loud ? high : low)
        }
    }

    /// Two-bar bars (period 0.5, downbeat every 2 s from 0).
    static func grid(confidence: Float = 0.9, phase: Int? = 0) -> MusicBeatGrid {
        MusicBeatPlannerTests.grid(period: 0.5, anchor: 0, phase: phase, confidence: confidence, span: 0...236)
    }
}

@Suite("MusicDropDetector")
struct MusicDropDetectorTests {
    @Test("a 12 dB step on a bar line is one drop, on that downbeat, 12 dB high")
    func stepOnTheBarLine() throws {
        let drops = try #require(MusicDropDetector.drops(energy: DropFixtures.envelope(steps: [40]), grid: DropFixtures.grid()))
        #expect(drops.count == 1)
        let drop = try #require(drops.first)
        #expect(abs(drop.timeSec - 40) < 1e-9)
        #expect(abs(drop.riseDb - 12) < 0.01)
        #expect(drop.confidence >= MusicDropDetector.confidenceFloor && drop.confidence <= 1)
    }

    @Test("a step between bar lines is snapped to the nearest downbeat")
    func snapsToDownbeat() throws {
        let drops = try #require(MusicDropDetector.drops(energy: DropFixtures.envelope(steps: [16.3]), grid: DropFixtures.grid()))
        #expect(drops.count == 1)
        let drop = try #require(drops.first)
        #expect(abs(drop.timeSec - 16) < 1e-9, "snapped to \(drop.timeSec)")
        // It is a downbeat of the grid.
        let bar = (drop.timeSec - (DropFixtures.grid().barTime(0) ?? 0)) / 2
        #expect(abs(bar - bar.rounded()) < 1e-9)
    }

    @Test("a grid with another phase and anchor still gives a downbeat")
    func otherGrid() throws {
        let grid = MusicBeatPlannerTests.grid(period: 0.48, anchor: 0.1, phase: 1, span: 0.1...236)
        let downbeat = try #require(grid.barTime(20))
        let step = (downbeat * 10).rounded() / 10
        let drops = try #require(MusicDropDetector.drops(energy: DropFixtures.envelope(steps: [step]), grid: grid))
        #expect(drops.count == 1)
        #expect(abs(try #require(drops.first).timeSec - downbeat) < 1e-9)
    }

    @Test("flat energy has no drop, and an empty list is not nil")
    func flat() throws {
        let drops = try #require(MusicDropDetector.drops(energy: DropFixtures.envelope(), grid: DropFixtures.grid()))
        #expect(drops.isEmpty)
        #expect(MusicDropDetector.drops(energy: [], grid: DropFixtures.grid()) == [])
    }

    @Test("a rise under 6 dB is not a drop")
    func subThreshold() throws {
        let envelope = DropFixtures.envelope(low: -30, high: -25.5, steps: [40])
        #expect(try #require(MusicDropDetector.drops(energy: envelope, grid: DropFixtures.grid())).isEmpty)
        let nearly = DropFixtures.envelope(low: -30, high: -23.5, steps: [40])
        #expect(try #require(MusicDropDetector.drops(energy: nearly, grid: DropFixtures.grid())).count == 1)
    }

    @Test("a short spike is not a drop: the loud stretch has to hold")
    func spike() throws {
        var envelope = DropFixtures.envelope()
        // 0.3 s at +20 dB on a bar line.
        for block in 400..<403 { envelope[block] = MusicAnalysis.energyCode(forDb: -10) }
        #expect(try #require(MusicDropDetector.drops(energy: envelope, grid: DropFixtures.grid())).isEmpty)
    }

    @Test("a song that starts from silence has no drop at its first note")
    func silentStart() throws {
        var envelope = DropFixtures.envelope(low: -30, high: -12, steps: [20])
        for block in 0..<200 { envelope[block] = 0 }
        let drops = try #require(MusicDropDetector.drops(energy: envelope, grid: DropFixtures.grid()))
        #expect(!drops.contains { abs($0.timeSec - 20) < 1e-9 })
    }

    @Test("no grid, an untrusted grid or a grid without a downbeat gives nil")
    func noGrid() {
        let envelope = DropFixtures.envelope(steps: [40])
        #expect(MusicDropDetector.drops(energy: envelope, grid: nil) == nil)
        #expect(MusicDropDetector.drops(energy: envelope, grid: DropFixtures.grid(confidence: 0.2)) == nil)
        #expect(MusicDropDetector.drops(energy: envelope, grid: DropFixtures.grid(phase: nil)) == nil)
    }

    @Test("several drops come back in time order, one per stretch")
    func several() throws {
        let envelope = DropFixtures.envelope(steps: [40])
        var two = envelope
        for block in 1_000..<1_100 { two[block] = MusicAnalysis.energyCode(forDb: -48) }
        for block in 1_100..<two.count { two[block] = MusicAnalysis.energyCode(forDb: -18) }
        let drops = try #require(MusicDropDetector.drops(energy: two, grid: DropFixtures.grid()))
        #expect(drops.map(\.timeSec) == drops.map(\.timeSec).sorted())
        #expect(drops.count >= 2)
        #expect(drops.contains { abs($0.timeSec - 40) < 1e-9 } && drops.contains { abs($0.timeSec - 110) < 1e-9 })
    }

    @Test("best is the first confident drop with 4 bars of material before it")
    func bestDrop() throws {
        func row(_ envelope: [UInt8]) -> MusicAnalysis {
            var row = MusicTransitionPlannerTests.analysis("bbbbbbbbbbb", duration: 240)
            row.energy = envelope
            return row
        }
        let grid = DropFixtures.grid()
        let first = try #require(MusicDropDetector.best(in: row(DropFixtures.envelope(steps: [8, 100])), grid: grid))
        #expect(abs(first.timeSec - 8) < 1e-9, "exactly 4 bars in is allowed")
        let later = try #require(MusicDropDetector.best(in: row(DropFixtures.envelope(steps: [100])), grid: grid))
        #expect(abs(later.timeSec - 100) < 1e-9)
        // A step under 4 bars in is too early for the window and is never seen.
        #expect(MusicDropDetector.best(in: row(DropFixtures.envelope(steps: [3])), grid: grid) == nil)
        #expect(MusicDropDetector.best(in: row(DropFixtures.envelope()), grid: grid) == nil)
        #expect(MusicDropDetector.best(in: row(DropFixtures.envelope(steps: [40])), grid: nil) == nil)
    }

    @Test("a long song with a thousand blocks of noise stays quick and finite")
    func largeInput() throws {
        var state: UInt64 = 1
        let envelope: [UInt8] = (0..<36_000).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return UInt8(100 + (state >> 60))
        }
        let drops = try #require(MusicDropDetector.drops(energy: envelope, grid: MusicBeatPlannerTests.grid(period: 0.5, anchor: 0, phase: 0, span: 0...3_500)))
        #expect(drops.allSatisfy { $0.riseDb.isFinite && $0.confidence.isFinite })
    }
}
