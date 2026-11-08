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

    /// The collision of an overlap between two analysed songs; nil when the guard is a no-op for the pair.
    static func collisionSec(
        outgoing: MusicAnalysis?, incoming: MusicAnalysis?, outStart: Double, inStart: Double, rate: Double = 1,
        length: Double
    ) -> Double? {
        guard let p = proxy(outgoing: outgoing, incoming: incoming) else { return nil }
        return collisionSec(
            outroStartA: p.outroStartA, introEndB: p.introEndB, outStart: outStart, inStart: inStart, rate: rate,
            length: length
        )
    }
}
