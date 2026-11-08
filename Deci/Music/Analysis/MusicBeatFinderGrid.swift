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
    static let onsetPeakSeparationSec = 0.04
    static let phasePeakednessMin = 3.0
    /// The attack starts where the rise is this fraction of its peak. A quarter caught the foot of a sustained note and
    /// scattered the start of a loud and a soft kick by 10 to 20 ms on real songs; the half rise point does not.
    static let attackStartFraction: Float = 0.35
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
            if band.flux[index] > attackStartFraction * strength { start = index }
        }
        return (Double(start) / band.rate - bassOnsetBiasSec, strength)
    }

    /// One bass attack found without any prediction: its start time (as `onset(near:)` defines it) and the rise's strength.
    struct BassOnset {
        var time: Double
        var strength: Float
        /// Where the rise is steepest.
        var peakTime: Double = 0
    }

    /// Every bass attack of the song. Peaks of the bass rise, at least `onsetPeakSeparationSec` apart and at least
    /// `onsetFloorFraction` of the 75th percentile peak, each walked back to its start. The search no longer depends on
    /// where a grid is predicted (the old per-beat window chose a different hump of a sustained note for a different
    /// prediction, so the same song measured differently from different starting grids).
    static func bassOnsets(in band: Band) -> [BassOnset] {
        let count = band.flux.count
        let radius = max(1, Int((onsetPeakSeparationSec * band.rate).rounded()))
        let width = 2 * radius + 1
        guard count > width else { return [] }
        var slidingMax = [Float](repeating: 0, count: count)
        band.flux.withUnsafeBufferPointer { flux in
            vDSP_vswmax(flux.baseAddress!, 1, &slidingMax[radius], 1, vDSP_Length(count - width + 1), vDSP_Length(width))
        }
        var peaks: [Int] = []
        for index in radius..<(count - radius) where band.flux[index] > 0 && band.flux[index] == slidingMax[index] {
            if let last = peaks.last, index - last <= radius {
                if band.flux[index] > band.flux[last] { peaks[peaks.count - 1] = index }
            } else {
                peaks.append(index)
            }
        }
        guard !peaks.isEmpty else { return [] }
        let sorted = peaks.map { band.flux[$0] }.sorted()
        let floorStrength = Float(onsetFloorFraction) * sorted[sorted.count * 3 / 4]
        let gap = Int((attackGapSec * band.rate).rounded())
        var result: [BassOnset] = []
        for peak in peaks where band.flux[peak] >= floorStrength {
            let strength = band.flux[peak]
            var start = peak
            var index = peak
            let floor = max(0, peak - Int((0.12 * band.rate).rounded()))
            while index > floor, start - index <= gap {
                index -= 1
                if band.flux[index] > attackStartFraction * strength { start = index }
            }
            result.append(BassOnset(time: Double(start) / band.rate - bassOnsetBiasSec, strength: strength, peakTime: Double(peak) / band.rate))
        }
        return result
    }

    static func refine(band: Band, period: Double, anchor anchor0: Double, beats: ClosedRange<Int>) -> BassRefinement? {
        guard period > 0, !beats.isEmpty else { return nil }
        let duration = Double(band.flux.count) / band.rate
        let onsets = bassOnsets(in: band).filter { $0.time >= anchor0 + Double(beats.lowerBound) * period - period / 2
            && $0.time <= anchor0 + Double(beats.upperBound) * period + period / 2 }
        guard onsets.count >= 4 else { return nil }
        let total = beats.count

        // Phase: each onset's offset from its nearest beat of the finder grid, over the whole period. The fullest
        // 2 * hitToleranceSec neighbourhood of the (strength weighted) histogram is where the bass attacks.
        var line = (anchor: anchor0, period: period)
        var offsets: [(offset: Double, weight: Double)] = []
        let typical = Double(onsets.map(\.strength).sorted()[onsets.count / 2])
        for onset in onsets {
            let k = ((onset.time - anchor0) / period).rounded()
            offsets.append((onset.time - (anchor0 + k * period), min(2, Double(onset.strength) / max(typical, 1e-12))))
        }
        if let mode = phaseMode(offsets, period: period) { line.anchor = anchor0 + mode }

        // Then the line through the attacks within tolerance of it, twice: the second pass sees the corrected period.
        for pass in 0..<2 {
            let tolerance = pass == 0 ? 0.015 : hitToleranceSec
            var points: [(Double, Double)] = []
            var bestFor: [Int: (time: Double, strength: Float)] = [:]
            for onset in onsets {
                let k = Int(((onset.time - line.anchor) / line.period).rounded())
                guard abs(onset.time - (line.anchor + Double(k) * line.period)) < tolerance else { continue }
                if let held = bestFor[k], held.strength >= onset.strength { continue }
                bestFor[k] = (onset.time, onset.strength)
            }
            for (k, hit) in bestFor { points.append((Double(k), hit.time)) }
            if points.count >= 8, let fit = lineFit(points), abs(fit.slope / period - 1) < 0.03 {
                line = (fit.intercept, fit.slope)
            }
        }

        // A least squares line follows a lopsided cloud of attacks (a bass note trailing its kick) away from the dense
        // core, so the anchor takes the shift of up to one tolerance that puts the most beats on an attack.
        func hitCount(_ anchor: Double) -> Int {
            var count = 0, cursor = 0
            for k in beats {
                let predicted = anchor + Double(k) * line.period
                while cursor < onsets.count, onsets[cursor].time < predicted - hitToleranceSec { cursor += 1 }
                if cursor < onsets.count, onsets[cursor].time <= predicted + hitToleranceSec { count += 1 }
            }
            return count
        }
        var bestShifts: [Double] = []
        var bestCount = -1
        for step in -10...10 {
            let shift = Double(step) * 0.001
            let count = hitCount(line.anchor + shift)
            if count > bestCount { bestCount = count; bestShifts = [shift] } else if count == bestCount { bestShifts.append(shift) }
        }
        line.anchor += bestShifts.reduce(0, +) / Double(bestShifts.count)

        // The strongest attack within the old search window of each beat; a hit when it sits within tolerance.
        var after: [(Int, Double)] = []
        var hits = 0
        var cursor = 0
        for k in beats {
            let predicted = line.anchor + Double(k) * line.period
            guard predicted - refineWindowSec >= 0, predicted + refineWindowSec <= duration else { continue }
            while cursor < onsets.count, onsets[cursor].time < predicted - refineWindowSec { cursor += 1 }
            var best: BassOnset?
            var probe = cursor
            while probe < onsets.count, onsets[probe].time <= predicted + refineWindowSec {
                if best == nil || onsets[probe].strength > best!.strength { best = onsets[probe] }
                probe += 1
            }
            guard let best else { continue }
                // The closest attack to the beat is its hit when it is within tolerance, else the strongest in reach.
            var nearest = best
            probe = cursor
            while probe < onsets.count, onsets[probe].time <= predicted + refineWindowSec {
                if abs(onsets[probe].time - predicted) < abs(nearest.time - predicted) { nearest = onsets[probe] }
                probe += 1
            }
            let hit = abs(nearest.time - predicted) <= hitToleranceSec ? nearest : best
            after.append((k, hit.time - predicted))
            if abs(hit.time - predicted) <= hitToleranceSec { hits += 1 }
        }
        guard after.count >= 4 else { return nil }
        let middle = Double(beats.lowerBound + beats.upperBound) / 2
        let early = after.filter { Double($0.0) < middle }.map(\.1), late = after.filter { Double($0.0) >= middle }.map(\.1)
        var drift: Float = 0
        if early.count >= 4, late.count >= 4 {
            drift = Float((median(late) - median(early)) / max(1, Double(total) / 2))
        }
        return BassRefinement(
            anchor: line.anchor, period: line.period, confidence: min(1, Float(hits) / Float(total)), drift: drift
        )
    }

    /// The offset (in -period/2 ..< period/2) with the most weight within `hitToleranceSec` either side, as the weighted
    /// median of the offsets inside that neighbourhood. Offsets are counted circularly.
    /// nil unless that neighbourhood holds at least `phasePeakednessMin` times the weight an even spread would put there:
    /// onsets with no common phase (noise, or a song without a beat in the bass) leave the finder's anchor alone.
    static func phaseMode(_ offsets: [(offset: Double, weight: Double)], period: Double) -> Double? {
        let binWidth = 0.002
        let bins = max(1, Int((period / binWidth).rounded(.up)))
        var weights = [Double](repeating: 0, count: bins)
        for (offset, weight) in offsets {
            let index = Int(((offset + period / 2) / binWidth).rounded(.down))
            weights[((index % bins) + bins) % bins] += weight
        }
        let reach = Int((hitToleranceSec / binWidth).rounded())
        var bestIndex = 0, bestScore = -1.0
        for index in 0..<bins {
            var score = 0.0
            for d in -reach...reach { score += weights[((index + d) % bins + bins) % bins] }
            if score > bestScore { bestScore = score; bestIndex = index }
        }
        let total = weights.reduce(0, +)
        let even = total * Double(2 * reach + 1) * binWidth / period
        guard total > 0, bestScore >= phasePeakednessMin * even else { return nil }
        let centre = (Double(bestIndex) + 0.5) * binWidth - period / 2
        let inside = offsets.filter {
            var d = $0.offset - centre
            d -= (d / period).rounded() * period
            return abs(d) <= hitToleranceSec
        }.map { $0.offset }
        let wrapped = inside.map { value -> Double in
            var d = value - centre
            d -= (d / period).rounded() * period
            return d
        }
        return centre + median(wrapped)
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
