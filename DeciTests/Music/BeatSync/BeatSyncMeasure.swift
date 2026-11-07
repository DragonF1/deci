// DeciTests/Music/BeatSync/BeatSyncMeasure.swift
// The pure helpers of the beat sync spike (tier 3a): click tracks, a per-band matched-filter click finder, and the
// comparison of B's clicks against A's beat grid. No audio device, no capture, nothing from the app.

import Foundation
import Accelerate

nonisolated enum BeatSyncSignal {
    static let bpm = 120.0
    static let beatPeriod = 60.0 / bpm
    /// Where the first burst is centred, in seconds from the start of the file. Not 0, so no burst is cut by the start.
    static let firstCenter = 0.25
    /// A burst is a Hann-windowed sine this long: short enough to be a click, long enough to sit in a narrow band.
    static let burstSeconds = 0.006

    /// A mono click track: one burst per beat, centres at `firstCenter + k * beatPeriod (+ centreShift)`.
    static func clickTrack(
        frequency: Double, sampleRate: Double, seconds: Double, amplitude: Float = 0.5, centreShift: Double = 0
    ) -> [Float] {
        let frames = max(0, Int(seconds * sampleRate))
        var track = [Float](repeating: 0, count: frames)
        let half = burstSeconds / 2
        var beat = 0
        while true {
            let centre = firstCenter + Double(beat) * beatPeriod + centreShift
            if centre - half > seconds { break }
            let first = max(0, Int(((centre - half) * sampleRate).rounded(.up)))
            let last = min(frames - 1, Int(((centre + half) * sampleRate).rounded(.down)))
            if first <= last {
                for frame in first...last {
                    let offset = Double(frame) / sampleRate - centre
                    let window = 0.5 * (1 + cos(Double.pi * offset / half))
                    track[frame] = amplitude * Float(window * cos(2 * Double.pi * frequency * offset))
                }
            }
            beat += 1
        }
        return track
    }
}

nonisolated enum ClickDetector {
    /// The centres, in seconds from the first sample, of the bursts of `frequency` in `samples`: a quadrature matched
    /// filter (the burst's window times a cosine and a sine), its envelope's peaks, each refined with a parabola.
    /// Peaks need 0.4 times the strongest one, and are at least 0.1 s apart.
    static func detect(
        _ samples: [Float], sampleRate: Double, frequency: Double, burstSeconds: Double = BeatSyncSignal.burstSeconds
    ) -> [Double] {
        let length = max(8, Int((burstSeconds * sampleRate).rounded()))
        guard samples.count > length, sampleRate > 0, frequency > 0 else { return [] }
        let centreIndex = Double(length - 1) / 2
        var cosine = [Float](repeating: 0, count: length)
        var sine = [Float](repeating: 0, count: length)
        for index in 0..<length {
            let offset = Double(index) - centreIndex
            let window = 0.5 * (1 + cos(Double.pi * offset / (Double(length) / 2)))
            let phase = 2 * Double.pi * frequency * offset / sampleRate
            cosine[index] = Float(window * cos(phase))
            sine[index] = Float(window * sin(phase))
        }
        let outCount = samples.count - length + 1
        var inPhase = [Float](repeating: 0, count: outCount)
        var quadrature = [Float](repeating: 0, count: outCount)
        vDSP_conv(samples, 1, cosine, 1, &inPhase, 1, vDSP_Length(outCount), vDSP_Length(length))
        vDSP_conv(samples, 1, sine, 1, &quadrature, 1, vDSP_Length(outCount), vDSP_Length(length))
        var envelope = [Float](repeating: 0, count: outCount)
        for index in 0..<outCount { envelope[index] = (inPhase[index] * inPhase[index] + quadrature[index] * quadrature[index]).squareRoot() }
        let strongest = envelope.max() ?? 0
        guard strongest > 1e-6 else { return [] }
        let threshold = 0.4 * strongest
        let separation = max(1, Int(0.1 * sampleRate))

        var times: [Double] = []
        var index = 0
        while index < outCount {
            guard envelope[index] >= threshold else { index += 1; continue }
            // The highest point of this stretch above the threshold.
            var peak = index
            var cursor = index
            while cursor < outCount, envelope[cursor] >= threshold {
                if envelope[cursor] > envelope[peak] { peak = cursor }
                cursor += 1
            }
            var position = Double(peak)
            if peak > 0, peak + 1 < outCount {
                let left = Double(envelope[peak - 1])
                let middle = Double(envelope[peak])
                let right = Double(envelope[peak + 1])
                let denominator = left - 2 * middle + right
                if denominator < 0 { position += 0.5 * (left - right) / denominator }
            }
            times.append((position + centreIndex) / sampleRate)
            index = max(cursor, peak + separation)
        }
        return times
    }
}

/// How well B's clicks sit on the grid they were meant to follow, in milliseconds.
nonisolated struct BeatSyncStats: Equatable, Sendable {
    /// The error line's value at B's first click (the fit's intercept).
    var startErrorMs: Double
    /// The error of B's very first click.
    var firstErrorMs: Double
    var meanErrorMs: Double
    /// Largest minus smallest error over the overlap.
    var driftMs: Double
    /// The fitted line's rise over the overlap.
    var slopeDriftMs: Double
    /// Standard deviation of the errors around the fitted line.
    var jitterMs: Double
    var matched: Int
    var errorsMs: [Double]
}

nonisolated enum BeatGrid {
    /// A's clicks give the grid: its fitted line `time(k)`. B started on A's beat `startBeat` (B's media time 0 at A's
    /// media time `startBeat * period`) and plays at `rate`, so B's click j is expected at
    /// `time(startBeat) - firstCenter + (firstCenter + j * period) / rate`. Each of B's clicks is matched to the nearest j;
    /// nil when there is nothing to compare, or a click is further than a quarter beat from its expected place.
    static func compare(
        aOnsets: [Double], bOnsets: [Double], startBeat: Int, rate: Double,
        firstCenter: Double = BeatSyncSignal.firstCenter, period: Double = BeatSyncSignal.beatPeriod
    ) -> BeatSyncStats? {
        guard rate.isFinite, rate > 0, aOnsets.count >= 2, startBeat >= 0, startBeat < aOnsets.count, !bOnsets.isEmpty
        else { return nil }
        let (intercept, slope) = fitLine(x: aOnsets.indices.map(Double.init), y: aOnsets)
        let startHost = intercept + slope * Double(startBeat) - firstCenter
        func expected(_ j: Int) -> Double { startHost + (firstCenter + Double(j) * period) / rate }

        var errors: [Double] = []
        var indices: [Double] = []
        for time in bOnsets {
            let j = Int((((time - startHost) * rate - firstCenter) / period).rounded())
            guard j >= 0 else { return nil }
            let error = time - expected(j)
            guard abs(error) < period / 4 else { return nil }
            errors.append(error * 1000)
            indices.append(Double(j))
        }
        let (start, rise) = fitLine(x: indices, y: errors)
        let residuals = zip(indices, errors).map { $1 - (start + rise * $0) }
        let mean = errors.reduce(0, +) / Double(errors.count)
        let jitter = (residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count)).squareRoot()
        let span = (indices.last ?? 0) - (indices.first ?? 0)
        return BeatSyncStats(
            startErrorMs: start + rise * (indices.first ?? 0),
            firstErrorMs: errors[0],
            meanErrorMs: mean,
            driftMs: (errors.max() ?? 0) - (errors.min() ?? 0),
            slopeDriftMs: rise * span,
            jitterMs: jitter,
            matched: errors.count,
            errorsMs: errors
        )
    }

    /// Least squares `y = intercept + slope * x`.
    static func fitLine(x: [Double], y: [Double]) -> (intercept: Double, slope: Double) {
        let n = Double(x.count)
        guard n >= 2 else { return (y.first ?? 0, 0) }
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        var covariance = 0.0
        var variance = 0.0
        for (px, py) in zip(x, y) {
            covariance += (px - meanX) * (py - meanY)
            variance += (px - meanX) * (px - meanX)
        }
        guard variance > 0 else { return (meanY, 0) }
        let slope = covariance / variance
        return (meanY - slope * meanX, slope)
    }
}

/// Mean and spread of one number across runs.
nonisolated struct BeatSyncSummary: Equatable, Sendable {
    let mean: Double
    let stdev: Double
    let minimum: Double
    let maximum: Double

    init(_ values: [Double]) {
        guard !values.isEmpty else {
            mean = 0; stdev = 0; minimum = 0; maximum = 0
            return
        }
        let average = values.reduce(0, +) / Double(values.count)
        mean = average
        stdev = (values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count)).squareRoot()
        minimum = values.min() ?? 0
        maximum = values.max() ?? 0
    }
}
