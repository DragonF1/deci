// Deci/Music/Playback/MusicVocalGuard.swift
// Tier 3c: the structural vocal guard. Pure: no detector, no I/O. A song is assumed to sing between its `introEnd`
// and its `outroStart`; the guard measures how long the outgoing singer and the incoming singer would be heard at
// the same time in a planned overlap, and the planners shorten or refuse an overlap that collides for too long.

import Foundation

enum MusicVocalGuard {
    /// A collision up to this long (seconds of wall time) is clean.
    static let budgetSec = 2.0
    /// A smart fade is never shortened below this.
    static let minFadeSec = 3.0
    /// The fades a colliding smart plan is shortened to, longest first (only those shorter than the plan's fade).
    static let shortenFades: [Double] = [8, 5, 3]
    /// A 4-bar beat overlap is only tried when it lasts at least this long.
    static let minBeatTierSec = 6.0

    /// The singing proxy of a pair: where the outgoing song stops singing and where the incoming song starts.
    /// nil (the guard is a no-op) when either side has no analysis, a value is not finite, a song has
    /// introEnd >= outroStart, or an outroStart <= 0.
    static func proxy(
        outgoing: MusicAnalysis?, incoming: MusicAnalysis?
    ) -> (outroStartA: Double, introEndB: Double)? {
        guard let a = outgoing, let b = incoming else { return nil }
        for song in [a, b] {
            guard song.introEnd.isFinite, song.outroStart.isFinite, song.outroStart > 0,
                  song.introEnd < song.outroStart else { return nil }
        }
        return (a.outroStart, b.introEnd)
    }

    /// Wall seconds both singers are heard in an overlap of wall length `length` that starts at outgoing item time
    /// `outStart` and incoming item time `inStart`, the incoming playing at `rate`. A sings in wall [0, A], B in
    /// [B, length], the collision is their intersection.
    static func collisionSec(
        outroStartA: Double, introEndB: Double, outStart: Double, inStart: Double, rate: Double = 1, length: Double
    ) -> Double {
        guard length.isFinite, length > 0, outroStartA.isFinite, introEndB.isFinite, outStart.isFinite,
              inStart.isFinite else { return 0 }
        let r = rate.isFinite && rate > 0 ? rate : 1
        let aEnd = min(max(outroStartA - outStart, 0), length)
        let bStart = min(max((introEndB - inStart) / r, 0), length)
        return max(0, aEnd - bStart)
    }

    /// The collision of an overlap between two songs; nil when the guard is a no-op for the pair. A side with lyric
    /// `intervals` (3d-4) is measured by them; a side without uses the structural proxy from its analysis. Both
    /// intervals nil is exactly the proxy.
    static func collisionSec(
        outgoing: MusicAnalysis?, incoming: MusicAnalysis?, outStart: Double, inStart: Double, rate: Double = 1,
        length: Double, outgoingIntervals: [ClosedRange<Double>]? = nil, incomingIntervals: [ClosedRange<Double>]? = nil,
        incomingLoop: MusicLoopMap? = nil
    ) -> Double? {
        // Loop extend: the incoming song is measured in item time, where everything after the loop's end sits `extension` later.
        if let map = incomingLoop {
            var shifted = incoming
            if var row = shifted {
                if row.introEnd.isFinite { row.introEnd = map.itemTime(row.introEnd) }
                if row.outroStart.isFinite { row.outroStart = map.itemTime(row.outroStart) }
                shifted = row
            }
            let moved = incomingIntervals?.map { ClosedRange(uncheckedBounds: (map.itemTime($0.lowerBound), map.itemTime($0.upperBound))) }
            return collisionSec(
                outgoing: outgoing, incoming: shifted, outStart: outStart, inStart: inStart, rate: rate, length: length,
                outgoingIntervals: outgoingIntervals, incomingIntervals: moved
            )
        }
        if outgoingIntervals == nil, incomingIntervals == nil {
            guard let p = proxy(outgoing: outgoing, incoming: incoming) else { return nil }
            return collisionSec(
                outroStartA: p.outroStartA, introEndB: p.introEndB, outStart: outStart, inStart: inStart, rate: rate,
                length: length
            )
        }
        var outro = 0.0, intro = 0.0
        if outgoingIntervals == nil {
            guard let a = outgoing, a.introEnd.isFinite, a.outroStart.isFinite, a.outroStart > 0,
                  a.introEnd < a.outroStart else { return nil }
            outro = a.outroStart
        }
        if incomingIntervals == nil {
            guard let b = incoming, b.introEnd.isFinite, b.outroStart.isFinite, b.outroStart > 0,
                  b.introEnd < b.outroStart else { return nil }
            intro = b.introEnd
        }
        return MusicVocalGuardIntervals.collisionSec(
            a: outgoingIntervals, b: incomingIntervals, outroStartA: outro, introEndB: intro, outStart: outStart,
            inStart: inStart, rate: rate, length: length
        )
    }

    // MARK: Cut-off (the outgoing singer stopped mid-word)

    /// How far a mix point may move to land in a gap between sung lines.
    static let gapSearchSec = 4.0
    /// Where in a gap the moved end lands, in seconds past the last word.
    static let gapMarginSec = 0.05

    /// True when the outgoing song is still being sung at `endSec`: the audible end of a cut (its mix-out), or of a blend (its
    /// mix-out plus its fade), falls strictly inside a vocal interval.
    static func cutsOutgoingSinger(_ intervals: [ClosedRange<Double>], endSec: Double) -> Bool {
        guard endSec.isFinite else { return false }
        return intervals.contains { $0.lowerBound < endSec && endSec < $0.upperBound }
    }

    /// The same with the structural proxy when the song has no lyric intervals: it sings between `introEnd` and `outroStart`,
    /// so an end before the outro start clips the singer. A song the proxy cannot read (no analysis, a value that is not
    /// finite, introEnd >= outroStart) never clips.
    static func cutsOutgoingSinger(outgoing: MusicAnalysis?, intervals: [ClosedRange<Double>]?, endSec: Double) -> Bool {
        if let intervals { return cutsOutgoingSinger(intervals, endSec: endSec) }
        guard endSec.isFinite, let a = outgoing, a.introEnd.isFinite, a.outroStart.isFinite, a.outroStart > 0,
              a.introEnd < a.outroStart else { return false }
        return a.introEnd < endSec && endSec < a.outroStart
    }

    /// The point nearest `endSec` (within `within` seconds) that no sung line covers: just past the end of a line or just
    /// before the start of one. nil when there is none.
    static func nearestGap(_ intervals: [ClosedRange<Double>], to endSec: Double, within: Double = gapSearchSec) -> Double? {
        guard endSec.isFinite else { return nil }
        let candidates = intervals.flatMap { [$0.lowerBound - gapMarginSec, $0.upperBound + gapMarginSec] }
            .filter { abs($0 - endSec) <= within && $0 >= 0 && !cutsOutgoingSinger(intervals, endSec: $0) }
        return candidates.min { abs($0 - endSec) < abs($1 - endSec) }
    }
}
