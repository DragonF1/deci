import Foundation
import Testing
@testable import Deci

@Suite struct BeatThisGridFitTests {
    private func steady(bpm: Double, count: Int, start: Double = 0.3, jitter: Double = 0, seed: UInt64 = 7) -> [Double] {
        var rng = SplitMix(seed: seed)
        let p = 60 / bpm
        return (0..<count).map { start + Double($0) * p + jitter * (rng.unit() * 2 - 1) }
    }

    @Test func steadyBeatsGiveExactGrid() throws {
        let beats = steady(bpm: 120, count: 100)
        let downs = stride(from: 2, to: 100, by: 4).map { beats[$0] }
        let grid = try #require(BeatThisGridFit.grid(beats: beats, downbeats: downs, duration: 60))
        #expect(abs((grid.periodSec) - (0.5)) <=  1e-9)
        #expect(abs((grid.anchorSec) - (0.3)) <=  1e-9)
        #expect(grid.beatConfidence == 1)
        #expect(abs((grid.intervalSpread) - (0)) <=  1e-6)
        #expect(abs((grid.driftSec) - (0)) <=  1e-9)
        #expect(grid.downbeatPhase == 2)
        #expect(grid.downbeatConfidence == 1)
        #expect(abs((grid.spanStartSec) - (0.3)) <=  1e-9)
        #expect(abs((grid.spanEndSec) - (0.3 + 99 * 0.5)) <=  1e-9)
    }

    @Test func frameQuantisedBeatsPassThePlannerGates() throws {
        // beat_this times sit on the 20 ms frame: the grid must still read as steady.
        let beats = steady(bpm: 128, count: 200).map { ($0 * 50).rounded() / 50 }
        let grid = try #require(BeatThisGridFit.grid(beats: beats, downbeats: [], duration: 120))
        #expect(abs((grid.bpm) - (128)) <=  0.1)
        #expect(grid.beatConfidence >= 0.9)
        #expect(grid.intervalSpread <= 0.04)
        #expect(abs(grid.driftSec) <= 0.003)
        #expect(grid.downbeatPhase == nil)
    }

    @Test func jitteredBeatsKeepPeriodAndDropOutliers() throws {
        var beats = steady(bpm: 100, count: 150, jitter: 0.008)
        beats[40] += 0.2   // a beat far off the line (a quarter of the period)
        beats.sort()
        let grid = try #require(BeatThisGridFit.grid(beats: beats, downbeats: [], duration: 100))
        #expect(abs((grid.periodSec) - (0.6)) <=  0.001)
        #expect(grid.beatConfidence > 0.98)
        #expect(grid.beatConfidence < 1)
    }

    @Test func tempoDriftShowsInDriftAndBreaksConfidence() throws {
        // 100 bpm speeding up to 120 bpm over the song.
        var t = 0.0
        var beats: [Double] = []
        for k in 0..<160 {
            beats.append(t)
            t += 60 / (100 + 20 * Double(k) / 160)
        }
        let grid = try #require(BeatThisGridFit.grid(beats: beats, downbeats: [], duration: 120))
        #expect(grid.driftSec < -0.01)   // the second half has a shorter period
        #expect(grid.beatConfidence < 0.8)
        #expect(abs(grid.driftSec) > 0.003)
    }

    @Test func missedBeatsKeepNumbering() throws {
        var beats = steady(bpm: 90, count: 80)
        beats.removeSubrange(30..<33)   // three beats missing
        let downs = stride(from: 1, to: 80, by: 4).map { steady(bpm: 90, count: 80)[$0] }.filter { d in beats.contains { abs($0 - d) < 1e-9 } }
        let grid = try #require(BeatThisGridFit.grid(beats: beats, downbeats: downs, duration: 80))
        #expect(abs((grid.periodSec) - (60.0 / 90)) <=  1e-9)
        #expect(grid.downbeatPhase == 1)
        #expect(grid.downbeatConfidence == 1)
    }

    @Test func downbeatsThatDoNotRepeatEveryFourLowerTheShare() throws {
        let beats = steady(bpm: 120, count: 120)
        let downs = stride(from: 0, to: 120, by: 3).map { beats[$0] }   // 3/4 time
        let grid = try #require(BeatThisGridFit.grid(beats: beats, downbeats: downs, duration: 80))
        #expect(grid.downbeatConfidence < 0.5)
    }

    @Test func periodIsFoldedIntoRange() throws {
        // 20 bpm (period 3 s) is below 30 bpm: folded to 40 bpm... 3 s halves to 1.5 s (40 bpm).
        let slow = steady(bpm: 20, count: 30)
        let grid = try #require(BeatThisGridFit.grid(beats: slow, downbeats: [], duration: 100))
        #expect(abs((grid.periodSec) - (1.5)) <=  1e-9)
        #expect(MusicBeatGrid.periodRange.contains(grid.periodSec))
        #expect(grid.beatConfidence == 1)
        // 400 bpm (period 0.15 s) is above 300: folded to 0.3 s.
        let fast = steady(bpm: 400, count: 200)
        let grid2 = try #require(BeatThisGridFit.grid(beats: fast, downbeats: [], duration: 100))
        #expect(abs((grid2.periodSec) - (0.3)) <=  1e-9)
        #expect(MusicBeatGrid.periodRange.contains(grid2.periodSec))
    }

    @Test func tooFewOrNoBeatsGiveNil() {
        #expect(BeatThisGridFit.grid(beats: [], downbeats: [], duration: 10) == nil)
        #expect(BeatThisGridFit.grid(beats: steady(bpm: 120, count: 7), downbeats: [], duration: 10) == nil)
        #expect(BeatThisGridFit.grid(beats: [Double](repeating: 1, count: 20), downbeats: [], duration: 10) == nil)
    }

    @Test func gridRoundTripsThroughPayload() throws {
        let grid = try #require(BeatThisGridFit.grid(beats: steady(bpm: 110, count: 90), downbeats: [0.3], duration: 60))
        #expect(MusicBeatGrid.decode(grid.encode()) == grid)
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
