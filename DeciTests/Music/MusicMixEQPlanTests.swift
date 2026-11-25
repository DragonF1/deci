// DeciTests/Music/MusicMixEQPlanTests.swift
// The mixer moves of a blend: who gets its mids and highs when, and whose voice gives way.

import Foundation
import Testing
@testable import Deci

@Suite("MusicMixEQPlan")
struct MusicMixEQPlanTests {
    typealias BT = MusicBeatPlannerTests
    typealias P = MusicMixEQPlan

    /// A blend of 8 bars of 2 s whose bass is full on the downbeat at 8 s (or a sweep's at 4 s).
    static func blend(_ style: MusicTransitionStyle = .longBlend) -> TransitionPlan {
        var plan = TransitionPlan(
            mode: .beat, incomingStartSec: 10, outgoingEndSec: 216, fadeStartSec: 200, fadeSeconds: 16, incomingGainDb: 0,
            incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok
        )
        plan.style = style
        plan.mixOutSec = 200
        plan.mixInSec = 10
        plan.overlapBars = 8
        plan.overlapSec = 16
        plan.barSec = 2
        plan.bassSwapAtSec = style == .filterSweep ? 3.5 : 7.5
        plan.bassHandoverSec = 0.5
        return plan
    }

    static func inputs(out: [ClosedRange<Double>]? = nil, in incoming: [ClosedRange<Double>]? = nil) -> MusicTransitionInputs {
        var i = BT.inputs(swap: true)
        i.vocalGuardEnabled = true
        i.outgoing.vocalIntervals = out
        i.incoming.vocalIntervals = incoming
        return i
    }

    @Test("highs first, then mids, then bass on the one; after it the old song's mids and then its highs step back, all on beats")
    func order() throws {
        let eq = try #require(P.make(for: Self.blend(), Self.inputs()))
        #expect(eq.incomingMid == [.init(at: 2.5, gain: P.incomingMidStart), .init(at: 8, gain: 1)])
        #expect(eq.outgoingMid == [.init(at: 6, gain: 1), .init(at: 10, gain: P.outgoingMidEnd)])
        #expect(eq.outgoingHigh == [.init(at: 8, gain: 1), .init(at: 12, gain: P.outgoingHighEnd)])
        #expect(eq.carvedSec == 0)
    }

    @Test("a sweep leaves the outgoing song to its high-pass and gives the incoming mids until three eighths")
    func sweep() throws {
        let eq = try #require(P.make(for: Self.blend(.filterSweep), Self.inputs()))
        #expect(eq.outgoingMid.isEmpty && eq.outgoingHigh.isEmpty)
        #expect(eq.incomingMid.last == .init(at: 6, gain: 1) && eq.incomingMid.first?.gain == P.incomingMidStart)
    }

    @Test("no blend, no moves: cuts, echoes, drop swaps, plain fades and very short overlaps", arguments: [MusicTransitionStyle.quickCut, .echoOut, .dropSwap])
    func onlyBlends(style: MusicTransitionStyle) {
        #expect(P.make(for: Self.blend(style), Self.inputs()) == nil)
        var plain = Self.blend()
        plain.mode = .smart
        #expect(P.make(for: plain, Self.inputs()) == nil)
        var short = Self.blend()
        short.overlapSec = 2
        #expect(P.make(for: short, Self.inputs()) == nil)
    }

    @Test("the level of a steady pair in every band dips by less than 2 dB through a blend, and no gain is above 1")
    func noHole() throws {
        let eq = try #require(P.make(for: Self.blend(), Self.inputs()))
        for moves in [eq.incomingMid, eq.outgoingMid, eq.outgoingHigh] { #expect(moves.allSatisfy { $0.gain > 0 && $0.gain <= 1 }) }
        for step in 0...160 {
            let t = Double(step) / 10
            let a = cos(t / 16 * .pi / 2), b = sin(t / 16 * .pi / 2)
            let mid = pow(a * P.gain(eq.outgoingMid, at: t), 2) + pow(b * P.gain(eq.incomingMid, at: t), 2)
            let high = pow(a * P.gain(eq.outgoingHigh, at: t), 2) + pow(b, 2)
            #expect(10 * log10(mid) > -2 && 10 * log10(high) > -2, "\(t) s: mid \(10 * log10(mid)) high \(10 * log10(high))")
        }
    }

    @Test("two singers: before the bass swap the new song's mids give way, after it the old song's")
    func carve() throws {
        // Outgoing sings 203...206 and 211...213 (3...6 and 11...13 in), incoming 14...17 and 20...30 (4...7 and 10...20 in).
        let eq = try #require(P.make(for: Self.blend(), Self.inputs(out: [203...206, 211...213], in: [14...17, 20...30])))
        #expect(abs(eq.carvedSec - 4) < 0.2, "\(eq.carvedSec)")
        for t in [4.2, 5, 5.8] {
            #expect(P.gain(eq.incomingMid, at: t) <= P.carveGain + 1e-9 && P.gain(eq.outgoingMid, at: t) == 1, "\(t)")
        }
        for t in [11.2, 12, 12.8] {
            #expect(P.gain(eq.outgoingMid, at: t) <= P.carveGain + 1e-9 && P.gain(eq.incomingMid, at: t) == 1, "\(t)")
        }
        #expect(P.gain(eq.incomingMid, at: 3.5) > P.carveGain && P.gain(eq.incomingMid, at: 8) == 1)
        #expect(P.gain(eq.outgoingMid, at: 14) == P.outgoingMidEnd)
        #expect(eq.incomingMid.last?.gain == 1)
    }

    @Test("singing across the swap changes hands on it: the new voice is open when the old one is down")
    func carveAcrossTheSwap() throws {
        let eq = try #require(P.make(for: Self.blend(), Self.inputs(out: [100...230], in: [0...200])))
        #expect(abs(eq.carvedSec - 16) < 0.1)
        #expect(P.gain(eq.incomingMid, at: 0) == P.carveGain && P.gain(eq.incomingMid, at: 7.9) == P.carveGain)
        #expect(P.gain(eq.outgoingMid, at: 7.5) > 0.5 && P.gain(eq.outgoingMid, at: 8) == P.carveGain && P.gain(eq.outgoingMid, at: 16) == P.carveGain)
        #expect(P.gain(eq.incomingMid, at: 8.4) == 1)
    }

    @Test("no carve without both songs' lyrics, or with the vocal guard off")
    func carveNeedsLyrics() throws {
        let plain = try #require(P.make(for: Self.blend(), Self.inputs()))
        for i in [Self.inputs(out: [200...216]), Self.inputs(in: [0...200]), Self.inputs(out: [200...216], in: [])] {
            #expect(P.make(for: Self.blend(), i) == plain)
        }
        var off = Self.inputs(out: [200...216], in: [0...200])
        off.vocalGuardEnabled = false
        #expect(P.make(for: Self.blend(), off) == plain)
    }

    @Test("the windows follow the rates: the outgoing deck's, the tempo match's, and a loop's repeats sing nothing")
    func windowsFollowTheRates() throws {
        var plan = Self.blend()
        var i = Self.inputs(out: [204...208], in: [12...30])
        #expect(abs(try #require(P.bothSing(plan, i).first).lowerBound - 4) < 0.06)
        i.outgoing.deckRate = 1.25
        #expect(abs(try #require(P.bothSing(plan, i).first).lowerBound - 3.2) < 0.06)
        i.outgoing.deckRate = 1
        i.incoming.vocalIntervals = [16...30]
        plan.stretchRate = 1.0625
        #expect(abs(try #require(P.bothSing(plan, i).first).lowerBound - 6 / 1.0625) < 0.06)
        plan.stretchRate = 1
        plan.style = .loopExtend
        plan.loopStartSec = 10
        plan.loopLengthSec = 4
        plan.loopBars = 2
        plan.loopRepeats = 1
        // The song is at 14 s until the repeat is over, 8 s in, so its 16 s comes 10 s in: nothing together.
        #expect(P.bothSing(plan, i).isEmpty)
        i.outgoing.vocalIntervals = [204...214]
        #expect(abs(try #require(P.bothSing(plan, i).first).lowerBound - 10) < 0.06)
    }

    @Test("however many lines collide, a band never has more points than the EQ holds, and its times go up")
    func pointBudget() throws {
        let lines = stride(from: 0.0, to: 16, by: 2).map { ($0 + 200)...($0 + 200.4) }
        let eq = try #require(P.make(for: Self.blend(), Self.inputs(out: lines, in: [0...200])))
        for moves in [eq.incomingMid, eq.outgoingMid, eq.outgoingHigh] {
            #expect(moves.count <= MusicMixEQSettings.maxPoints)
            #expect(zip(moves, moves.dropFirst()).allSatisfy { $0.at < $1.at })
            #expect(moves.allSatisfy { $0.at >= 0 && $0.at <= 16 && $0.gain >= P.carveGain && $0.gain <= 1 })
        }
    }

    @Test("the planner puts the moves on every blend it returns, and none on a smart fade")
    func plannerHook() throws {
        var i = BT.inputs(swap: true)
        let blend = MusicTransitionPlanner.plan(i)
        #expect(blend.mode == .beat && blend.style == .longBlend)
        #expect(blend.mixEQ == P.make(for: blend, i) && blend.mixEQ != nil)
        i.beatMixEnabled = false
        #expect(MusicTransitionPlanner.plan(i).mixEQ == nil)
    }

    @Test("the log line names every move and nothing is logged without any")
    func logLine() {
        var plan = Self.blend()
        #expect(MusicTransitionLog.eqLine(from: "a", to: "b", plan: plan) == nil)
        plan.mixEQ = P(incomingMid: [.init(at: 1, gain: 0.35), .init(at: 8, gain: 1)], outgoingHigh: [.init(at: 8, gain: 1)], carvedSec: 1.4)
        #expect(MusicTransitionLog.eqLine(from: "a", to: "b", plan: plan)
            == "transition_eq from=a to=b inMid=1.00:0.35,8.00:1.00 outMid=- outHigh=8.00:1.00 carve=1.40")
    }

    @Test("moves due before the clock starts become the gain they lead to; a deck that is heard gets there without a jump")
    func lateMoves() {
        let moves = [MusicMixEQPlan.Move(at: 1, gain: 1), .init(at: 1.2, gain: 0.25), .init(at: 3, gain: 0.25), .init(at: 3.4, gain: 1)]
        let ahead = P.shifted(moves, by: 0.5, heard: true)
        #expect(ahead.count == 4 && zip(ahead, moves).allSatisfy { abs($0.at - $1.at - 0.5) < 1e-9 && $0.gain == $1.gain })
        #expect(P.shifted(moves, by: .nan, heard: true) == moves)
        let quiet = P.shifted(moves, by: -1.1, heard: false)
        #expect(quiet.count == 4 && quiet[0].at == 0 && abs(quiet[0].gain - 0.5) < 1e-9 && abs(quiet[1].at - 0.1) < 1e-9)
        let heard = P.shifted(moves, by: -2, heard: true)
        #expect(heard.prefix(2).map(\.at) == [0, P.catchUpSec] && heard.prefix(2).map(\.gain) == [1, 0.25])
        #expect(abs(heard[2].at - 1) < 1e-9 && heard.last?.gain == 1 && heard.count == 4)
        // All of them past: open again, nothing to do.
        #expect(P.shifted(moves, by: -5, heard: true).allSatisfy { $0.gain == 1 })
    }

    @Test("a swap length that is not a number leaves the bass change in the middle")
    func brokenHandover() {
        var plan = Self.blend()
        plan.bassHandoverSec = .nan
        #expect(P.bassOwnerChange(plan) == 8)
    }
}
