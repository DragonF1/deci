// Deci/Music/Analysis/BeatThis/BeatThisPeaks.swift
// beat_this "minimal" post-processing at 50 fps: a peak is a logit that is the maximum of its 7 frame window and above
// 0; peaks one frame apart are merged at their running mean; downbeats snap to the nearest beat.

import Foundation

nonisolated enum BeatThisPeaks {
    static let framesPerSecond = 50.0
    static let window = 7

    /// Beat and downbeat times in seconds, ascending; every downbeat is one of the beats.
    static func pick(beat: [Float], downbeat: [Float]) -> (beats: [Double], downbeats: [Double]) {
        let beats = times(logits: beat)
        var downs = times(logits: downbeat)
        guard !beats.isEmpty else { return ([], []) }
        downs = downs.map { d in
            var best = beats[0]
            for b in beats where abs(b - d) < abs(best - d) { best = b }
            return best
        }
        return (beats, Array(Set(downs)).sorted())
    }

    /// Peak positions in seconds.
    static func times(logits: [Float]) -> [Double] {
        let n = logits.count
        let radius = window / 2
        var peaks: [Int] = []
        for i in 0..<n where logits[i] > 0 {
            var isMax = true
            for j in max(0, i - radius)...min(n - 1, i + radius) where logits[j] > logits[i] { isMax = false; break }
            if isMax { peaks.append(i) }
        }
        // Dedupe: adjacent peaks join the group, whose position is the running mean.
        var out: [Double] = []
        guard var position = peaks.first.map(Double.init) else { return [] }
        var count = 1.0
        for p in peaks.dropFirst() {
            let value = Double(p)
            if value - position <= 1 {
                count += 1
                position += (value - position) / count
            } else {
                out.append(position / framesPerSecond)
                position = value
                count = 1
            }
        }
        out.append(position / framesPerSecond)
        return out
    }
}
