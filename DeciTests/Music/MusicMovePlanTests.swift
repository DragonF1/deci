// DeciTests/Music/MusicMovePlanTests.swift
// The plans of the new moves: what each puts on top of the blend or the cut it is made of, where it lands, and when there is
// none.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicMovePlan")
struct MusicMovePlanTests {
    typealias B = MusicBeatPlanner
    typealias BT = MusicBeatPlannerTests
    typealias P = MusicTransitionPlanner

    /// A 120 bpm blend with a bass swap: the outgoing bar is 2 s.
    static func blend(_ inputs: MusicTransitionInputs = BT.inputs(swap: true)) throws -> TransitionPlan {
        let smart = P.smartPlan(inputs)
        let beat = B.plan(inputs, smart: smart)
        try #require(beat.mode == .beat && beat.bassSwapAtSec != nil && beat.overlapBars >= 4)
        return beat
    }

    // MARK: Low-pass sweep

    @Test("the low-pass sweep is the blend, bass swap and all, with a falling low-pass on the outgoing song")
    func lowpassIsTheBlend() throws {
        let beat = try Self.blend()
        let plan = try #require(B.lowpassSweepPlan(from: beat))
        #expect(plan.style == .lowpassSweep && !plan.sweepHighpass)
        #expect(plan.sweepFromHz == 18_000 && plan.sweepToHz == 300)
        #expect(plan.bassSwapAtSec != nil, "the lows still change hands in one step")
        var same = plan
        same.style = .longBlend
        same.sweepHighpass = true
        same.sweepFromHz = 0
        same.sweepToHz = 0
        #expect(same == beat)
        #expect(B.lowpassSweepPlan(from: P.smartPlan(BT.inputs())) == nil)
        let cut = try #require(B.styledPlan(BT.inputs(), smart: P.smartPlan(BT.inputs()), style: .quickCut))
        #expect(B.lowpassSweepPlan(from: cut) == nil)
    }

    // MARK: Echo throw

    @Test("the throw lands on a bar line after the new bass, echoes one beat apart and keeps the song for as long as it is heard")
    func throwLands() throws {
        let i = BT.inputs(swap: true)
        let beat = try Self.blend(i)
        let plan = try #require(B.echoThrowPlan(from: beat, i, smart: P.smartPlan(i)))
        #expect(plan.style == .echoThrow)
        #expect(abs(plan.echoThrowAtSec / 2 - (plan.echoThrowAtSec / 2).rounded()) < 1e-9, "a bar is 2 s, the throw is at \(plan.echoThrowAtSec)")
        #expect(abs(plan.echoThrowAtSec - beat.overlapSec * 0.75) <= 1 + 1e-9)
        let bass = try #require(beat.bassSwapAtSec) + beat.bassHandoverSec
        #expect(plan.echoThrowAtSec > bass && plan.echoThrowAtSec < beat.overlapSec)
        #expect(plan.echoDelaySec == 0.5 && plan.echoTailSec >= 1 && plan.echoTailSec <= 3)
        let end = try #require(plan.outgoingEndSec), mixOut = try #require(plan.mixOutSec)
        #expect(end >= mixOut + plan.echoThrowAtSec + plan.echoTailSec - 1e-9)
        #expect(end <= 236 + 1e-9, "never past the song's end")
        #expect(plan.mixOutSec == beat.mixOutSec && plan.mixInSec == beat.mixInSec && plan.overlapSec == beat.overlapSec)
    }

    @Test("no throw without bars, a bass swap, a trusted grid or room for two repeats")
    func throwNeeds() throws {
        let i = BT.inputs(swap: true)
        let smart = P.smartPlan(i)
        let beat = try Self.blend(i)
        var plain = beat
        plain.bassSwapAtSec = nil
        #expect(B.echoThrowPlan(from: plain, i, smart: smart) == nil)
        plain = beat
        plain.overlapBars = 0
        #expect(B.echoThrowPlan(from: plain, i, smart: smart) == nil)
        plain = beat
        plain.style = .dropSwap
        #expect(B.echoThrowPlan(from: plain, i, smart: smart) == nil)
        var loose = i
        loose.outgoing.grid = BT.grid(phase: nil)
        #expect(B.echoThrowPlan(from: beat, loose, smart: smart) == nil)
        loose.outgoing.grid = BT.grid(confidence: 0.1)
        #expect(B.echoThrowPlan(from: beat, loose, smart: smart) == nil)
        // The song is over half a second after the throw.
        let plan = try #require(B.echoThrowPlan(from: beat, i, smart: smart))
        var short = smart
        short.outgoingEndSec = try #require(beat.mixOutSec) + plan.echoThrowAtSec + 0.5
        #expect(B.echoThrowPlan(from: beat, i, smart: short) == nil)
        // The bass lands so late that the throw would come before it.
        var late = beat
        late.bassSwapAtSec = beat.overlapSec - 1
        late.bassHandoverSec = 0.5
        #expect(B.echoThrowPlan(from: late, i, smart: smart) == nil)
    }

    // MARK: Loop roll

    @Test("the roll is the bar that ends where the new bass lands")
    func rollLands() throws {
        let i = BT.inputs(swap: true)
        let beat = try Self.blend(i)
        let plan = try #require(B.loopRollPlan(from: beat, i))
        #expect(plan.style == .loopRoll && plan.rollBeatSec == 0.5)
        let bass = try #require(beat.bassSwapAtSec) + beat.bassHandoverSec
        #expect(abs(plan.rollAtSec + 4 * plan.rollBeatSec - bass) < 1e-9)
        #expect(plan.rollAtSec >= 0.5)
        var same = plan
        same.style = .longBlend
        same.rollAtSec = 0
        same.rollBeatSec = 0
        #expect(same == beat)
        var brief = beat
        brief.overlapBars = 2
        #expect(B.loopRollPlan(from: brief, i) == nil, "too few bars")
        var early = beat
        early.bassSwapAtSec = 1.5
        early.bassHandoverSec = 0.5
        #expect(B.loopRollPlan(from: early, i) == nil, "the bar before the bass is not inside the overlap")
    }

    // MARK: Reverb out

    @Test("the reverb out is the cut with a room behind it, and needs a second of song left")
    func reverbTail() throws {
        let i = BT.inputs()
        let smart = P.smartPlan(i)
        let cut = try #require(B.styledPlan(i, smart: smart, style: .quickCut))
        let plan = try #require(B.styledPlan(i, smart: smart, style: .reverbOut))
        #expect(plan.style == .reverbOut && plan.echoTailSec == 2.5 && plan.echoDelaySec == 0)
        #expect(plan.mixOutSec == cut.mixOutSec && plan.mixInSec == cut.mixInSec && plan.brakeLeadSec == 0)
        let mixOut = try #require(plan.mixOutSec)
        #expect(plan.outgoingEndSec == mixOut + 2.5)
        var tail = cut
        #expect(B.applyTail(&tail, style: .reverbOut, cut: 100, end: 101.5, rate: 1, beat: 0.5))
        #expect(tail.echoTailSec == 1.5 && tail.outgoingEndSec == 101.5)
        #expect(!B.applyTail(&tail, style: .reverbOut, cut: 100, end: 100.9, rate: 1, beat: 0.5))
        #expect(!B.applyTail(&tail, style: .reverbOut, cut: 100, end: .nan, rate: 1, beat: 0.5) || tail.echoTailSec.isFinite)
        // A song that plays a tenth faster leaves less wall time, and its item is kept for the tail's worth of song.
        #expect(B.applyTail(&tail, style: .reverbOut, cut: 100, end: 200, rate: 1.1, beat: 0.5))
        #expect(abs((tail.outgoingEndSec ?? 0) - 102.75) < 1e-9)
    }

    // MARK: Brake

    @Test("the brake takes the last beat before the bar line the cut would land on, in both songs")
    func brakeLead() throws {
        let i = BT.inputs(b: BT.grid(anchor: 0.1, phase: 1, span: 0.1...236), bSilenceStart: 4)
        let smart = P.smartPlan(i)
        let cut = try #require(B.styledPlan(i, smart: smart, style: .quickCut))
        let plan = try #require(B.styledPlan(i, smart: smart, style: .brake))
        #expect(plan.style == .brake && plan.brakeLeadSec == 0.5 && plan.echoTailSec == 0.5)
        let cutOut = try #require(cut.mixOutSec), cutIn = try #require(cut.mixInSec)
        let out = try #require(plan.mixOutSec), mixIn = try #require(plan.mixInSec)
        #expect(abs(out - (cutOut - 0.5)) < 1e-9 && abs(mixIn - (cutIn - 0.5)) < 1e-9)
        #expect(plan.incomingStartSec == mixIn && plan.fadeStartSec == out && plan.outgoingEndSec == out + 0.5)
        #expect(plan.incomingRate == 1)
    }

    @Test("a beat too short or too long for a platter is held to 0.4 to 0.6 s, and the new song's own start limits the lead")
    func brakeLengths() throws {
        #expect(B.brakeLength(0.3) == 0.4 && B.brakeLength(0.5) == 0.5 && B.brakeLength(0.9) == 0.6 && B.brakeLength(nil) == 0.5)
        #expect(B.brakeLead(.brake, beat: 0.5, mixIn: 10) == 0.5)
        #expect(B.brakeLead(.brake, beat: 0.5, mixIn: 0.2) == 0.2)
        #expect(B.brakeLead(.brake, beat: 0.5, mixIn: 0) == 0)
        #expect(B.brakeLead(.reverbOut, beat: 0.5, mixIn: 10) == 0 && B.brakeLead(.quickCut, beat: 0.5, mixIn: 10) == 0)
        var plan = try #require(B.styledPlan(BT.inputs(), smart: P.smartPlan(BT.inputs()), style: .quickCut))
        #expect(!B.applyTail(&plan, style: .brake, cut: 100, end: 100.2, rate: 1, beat: 0.5))
        #expect(B.applyTail(&plan, style: .brake, cut: 100, end: 100.4, rate: 1, beat: 0.5))
        #expect(plan.echoTailSec <= 0.4 + 1e-9)
    }

    @Test("songs with no grid still get a reverb out and a brake, at the point the fade would have started")
    func gridless() throws {
        let i = BT.inputs(a: nil, b: nil, bSilenceStart: 3)
        let smart = P.smartPlan(i)
        let point = try #require(smart.fadeStartSec)
        let reverb = try #require(B.styledPlan(i, smart: smart, style: .reverbOut))
        #expect(reverb.mixOutSec == point && reverb.echoTailSec > 0 && reverb.brakeLeadSec == 0)
        let brake = try #require(B.styledPlan(i, smart: smart, style: .brake))
        let out = try #require(brake.mixOutSec)
        #expect(abs(out + brake.brakeLeadSec - point) < 1e-9)
        #expect(brake.brakeLeadSec > 0 && brake.brakeLeadSec <= 0.5)
    }

    // MARK: Double drop

    /// Both songs build up to a drop: the outgoing one at `out` s, the incoming one at about `into` s.
    static func drops(
        out: [Double] = [204.2], into: [Double] = [40.6], b: MusicBeatGrid? = BT.grid(anchor: 0.1, phase: 1, span: 0.1...236),
        swap: Bool = true, bStart: Double = 0
    ) -> MusicTransitionInputs {
        var i = BT.inputs(b: b, bSilenceStart: bStart, swap: swap)
        i.outgoing.analysis?.energy = DropFixtures.envelope(steps: out)
        i.incoming.analysis?.energy = DropFixtures.envelope(steps: into)
        return i
    }

    static func doubleDrop(_ i: MusicTransitionInputs) -> TransitionPlan? { B.doubleDropPlan(i, smart: P.smartPlan(i)) }

    @Test("both drops land on the same moment in the middle of the overlap, and the bass changes hands on it")
    func doubleDropLands() throws {
        let i = Self.drops()
        let aGrid = try #require(i.outgoing.grid), bGrid = try #require(i.incoming.grid)
        let a = try #require(i.outgoing.analysis), b = try #require(i.incoming.analysis)
        let leaving = try #require(MusicDropDetector.drops(in: a, grid: aGrid)?.last)
        let landing = try #require(MusicDropDetector.best(in: b, grid: bGrid))
        let plan = try #require(Self.doubleDrop(i))
        let mixOut = try #require(plan.mixOutSec), mixIn = try #require(plan.mixInSec)
        #expect(plan.style == .doubleDrop && plan.mode == .beat && plan.incomingRate == 1)
        #expect(plan.overlapBars == 16 && plan.overlapSec == 32)
        #expect(abs(leaving.timeSec - mixOut - 16) < 1e-9, "the outgoing drop is \(leaving.timeSec - mixOut) s in")
        #expect(abs(landing.timeSec - mixIn - 16) < 0.02, "the incoming drop is \(landing.timeSec - mixIn) s in")
        #expect(plan.outgoingEndSec == leaving.timeSec + 16)
        let bass = try #require(plan.bassSwapAtSec) + plan.bassHandoverSec
        #expect(abs(bass - 16) < 1e-9, "the bass is the new song's at \(bass) s")
    }

    @Test("a song with less room around its drop gets four bars either side, or no double drop")
    func doubleDropRoom() throws {
        // 10 s before the incoming drop is less than 8 bars and more than 4.
        let tight = try #require(Self.doubleDrop(Self.drops(into: [10.6])))
        #expect(tight.overlapBars == 8 && tight.overlapSec == 16)
        // The same drop in a song that only starts at 4 s.
        #expect(Self.doubleDrop(Self.drops(into: [10.6], bStart: 4)) == nil)
        // The outgoing song ends 4 s after its drop.
        #expect(Self.doubleDrop(Self.drops(out: [232.2])) == nil)
        // Its only drop is in the first half: that is no place to leave.
        #expect(Self.doubleDrop(Self.drops(out: [100.2])) == nil)
    }

    @Test("no double drop without two drops, the bass swap, one tempo and two trusted grids")
    func doubleDropNeeds() throws {
        #expect(Self.doubleDrop(Self.drops(out: [])) == nil)
        #expect(Self.doubleDrop(Self.drops(into: [])) == nil)
        #expect(Self.doubleDrop(Self.drops(swap: false)) == nil)
        #expect(Self.doubleDrop(Self.drops(b: BT.grid(period: 60 / 131, anchor: 0.1, phase: 1, span: 0.1...236))) == nil)
        #expect(Self.doubleDrop(Self.drops(b: BT.grid(period: 1, anchor: 0.1, phase: 1, span: 0.1...236))) == nil, "half time")
        #expect(Self.doubleDrop(Self.drops(b: BT.grid(anchor: 0.1, phase: nil, span: 0.1...236))) == nil)
        #expect(Self.doubleDrop(Self.drops(b: BT.grid(anchor: 0.1, phase: 1, confidence: 0.1, span: 0.1...236))) == nil)
        for spoil in [\MusicTransitionInputs.manualSkip, \.albumInOrder, \.loopSong] {
            var i = Self.drops()
            i[keyPath: spoil] = true
            #expect(Self.doubleDrop(i) == nil)
        }
    }

    @Test("with a DJ exit the double drop is over by it, and starts from a drop not long before it")
    func doubleDropExit() throws {
        var i = Self.drops(out: [120.2])
        i.djMixOutSec = 136.2
        let plan = try #require(Self.doubleDrop(i))
        #expect(plan.outgoingEndSec == 136.2)
        i.djMixOutSec = 120.2
        #expect(Self.doubleDrop(i) == nil, "the exit comes before the drop has been heard")
        i.djMixOutSec = 190.2
        #expect(Self.doubleDrop(i) == nil, "the drop is more than 32 bars before the exit")
    }

    // MARK: Through the planner

    @Test("every new move the picker can ask for comes out of the planner as that move, at rate 1 and inside the song")
    func throughThePlanner() throws {
        for style in [MusicTransitionStyle.lowpassSweep, .echoThrow, .loopRoll] {
            var i = BT.inputs(swap: true)
            // Two songs of one key and one energy suit all three.
            let key = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.5).encode()
            i.outgoing.analysis?.keyInfo = key
            i.incoming.analysis?.keyInfo = key
            let plan = MusicTransitionStylePicker.$debugScopedStyle.withValue(style) { P.plan(i) }
            #expect(plan.style == style, "asked for \(style.rawValue), got \(plan.style.rawValue)")
            #expect(plan.incomingRate == 1)
            let end = try #require(plan.outgoingEndSec)
            #expect(end <= 240 && plan.overlapSec > 0)
        }
    }

    @Test("the tempo does not bridge a clash for a move on a blend")
    func clash() {
        let i = BT.inputs(b: BT.grid(period: 60 / 131, anchor: 0.1, phase: 1, span: 0.1...236), swap: true)
        for style in [MusicTransitionStyle.echoThrow, .loopRoll, .doubleDrop] {
            let plan = MusicTransitionStylePicker.$debugScopedStyle.withValue(style) { P.plan(i) }
            #expect(plan.style != style)
            #expect(plan.echoThrowAtSec == 0 && plan.rollAtSec == 0)
        }
    }
}
