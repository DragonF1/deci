// Deci/Music/Analysis/MusicBeatFinderGrid.swift
// From a beat finder result to a stored beat grid (tier 3b). The finder's beat times sit on the broadband flux and ran
// about 28 ms early on real kicks, so the phase is refined on the bass band: low-pass about 120 Hz, a smoothed
// onset flux, and per beat the attack found within +/-60 ms of the fitted grid. The anchor shifts by the robust median
// of those residuals (mode of a 2 ms histogram), then a line through the inlier onsets also fixes the period.
// Every song gets the same onset definition, so whatever bias is left cancels between two songs of a mix.

import Foundation
import Accelerate

nonisolated extension MusicBeatFinder {
    // MARK: Parameters

    static let bassCutoffHz = 120.0
    static let refineWindowSec = 0.06
    static let hitToleranceSec = 0.010
    /// A beat onset must be this fraction of the median beat onset strength to count.
    static let onsetFloorFraction = 0.15
    /// Below this finder confidence there is no grid at all.
    static let minGridFinderConfidence = 0.3
    /// Below this downbeat confidence the downbeat is reported unknown.
    static let minDownbeatConfidence = 0.25
    static let minDownbeatBeats = 16
    /// Where the bass attack detector lands relative to the true attack on a synthetic kick, subtracted from every onset.
    static let bassOnsetBiasSec = 0.001
    /// A pause this long in the rise ends the attack walk.
    static let attackGapSec = 0.008

    /// What `refine` learned about one song.
    struct BassRefinement {
        var anchor: Double
        var period: Double
        var confidence: Float
        var drift: Float
    }

    /// The bass band of a song: rectified, smoothed envelope and its rising edge, both at the decimated rate.
    struct Band {
        var env: [Float]
        var flux: [Float]
        var rate: Double
    }

    // MARK: Entry points

    /// The refined beat phase. `anchor` and `period` come from the finder's fit; the result keeps the period unless the
    /// bass onsets fit a slightly different one. Confidence is the fraction of beats within +/-10 ms of the new grid.
    static func refineOnBass(
        decimated: [Float], rate: Double, period: Double, anchor: Double
    ) -> (anchor: Double, confidence: Float) {
        guard period > 0, period.isFinite, anchor.isFinite, rate > 0 else { return (anchor, 0) }
        let band = bassBand(decimated, rate: rate)
        guard !Task.isCancelled else { return (anchor, 0) }
        let last = Int(floor((Double(decimated.count) / rate - anchor) / period))
        let first = Int(ceil(-anchor / period))
        guard first <= last, let refined = refine(band: band, period: period, anchor: anchor, beats: first...last) else {
            return (anchor, 0)
        }
        return (refined.anchor, refined.confidence)
    }

    /// nil when the finder found no tempo or is not sure of it. A song whose bass refinement fails still gets a grid
    /// (on the finder's own fit) with confidence 0, which every consumer gates out.
    static func grid(from result: MusicBeatResult, decimated: [Float], rate: Double) -> MusicBeatGrid? {
        guard !result.isEmpty, result.confidence >= minGridFinderConfidence, result.beats.count >= 8,
              let fit = fitGrid(result.beats), fit.period > 0 else { return nil }
        let first = Int(((result.beats[0] - fit.start) / fit.period).rounded())
        let last = Int(((result.beats[result.beats.count - 1] - fit.start) / fit.period).rounded())
        guard first < last else { return nil }
        let band = bassBand(decimated, rate: rate)
        guard !Task.isCancelled else { return nil }
        let refined = refine(band: band, period: fit.period, anchor: fit.start, beats: first...last)
        let anchor = refined?.anchor ?? fit.start
        let period = refined?.period ?? fit.period
        let duration = Double(decimated.count) / rate

        var grid = MusicBeatGrid(
            periodSec: period, anchorSec: anchor, downbeatPhase: nil,
            beatConfidence: refined?.confidence ?? 0, downbeatConfidence: 0,
            intervalSpread: Float(result.intervalSpread), driftSec: refined?.drift ?? 0,
            spanStartSec: max(0, anchor + Double(first) * period),
            spanEndSec: min(duration, anchor + Double(last) * period)
        )
        guard grid.spanEndSec > grid.spanStartSec, grid.bpm.isFinite else { return nil }
        if refined != nil, let downbeat = estimateGridDownbeat(band: band, grid: grid, beats: first...last) {
            grid.downbeatConfidence = Float(downbeat.confidence)
            grid.downbeatPhase = downbeat.confidence >= minDownbeatConfidence ? downbeat.phase : nil
        }
        return grid
    }

    // MARK: Bass band

    /// Two Butterworth biquads (4th order) at `bassCutoffHz`, rectified, 3 ms moving average, then a 2 ms centred rise.
    /// Memory: at most two song-length Float arrays are alive at once besides the input (the filtered signal is rectified
    /// in place, then freed once the envelope exists). An empty band comes back when the task is cancelled.
    static func bassBand(_ audio: [Float], rate: Double) -> Band {
        let count = audio.count
        var low = lowPass(audio, rate: rate)
        guard !Task.isCancelled, count > 0 else { return Band(env: [], flux: [], rate: rate) }
        vDSP_vabs(low, 1, &low, 1, vDSP_Length(count))

        let width = max(1, Int((0.003 * rate).rounded())) | 1
        let half = width / 2
        var env = [Float](repeating: 0, count: count)
        if count >= width {
            // env[i + half] = sum of low[i ..< i + width]; the first and last `half` samples see a zero-padded window.
            vDSP_vswsum(low, 1, &env[half], 1, vDSP_Length(count - width + 1), vDSP_Length(width))
        }
        let edges = count >= width ? Array(0..<half) + Array((count - half)..<count) : Array(0..<count)
        for index in edges {
            var sum: Float = 0
            for tap in max(0, index - half)...min(count - 1, index + half) { sum += low[tap] }
            env[index] = sum
        }
        low = []
        var scale = 1 / Float(width)
        vDSP_vsmul(env, 1, &scale, &env, 1, vDSP_Length(count))

        let step = max(1, Int((0.001 * rate).rounded()))
        var flux = [Float](repeating: 0, count: count)
        if count > 2 * step {
            let inner = vDSP_Length(count - 2 * step)
            env.withUnsafeBufferPointer { e in
                // flux[i] = env[i + step] - env[i - step], for i in step..<(count - step); vsub computes B - A.
                vDSP_vsub(e.baseAddress!, 1, e.baseAddress! + 2 * step, 1, &flux[step], 1, inner)
            }
            var zero: Float = 0
            vDSP_vthr(flux, 1, &zero, &flux, 1, vDSP_Length(count))
        }
        return Band(env: env, flux: flux, rate: rate)
    }

    /// Zero-state 4th order Butterworth low-pass: two RBJ biquads run as one vDSP cascade in Float.
    static func lowPass(_ audio: [Float], rate: Double) -> [Float] {
        let count = audio.count
        guard count > 0, rate > 0, rate.isFinite else { return [] }
        let w = 2 * Double.pi * min(bassCutoffHz, rate / 4) / rate
        var coefficients: [Double] = []
        for q in [0.5411961, 1.3065630] {
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            coefficients += [(1 - cos(w)) / 2 / a0, (1 - cos(w)) / a0, (1 - cos(w)) / 2 / a0, -2 * cos(w) / a0, (1 - alpha) / a0]
        }
        guard let setup = vDSP_biquad_CreateSetup(coefficients, 2) else { return [] }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 2 * 2 + 2)
        var out = [Float](repeating: 0, count: count)
        audio.withUnsafeBufferPointer { input in
            vDSP_biquad(setup, &delay, input.baseAddress!, 1, &out, 1, vDSP_Length(count))
        }
        return out
    }

    // MARK: Refinement

    /// The attack near `time`: the strongest rise within the window, walked back to where it is a quarter as steep.
    static func onset(near time: Double, in band: Band, window: Double) -> (time: Double, strength: Float)? {
        let count = band.flux.count
        let centre = Int((time * band.rate).rounded())
        let reach = Int((window * band.rate).rounded())
        let lo = max(0, centre - reach), hi = min(count - 1, centre + reach)
        guard lo < hi else { return nil }
        var peak = lo
        for index in lo...hi where band.flux[index] > band.flux[peak] { peak = index }
        let strength = band.flux[peak]
        guard strength > 0 else { return nil }
        // Walk back to the earliest point still a quarter as steep. A rectified low note rises in humps with flat
        // troughs between them, so a gap shorter than `attackGapSec` does not end the attack.
        var start = peak
        let floor = max(0, centre - 2 * reach)
        let gap = Int((attackGapSec * band.rate).rounded())
        var index = peak
        while index > floor, start - index <= gap {
            index -= 1
            if band.flux[index] > 0.25 * strength { start = index }
        }
        return (Double(start) / band.rate - bassOnsetBiasSec, strength)
    }

    static func refine(band: Band, period: Double, anchor: Double, beats: ClosedRange<Int>) -> BassRefinement? {
        guard period > 0, !beats.isEmpty else { return nil }
        var found: [(k: Int, time: Double, strength: Float)] = []
        for k in beats {
            let predicted = anchor + Double(k) * period
            guard predicted - refineWindowSec >= 0, predicted + refineWindowSec <= Double(band.flux.count) / band.rate,
                  let hit = onset(near: predicted, in: band, window: refineWindowSec) else { continue }
            found.append((k, hit.time, hit.strength))
        }
        guard !found.isEmpty else { return nil }
        let strengths = found.map(\.strength).sorted()
        let floorStrength = Float(onsetFloorFraction) * strengths[strengths.count / 2]
        found = found.filter { $0.strength >= floorStrength }
        guard found.count >= 4 else { return nil }

        let total = beats.count
        let residuals = found.map { $0.time - (anchor + Double($0.k) * period) }
        let shift = histogramMode(residuals, binWidth: 0.002)
        var line = (anchor: anchor + shift, period: period)

        let inliers = found.filter { abs($0.time - (line.anchor + Double($0.k) * period)) < 0.015 }
        if inliers.count >= 8, let fit = lineFit(inliers.map { (Double($0.k), $0.time) }),
           abs(fit.slope / period - 1) < 0.03 {
            line = (fit.intercept, fit.slope)
        }
        let hits = found.filter { abs($0.time - (line.anchor + Double($0.k) * line.period)) <= hitToleranceSec }.count
        let confidence = Float(hits) / Float(total)

        let after = found.map { ($0.k, $0.time - (line.anchor + Double($0.k) * line.period)) }
        let middle = Double(beats.lowerBound + beats.upperBound) / 2
        let early = after.filter { Double($0.0) < middle }.map(\.1), late = after.filter { Double($0.0) >= middle }.map(\.1)
        var drift: Float = 0
        if early.count >= 4, late.count >= 4 {
            drift = Float((median(late) - median(early)) / max(1, Double(total) / 2))
        }
        return BassRefinement(anchor: line.anchor, period: line.period, confidence: min(1, confidence), drift: drift)
    }

    /// Centre of the fullest 3-bin neighbourhood, refined by the median of the values inside it.
    static func histogramMode(_ values: [Double], binWidth: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        var counts: [Int: Int] = [:]
        for value in values { counts[Int((value / binWidth).rounded(.down)), default: 0] += 1 }
        let best = counts.keys.max { a, b in
            let scoreA = (a - 1...a + 1).reduce(0) { $0 + (counts[$1] ?? 0) }
            let scoreB = (b - 1...b + 1).reduce(0) { $0 + (counts[$1] ?? 0) }
            return scoreA != scoreB ? scoreA < scoreB : a > b
        } ?? 0
        let inside = values.filter { abs(Int(($0 / binWidth).rounded(.down)) - best) <= 1 }
        return median(inside)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Ordinary least squares y = intercept + slope * x. nil when x does not vary.
    static func lineFit(_ points: [(Double, Double)]) -> (intercept: Double, slope: Double)? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }
        let meanX = points.reduce(0) { $0 + $1.0 } / n, meanY = points.reduce(0) { $0 + $1.1 } / n
        var sxx = 0.0, sxy = 0.0
        for (x, y) in points { sxx += (x - meanX) * (x - meanX); sxy += (x - meanX) * (y - meanY) }
        guard sxx > 1e-9 else { return nil }
        let slope = sxy / sxx
        return (meanY - slope * meanX, slope)
    }

    // MARK: Downbeat

    /// Which of four beat phases (index mod 4 from the anchor) carries the accent: per beat the bass level and the bass
    /// attack, each scaled by its mean, summed, then averaged per phase. Confidence is the best phase's margin over the
    /// second best. nil with too few beats.
    static func estimateGridDownbeat(
        band: Band, grid: MusicBeatGrid, beats: ClosedRange<Int>
    ) -> (phase: Int, confidence: Double)? {
        var level: [(k: Int, bass: Double, attack: Double)] = []
        let count = band.env.count
        for k in beats {
            let t = grid.beatTime(k)
            let lo = Int(((t - 0.01) * band.rate).rounded()), hi = Int(((t + 0.05) * band.rate).rounded())
            guard lo >= 0, hi < count else { continue }
            var bass: Float = 0
            for index in lo...hi { bass = max(bass, band.env[index]) }
            var attack: Float = 0
            for index in max(0, lo - Int(0.02 * band.rate))...min(count - 1, hi) { attack = max(attack, band.flux[index]) }
            level.append((k, Double(bass), Double(attack)))
        }
        guard level.count >= minDownbeatBeats else { return nil }
        let meanBass = level.reduce(0) { $0 + $1.bass } / Double(level.count)
        let meanAttack = level.reduce(0) { $0 + $1.attack } / Double(level.count)
        guard meanBass > 1e-9, meanAttack > 1e-9 else { return nil }
        var sums = [Double](repeating: 0, count: 4), counts = [Double](repeating: 0, count: 4)
        for item in level {
            let phase = ((item.k % 4) + 4) % 4
            sums[phase] += item.bass / meanBass + item.attack / meanAttack
            counts[phase] += 1
        }
        let means = (0..<4).map { counts[$0] > 0 ? sums[$0] / counts[$0] : 0 }
        let order = means.indices.sorted { means[$0] > means[$1] }
        guard means[order[0]] > 0 else { return nil }
        return (order[0], max(0, min(1, (means[order[0]] - means[order[1]]) / means[order[0]])))
    }
}
