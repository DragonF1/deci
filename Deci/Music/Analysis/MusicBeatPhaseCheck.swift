// Deci/Music/Analysis/MusicBeatPhaseCheck.swift
// Tier 4c A2: beat_this sometimes locks a steady, confident grid half a beat away from where the music hits (2 of 54 real
// songs: an offbeat bass or hat pattern). Its own confidence cannot see that, so this looks at the audio: in each beat
// window, where does the strongest onset sit? When most of them sit half a beat from the grid and few on it, the grid
// is moved by half a beat. The downbeat is dropped (which half-beat neighbour is the bar line is not known).

import Foundation

nonisolated enum MusicBeatPhaseCheck {
    static let frame = 512
    static let hop = 128
    /// Beats with a usable window needed before a verdict.
    static let minBeats = 32
    /// A strongest onset within [-0.2, 0.1) of a beat is on the grid (an onset reads a little early); beyond 0.3 it is on the offbeat.
    static let onGridRange: Range<Double> = -0.2..<0.1
    static let offbeatDistance = 0.3
    static let minOffbeatShare = 0.4
    static let offbeatOverGrid = 1.5
    static let maxSeconds = 600.0

    /// The grid, or the same grid half a beat later when the onsets say so. `samples` is mono audio at `rate`.
    static func corrected(_ grid: MusicBeatGrid, samples: [Float], rate: Double) -> MusicBeatGrid {
        guard let share = onsetShares(grid, samples: samples, rate: rate),
              share.offbeat >= minOffbeatShare, share.offbeat >= offbeatOverGrid * share.onGrid else { return grid }
        var out = grid
        out.anchorSec = grid.anchorSec + grid.periodSec / 2
        out.downbeatPhase = nil
        out.downbeatConfidence = 0
        return out
    }

    /// Shares of beat windows whose strongest onset is on the grid and on the offbeat. nil without enough evidence.
    static func onsetShares(_ grid: MusicBeatGrid, samples: [Float], rate: Double) -> (onGrid: Double, offbeat: Double)? {
        guard rate.isFinite, rate > 1000, rate < 1e6, grid.periodSec.isFinite, grid.periodSec > 0, grid.anchorSec.isFinite,
              samples.count >= frame + 2 * hop else { return nil }
        let usable = min(samples.count, Int(maxSeconds * rate))
        // Spectral flux: summed rises of log(1 + magnitude) between frames (the audio is in -1...1, scaled to 16 bit units).
        guard let spectrum = MusicBeatFinder.Spectrum(size: frame) else { return nil }
        defer { spectrum.destroy() }
        let frames = (usable - frame) / hop + 1
        var prev = [Float](repeating: 0, count: frame / 2)
        var rise = [Double](repeating: 0, count: max(0, frames - 1))
        for f in 0..<frames {
            var mags = spectrum.magnitudes(samples, start: f * hop)
            for i in 0..<mags.count {
                let m = mags[i]
                mags[i] = m.isFinite ? log(1 + 32768 * m) : 0
            }
            if f > 0 {
                var sum: Float = 0
                for i in 0..<mags.count { sum += max(0, mags[i] - prev[i]) }
                rise[f - 1] = Double(sum)
            }
            prev = mags
        }
        guard !rise.isEmpty else { return nil }
        func time(_ j: Int) -> Double { (Double(j + 1) * Double(hop) + Double(frame) / 2) / rate }

        let first = Int(((time(0) + grid.periodSec - grid.anchorSec) / grid.periodSec).rounded(.up))
        let end = time(rise.count - 1) - grid.periodSec
        var windows = 0, on = 0, off = 0
        var k = max(first, Int(((grid.spanStartSec - grid.anchorSec) / grid.periodSec).rounded(.up)))
        while true {
            let centre = grid.anchorSec + Double(k) * grid.periodSec
            if centre > end || centre > grid.spanEndSec { break }
            defer { k += 1 }
            let lo = max(0, Int(((centre - grid.periodSec / 2) * rate - Double(frame) / 2) / Double(hop)) - 1)
            let hi = min(rise.count - 1, Int(((centre + grid.periodSec / 2) * rate - Double(frame) / 2) / Double(hop)) - 1)
            guard lo < hi else { continue }
            var best = lo
            for j in lo...hi where rise[j] > rise[best] { best = j }
            guard rise[best] > 1e-6 else { continue }
            windows += 1
            let offset = (time(best) - centre) / grid.periodSec
            if onGridRange.contains(offset) { on += 1 } else if abs(offset) > offbeatDistance { off += 1 }
        }
        guard windows >= minBeats else { return nil }
        return (Double(on) / Double(windows), Double(off) / Double(windows))
    }
}
