// Deci/Music/Playback/MusicDropDetector.swift
// Tier 4b P2: finds drops in a song, for the drop swap. Pure: the energy curve (one code per 100 ms block, 0.5 dB steps)
// and the beat grid in, a list of drops out. A drop is the first bar line where the mean level of the next two bars is at
// least 6 dB above the mean of the four bars before it (a low stretch), found by looking at every bar line, so it is
// snapped to a downbeat by construction. Derived on demand: nothing is stored, the analysis version does not change.

import Foundation

nonisolated struct MusicDrop: Equatable, Sendable {
    /// The downbeat the drop lands on, in song seconds.
    var timeSec: Double
    /// Mean level of the two bars after it minus the mean of the four before it, in dB.
    var riseDb: Float
    /// 0...1: 0.4 at the 6 dB threshold up to 1 at 18 dB, scaled by how much of the loud stretch really stays up.
    var confidence: Float
}

nonisolated enum MusicDropDetector {
    static let minRiseDb: Float = 6
    static let barsBefore = 4
    static let barsAfter = 2
    /// A rise of this many dB (sustained) is full confidence.
    static let fullConfidenceRiseDb: Float = 18
    /// Drops under this confidence are not reported.
    static let confidenceFloor: Float = 0.4
    /// A song needs this many bars of material before a drop for the drop swap to use it.
    static let minBarsBefore = 4
    /// Blocks quieter than this are silence, not a low stretch: a song that starts from nothing has no drop.
    static let silenceDb: Float = -60

    /// All drops, earliest first. nil without a trusted grid that knows its downbeat; an empty list when the song has none.
    static func drops(energy: [UInt8], grid: MusicBeatGrid?) -> [MusicDrop]? {
        guard let grid, MusicBeatPlanner.trusted(grid), grid.downbeatPhase != nil,
              let first = grid.barTime(0), first.isFinite else { return nil }
        let barSec = 4 * grid.periodSec
        let block = MusicAnalysis.energyBlockSeconds
        let total = Double(energy.count) * block
        guard barSec > 0, barSec.isFinite, !energy.isEmpty else { return [] }

        // Level of a stretch of the curve in dB, as the mean of its blocks; nil when it holds no block.
        func levels(_ from: Double, _ to: Double) -> ArraySlice<Float>? {
            let lo = Int((from / block).rounded()), hi = Int((to / block).rounded())
            guard lo >= 0, hi <= energy.count, hi > lo else { return nil }
            return energy[lo..<hi].map { Float($0) * MusicAnalysis.energyStepDb + MusicAnalysis.energyFloorDb }[...]
        }

        var candidates: [MusicDrop] = []
        let firstBar = Int((Double(barsBefore) - first / barSec - 1e-9).rounded(.up))
        var bar = firstBar
        while true {
            let time = first + Double(bar) * barSec
            if time + Double(barsAfter) * barSec > total + 1e-9 { break }
            defer { bar += 1 }
            guard let before = levels(time - Double(barsBefore) * barSec, time),
                  let after = levels(time, time + Double(barsAfter) * barSec) else { continue }
            let low = before.reduce(0, +) / Float(before.count)
            let high = after.reduce(0, +) / Float(after.count)
            guard low > silenceDb else { continue }
            let rise = high - low
            guard rise >= minRiseDb else { continue }
            // A spike is not a drop: most of the loud stretch has to stay well above the low one.
            let held = Float(after.filter { $0 >= low + minRiseDb / 2 }.count) / Float(after.count)
            // A rise at the 6 dB threshold sits on the floor; it grows to 1 at `fullConfidenceRiseDb`.
            let strength = confidenceFloor + (1 - confidenceFloor) * min(1, (rise - minRiseDb) / (fullConfidenceRiseDb - minRiseDb))
            let confidence = strength * held
            guard confidence >= confidenceFloor else { continue }
            candidates.append(MusicDrop(timeSec: time, riseDb: rise, confidence: confidence))
        }

        // One drop per stretch: the bar lines around a real step also score, so the biggest rise wins and silences its
        // neighbours (a step on a bar line scores on the bars on either side too).
        var kept: [MusicDrop] = []
        for candidate in candidates.sorted(by: { ($0.riseDb, -$0.timeSec) > ($1.riseDb, -$1.timeSec) }) {
            if kept.contains(where: { abs($0.timeSec - candidate.timeSec) < Double(barsBefore) * barSec - 1e-9 }) { continue }
            kept.append(candidate)
        }
        return kept.sorted { $0.timeSec < $1.timeSec }
    }

    /// The drops of an analysed song on its own grid (or the one given).
    static func drops(in analysis: MusicAnalysis, grid: MusicBeatGrid? = nil) -> [MusicDrop]? {
        drops(energy: analysis.energy, grid: grid ?? analysis.usableGrid)
    }

    /// The drop a swap would use: the first confident one with at least `minBarsBefore` bars of material before it. nil when
    /// there is none or the grid is not trusted.
    static func best(in analysis: MusicAnalysis, grid: MusicBeatGrid? = nil) -> MusicDrop? {
        guard let grid = grid ?? analysis.usableGrid, let found = drops(energy: analysis.energy, grid: grid) else { return nil }
        let room = Double(minBarsBefore) * 4 * grid.periodSec
        return found.first { $0.timeSec >= room - 1e-9 && $0.confidence >= confidenceFloor }
    }
}
