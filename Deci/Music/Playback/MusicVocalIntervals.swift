// Deci/Music/Playback/MusicVocalIntervals.swift
// 3d-4: where a song is sung, read from synced lyrics. Pure.

import Foundation

enum MusicVocalIntervals {
    /// A line starts being heard this long before its timestamp and keeps ringing this long after its end.
    static let padSec = 0.3
    /// One line never counts for more than this, so a missing end cannot blanket a long gap.
    static let maxLineSec = 8.0

    /// Sung intervals in song seconds, sorted, merged, clamped to 0...duration. Empty text lines are gaps.
    /// A line with no end runs to the next line's time, the last line to the 8 s cap.
    /// An empty result means no singing at all.
    static func from(lines: [LyricLine], duration: Double) -> [ClosedRange<Double>] {
        guard duration.isFinite, duration > 0 else { return [] }
        let sorted = lines.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
        var raw: [ClosedRange<Double>] = []
        for (i, line) in sorted.enumerated() {
            guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // The last line has no next line: it runs to the cap (a cached LRCLIB line carries no end).
            let next = i + 1 < sorted.count ? sorted[i + 1].time : line.time + maxLineSec
            var end = line.end.flatMap { $0.isFinite ? $0 : nil } ?? next
            end = max(end, line.time)
            end = min(end, line.time + maxLineSec)
            let lo = max(0, line.time - padSec), hi = min(duration, end + padSec)
            if hi >= lo, lo <= duration { raw.append(lo...hi) }
        }
        var merged: [ClosedRange<Double>] = []
        for r in raw.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }
}

enum MusicVocalGuardIntervals {
    /// Wall seconds of `intervals` (mapped t -> (t - start) / rate) that fall inside [0, length].
    static func wallRanges(_ intervals: [ClosedRange<Double>], start: Double, rate: Double, length: Double)
        -> [ClosedRange<Double>] {
        intervals.compactMap { r in
            let lo = max((r.lowerBound - start) / rate, 0), hi = min((r.upperBound - start) / rate, length)
            return hi > lo ? lo...hi : nil
        }
    }

    static func overlap(_ a: [ClosedRange<Double>], _ b: [ClosedRange<Double>]) -> Double {
        var total = 0.0
        for x in a { for y in b {
            let lo = max(x.lowerBound, y.lowerBound), hi = min(x.upperBound, y.upperBound)
            if hi > lo { total += hi - lo }
        } }
        return total
    }

    /// Collision wall seconds. `a`/`b` are the sides' singing intervals or nil to use the span
    /// (A: song start..outroStartA, B: introEndB..end), both in song seconds.
    static func collisionSec(
        a: [ClosedRange<Double>]?, b: [ClosedRange<Double>]?, outroStartA: Double, introEndB: Double,
        outStart: Double, inStart: Double, rate: Double = 1, length: Double
    ) -> Double {
        guard length.isFinite, length > 0, outStart.isFinite, inStart.isFinite else { return 0 }
        let r = rate.isFinite && rate > 0 ? rate : 1
        let aSet = a ?? [0...max(outroStartA, 0)]
        let bSet = b ?? [min(introEndB, .greatestFiniteMagnitude)...Double.greatestFiniteMagnitude]
        let wa = wallRanges(aSet, start: outStart, rate: 1, length: length)
        let wb = wallRanges(bSet, start: inStart, rate: r, length: length)
        return overlap(wa, wb)
    }
}
