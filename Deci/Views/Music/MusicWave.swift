// Deci/Views/Music/MusicWave.swift
// The hover card's wave progress: the playhead's place, the time a click means, and the smooth played curve built from
// the same per-slice levels the player column's spectrum shows. Pure geometry (y grows downward, as in a Canvas), so
// every rule is unit tested and nothing here draws.

import CoreGraphics
import Foundation

nonisolated enum MusicWave {
    /// The wave's box: tall enough for the knob and the loudest swell above the baseline.
    static let boxHeight: Double = 22
    static let knobDiameter: Double = 12

    /// Space kept at each end, so the knob at the first or last second is not clipped.
    static let inset: Double = knobDiameter / 2

    /// Where the played curve and the unplayed line sit, from the top of the box.
    static let baselineY: Double = 15

    /// The most the played curve rises above the baseline, at level 1.
    static let maxAmplitude: Double = 14

    /// How far behind the playhead the curve takes to reach its full height, so it ends in a point.
    static let taperLength: Double = 10

    /// The distance between the curve's samples. A fixed step on a fixed grid: the same stretch of song keeps the same
    /// shape as the playhead moves past it.
    static let sampleStep: Double = 2

    /// A point of the played curve: its x and how high it rises above the baseline.
    struct Sample: Equatable, Sendable {
        let x: Double
        let height: Double
    }

    // MARK: - Playhead and seek

    /// The playhead's x for a progress through the song: from the inset to the other end less the inset.
    static func playheadX(progress: Double, width: Double) -> Double {
        let span = trackSpan(width: width)
        guard span > 0 else { return inset }
        let held = progress.isNaN ? 0 : min(max(progress, 0), 1)
        return inset + held * span
    }

    /// The progress a click at `x` means, held to 0...1.
    static func progress(atX x: Double, width: Double) -> Double {
        let span = trackSpan(width: width)
        guard span > 0, !x.isNaN else { return 0 }
        return min(max((x - inset) / span, 0), 1)
    }

    /// The time a click at `x` seeks to; the start for a song with no known length.
    static func seekTime(atX x: Double, duration: TimeInterval, width: Double) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return progress(atX: x, width: width) * duration
    }

    // MARK: - Played curve

    /// 0 at the playhead, rising smoothly to 1 at `taperLength` behind it.
    static func taper(distanceToPlayhead distance: Double) -> Double {
        guard !distance.isNaN, distance > 0 else { return 0 }
        guard distance < taperLength else { return 1 }
        let t = distance / taperLength
        return t * t * (3 - 2 * t)
    }

    /// The played part of the wave: samples from the left inset to the playhead, which is where the curve ends in a
    /// point. The levels are spread over the whole song, so the shape under any x does not change as the song plays.
    /// Nothing is played at progress 0, so there is nothing to draw.
    static func profile(levels: [Double], progress: Double, width: Double) -> [Sample] {
        guard progress.isFinite, progress > 0, trackSpan(width: width) > 0 else { return [] }
        let end = playheadX(progress: progress, width: width)
        guard end > inset else { return [] }
        let clean = sanitized(levels)
        let span = trackSpan(width: width)
        let lastIndex = Double(clean.count - 1)

        func sample(at x: Double) -> Sample {
            let t = min(max((x - inset) / span, 0), 1)
            let level = curve(clean, at: t * lastIndex)
            return Sample(x: x, height: maxAmplitude * level * taper(distanceToPlayhead: end - x))
        }

        var samples = [sample(at: inset)]
        var step = 1.0
        // A grid point closer than half a point to the playhead is left out: the playhead's own sample follows it.
        while inset + step * sampleStep < end - 0.5 {
            samples.append(sample(at: inset + step * sampleStep))
            step += 1
        }
        samples.append(Sample(x: end, height: 0))
        return samples
    }

    // MARK: - Gradient

    /// The played fill's colours, left to right: two lighter variants with the hue turned on, ending on the tint itself
    /// at the playhead (the cover's pink, yellow and cyan in the One UI card).
    static func gradientTints(for tint: MusicTint) -> [MusicTint] {
        [
            MusicTint(hue: tint.hue + 0.20, saturation: tint.saturation, brightness: min(tint.brightness + 0.10, 1)),
            MusicTint(hue: tint.hue + 0.10, saturation: tint.saturation, brightness: min(tint.brightness + 0.05, 1)),
            tint,
        ]
    }

    // MARK: - Private

    /// The width the playhead travels: the box less the inset at both ends; 0 when the box cannot hold the knob.
    private static func trackSpan(width: Double) -> Double {
        guard width.isFinite else { return 0 }
        return max(width - 2 * inset, 0)
    }

    /// Levels as numbers in the spectrum's range; a list with none is the floor.
    private static func sanitized(_ levels: [Double]) -> [Double] {
        guard !levels.isEmpty else { return [MusicSpectrum.minLevel] }
        return levels.map { $0.isNaN ? MusicSpectrum.minLevel : min(max($0, MusicSpectrum.minLevel), 1) }
    }

    /// Catmull-Rom through `levels` at a position between index 0 and the last, ends held flat.
    private static func curve(_ levels: [Double], at position: Double) -> Double {
        guard levels.count > 1 else { return levels[0] }
        let last = levels.count - 1
        let held = min(max(position, 0), Double(last))
        let segment = min(Int(held.rounded(.down)), last - 1)
        let u = held - Double(segment)
        let p0 = levels[max(segment - 1, 0)]
        let p1 = levels[segment]
        let p2 = levels[segment + 1]
        let p3 = levels[min(segment + 2, last)]
        let value = 0.5 * (2 * p1
            + (p2 - p0) * u
            + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u
            + (3 * p1 - p0 - 3 * p2 + p3) * u * u * u)
        return min(max(value, MusicSpectrum.minLevel), 1)
    }
}
