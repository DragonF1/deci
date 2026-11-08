// DeciTests/Music/BeatFinder/MusicBeatChanceTests.swift
// Tier 3b finder review fixes: a grid is trusted only when its bass hit rate beats what the same onsets give at off-phase
// positions, the final shift is chosen on one half of the beats and scored on the other, and the onset list, the shift
// choice and the phase mode are well defined (sorted, centred on plateaus, deterministic).

import Foundation
import Testing
@testable import Deci

@Suite("MusicBeatChance")
struct MusicBeatChanceTests {
    /// Deterministic uniform values in 0..<1.
    struct Lcg {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static func kicks(at times: [Double], gains: [Float]? = nil, seconds: Double = 40) -> (audio: [Float], rate: Double) {
        var samples = [Float](repeating: 0, count: Int(44_100 * seconds))
        let kick = BeatSynth.kickTemplate(sampleRate: 44_100)
        for (index, time) in times.enumerated() where time < seconds - 0.3 {
            BeatSynth.mix(kick, into: &samples, at: time, sampleRate: 44_100, gain: gains?[index] ?? 0.8)
        }
        return MusicBeatPhaseTests.decimated(BeatSynth.Track(samples: samples, sampleRate: 44_100, beats: []))
    }

    @Test("a stream of 16th note kicks cannot tell the quarter note phase from its off-phase positions: no trust")
    func sixteenths() {
        let (audio, rate) = Self.kicks(at: stride(from: 0.3, to: 39.5, by: 0.125).map { $0 })
        let result = MusicBeatFinder.refineOnBass(decimated: audio, rate: rate, period: 0.5, anchor: 0.3)
        #expect(result.confidence < 0.3, "confidence \(result.confidence)")
    }

    @Test("random 808 style bass onsets against a wrong tempo: no trust", arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
    func randomOnsets(seed: UInt64) {
        var random = Lcg(state: seed &* 7919)
        var times: [Double] = []
        var time = 0.3
        while time < 39.5 {
            time += 0.04 + random.next() * 0.16
            times.append(time)
        }
        let (audio, rate) = Self.kicks(at: times)
        let result = MusicBeatFinder.refineOnBass(decimated: audio, rate: rate, period: 0.45, anchor: 0.2)
        #expect(result.confidence < 0.3, "seed \(seed) confidence \(result.confidence)")
    }

    @Test("kicks on every beat with random clutter between them keep their grid")
    func clutterKeepsGrid() {
        var random = Lcg(state: 4242)
        var times = stride(from: 0.3, to: 39.5, by: 0.5).map { $0 }
        var gains = [Float](repeating: 0.9, count: times.count)
        var time = 0.3
        while time < 39.5 {
            time += 0.1 + random.next() * 0.3
            times.append(time)
            gains.append(0.3)
        }
        let (audio, rate) = Self.kicks(at: times, gains: gains)
        let result = MusicBeatFinder.refineOnBass(decimated: audio, rate: rate, period: 0.5, anchor: 0.33)
        let error = MusicBeatPhaseTests.phaseError(anchor: result.anchor, period: 0.5, truth: 0.3)
        #expect(abs(error) <= 0.005, "error \(error * 1000) ms")
        #expect(result.confidence >= 0.5, "confidence \(result.confidence)")
    }

    @Test("onsets come back sorted by start time even when a quiet later peak walks back past a louder earlier one")
    func onsetsSorted() {
        // 1 kHz band: a loud peak at 1.000 s rising from 0.970 s, a quiet peak at 1.050 s over a 2.0 valley that stays above
        // its lower threshold, so its walk-back reaches further back than the loud one's.
        var flux = [Float](repeating: 0, count: 2000)
        for i in 970...1000 { flux[i] = Float(i - 970) / 30 * 10 }
        for i in 1001...1010 { flux[i] = 10 - Float(i - 1000) * 0.8 }
        for i in 1011...1040 { flux[i] = 2 }
        for i in 1041...1050 { flux[i] = 2 + Float(i - 1040) * 0.2 }
        for i in 1051...1060 { flux[i] = 4 - Float(i - 1050) * 0.2 }
        let onsets = MusicBeatFinder.bassOnsets(in: MusicBeatFinder.Band(env: [Float](repeating: 0, count: 2000), flux: flux, rate: 1000))
        #expect(onsets.count == 2)
        #expect(zip(onsets, onsets.dropFirst()).allSatisfy { $0.time <= $1.time }, "\(onsets.map(\.time))")
    }

    @Test("tied best shifts take the middle of the longest run, never the average of two far apart")
    func shiftRuns() {
        #expect(MusicBeatFinder.bestShiftIndex(counts: [3, 5, 4, 2, 1, 5]) == 1)
        #expect(MusicBeatFinder.bestShiftIndex(counts: [1, 5, 5, 5, 2, 5, 5]) == 2)
        var counts = [Int](repeating: 1, count: 21)
        counts[2] = 9
        counts[18] = 9
        #expect(MusicBeatFinder.bestShiftIndex(counts: counts) == 2)
        #expect(MusicBeatFinder.bestShiftIndex(counts: [4, 4, 4, 4]) == 1)
    }

    @Test("a flat plateau of phase offsets is centred, not read from its left edge")
    func plateau() throws {
        var offsets: [(offset: Double, weight: Double)] = []
        for i in -20...20 { for _ in 0..<5 { offsets.append((Double(i) * 0.001, 1)) } }
        let mode = try #require(MusicBeatFinder.phaseMode(offsets, period: 0.5))
        #expect(abs(mode) <= 0.003, "mode \(mode * 1000) ms")
    }

    @Test("the refinement is deterministic")
    func deterministic() {
        let (audio, rate) = MusicBeatPhaseTests.decimated(BeatSynth.pulse(bpm: 120, seconds: 40, offset: 0.3, click: false))
        let first = MusicBeatFinder.refineOnBass(decimated: audio, rate: rate, period: 0.5, anchor: 0.34)
        for _ in 0..<5 {
            let again = MusicBeatFinder.refineOnBass(decimated: audio, rate: rate, period: 0.5, anchor: 0.34)
            #expect(again.anchor.bitPattern == first.anchor.bitPattern && again.confidence == first.confidence)
        }
    }
}
