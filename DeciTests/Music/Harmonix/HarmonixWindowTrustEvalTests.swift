// DeciTests/Music/Harmonix/HarmonixWindowTrustEvalTests.swift
// Tier 3d-2 (Jot ty1hzg) step 1: measure a local trust score for the two windows a mix uses (the outgoing song's last 40 s
// before its trimmed end, the incoming song's first 40 s from its trimmed start), against beat F on the truth in the same
// window. Same gate and dataset as HarmonixBeatEvalTests. Features per window come from the finder's own bass onsets
// (MusicBeatFinder.bassOnsets): the share of grid beats with an onset within 10 ms, the best share when the grid is moved
// to the chance offsets, the median residual and its robust jitter. Also, per grid, the downbeat estimate against the
// truth bars (what separates right phases from wrong ones). Output: <dataset>/eval/windows-<sha>.json and .txt.

import Foundation
import Testing
@testable import Deci

@Suite("Harmonix window trust eval", .serialized, .enabled(if: harmonixGate))
struct HarmonixWindowTrustEvalTests {
    static let windowSec = 40.0

    nonisolated struct Features {
        var beats = 0
        var on = 0.0, off = 0.0
        var medianMs = Double.nan, jitterMs = Double.nan
        /// Late-half median residual minus early-half median residual, ms per beat.
        var driftMsPerBeat = Double.nan
    }

    /// Features of the grid inside [from, to] against sorted onset times.
    nonisolated static func features(onsets: [Double], grid g: MusicBeatGrid, from: Double, to: Double) -> Features {
        var out = Features()
        guard to > from, !onsets.isEmpty else { return out }
        let first = Int(ceil((from - g.anchorSec) / g.periodSec)), last = Int(floor((to - g.anchorSec) / g.periodSec))
        guard first <= last else { return out }
        func nearest(_ t: Double) -> Double {
            var lo = 0, hi = onsets.count
            while lo < hi { let m = (lo + hi) / 2; if onsets[m] < t { lo = m + 1 } else { hi = m } }
            var best = Double.infinity
            for i in [lo - 1, lo] where i >= 0 && i < onsets.count { best = abs(onsets[i] - t) < abs(best) ? onsets[i] - t : best }
            return best
        }
        func rate(shift: Double) -> Double {
            var hits = 0
            for k in first...last where abs(nearest(g.beatTime(k) + shift)) <= MusicBeatFinder.hitToleranceSec { hits += 1 }
            return Double(hits) / Double(last - first + 1)
        }
        out.beats = last - first + 1
        out.on = rate(shift: 0)
        out.off = MusicBeatFinder.chanceOffsets.map { rate(shift: $0 * g.periodSec) }.max() ?? 0
        var residuals: [(Int, Double)] = []
        for k in first...last {
            let d = nearest(g.beatTime(k))
            if abs(d) <= 0.06 { residuals.append((k, d)) }
        }
        let r = residuals.map(\.1)
        if !r.isEmpty {
            let med = HarmonixBeatEvalTests.median(r)
            out.medianMs = med * 1000
            out.jitterMs = 1.4826 * HarmonixBeatEvalTests.median(r.map { abs($0 - med) }) * 1000
            let mid = Double(first + last) / 2
            let early = residuals.filter { Double($0.0) < mid }.map(\.1), late = residuals.filter { Double($0.0) >= mid }.map(\.1)
            if early.count >= 4, late.count >= 4 {
                out.driftMsPerBeat = (HarmonixBeatEvalTests.median(late) - HarmonixBeatEvalTests.median(early)) * 1000 / max(1, Double(out.beats) / 2)
            }
        }
        return out
    }

    /// The finder's own onset envelope (broadband plus bass flux, scaled by its deviation) and its frame rate.
    nonisolated static func broadband(_ audio: [Float], rate: Double) -> (env: [Float], frameRate: Double)? {
        guard let e = MusicBeatFinder.onsetEnvelopes(audio, rate: rate) else { return nil }
        var env = e.full
        for i in 0..<env.count { env[i] += Float(MusicBeatFinder.bassWeight) * e.low[i] }
        return (MusicBeatFinder.normalisedByDeviation(env), rate / Double(e.hop))
    }

    /// Mean envelope peak (within one frame) at the grid beats of [from, to], and the highest such mean at the chance offsets.
    nonisolated static func broadbandScore(_ b: (env: [Float], frameRate: Double), grid g: MusicBeatGrid, from: Double, to: Double) -> (on: Double, off: Double) {
        let first = Int(ceil((from - g.anchorSec) / g.periodSec)), last = Int(floor((to - g.anchorSec) / g.periodSec))
        guard first <= last else { return (0, 0) }
        func mean(shift: Double) -> Double {
            var sum = 0.0, n = 0
            for k in first...last {
                let f = Int(((g.beatTime(k) + shift) * b.frameRate + MusicBeatFinder.leadFrames).rounded())
                guard f >= 1, f + 1 < b.env.count else { continue }
                sum += Double(max(b.env[f - 1], b.env[f], b.env[f + 1]))
                n += 1
            }
            return n > 0 ? sum / Double(n) : 0
        }
        return (mean(shift: 0), MusicBeatFinder.chanceOffsets.map { mean(shift: $0 * g.periodSec) }.max() ?? 0)
    }

    @Test("Harmonix: window trust features against local beat F, and downbeat signals")
    func evaluate() async throws {
        let songs = try HarmonixBeatEvalTests.loadSongs()
        var rows: [[String: Any]] = []
        var downs: [[String: Any]] = []
        func num(_ x: Double) -> Any { x.isFinite ? x : NSNull() }
        for song in songs {
            guard FileManager.default.fileExists(atPath: song.songPath), FileManager.default.fileExists(atPath: song.truthPath) else { continue }
            let truth = try HarmonixBeatEvalTests.loadTruth(song)
            let url = URL(fileURLWithPath: song.songPath)
            let result = try await MusicFileAnalyzer.analyze(file: url, exactDuration: nil)
            let analysis = MusicAnalysis(videoId: song.id, result: result, source: .playbackCache)
            guard let g = analysis.usableGrid else { continue }
            let (audio, rate) = try await GridGateDiagnosisTests.decode(url)
            let duration = Double(audio.count) / rate
            let band = MusicBeatFinder.bassBand(audio, rate: rate)
            let bb = Self.broadband(audio, rate: rate)
            let onsets = MusicBeatFinder.bassOnsets(in: band).map(\.time).sorted()
            let outEnd = MusicTransitionPlanner.trimmedEnd(of: analysis, duration: duration) ?? duration
            let inStart = MusicTransitionPlanner.trimmedStart(of: analysis, duration: duration) ?? 0
            let slack = MusicBeatPlanner.spanSlackBeats * g.periodSec
            let wholeSpanTrusted = HarmonixBeatEvalTests.trusted(g)
            let spanF = BeatScoring.fMeasure(
                reference: HarmonixBeatEvalTests.within(truth.beats, g.spanStartSec, g.spanEndSec),
                estimated: HarmonixBeatEvalTests.gridTimes(g, from: g.spanStartSec, to: g.spanEndSec)).f
            let windows: [(String, Double, Double)] = [
                ("out", max(g.spanStartSec, outEnd - Self.windowSec), min(outEnd, g.spanEndSec + slack)),
                ("in", max(g.spanStartSec - slack, inStart), min(inStart + Self.windowSec, g.spanEndSec)),
                // Windows fixed on the grid span (computable at analysis time without the plan's trims).
                ("tail", max(g.spanStartSec, g.spanEndSec - Self.windowSec), g.spanEndSec),
                ("head", g.spanStartSec, min(g.spanEndSec, g.spanStartSec + Self.windowSec)),
            ]
            // The annotation covers only part of the audio (no beats in leading and trailing silence or fades): a window is
            // clipped to the annotated stretch so local F is not zero where the truth is simply missing.
            let annotated = (truth.beats.first ?? 0, truth.beats.last ?? 0)
            for (side, from0, to0) in windows {
                let from = max(from0, annotated.0), to = min(to0, annotated.1)
                guard to > from + 8 else { continue }
                let f = Self.features(onsets: onsets, grid: g, from: from, to: to)
                let local = BeatScoring.fMeasure(
                    reference: HarmonixBeatEvalTests.within(truth.beats, from, to),
                    estimated: HarmonixBeatEvalTests.gridTimes(g, from: from, to: to))
                let bs = bb.map { Self.broadbandScore($0, grid: g, from: from, to: to) } ?? (on: 0, off: 0)
                rows.append([
                    "bb_on": bs.on, "bb_off": bs.off,
                    "id": song.id, "genre": song.genre, "side": side, "from": from, "to": to, "beats": f.beats,
                    "on": f.on, "off": f.off, "median_ms": num(f.medianMs), "jitter_ms": num(f.jitterMs),
                    "drift_ms_per_beat": num(f.driftMsPerBeat), "local_f": local.f, "span_f": spanF,
                    "whole_span_trusted": wholeSpanTrusted, "alias": song.alias,
                ])
            }
            // Downbeat signals on every grid with a span (not only the trusted ones).
            let first = Int(ceil((g.spanStartSec - g.anchorSec) / g.periodSec)), last = Int(floor((g.spanEndSec - g.anchorSec) / g.periodSec))
            if first < last, let e = MusicBeatFinder.estimateDownbeat(decimated: audio, rate: rate, grid: g, beats: first...last, band: band) {
                let byPhase = (0..<4).map { p in
                    BeatScoring.fMeasure(
                        reference: HarmonixBeatEvalTests.within(truth.downbeats, g.spanStartSec, g.spanEndSec),
                        estimated: HarmonixBeatEvalTests.gridTimes(g, from: g.spanStartSec, to: g.spanEndSec, phase: p)).f
                }
                downs.append([
                    "id": song.id, "span_f": spanF, "trusted": wholeSpanTrusted, "alias": song.alias, "phase": e.phase,
                    "margin": e.margin, "effect": e.effect, "agrees": e.agrees, "blocks": e.blocks,
                    "splits": e.splitPhases, "f_by_phase": byPhase, "correct": byPhase[e.phase] >= 0.5,
                    "stored_phase": g.downbeatPhase.map { $0 as Any } ?? NSNull(),
                ])
            }
        }
        let sha = HarmonixBeatEvalTests.gitSha()
        let dir = harmonixDir + "/eval"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["windows": rows, "downbeats": downs], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "\(dir)/windows-\(sha).json"))
        #expect(!rows.isEmpty)
    }
}
