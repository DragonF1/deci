// Deci/Music/Playback/MusicDJEntry.swift
// Where a DJ brings a song in. Not at its first second: a blend is started so many bars early that it is over exactly when the
// song gets going (its first verse, hook or drop), and a cut lands right on it. The long part of an intro that the blend does
// not need is skipped. Pure and derived on demand.

import Foundation

nonisolated struct MusicDJEntry: Equatable, Sendable {
    enum Kind: String, Sendable { case verse, hook, drop }

    var kind: Kind
    /// Where the song gets going, in song seconds: on the bar line at or before it when the grid is trusted.
    var targetSec: Double

    /// An entry never skips more of a song than this, in seconds and as a share of its length: past it the long intro is the song.
    static let maxSkipSec = 60.0
    static let maxSkipShare = 0.3
    /// An event this close after a bar line counts as on it.
    static let barSlackSec = 0.05

    /// The first thing that happens in a song, or nil when nothing is known or it comes too late to skip to. `start` is where the
    /// song starts after its leading silence.
    static func pick(_ side: MusicTransitionSide, start: Double) -> MusicDJEntry? {
        guard let duration = MusicBeatPlanner.valid(side.durationSeconds), let analysis = side.analysis,
              start.isFinite, start >= 0 else { return nil }
        let stored = side.grid ?? analysis.usableGrid
        let grid = stored.flatMap { MusicBeatPlanner.trusted($0) && $0.downbeatPhase != nil ? $0 : nil }
        var events: [MusicDJEntry] = []
        func add(_ kind: Kind, _ time: Double?) {
            guard let time, time.isFinite, time > start else { return }
            events.append(MusicDJEntry(kind: kind, targetSec: time))
        }
        add(.verse, side.lyricCues?.firstLineSec ?? side.vocalIntervals?.first?.lowerBound)
        add(.hook, side.lyricCues?.hooks.first?.lowerBound)
        if let grid {
            add(.hook, MusicSectionMap.derive(analysis: analysis, grid: grid).sections.first { $0.kind == .chorus }?.startSec)
            add(.drop, MusicDropDetector.drops(in: analysis, grid: grid)?.first { $0.confidence >= MusicDropDetector.confidenceFloor }?.timeSec)
        }
        // Without lyrics the vocal guard takes the end of the intro for the first words, so this does too.
        if side.vocalIntervals == nil { add(.verse, analysis.introEnd) }
        guard var first = events.min(by: { $0.targetSec < $1.targetSec }) else { return nil }
        if let grid, let origin = grid.barTime(0) {
            let bar = 4 * grid.periodSec
            first.targetSec = origin + ((first.targetSec - origin + barSlackSec) / bar).rounded(.down) * bar
        } else if first.kind != .drop {
            // No bar line to lean on: a breath before the word.
            first.targetSec -= MusicVocalIntervals.padSec
        }
        guard first.targetSec > start, first.targetSec - start <= min(maxSkipSec, maxSkipShare * duration) else { return nil }
        return first
    }

    /// Where the incoming song starts (song seconds) so that `lead` seconds of it are over as it gets going, never before `start`.
    func start(lead: Double, notBefore start: Double) -> Double {
        guard lead.isFinite else { return start }
        return max(start, targetSec - max(0, lead))
    }

    /// `start(lead:notBefore:)` for a planner that takes the first bar line at or after the time it is given: up to a bar earlier, so
    /// the bar line it finds is the one at or before the target.
    func barStart(lead: Double, barSec: Double, notBefore start: Double) -> Double {
        self.start(lead: lead + max(0, barSec - Self.barSlackSec), notBefore: start)
    }
}

extension TransitionPlan {
    /// The incoming song is parked well past where a plain start would put it: a drop swap, or an entry that skips an intro. Such a
    /// standby must never be played as a plain start.
    nonisolated var entersDeep: Bool {
        guard mode == .beat, let mixIn = mixInSec, let plain = fallbackIncomingStartSec else { return false }
        return mixIn - plain > max(barSec, style == .dropSwap ? 0.5 : 2.5)
    }
}
