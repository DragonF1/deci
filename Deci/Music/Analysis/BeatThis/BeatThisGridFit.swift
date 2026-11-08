// Deci/Music/Analysis/BeatThis/BeatThisGridFit.swift
// From beat_this beat and downbeat times to a stored MusicBeatGrid: one straight line through the beats.
//  - Beats are numbered by rounding each interval over the median interval; a least squares line t = a + k p is fitted
//    and beats more than `outlierSec` off it are dropped and the line refitted.
//  - The period is folded into MusicBeatGrid.periodRange by doubling or halving (the anchor stays on a beat).
//  - beatConfidence: fraction of all beat_this beats within `toleranceSec` of the final line.
//  - intervalSpread: robust spread (1.4826 MAD / median) of the 4-beat intervals divided by 4. A single interval is
//    quantised to the 20 ms frame, which alone would read as a 4 percent spread at 130 bpm; four beats average it down
//    while a real tempo wobble still shows.
//  - driftSec: slope of a line fitted to the second half of the beats minus the slope of the first half.
//  - downbeatPhase: the most common (line index of a downbeat) mod 4, downbeatConfidence its share of the downbeats.

import Foundation

nonisolated enum BeatThisGridFit {
    static let minBeats = 8
    static let toleranceSec = 0.07
    static let outlierSec = 0.07

    static func grid(beats: [Double], downbeats: [Double], duration: Double) -> MusicBeatGrid? {
        let times = beats.filter(\.isFinite).sorted()
        guard times.count >= minBeats, duration.isFinite, duration > 0 else { return nil }
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }
        let median = Self.median(intervals)
        guard median > 0 else { return nil }

        // Number the beats.
        var index = [0]
        for dt in intervals { index.append(index[index.count - 1] + max(1, Int((dt / median).rounded()))) }
        var points = zip(index, times).map { (Double($0), $1) }
        guard var line = lineFit(points) else { return nil }
        let kept = points.filter { abs($0.1 - (line.intercept + line.slope * $0.0)) <= outlierSec }
        if kept.count >= minBeats, kept.count < points.count, let refit = lineFit(kept) { line = refit; points = kept }
        guard line.slope > 0 else { return nil }

        var period = line.slope
        let anchor = line.intercept + points[0].0 * line.slope
        // Fold into range. Halving the tempo keeps every second beat; doubling it adds the beats in between.
        while period < MusicBeatGrid.periodRange.lowerBound { period *= 2 }
        while period > MusicBeatGrid.periodRange.upperBound { period /= 2 }
        guard MusicBeatGrid.periodRange.contains(period) else { return nil }

        func nearest(_ t: Double) -> Int { Int(((t - anchor) / period).rounded()) }
        let hits = times.filter { abs($0 - (anchor + Double(nearest($0)) * period)) <= toleranceSec }.count
        let confidence = Float(hits) / Float(times.count)

        // Spread of the 4-beat intervals (per beat), over the beats that sit on the line.
        var spread: Float = 0
        if times.count > 4 {
            let lag = zip(times.dropFirst(4), times).map { ($0 - $1) / 4 }
            let m = Self.median(lag)
            if m > 0 { spread = Float(1.4826 * Self.median(lag.map { abs($0 - m) }) / m) }
        }

        // Drift: second half slope minus first half slope.
        var drift: Float = 0
        let middle = points.count / 2
        if middle >= 4, points.count - middle >= 4,
           let first = lineFit(Array(points[..<middle])), let second = lineFit(Array(points[middle...])) {
            drift = Float((second.slope - first.slope) * (period / line.slope))
        }

        var phase: Int?
        var phaseConfidence: Float = 0
        if !downbeats.isEmpty {
            var counts = [0, 0, 0, 0]
            for d in downbeats { counts[((nearest(d) % 4) + 4) % 4] += 1 }
            if let best = counts.indices.max(by: { counts[$0] < counts[$1] }) {
                phase = best
                phaseConfidence = Float(counts[best]) / Float(downbeats.count)
            }
        }

        let first = max(0, anchor + Double(nearest(times[0])) * period)
        let last = min(duration, anchor + Double(nearest(times[times.count - 1])) * period)
        let grid = MusicBeatGrid(
            periodSec: period, anchorSec: anchor, downbeatPhase: phase, beatConfidence: confidence,
            downbeatConfidence: phaseConfidence, intervalSpread: spread, driftSec: drift, spanStartSec: first, spanEndSec: last
        )
        guard grid.spanEndSec > grid.spanStartSec, grid.bpm.isFinite else { return nil }
        return grid
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
}
