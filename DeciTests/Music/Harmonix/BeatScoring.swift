// DeciTests/Music/Harmonix/BeatScoring.swift
// Tier 3d card fwj3ia: the beat F-measure used by the Harmonix evaluation (mir_eval definition: an estimate is a hit when
// it lies within the window of a reference beat, each reference beat and each estimate used at most once, precision =
// hits / estimates, recall = hits / references, F = harmonic mean). The matching is greedy by distance, nearest pair first.
// The unit tests below pin the numbers on toy inputs so the eval's figures can be trusted.

import Foundation
import Testing

nonisolated enum BeatScoring {
    struct Score: Equatable {
        var precision: Double
        var recall: Double
        var f: Double
        var hits: Int
        var estimated: Int
        var reference: Int
    }

    static let window = 0.07

    /// Both empty scores 1 (mir_eval); exactly one empty scores 0.
    static func fMeasure(reference: [Double], estimated: [Double], window: Double = BeatScoring.window) -> Score {
        if reference.isEmpty && estimated.isEmpty { return Score(precision: 1, recall: 1, f: 1, hits: 0, estimated: 0, reference: 0) }
        if reference.isEmpty || estimated.isEmpty {
            return Score(precision: 0, recall: 0, f: 0, hits: 0, estimated: estimated.count, reference: reference.count)
        }
        let ref = reference.sorted(), est = estimated.sorted()
        // Every candidate pair within the window, then nearest first.
        var pairs: [(d: Double, r: Int, e: Int)] = []
        var low = 0
        for (e, t) in est.enumerated() {
            while low < ref.count, ref[low] < t - window { low += 1 }
            var r = low
            while r < ref.count, ref[r] <= t + window {
                pairs.append((abs(ref[r] - t), r, e))
                r += 1
            }
        }
        pairs.sort { $0.d != $1.d ? $0.d < $1.d : ($0.r != $1.r ? $0.r < $1.r : $0.e < $1.e) }
        var usedRef = Set<Int>(), usedEst = Set<Int>()
        for p in pairs where !usedRef.contains(p.r) && !usedEst.contains(p.e) {
            usedRef.insert(p.r)
            usedEst.insert(p.e)
        }
        let hits = usedRef.count
        let precision = Double(hits) / Double(est.count), recall = Double(hits) / Double(ref.count)
        let f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        return Score(precision: precision, recall: recall, f: f, hits: hits, estimated: est.count, reference: ref.count)
    }

    /// Median of the signed distance from each estimate to its nearest reference, seconds (nil without data).
    static func medianOffset(reference: [Double], estimated: [Double]) -> Double? {
        let ref = reference.sorted()
        guard !ref.isEmpty, !estimated.isEmpty else { return nil }
        let offsets = estimated.map { t -> Double in
            ref.min(by: { abs($0 - t) < abs($1 - t) }).map { t - $0 } ?? 0
        }.sorted()
        return offsets[offsets.count / 2]
    }
}

@Suite("Beat scoring (Harmonix eval matcher)")
struct BeatScoringTests {
    @Test("a perfect match scores 1")
    func perfect() {
        let t = [0.5, 1.0, 1.5, 2.0]
        let s = BeatScoring.fMeasure(reference: t, estimated: t)
        #expect(s.f == 1 && s.precision == 1 && s.recall == 1 && s.hits == 4)
    }

    @Test("the window is inclusive of 70 ms and excludes 80 ms")
    func window() {
        let ref = [1.0, 2.0]
        #expect(BeatScoring.fMeasure(reference: ref, estimated: [1.069, 2.069]).hits == 2)
        #expect(BeatScoring.fMeasure(reference: ref, estimated: [1.08, 2.08]).hits == 0)
        #expect(BeatScoring.fMeasure(reference: ref, estimated: [0.92, 1.931]).hits == 1)
    }

    @Test("one-to-one: two estimates near one reference count once")
    func oneToOne() {
        let s = BeatScoring.fMeasure(reference: [1.0, 2.0], estimated: [1.01, 1.02])
        #expect(s.hits == 1)
        #expect(s.precision == 0.5 && s.recall == 0.5 && abs(s.f - 0.5) < 1e-12)
    }

    @Test("nearest pair wins when two estimates compete for a reference")
    func nearestFirst() {
        // Each estimate is 40 ms from one reference and 60 ms from the other: the nearest pairs are taken first, both match.
        let s = BeatScoring.fMeasure(reference: [1.0, 1.1], estimated: [1.04, 1.06])
        #expect(s.hits == 2)
    }

    @Test("precision and recall differ with extra estimates: a half-tempo grid")
    func halfTempo() {
        let ref = stride(from: 0.0, through: 10.0, by: 0.5).map { $0 }
        let est = stride(from: 0.0, through: 10.0, by: 1.0).map { $0 }
        let s = BeatScoring.fMeasure(reference: ref, estimated: est)
        #expect(s.precision == 1 && abs(s.recall - 11.0 / 21.0) < 1e-12)
        #expect(abs(s.f - 2 * (11.0 / 21.0) / (1 + 11.0 / 21.0)) < 1e-12)
    }

    @Test("a half-beat offset scores 0")
    func offBeat() {
        let ref = stride(from: 0.0, through: 10.0, by: 0.5).map { $0 }
        #expect(BeatScoring.fMeasure(reference: ref, estimated: ref.map { $0 + 0.25 }).f == 0)
    }

    @Test("empty inputs")
    func empties() {
        #expect(BeatScoring.fMeasure(reference: [], estimated: []).f == 1)
        #expect(BeatScoring.fMeasure(reference: [1], estimated: []).f == 0)
        #expect(BeatScoring.fMeasure(reference: [], estimated: [1]).f == 0)
    }

    @Test("unsorted input gives the same answer; median offset is signed")
    func unsortedAndOffset() {
        let a = BeatScoring.fMeasure(reference: [2, 1, 3], estimated: [3.01, 1.0, 2.02])
        #expect(a.hits == 3)
        let m = BeatScoring.medianOffset(reference: [1, 2, 3], estimated: [1.02, 2.03, 3.01])
        #expect(m.map { abs($0 - 0.02) < 1e-9 } == true)
        #expect(BeatScoring.medianOffset(reference: [], estimated: [1]) == nil)
    }
}
