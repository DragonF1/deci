// Deci/Music/Playback/MusicMixEQPlan.swift
// What a DJ's hands do on the mids and highs of a blend, worked out once when the pair is planned. The new song comes in as
// highs with its mids down, its mids open on the way to the bass swap, and once its bass is in the old song's mids and highs
// step back. Where both songs sing, the one that does not own the bass gives up its mids, so there is one voice. Cuts only:
// volume (the equal power fade) stays the main control, and no gain is ever above 1. Pure.

import Foundation

nonisolated struct MusicMixEQPlan: Equatable, Sendable {
    /// A band's gain `at` seconds into the overlap. Between two moves the gain goes evenly in decibels.
    nonisolated struct Move: Equatable, Sendable {
        var at: Double
        var gain: Double
    }

    /// Seconds where the incoming song's mids are cut. Its highs are open all the way.
    var incomingMid: [Move] = []
    var outgoingMid: [Move] = []
    var outgoingHigh: [Move] = []
    /// Seconds both singers would be heard together, carved apart by a mid cut.
    var carvedSec = 0.0

    /// The incoming mids at the start of the overlap, -9 dB.
    static let incomingMidStart = 0.35
    /// Where the outgoing mids go once the new bass is in, -6 dB.
    static let outgoingMidEnd = 0.5
    /// Where the outgoing highs go after that, -8 dB.
    static let outgoingHighEnd = 0.4
    /// The mids of the song that gives way to the other's voice, -14 dB.
    static let carveGain = 0.2
    /// How fast a carve closes and opens again.
    static let carveAttackSec = 0.15
    static let carveReleaseSec = 0.4
    /// Carves closer together than this are one, and shorter ones are left alone.
    static let carveJoinSec = 1.5
    static let carveShortestSec = 0.3
    /// The most carves on one song: with the three moves of a blend they fit in `MusicMixEQSettings.maxPoints`.
    static let mostCarves = 2
    /// An overlap shorter than this is over before a hand could turn a knob.
    static let shortestOverlapSec = 3.0
    private static let sampleSec = 0.05

    // MARK: Building

    /// The moves of `plan`, or nil when it has no blend (cuts, echoes and drop swaps have their own shape).
    static func make(for plan: TransitionPlan, _ inputs: MusicTransitionInputs) -> MusicMixEQPlan? {
        let length = plan.overlapSec
        guard plan.mode == .beat, [.longBlend, .filterSweep, .loopExtend].contains(plan.style),
              length.isFinite, length >= shortestOverlapSec else { return nil }
        let owner = bassOwnerChange(plan)
        let sweeps = plan.style == .filterSweep
        let unit = beatSec(plan)
        func on(_ t: Double) -> Double { snapped(t, unit: unit, length: length) }

        // A sweep swaps its bass early, so its mids get a little longer to open.
        let midOpen = on(sweeps ? max(owner, length * 3 / 8) : owner)
        let midStart = min(on(owner * 0.3), midOpen)
        var out = MusicMixEQPlan()
        let baseIn = [Move(at: midStart, gain: incomingMidStart), Move(at: midOpen, gain: 1)]
        var baseOut: [Move] = []
        if !sweeps {
            // The high-pass of a sweep already takes the outgoing song away from below.
            baseOut = [Move(at: on(owner * 0.75), gain: 1), Move(at: on(owner + (length - owner) / 4), gain: outgoingMidEnd)]
            out.outgoingHigh = [
                Move(at: on(owner), gain: 1), Move(at: on(owner + (length - owner) / 2), gain: outgoingHighEnd),
            ]
        }
        let both = inputs.vocalGuardEnabled ? bothSing(plan, inputs) : []
        out.carvedSec = both.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        // Before the new bass is in, the old song keeps its voice; after it, the new one does.
        out.incomingMid = carved(baseIn, windows: clip(both, to: 0...owner), length: length, opensAtEnd: true)
        out.outgoingMid = carved(baseOut, windows: clip(both, to: owner...length), length: length, opensAtEnd: false)
        return out
    }

    /// When the bass changes hands: the downbeat the swap lands on, or the middle of a swap that has no beat to land on.
    static func bassOwnerChange(_ plan: TransitionPlan) -> Double {
        let length = plan.overlapSec
        guard let swap = plan.bassSwapAtSec, swap.isFinite else { return length / 2 }
        let landed = plan.overlapBars > 0 || plan.floorAligned
        let at = swap + (landed ? plan.bassHandoverSec : plan.bassHandoverSec / 2)
        return at.isFinite ? min(max(at, length / 8), length * 7 / 8) : length / 2
    }

    /// One beat of the overlap in wall seconds, 0 when it has no bars.
    private static func beatSec(_ plan: TransitionPlan) -> Double {
        plan.overlapBars > 0 ? plan.overlapSec / Double(plan.overlapBars * 4) : 0
    }

    private static func snapped(_ t: Double, unit: Double, length: Double) -> Double {
        let at = unit > 0 ? (t / unit).rounded() * unit : t
        return min(max(at, 0), length)
    }

    // MARK: Running late

    /// How long a deck that can be heard takes to get to where its moves should be by now.
    static let catchUpSec = 0.1

    /// `moves` on a clock that reads `after` at the overlap's start. The ones that are due before it began (`after` is negative
    /// on an output with a long delay) become the gain they lead to at its start; a deck that can be `heard` by then goes
    /// there from open instead of jumping.
    static func shifted(_ moves: [Move], by after: Double, heard: Bool) -> [Move] {
        let all = moves.map { Move(at: $0.at + after, gain: $0.gain) }
        guard after.isFinite, let first = all.first, first.at < 0 else { return after.isFinite ? all : moves }
        let late = heard && gain(of: all, at: 0) < 1
        let from = late ? catchUpSec : 0
        return (late ? [Move(at: 0, gain: 1)] : []) + [Move(at: from, gain: gain(of: all, at: from))] + all.filter { $0.at > from }
    }

    /// The gain of `moves` at `t`: even in decibels between two moves, held before the first and after the last.
    private static func gain(of moves: [Move], at t: Double) -> Double {
        guard let next = moves.firstIndex(where: { $0.at > t }) else { return moves.last?.gain ?? 1 }
        guard next > 0 else { return moves[0].gain }
        let a = moves[next - 1], b = moves[next]
        guard a.gain > 0, b.gain > 0, b.at > a.at else { return a.gain }
        return a.gain * pow(b.gain / a.gain, (t - a.at) / (b.at - a.at))
    }

    // MARK: Vocal carve

    /// Where in the overlap (wall seconds) both songs are sung. Empty unless both songs' lyrics are known.
    static func bothSing(_ plan: TransitionPlan, _ inputs: MusicTransitionInputs) -> [ClosedRange<Double>] {
        guard let a = inputs.outgoing.vocalIntervals, let b = inputs.incoming.vocalIntervals, !a.isEmpty, !b.isEmpty,
              let mixOut = plan.mixOutSec, let mixIn = plan.mixInSec else { return [] }
        let outRate = inputs.outgoing.deckRate.isFinite && inputs.outgoing.deckRate > 0 ? inputs.outgoing.deckRate : 1
        let inRate = plan.stretchRate.isFinite && plan.stretchRate > 0 ? plan.stretchRate : 1
        var map: MusicLoopMap?
        if plan.style == .loopExtend, plan.loopRepeats > 0 {
            map = MusicLoopMap(MusicLoopExtend.Spec(
                loopStart: plan.loopStartSec, loopLength: plan.loopLengthSec, repeats: plan.loopRepeats
            ))
        }
        func sings(_ t: Double) -> Bool {
            let outAt = mixOut + t * outRate
            let item = mixIn + t * inRate
            // A loop never repeats a sung line, so the repeats sing nothing.
            if let map, item > map.loopEnd, item < map.loopEnd + map.extensionSec { return false }
            let inAt = map?.songTime(item) ?? item
            return a.contains { $0.contains(outAt) } && b.contains { $0.contains(inAt) }
        }
        var found: [ClosedRange<Double>] = []
        var start: Double?
        let steps = Int((plan.overlapSec / sampleSec).rounded(.down))
        for step in 0...max(0, steps) {
            let t = Double(step) * sampleSec
            if sings(t) {
                if start == nil { start = t }
            } else if let from = start {
                found.append(from...t)
                start = nil
            }
        }
        if let from = start, plan.overlapSec > from { found.append(from...plan.overlapSec) }
        return found
    }

    /// The parts of `ranges` inside `bounds`, joined where they are close and limited to `mostCarves`.
    static func clip(_ ranges: [ClosedRange<Double>], to bounds: ClosedRange<Double>) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for range in ranges {
            let low = max(range.lowerBound, bounds.lowerBound), high = min(range.upperBound, bounds.upperBound)
            guard high > low else { continue }
            if let last = out.last, low - last.upperBound < carveJoinSec {
                out[out.count - 1] = last.lowerBound...high
            } else {
                out.append(low...high)
            }
        }
        out.removeAll { $0.upperBound - $0.lowerBound < carveShortestSec }
        while out.count > mostCarves {
            // The two with the smallest gap become one.
            let gap = (1..<out.count).min { out[$0].lowerBound - out[$0 - 1].upperBound < out[$1].lowerBound - out[$1 - 1].upperBound }
            guard let gap else { break }
            out[gap - 1] = out[gap - 1].lowerBound...out[gap].upperBound
            out.remove(at: gap)
        }
        return out
    }

    /// `base` with each window held down to `carveGain`. `opensAtEnd`: the band must be open again by the end of the overlap
    /// (the incoming song plays on alone).
    static func carved(_ base: [Move], windows: [ClosedRange<Double>], length: Double, opensAtEnd: Bool) -> [Move] {
        guard !windows.isEmpty else { return base }
        let carves: [[Move]] = windows.map { window in
            let down = [
                Move(at: max(0, window.lowerBound - carveAttackSec), gain: 1), Move(at: window.lowerBound, gain: carveGain),
                Move(at: window.upperBound, gain: carveGain),
            ]
            // A carve that lasts to the end stays down.
            guard window.upperBound < length else { return down }
            return down + [Move(at: min(length, window.upperBound + carveReleaseSec), gain: 1)]
        }
        let times = Set((base + carves.flatMap { $0 }).map(\.at)).sorted()
        var out: [Move] = times.map { t in
            var value = gain(base, at: t)
            // A carve that starts at 0 is down from the first frame.
            for carve in carves { value = min(value, carve[0].at == carve[1].at && t <= carve[1].at ? carveGain : gain(carve, at: t)) }
            return Move(at: t, gain: value)
        }
        if opensAtEnd, let last = out.last, last.gain < 1 {
            if last.at < length { out.append(Move(at: length, gain: 1)) } else { out[out.count - 1].gain = 1 }
        }
        return out
    }

    /// A band's gain `at` seconds in: even in decibels between its moves, held outside them, 1 without any.
    static func gain(_ moves: [Move], at t: Double) -> Double {
        guard let first = moves.first, let last = moves.last else { return 1 }
        if t <= first.at { return first.gain }
        if t >= last.at { return last.gain }
        for (before, next) in zip(moves, moves.dropFirst()) where t < next.at {
            let span = next.at - before.at
            return span > 0 ? before.gain * pow(next.gain / before.gain, (t - before.at) / span) : next.gain
        }
        return last.gain
    }
}
