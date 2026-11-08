import Foundation
import Testing
@testable import Deci

@Suite struct BeatThisPeaksChunkerTests {
    /// Frame numbers to seconds at 50 frames per second.
    private func frames(_ numbers: [Double]) -> [Double] { numbers.map { $0 / 50 } }

    @Test func peaksPickLocalMaximaAboveZero() {
        var logits = [Float](repeating: -5, count: 100)
        logits[10] = 3; logits[40] = 2; logits[70] = -1   // the last is below zero
        let times = BeatThisPeaks.times(logits: logits)
        #expect(times == frames([10, 40]))
    }

    @Test func weakerNeighbourWithinWindowIsDropped() {
        var logits = [Float](repeating: -5, count: 60)
        logits[20] = 4; logits[23] = 2   // 3 frames apart: inside the 7 frame window
        #expect(BeatThisPeaks.times(logits: logits) == frames([20]))
        logits[23] = -5; logits[27] = 2  // 7 apart: outside the window
        #expect(BeatThisPeaks.times(logits: logits) == frames([20, 27]))
    }

    @Test func equalAdjacentPeaksMergeAtRunningMean() {
        var logits = [Float](repeating: -5, count: 60)
        logits[30] = 2; logits[31] = 2   // a flat top of two frames
        #expect(BeatThisPeaks.times(logits: logits) == frames([30.5]))
        logits[32] = 2                   // reference rule: 32 is 1.5 from the running mean 30.5, so it starts a new peak
        #expect(BeatThisPeaks.times(logits: logits) == frames([30.5, 32]))
    }

    @Test func downbeatsSnapToNearestBeatAndAreUnique() {
        var beat = [Float](repeating: -5, count: 200)
        for f in stride(from: 10, to: 200, by: 20) { beat[f] = 3 }
        var down = [Float](repeating: -5, count: 200)
        down[12] = 1; down[16] = 1       // both nearest to the beat at frame 10 and 30 respectively
        down[31] = 1
        let out = BeatThisPeaks.pick(beat: beat, downbeat: down)
        #expect(out.beats.count == 10)
        #expect(out.downbeats == frames([10, 30]))
        #expect(out.downbeats.allSatisfy { out.beats.contains($0) })
    }

    @Test func noBeatsGivesNothing() {
        let out = BeatThisPeaks.pick(beat: [Float](repeating: -3, count: 50), downbeat: [Float](repeating: 2, count: 50))
        #expect(out.beats.isEmpty && out.downbeats.isEmpty)
    }

    @Test func chunkStarts() {
        #expect(BeatThisChunker.starts(length: 100) == [-6])
        #expect(BeatThisChunker.starts(length: 1488) == [-6])
        let two: [Int] = [-6, -5]
        #expect(BeatThisChunker.starts(length: 1489) == two)
        let seven: [Int] = [-6, 1482, 2970, 4458, 5946, 7434, 8728]
        #expect(BeatThisChunker.starts(length: 10222) == seven)
        #expect(BeatThisChunker.starts(length: 0) == [])
    }

    @Test func chunkPadsLeftAndRightWithZeros() {
        let length = 20
        let spect = (0..<(length * 128)).map { Float($0 / 128) + 1 }   // row value = frame + 1
        let chunk = BeatThisChunker.chunk(spect: spect, length: length, start: -6)
        #expect(chunk.count == 1500 * 128)
        #expect(chunk[5 * 128] == 0)           // left pad
        #expect(chunk[6 * 128] == 1)           // frame 0 lands at row 6
        #expect(chunk[25 * 128 + 127] == 20)   // last frame at row 25
        #expect(chunk[26 * 128] == 0)          // zero after the piece
    }

    @Test func aggregateKeepsFirstChunkAndMiddleFrames() {
        // Two chunks over a 2000 frame piece: starts -6 and 506 (= 2000 - 1494).
        let starts = BeatThisChunker.starts(length: 2000)
        #expect(starts == [-6, 506])
        func logits(_ value: Float) -> BeatThisChunker.Logits {
            BeatThisChunker.Logits(beat: [Float](repeating: value, count: 1500), downbeat: [Float](repeating: -value, count: 1500))
        }
        let out = BeatThisChunker.aggregate(starts: starts, logits: [logits(1), logits(2)], length: 2000)
        #expect(out.beat.count == 2000)
        #expect(out.beat[0] == 1)               // chunk 0 frame 6
        #expect(out.beat[1487] == 1)            // chunk 0 last kept frame (start + 1493)
        #expect(out.beat[1488] == 2)            // first frame past chunk 0's kept range
        #expect(out.beat[1999] == 2)
        #expect(out.downbeat[1500] == -2)
    }

    @Test func aggregateLeavesUnwrittenFramesLow() {
        let starts = BeatThisChunker.starts(length: 100)
        let logits = BeatThisChunker.Logits(beat: [Float](repeating: 1, count: 1500), downbeat: [Float](repeating: 1, count: 1500))
        let out = BeatThisChunker.aggregate(starts: starts, logits: [logits], length: 100)
        #expect(out.beat == [Float](repeating: 1, count: 100))
    }
}
