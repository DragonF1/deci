// DeciTests/Music/Vocals/BeatFinderRealSongEvalTests.swift
// Tier 3b finder accuracy P1, real songs. Opt-in, same gate as the vocal eval:
//   TEST_RUNNER_DECI_VOCAL_EVAL=1 run-tests.sh finder-eval BeatFinderRealSongEvalTests
// Per song in /Volumes/Storage/_test/deci-3c/songs: the grid the production analyzer stores now, against the table the
// finder printed before the change (commit 6575e52, GridGateDiagnosisTests). The residual and jitter are measured to the
// finder's own bass attack starts; the cross-check is a second onset measure that shares none of its code: where the
// 40-100 Hz envelope leaves 20% of its local peak, minus the offset the same measure shows on a synthetic kick with a
// known start. (A full-band version read 20 to 50 ms early on most songs, caught by the hats and vocals before the kick,
// and a steepest-rise version sat 40 ms late on sub-bass swells, so neither is used.) Output: /Volumes/Storage/_test/deci-3c/finder-eval.txt.

import Foundation
import Testing
@testable import Deci

private nonisolated let finderEval = ProcessInfo.processInfo.environment["DECI_VOCAL_EVAL"] == "1"

@Suite("Beat finder real songs", .serialized, .enabled(if: finderEval))
struct BeatFinderRealSongEvalTests {
    /// The finder before this change (6575e52): bpm, confidence, spread, median residual and robust jitter in ms (as that
    /// diagnosis measured them, to the strongest rise near each beat), and whether every planner gate passed.
    private nonisolated static let before: [String: (bpm: Double, conf: Double, resMs: Double, jitterMs: Double, trusted: Bool)] = [
        "B3tXcWTpgvQ": (142.02, 0.439, -0.1, 17.9, false), "FZQKzpjpz0Y": (132.00, 0.614, -0.6, 6.5, true),
        "MKQzx3vODio": (143.99, 0.170, -85.7, 52.3, false), "NjR7JpMqiAc": (103.60, 0.320, -116.0, 7.5, false),
        "RCaoGyIXI6Y": (84.99, 0.350, -62.3, 30.2, false), "Txnqzr_DZYg": (70.01, 0.504, -1.6, 12.9, true),
        "_ZDgkYXiD9Y": (118.00, 0.857, 2.5, 4.8, true), "jLmRqtKBchc": (105.00, 0.528, -0.2, 1.5, true),
        "w5mfm3zx6hs": (138.00, 0.364, -6.5, 35.9, false), "wXEwMBdTaow": (125.73, 0.165, -76.5, 64.8, false),
        "FXk4oLgkKL0": (133.00, 0.378, -1.0, 15.6, false), "R1kOdTm9FBk": (95.99, 0.356, -106.2, 22.0, false),
    ]

    private nonisolated static func f(_ x: Double, _ d: Int = 1) -> String { x.isNaN ? "n/a" : String(format: "%.\(d)f", x) }

    private nonisolated static func trusted(_ g: MusicBeatGrid) -> Bool {
        MusicBeatGrid.periodRange.contains(g.periodSec) && g.beatConfidence >= MusicBeatPlanner.minConfidence
            && g.intervalSpread <= MusicBeatPlanner.maxIntervalSpread && abs(g.driftSec) <= MusicBeatPlanner.maxDriftSec
    }

    private nonisolated static func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }

    /// Second order Butterworth high or low pass (RBJ), applied twice for a 4th order slope.
    private nonisolated static func filtered(_ x: [Float], rate: Double, highpass: Bool, cutoff: Double) -> [Float] {
        let w = 2 * Double.pi * cutoff / rate, alpha = sin(w) / (2 * 0.70710678), a0 = 1 + alpha, c = cos(w)
        let b0 = Float((highpass ? (1 + c) / 2 : (1 - c) / 2) / a0), b1 = Float((highpass ? -(1 + c) : (1 - c)) / a0)
        let a1 = Float(-2 * c / a0), a2 = Float((1 - alpha) / a0)
        var y = x
        for _ in 0..<2 {
            var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
            for i in 0..<y.count {
                let input = y[i]
                let out = b0 * input + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2
                y[i] = out; x2 = x1; x1 = input; y2 = y1; y1 = out
            }
        }
        return y
    }

    /// Offset, per beat of the grid, of where the 4 ms amplitude envelope last stays under 20% of its local peak before that
    /// peak (peak searched from 30 ms before to 100 ms after the beat, walk back at most 150 ms; a beat with no such quiet
    /// moment is skipped). The median over the beats. Seconds.
    private nonisolated static func riseStartOffset(_ x: [Float], rate: Double, grid g: MusicBeatGrid) -> Double {
        let w = max(2, Int(0.004 * rate))
        var env = [Float](repeating: 0, count: x.count)
        var run: Float = 0
        for i in 0..<x.count {
            run += x[i] * x[i]
            if i >= w { run -= x[i - w] * x[i - w] }
            env[i] = (max(run, 0) / Float(w)).squareRoot()
        }
        let first = Int(ceil((g.spanStartSec - g.anchorSec) / g.periodSec)), last = Int(floor((g.spanEndSec - g.anchorSec) / g.periodSec))
        guard first <= last else { return .nan }
        var offsets: [Double] = []
        for k in first...last {
            let p = g.anchorSec + Double(k) * g.periodSec
            let c = Int(p * rate)
            let lo = c - Int(0.03 * rate), hi = c + Int(0.1 * rate)
            guard lo > Int(0.2 * rate), hi < x.count else { continue }
            var peak = lo
            for i in lo...hi where env[i] > env[peak] { peak = i }
            let level = 0.2 * env[peak], floorIndex = peak - Int(0.15 * rate)
            var i = peak
            while i > floorIndex, env[i] >= level { i -= 1 }
            if i > floorIndex { offsets.append(Double(i) / rate - p) }
        }
        return median(offsets)
    }

    /// What the measure reads on kicks whose start is known: subtracted from the songs' readings.
    @MainActor private static func calibration() -> Double {
        let track = BeatSynth.pulse(bpm: 120, seconds: 40, offset: 0.3, click: false)
        let (audio, rate) = MusicBeatPhaseTests.decimated(track)
        let g = MusicBeatGrid(
            periodSec: 0.5, anchorSec: 0.3, downbeatPhase: nil, beatConfidence: 1, downbeatConfidence: 0,
            intervalSpread: 0, driftSec: 0, spanStartSec: 1, spanEndSec: 38
        )
        return bassOffset(audio, rate, g)
    }

    private nonisolated static func bassOffset(_ audio: [Float], _ rate: Double, _ g: MusicBeatGrid) -> Double {
        let band = filtered(filtered(audio, rate: rate, highpass: true, cutoff: 40), rate: rate, highpass: false, cutoff: 100)
        return riseStartOffset(band, rate: rate, grid: g)
    }

    @Test("per song: before and after, the cross-check, and the guarantees")
    func evaluate() async throws {
        let root = "/Volumes/Storage/_test/deci-3c/songs"
        let ids = try String(contentsOfFile: root + "/ids.txt", encoding: .utf8).split(separator: "\n").map(String.init)
        let cal = await Self.calibration()
        var report = "BEAT FINDER REAL SONGS (before = 6575e52 diagnosis, after = production analyzer now)\n"
        report += "calibration on a synthetic kick with known start: 40-100 Hz measure reads \(Self.f(cal * 1000))ms\n"
        report += "id | bpm before>after | conf before>after | median residual ms before>after | jitter ms before>after | on-phase/best off-phase rate | trusted before>after | xcheck 40-100 Hz ms (calibrated)\n"
        var trustedBefore = 0, trustedAfter = 0
        for id in ids {
            guard let old = Self.before[id],
                  let file = (try? FileManager.default.contentsOfDirectory(atPath: root))?
                    .first(where: { $0.hasPrefix(id + ".") && !$0.hasSuffix(".part") }) else { continue }
            let url = URL(fileURLWithPath: root + "/" + file)
            let result = try await MusicFileAnalyzer.analyze(file: url, exactDuration: nil)
            let analysis = MusicAnalysis(videoId: id, result: result, source: .playbackCache)
            let (audio, rate) = try await GridGateDiagnosisTests.decode(url)
            guard let g = analysis.usableGrid else {
                report += "\(id): NO GRID\n"
                #expect(!old.trusted, "\(id) was trusted and lost its grid")
                continue
            }
            // Residual and jitter: to the finder's own attack start nearest each grid beat (inliers within 30 ms).
            let band = MusicBeatFinder.bassBand(audio, rate: rate)
            let onsets = MusicBeatFinder.bassOnsets(in: band)
            let first = Int(ceil((g.spanStartSec - g.anchorSec) / g.periodSec)), last = Int(floor((g.spanEndSec - g.anchorSec) / g.periodSec))
            var residuals: [Double] = []
            for k in first...last {
                let p = g.anchorSec + Double(k) * g.periodSec
                if let n = onsets.filter({ abs($0.time - p) <= 0.06 }).min(by: { abs($0.time - p) < abs($1.time - p) }), abs(n.time - p) <= 0.03 {
                    residuals.append(n.time - p)
                }
            }
            let med = Self.median(residuals)
            let jitter = 1.4826 * Self.median(residuals.map { abs($0 - med) })
            let isTrusted = Self.trusted(g)
            // The raw refinement of the same song: hit rate on-phase and the best off-phase rate (held-out beats).
            let found = MusicBeatFinder.analyze(decimated: audio, rate: rate)
            var rates = "n/a"
            if let fit = MusicBeatFinder.fitGrid(found.beats), let firstBeat = found.beats.first, let lastBeat = found.beats.last {
                let a = Int(((firstBeat - fit.start) / fit.period).rounded()), b = Int(((lastBeat - fit.start) / fit.period).rounded())
                if a < b, let r = MusicBeatFinder.refine(band: band, period: fit.period, anchor: fit.start, beats: a...b) {
                    rates = "\(Self.f(Double(r.onRate), 3))/\(Self.f(Double(r.offRate), 3))"
                }
            }
            let x40 = Self.bassOffset(audio, rate, g) - cal
            if old.trusted { trustedBefore += 1 }
            if isTrusted { trustedAfter += 1 }
            report += "\(id) | \(Self.f(old.bpm, 2))>\(Self.f(g.bpm, 2)) | \(Self.f(old.conf, 3))>\(Self.f(Double(g.beatConfidence), 3))"
                + " | \(Self.f(old.resMs))>\(Self.f(med * 1000)) | \(Self.f(old.jitterMs))>\(Self.f(jitter * 1000))"
                + " | \(rates) | \(old.trusted ? "yes" : "no")>\(isTrusted ? "yes" : "no")"
                + " | \(Self.f(x40 * 1000))\(isTrusted && !old.trusted ? " | NEW" : "")\n"
            #expect(!(old.trusted && !isTrusted), "\(id) was trusted and no longer is")
            if isTrusted {
                #expect(abs(med) <= 0.010, "\(id) admitted with median residual \(med * 1000) ms")
                if !old.trusted { #expect(abs(x40) <= 0.010, "\(id) cross-check \(x40 * 1000) ms") }
            }
        }
        report += "trusted before \(trustedBefore), after \(trustedAfter)\n"
        try report.write(toFile: "/Volumes/Storage/_test/deci-3c/finder-eval.txt", atomically: true, encoding: .utf8)
    }
}
