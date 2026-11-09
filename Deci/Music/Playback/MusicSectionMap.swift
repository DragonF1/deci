// Deci/Music/Playback/MusicSectionMap.swift
// Tier 4b P3: song sections from the stored energy curve and the beat grid, and the DJ-length rule built on them. Pure and
// derived on demand: nothing is stored, the analysis version stays 5. A song whose grid is not trusted, whose envelope is flat
// or whose shape is ambiguous has NO sections, and a song without sections is planned exactly as before.
//
// Method: bars from the first downbeat, each averaged in dB from the 100 ms energy blocks; bars are grouped into phrases of
// 4 bars (8 at fast tempos, so a phrase stays near 16 s); phrases are split into high and low by their position between the
// song's 20th percentile and loudest phrase energy, with hysteresis. A chorus is a run of high phrases that comes after a
// lower stretch. Two such runs, both of similar level and with a lower stretch between them, are needed before anything is
// reported; one run, a lone peak or a ramp is ambiguous and gives nothing.

import Foundation

nonisolated struct MusicSectionMap: Equatable, Sendable {
    enum Kind: String, Sendable { case chorus, other }
    struct Section: Equatable, Sendable {
        var kind: Kind
        var startSec: Double
        var endSec: Double
    }

    var sections: [Section]
    /// The end of each chorus, on a downbeat, in song seconds, in order.
    var chorusEnds: [Double] { sections.filter { $0.kind == .chorus }.map(\.endSec) }

    static let empty = MusicSectionMap(sections: [])

    /// Phrase length: 8 bars when a bar is shorter than this, else 4.
    static let longBarSec = 2.2
    /// A song needs at least this much measured audio.
    static let minSongSec = 60.0
    /// The 20th percentile and the loudest phrase must be at least this far apart (dB), or the envelope counts as flat.
    static let minRangeDb: Float = 3
    /// A phrase is high above this fraction of that range and low below the lower one; in between it keeps its neighbour's state.
    static let highAt: Float = 0.6, lowAt: Float = 0.4
    /// Two choruses whose mean levels differ by more than this (dB) are not the same section.
    static let maxChorusSpreadDb: Float = 3
    /// The level must fall by at least this much (dB, over the two bars either side) at a chorus end, or there is no section.
    static let minDropDb: Float = 1.5
    /// A chorus end may be moved this many bars either way, to the bar line where the level falls most.
    static let snapBars = 2

    /// nil-safe entry: the analysis's own grid when none is given.
    static func derive(analysis: MusicAnalysis, grid: MusicBeatGrid?) -> MusicSectionMap {
        guard let grid = grid ?? analysis.usableGrid, MusicBeatPlanner.trusted(grid), grid.downbeatPhase != nil else { return .empty }
        // The service asks about the playing song on every tick: the map is worked out once per song and grid.
        let key = SectionCache.Key(
            videoId: analysis.videoId, energyHash: analysis.energy.hashValue, count: analysis.energy.count,
            period: grid.periodSec, anchor: grid.anchorSec, phase: grid.downbeatPhase
        )
        if let hit = SectionCache.shared.value(for: key) { return hit }
        let map = derive(energy: analysis.energy, grid: grid)
        SectionCache.shared.store(map, for: key)
        return map
    }

    /// How many times `derive(analysis:grid:)` worked a map out rather than reading the cache (tests read it).
    static var computeCount: Int { SectionCache.shared.computed }

    static func derive(energy: [UInt8], grid: MusicBeatGrid) -> MusicSectionMap {
        let blockSec = MusicAnalysis.energyBlockSeconds
        let measured = Double(energy.count) * blockSec
        let barSec = 4 * grid.periodSec
        guard measured >= minSongSec, barSec.isFinite, barSec > 0, grid.downbeatPhase != nil, grid.barTime(0) != nil else { return .empty }
        let phraseBars = barSec < longBarSec ? 8 : 4

        // Mean dB per bar.
        var bars: [Float] = []
        var barIndex = 0
        while let start = grid.barTime(barIndex), start >= 0, start + barSec <= measured + 1e-9 {
            let first = Int((start / blockSec).rounded()), last = min(energy.count, Int(((start + barSec) / blockSec).rounded()))
            guard last > first else { break }
            var sum: Float = 0
            for code in energy[first..<last] { sum += Float(code) * MusicAnalysis.energyStepDb }
            bars.append(sum / Float(last - first))
            barIndex += 1
        }
        // Phrases count from the bar where the song's own phrasing starts, which is not always bar 0 (an intro or a pickup of a
        // few bars): the offset whose phrase boundaries separate the levels most (the largest summed jump between neighbours).
        func phrasesStarting(at offset: Int) -> [Float] {
            let count = (bars.count - offset) / phraseBars
            guard count > 0 else { return [] }
            return (0..<count).map { p in
                bars[(offset + p * phraseBars)..<(offset + (p + 1) * phraseBars)].reduce(0, +) / Float(phraseBars)
            }
        }
        func contrast(_ phrases: [Float]) -> Float {
            zip(phrases, phrases.dropFirst()).reduce(0) { $0 + abs($1.1 - $1.0) }
        }
        var offset = 0
        var phrases = phrasesStarting(at: 0)
        var bestContrast = contrast(phrases)
        for candidate in 1..<phraseBars {
            let trial = phrasesStarting(at: candidate)
            guard trial.count >= 6 else { continue }
            let c = contrast(trial)
            // A different offset must beat the earlier one clearly, so noise keeps the song's own bar 0.
            if c > bestContrast * 1.05 + 0.01 { offset = candidate; phrases = trial; bestContrast = c }
        }
        let phraseCount = phrases.count
        guard phraseCount >= 6 else { return .empty }

        let sorted = phrases.sorted()
        func percentile(_ q: Float) -> Float { sorted[min(sorted.count - 1, Int(Float(sorted.count - 1) * q + 0.5))] }
        let lo = percentile(0.2), hi = sorted[sorted.count - 1]
        guard hi - lo >= minRangeDb else { return .empty }
        let highLine = lo + highAt * (hi - lo), lowLine = lo + lowAt * (hi - lo)

        // High and low phrases, with hysteresis. The first phrase starts low unless it is clearly high.
        var isHigh = [Bool](repeating: false, count: phraseCount)
        var state = false
        for p in 0..<phraseCount {
            if phrases[p] >= highLine { state = true } else if phrases[p] <= lowLine { state = false }
            isHigh[p] = state
        }

        // Runs of high phrases that follow a low phrase.
        struct Run { var first: Int; var end: Int; var mean: Float }
        var runs: [Run] = []
        var p = 0
        while p < phraseCount {
            guard isHigh[p] else { p += 1; continue }
            let first = p
            while p < phraseCount, isHigh[p] { p += 1 }
            if first > 0 {
                let mean = phrases[first..<p].reduce(0, +) / Float(p - first)
                runs.append(Run(first: first, end: p, mean: mean))
            }
        }
        // A run that reaches the last phrase is the finale, not a section whose end can be used.
        let closed = runs.filter { $0.end < phraseCount }
        guard closed.count >= 2, abs(closed[0].mean - closed[1].mean) <= maxChorusSpreadDb else { return .empty }

        // Bar-level end of each chorus: the bar line within `snapBars` of the phrase end where the level falls most.
        func barEnd(of run: Run) -> Int? {
            let nominal = offset + run.end * phraseBars
            var best = nominal, bestDrop = -Float.infinity
            for shift in -snapBars...snapBars {
                let b = nominal + shift
                guard b - 2 >= 0, b + 2 <= bars.count else { continue }
                let before = (bars[b - 2] + bars[b - 1]) / 2, after = (bars[b] + bars[b + 1]) / 2
                // Ties keep the phrase boundary.
                let drop = before - after - (shift == 0 ? 0 : 0.01)
                if drop > bestDrop { bestDrop = drop; best = b }
            }
            return bestDrop >= minDropDb ? best : nil
        }
        var sections: [Section] = []
        var cursor = 0
        for run in closed {
            let startBar = max(cursor, offset + run.first * phraseBars)
            guard let endBar = barEnd(of: run), endBar > startBar, let s = grid.barTime(startBar), let e = grid.barTime(endBar) else { return .empty }
            if let c = grid.barTime(cursor), s > c { sections.append(Section(kind: .other, startSec: c, endSec: s)) }
            sections.append(Section(kind: .chorus, startSec: s, endSec: e))
            cursor = endBar
        }
        return MusicSectionMap(sections: sections)
    }
}

/// A few section maps, newest last, so the playing song's map is not derived again on every tick.
private nonisolated final class SectionCache: @unchecked Sendable {
    struct Key: Hashable { var videoId: String; var energyHash: Int; var count: Int; var period: Double; var anchor: Double; var phase: Int? }
    static let shared = SectionCache()
    private let lock = NSLock()
    private var order: [Key] = []
    private var maps: [Key: MusicSectionMap] = [:]
    private(set) var computed = 0

    func value(for key: Key) -> MusicSectionMap? {
        lock.lock(); defer { lock.unlock() }
        return maps[key]
    }

    func store(_ map: MusicSectionMap, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        computed += 1
        if maps[key] == nil { order.append(key) }
        maps[key] = map
        while order.count > 8 { maps[order.removeFirst()] = nil }
    }
}

/// DJ-length songs: in Mix, an energetic run moves on after a song's second chorus. Off by default.
nonisolated enum MusicDJLength {
    /// "High" run energy. The energy rating (0...1, `MusicEnergyRating`) of the 54 songs of the live corpus runs from 0.35 to
    /// 0.72 with the median 0.58, the 75th percentile 0.65 and the 90th 0.69. A run's energy is the mean of 1 to 3 songs, so it
    /// is tighter than a single song; 0.62 is about the 65th percentile of single songs: a run above it is clearly driving,
    /// and a calm or mixed run stays under it.
    static let highEnergy: Float = 0.62
    /// Never cut a song before this many seconds have played: a song cut at its second chorus must still be a song.
    static let minPlayedSec = 60.0
    /// The songs that make a run: the playing one and this many before it.
    static let runSongs = 3
    /// A sung line that spans the cut moves it later by whole bars, at most this many.
    static let maxVocalShiftBars = 3

    /// The mean energy rating of the songs of the run, nil when none is known.
    static func runEnergy(_ ratings: [Float?]) -> Float? {
        let known = ratings.compactMap { $0 }.filter { $0.isFinite && (0...1).contains($0) }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Float(known.count)
    }

    static func isHigh(_ runEnergy: Float?) -> Bool {
        guard let runEnergy, runEnergy.isFinite else { return false }
        return runEnergy >= highEnergy
    }

    /// The outgoing item time of the second chorus end for this pair, or nil when the plan must stay as it is: the setting is
    /// off, the run is not energetic, a rule keeps the pair from mixing, the song has no sections, the cut would leave less
    /// than `minPlayedSec` played, it would not be earlier than the normal mix-out by a bar, or no clean bar can be found.
    static func mixOutSec(_ inputs: MusicTransitionInputs, smartEnd: Double?, normal: Double? = nil) -> Double? {
        cut(inputs, smartEnd: smartEnd, normal: normal)?.point
    }

    /// `mixOutSec` with the mix-out the planner would have used instead (`normal`), so a caller can see how much earlier it is.
    static func cut(_ inputs: MusicTransitionInputs, smartEnd: Double?, normal known: Double? = nil) -> (point: Double, normal: Double)? {
        guard inputs.djLength, isHigh(inputs.runEnergy), inputs.beatMixEnabled, inputs.crossfadeOn,
              !inputs.albumInOrder, !inputs.loopSong, !inputs.manualSkip, !inputs.cleanStartFlag, !inputs.cleanPairFlag,
              inputs.outgoing.videoId != inputs.incoming.videoId,
              let duration = MusicBeatPlanner.valid(inputs.outgoing.durationSeconds),
              let a = inputs.outgoing.analysis,
              let grid = inputs.outgoing.grid ?? a.usableGrid, MusicBeatPlanner.trusted(grid), grid.downbeatPhase != nil
        else { return nil }
        let map = MusicSectionMap.derive(analysis: a, grid: grid)
        let ends = map.chorusEnds
        guard ends.count >= 2 else { return nil }
        let barSec = 4 * grid.periodSec
        let end = smartEnd ?? duration
        // The mix-out the plan would have anyway: the cut must beat it by a bar. The planner passes the real one; without it
        // it is estimated at the overlap the beat planner tries first (16 bars with bass swap and a known downbeat, else 8).
        let estimateBars = inputs.bassSwapAvailable ? 16 : MusicBeatPlanner.phraseBars
        guard let normal = known ?? MusicBeatPlanner.mixOutTime(grid: grid, analysis: a, bars: estimateBars, barSec: barSec, end: end)
        else { return nil }
        // With the vocal guard on, a sung line may hold the cut back, and a song whose lyric timings are unknown gets no cut
        // at all (the same caution the guard shows elsewhere).
        var intervals: [ClosedRange<Double>]?
        if inputs.vocalGuardEnabled {
            guard let lyric = inputs.outgoing.vocalIntervals else { return nil }
            intervals = lyric
        }
        for shift in 0...maxVocalShiftBars {
            let point = ends[1] + Double(shift) * barSec
            guard point >= minPlayedSec, point <= normal - barSec + 1e-9 else { return nil }
            if let earliest = inputs.earliestMixOutSec, point < earliest { return nil }
            if !sung(intervals, at: point) { return (point, normal) }
        }
        return nil
    }

    /// A lyric line spans `time` (a margin of 50 ms either side keeps a line that ends on the bar from counting).
    static func sung(_ intervals: [ClosedRange<Double>]?, at time: Double) -> Bool {
        guard let intervals else { return false }
        return intervals.contains { $0.lowerBound < time - 0.05 && $0.upperBound > time + 0.05 }
    }
}
