// Deci/Music/Analysis/BeatThis/BeatThisGridFit.swift
// From beat_this beat and downbeat times to a stored MusicBeatGrid: one straight line through the beats.
//  - A beat whose interval from the last accepted beat is more than `skipFraction` of a period away from a whole
//    multiple of the median period is skipped (a spurious or half-period beat); the rest are numbered by rounding, a
//    least squares line t = a + k p is fitted, every beat is then renumbered as round((t - a) / p), those more than
//    `outlierSec` off the line are dropped and the line is refitted once.
//  - The period is folded into MusicBeatGrid.periodRange by doubling or halving (the anchor stays on a beat).
//  - beatConfidence: fraction of all beat_this beats within `confidenceSec` of the final line. 70 ms would be near
//    chance at 140 ms per period; 25 ms is a real hit.
//  - intervalSpread: 1.4826 * MAD(residuals of the on-line beats) * sqrt(2) / period, the spread a single beat to
//    beat interval would have, which is what the planner's gate (0.04) was set against. The 20 ms frame quantisation
//    alone reads about 0.017 at 128 bpm; plus or minus 50 ms of rubato about 0.09.
//  - driftSec: slope of a line fitted to the second half of the interval-numbered beats minus the slope of the
//    first half (seconds per beat).
//  - downbeatPhase: the most common (line index of a downbeat) mod 4, set only with at least `minDownbeats` downbeats
//    on the line and a share of `minDownbeatShare` or more of them on that phase, else nil with confidence 0. The
//    planner turns phrase alignment and the bass swap on from the phase alone.

import Foundation

nonisolated enum BeatThisGridFit {
    static let minBeats = 8
    static let outlierSec = 0.07
    static let confidenceSec = 0.025
    static let skipFraction = 0.25
    static let minDownbeats = 8
    static let minDownbeatShare = 0.7

    /// The two downbeat gates are parameters only so the calibration run can read the raw vote.
    static func grid(
        beats: [Double], downbeats: [Double], duration: Double,
        minDownbeats: Int = BeatThisGridFit.minDownbeats, minDownbeatShare: Double = BeatThisGridFit.minDownbeatShare
    ) -> MusicBeatGrid? {
        let times = beats.filter(\.isFinite).sorted()
        guard times.count >= minBeats, duration.isFinite, duration > 0 else { return nil }
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }
        let median = Self.median(intervals)
        guard median > 0 else { return nil }

        // Number the beats that fit the median period; a beat between two grid positions is skipped once (a second
        // one in a row is taken, so a real change of phase is not skipped for ever).
        var accepted: [(Double, Double)] = [(0, times[0])]
        var last = times[0]
        var skipped = false
        for t in times.dropFirst() {
            let ratio = (t - last) / median
            let whole = ratio.rounded()
            if (whole < 1 || abs(ratio - whole) > skipFraction) && !skipped { skipped = true; continue }
            skipped = false
            accepted.append((accepted[accepted.count - 1].0 + max(1, whole), t))
            last = t
        }
        guard let rough = lineFit(accepted), rough.slope > 0 else { return nil }

        // Renumber every beat against the rough line, keep the ones on it (the nearest when two share a number), refit.
        let tolerance = min(outlierSec, skipFraction * rough.slope)
        var nearest: [Int: Double] = [:]
        for t in times {
            let k = Int(((t - rough.intercept) / rough.slope).rounded())
            let miss = abs(t - (rough.intercept + Double(k) * rough.slope))
            guard miss <= tolerance else { continue }
            if let have = nearest[k], abs(have - (rough.intercept + Double(k) * rough.slope)) <= miss { continue }
            nearest[k] = t
        }
        let points = nearest.keys.sorted().map { (Double($0), nearest[$0]!) }
        guard points.count >= minBeats, let line = lineFit(points), line.slope > 0 else { return nil }

        // Statistics against the line as fitted, before the period is folded.
        let lineTime = { (k: Double) in line.intercept + k * line.slope }
        let hits = times.filter { t in
            abs(t - lineTime(((t - line.intercept) / line.slope).rounded())) <= confidenceSec
        }.count
        let confidence = Float(hits) / Float(times.count)
        let residuals = points.map { $0.1 - lineTime($0.0) }
        let centre = Self.median(residuals)
        let mad = Self.median(residuals.map { abs($0 - centre) })
        let spread = Float(1.4826 * mad * 2.0.squareRoot() / line.slope)

        // Drift: second half slope minus first half slope, over the beats numbered by their intervals (a tempo change
        // moves beats far from any single line, so the line's own on-line beats would hide it).
        var drift: Float = 0
        let middle = accepted.count / 2
        if middle >= 4, accepted.count - middle >= 4,
           let first = lineFit(Array(accepted[..<middle])), let second = lineFit(Array(accepted[middle...])) {
            drift = Float(second.slope - first.slope)
        }

        // Fold into range. Halving the tempo keeps every second beat; doubling it adds the beats in between.
        var period = line.slope
        let anchor = lineTime(points[0].0)
        while period < MusicBeatGrid.periodRange.lowerBound { period *= 2 }
        while period > MusicBeatGrid.periodRange.upperBound { period /= 2 }
        guard MusicBeatGrid.periodRange.contains(period) else { return nil }
        if period != line.slope { drift *= Float(period / line.slope) }

        func nearestIndex(_ t: Double) -> Int { Int(((t - anchor) / period).rounded()) }
        var phase: Int?
        var phaseConfidence: Float = 0
        var counts = [0, 0, 0, 0]
        var onLine = 0
        for d in downbeats where d.isFinite {
            let k = nearestIndex(d)
            guard abs(d - (anchor + Double(k) * period)) <= tolerance else { continue }
            counts[((k % 4) + 4) % 4] += 1
            onLine += 1
        }
        if onLine >= minDownbeats, let best = counts.indices.max(by: { counts[$0] < counts[$1] }) {
            let share = Float(counts[best]) / Float(downbeats.count)
            if share >= Float(minDownbeatShare) { phase = best; phaseConfidence = share }
        }

        let spanFirst = max(0, anchor + Double(nearestIndex(points[0].1)) * period)
        let spanLast = min(duration, anchor + Double(nearestIndex(points[points.count - 1].1)) * period)
        let grid = MusicBeatGrid(
            periodSec: period, anchorSec: anchor, downbeatPhase: phase, beatConfidence: confidence,
            downbeatConfidence: phaseConfidence, intervalSpread: spread, driftSec: drift, spanStartSec: spanFirst, spanEndSec: spanLast
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
