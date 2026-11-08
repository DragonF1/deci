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
        #expect(grid.downbeatPhase == nil)
        #expect(grid.downbeatConfidence == 0)
    }

    @Test func fewDownbeatsGiveNoPhase() throws {
        let beats = steady(bpm: 120, count: 100)
        // Seven agreeing downbeats are not enough to turn phrase alignment on; eight are.
        let seven = stride(from: 2, to: 30, by: 4).map { beats[$0] }
        #expect(seven.count == 7)
        let few = try #require(BeatThisGridFit.grid(beats: beats, downbeats: seven, duration: 60))
        #expect(few.downbeatPhase == nil)
        #expect(few.downbeatConfidence == 0)
        let eight = stride(from: 2, to: 34, by: 4).map { beats[$0] }
        #expect(eight.count == 8)
        let enough = try #require(BeatThisGridFit.grid(beats: beats, downbeats: eight, duration: 60))
        #expect(enough.downbeatPhase == 2)
        #expect(enough.downbeatConfidence == 1)
    }

    @Test func downbeatShareBelowGateGivesNoPhase() throws {
        let beats = steady(bpm: 120, count: 100)
        let onPhase = stride(from: 2, to: 50, by: 4).map { beats[$0] }              // 12 on phase 2
        func with(_ stray: Int) -> MusicBeatGrid? {
            let off = stride(from: 0, to: 4 * stray, by: 4).map { beats[$0 + 60] }  // phase 0
            return BeatThisGridFit.grid(beats: beats, downbeats: (onPhase + off).sorted(), duration: 60)
        }
        let mostly = try #require(with(4))     // 12 of 16 = 0.75
        #expect(mostly.downbeatPhase == 2)
        let split = try #require(with(8))      // 12 of 20 = 0.6
        #expect(split.downbeatPhase == nil)
        #expect(split.downbeatConfidence == 0)
    }

    @Test func halfPeriodExtraBeatDoesNotShiftTheNumbering() throws {
        var beats = steady(bpm: 120, count: 100)
        beats.append(beats[40] + 0.25)   // a spurious beat half a period after a real one
        beats.sort()
        let grid = try #require(BeatThisGridFit.grid(beats: beats, downbeats: [], duration: 60))
        #expect(abs(grid.periodSec - 0.5) <= 1e-6)
        #expect(abs(grid.anchorSec - 0.3) <= 1e-6)
        #expect(abs(grid.bpm - 120) <= 0.01)
        #expect(grid.beatConfidence > 0.98)
        #expect(abs(grid.driftSec) <= 0.0005)
        #expect(grid.intervalSpread <= 0.001)
    }

    @Test func fourBeatFillMidSongKeepsTheLine() throws {
        // Bars 11 to 11.75 are played as eight eighth notes: four beats on the line, four between.
        let p = 0.5
        var beats = steady(bpm: 120, count: 100)
        beats.removeSubrange(40..<44)
        for j in 0..<8 { beats.append(0.3 + 40 * p + Double(j) * p / 2) }
        beats.sort()
        let grid = try #require(BeatThisGridFit.grid(beats: beats, downbeats: [], duration: 60))
        #expect(abs(grid.periodSec - p) <= 1e-6)
        #expect(abs(grid.anchorSec - 0.3) <= 1e-6)
        #expect(abs(grid.bpm - 120) <= 0.01)
        #expect(abs(grid.beatConfidence - Float(100) / 104) <= 0.001)
        #expect(abs(grid.driftSec) <= 0.0005)
    }

    @Test func confidenceCountsOnlyBeatsWithin25Milliseconds() throws {
        // 140 bpm (period 0.43 s) with plus or minus 60 ms of wobble: a 70 ms window would call all of them hits.
        let beats = steady(bpm: 140, count: 300, jitter: 0.06, seed: 11)
        let grid = try #require(BeatThisGridFit.grid(beats: beats, downbeats: [], duration: 200))
        #expect(grid.beatConfidence < 0.6)
        #expect(grid.beatConfidence > 0.3)
    }

    @Test func spreadIsOfASingleIntervalAndRubatoReadsLoose() throws {
        // Frame quantisation alone stays under the planner's 0.04 gate, close to the 0.017 the formula gives.
        let quantised = steady(bpm: 128, count: 200).map { ($0 * 50).rounded() / 50 }
        let tight = try #require(BeatThisGridFit.grid(beats: quantised, downbeats: [], duration: 120))
        #expect(tight.intervalSpread > 0.005)
        #expect(tight.intervalSpread < 0.03)
        // Plus or minus 50 ms of rubato is far over it.
        let loose = try #require(BeatThisGridFit.grid(beats: steady(bpm: 128, count: 200, jitter: 0.05, seed: 3), downbeats: [], duration: 120))
        #expect(loose.intervalSpread > 0.08)
    }

    @Test func outliersDoNotInflateTheSpread() throws {
        var beats = steady(bpm: 100, count: 200)
        for k in stride(from: 10, to: 190, by: 20) { beats[k] += 0.22 }   // far-off beats, dropped from the line
        beats.sort()
        let grid = try #require(BeatThisGridFit.grid(beats: beats, downbeats: [], duration: 130))
        #expect(grid.intervalSpread <= 1e-6)
        #expect(abs(grid.periodSec - 0.6) <= 1e-6)
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
