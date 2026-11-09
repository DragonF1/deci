// DeciTests/Music/MusicLoopExtendTests.swift
// Tier 4b P2b: the loop map, the composition builder, the loop-extend plan and the picker rules around it.

import Foundation
import AVFoundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicLoopExtend")
struct MusicLoopExtendTests {
    typealias B = MusicBeatPlanner
    typealias BT = MusicBeatPlannerTests
    typealias S = MusicTransitionStyleInputs

    // MARK: Map and spec

    private let spec = MusicLoopExtend.Spec(loopStart: 4, loopLength: 8, repeats: 2)

    @Test("the spec snaps to the sample grid and knows its end and extension")
    func specNumbers() {
        let odd = MusicLoopExtend.Spec(loopStart: 1.0000001, loopLength: 2.1234567, repeats: 3)
        #expect(odd.loopStart * 48_000 == (odd.loopStart * 48_000).rounded())
        #expect(odd.loopLength * 48_000 == (odd.loopLength * 48_000).rounded())
        #expect(spec.loopEnd == 12 && spec.extensionSec == 16 && spec.isValid)
        for bad in [
            MusicLoopExtend.Spec(loopStart: -1, loopLength: 8, repeats: 1),
            MusicLoopExtend.Spec(loopStart: 1, loopLength: 0, repeats: 1),
            MusicLoopExtend.Spec(loopStart: 1, loopLength: 8, repeats: 0),
            MusicLoopExtend.Spec(loopStart: 1, loopLength: 8, repeats: 99),
            MusicLoopExtend.Spec(loopStart: .nan, loopLength: 8, repeats: 1),
        ] { #expect(!bad.isValid) }
    }

    @Test("song time from composition time: identical before the loop's end, held in the repeats, shifted back after")
    func songTime() {
        let map = MusicLoopMap(spec)
        #expect(map.songTime(0) == 0 && map.songTime(5) == 5 && map.songTime(12) == 12)
        #expect(map.songTime(12.001) == 12 && map.songTime(20) == 12 && map.songTime(27.999) == 12)
        #expect(map.songTime(28) == 12 && map.songTime(30) == 14 && map.songTime(100) == 84)
    }

    @Test("composition time from song time: the same before the loop's end, the extension added after")
    func itemTime() {
        let map = MusicLoopMap(spec)
        #expect(map.itemTime(0) == 0 && map.itemTime(11.999) == 11.999)
        #expect(map.itemTime(12) == 28 && map.itemTime(14) == 30 && map.itemTime(84) == 100)
    }

    @Test("the two maps agree: a song time after the loop comes back to itself, and the map never runs backwards")
    func roundTrip() {
        let map = MusicLoopMap(spec)
        for song in stride(from: 0.0, through: 200, by: 0.37) {
            if song >= map.loopEnd || song < map.loopEnd { #expect(abs(map.songTime(map.itemTime(song)) - song) < 1e-9) }
        }
        var last = -1.0
        for item in stride(from: 0.0, through: 300, by: 0.11) {
            let song = map.songTime(item)
            #expect(song >= last)
            last = song
        }
    }

    @Test("a plan gives a spec only for a loop-extend plan with a usable loop")
    func specFromPlan() {
        var plan = TransitionPlan.tier1Gapless
        #expect(MusicLoopExtend.spec(from: plan) == nil && MusicLoopExtend.spec(from: nil) == nil)
        plan.loopStartSec = 4; plan.loopLengthSec = 8; plan.loopRepeats = 2
        #expect(MusicLoopExtend.spec(from: plan) == nil, "a long blend carries no loop")
        plan.style = .loopExtend
        #expect(MusicLoopExtend.spec(from: plan) == spec)
        plan.loopRepeats = 0
        #expect(MusicLoopExtend.spec(from: plan) == nil)
        plan.loopRepeats = 2; plan.loopLengthSec = .infinity
        #expect(MusicLoopExtend.spec(from: plan) == nil)
    }

    @Test("only a file on this Mac is local")
    func locality() {
        #expect(MusicLoopExtend.isLocal(.trackCache) && MusicLoopExtend.isLocal(.download) && !MusicLoopExtend.isLocal(.network))
    }

    // MARK: Composition

    private func tone(seconds: Double) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/loop-extend", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tone-\(UUID().uuidString).m4a")
        let rate = 44_100.0
        let frames = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(0.2 * sin(2 * Double.pi * 440 * Double(frame) / rate))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        try await ToneFile.write(interleavedStereo: samples, sampleRate: rate, to: url)
        return url
    }

    @Test("a local file composes into the song plus the repeats; a remote origin, a bad spec and a loop past the audio are refused")
    func composition() async throws {
        let url = try await tone(seconds: 20)
        let asset = AVURLAsset(url: url)
        let loop = MusicLoopExtend.Spec(loopStart: 2, loopLength: 4, repeats: 2)
        for origin in [ResolvedStream.Origin.trackCache, .download] {
            let composition = try await MusicLoopExtend.composition(asset: asset, spec: loop, songDuration: 20, origin: origin)
            #expect(abs(composition.duration.seconds - (20 + loop.extensionSec)) < 0.05, "\(composition.duration.seconds)")
        }
        await #expect(throws: MusicLoopExtend.Failure.remote) {
            _ = try await MusicLoopExtend.composition(asset: asset, spec: loop, songDuration: 20, origin: .network)
        }
        await #expect(throws: MusicLoopExtend.Failure.badSpec) {
            _ = try await MusicLoopExtend.composition(
                asset: asset, spec: .init(loopStart: 2, loopLength: 0, repeats: 1), songDuration: 20, origin: .download)
        }
        await #expect(throws: MusicLoopExtend.Failure.badSpec) {
            _ = try await MusicLoopExtend.composition(asset: asset, spec: loop, songDuration: .nan, origin: .download)
        }
        await #expect(throws: MusicLoopExtend.Failure.rangeOutsideAsset) {
            _ = try await MusicLoopExtend.composition(
                asset: asset, spec: .init(loopStart: 18, loopLength: 8, repeats: 1), songDuration: 20, origin: .download)
        }
    }

    // MARK: Vocal guard in item time

    @Test("the collision is measured on the incoming song in composition time: its intro end moves out by the extension")
    func collisionInItemTime() throws {
        let b = BT.inputs().incoming.analysis
        let a = BT.inputs(aOutro: 230).outgoing.analysis
        let map = MusicLoopMap(.init(loopStart: 0.6, loopLength: 4, repeats: 1))
        let plain = try #require(MusicVocalGuard.collisionSec(outgoing: a, incoming: b, outStart: 216, inStart: 0.6, length: 16))
        let looped = try #require(MusicVocalGuard.collisionSec(
            outgoing: a, incoming: b, outStart: 216, inStart: 0.6, length: 16, incomingLoop: map))
        #expect(looped < plain, "the loop pushes the incoming vocal later: \(looped) against \(plain)")
        // With no loop the call is the old one.
        let none = MusicVocalGuard.collisionSec(outgoing: a, incoming: b, outStart: 216, inStart: 0.6, length: 16, incomingLoop: nil)
        #expect(none == plain)
        // Lyric intervals move the same way: a line at 9..12 s sits after the loop's end (4.6), so it is heard 4 s later.
        let moved = try #require(MusicVocalGuard.collisionSec(
            outgoing: nil, incoming: nil, outStart: 0, inStart: 0.6, length: 16, outgoingIntervals: [0...16],
            incomingIntervals: [9...12], incomingLoop: map))
        let still = try #require(MusicVocalGuard.collisionSec(
            outgoing: nil, incoming: nil, outStart: 0, inStart: 0.6, length: 16, outgoingIntervals: [0...16],
            incomingIntervals: [9...12]))
        #expect(abs(moved - still) < 1e-9, "the line is the same length wherever it lands, as long as it is inside the overlap")
    }

    // MARK: Planner

    /// A pair whose incoming intro (to `introEnd`) is shorter than the 8 bar overlap and whose outgoing song is still
    /// singing into it: the outgoing outro starts late, so the overlap has the outgoing singer in it.
    static func shortIntro(introEnd: Double = 10, aOutro: Double = 230, swap: Bool = false) -> MusicTransitionInputs {
        var i = BT.inputs(aOutro: aOutro, swap: swap)
        i.incoming.analysis?.introEnd = introEnd
        i.vocalGuardEnabled = true
        i.incomingLocal = true
        return i
    }

    private func loopPlan(_ i: MusicTransitionInputs) -> TransitionPlan? {
        B.loopExtendPlan(i, smart: MusicTransitionPlanner.smartPlan(i))
    }

    @Test("a short incoming intro under a singing outgoing song gets its first bars looped, and the overlap is clean")
    func loopsAShortIntro() throws {
        let i = Self.shortIntro()
        let plan = try #require(loopPlan(i))
        #expect(plan.style == .loopExtend && plan.mode == .beat && plan.reason == .ok)
        #expect(plan.loopBars == 4, "the intro has 4 bars, not 8")
        let mixIn = try #require(plan.mixInSec)
        #expect(plan.loopStartSec == MusicLoopExtend.snap(mixIn), "the loop starts on the plan's first bar line")
        #expect(abs(plan.loopLengthSec - 4 * 4 * 0.5) < 1e-3, "4 bars of a 120 bpm song is 8 s")
        #expect((1...MusicBeatPlanner.maxPlannedRepeats).contains(plan.loopRepeats))
        let spec = try #require(MusicLoopExtend.spec(from: plan))
        #expect(spec.loopEnd <= 10 + 1e-9, "the loop ends inside the intro")
        #expect((plan.vocalBeforeSec ?? 0) > MusicVocalGuard.budgetSec)
        #expect((plan.vocalCollisionSec ?? 99) <= MusicVocalGuard.budgetSec)
        #expect(plan.vocalAction == "loop")
        // The overlap is the plain blend's: 8 bars, no shortening.
        #expect(plan.overlapBars == 8 && plan.overlapSec == 16)
    }

    @Test("an intro with 8 bars is looped 8 bars when the overlap is longer than it")
    func loopsEightBars() throws {
        // The outgoing singer is known by lyric lines (the proxy cannot sing past 16 s of a 16 bar overlap).
        var i = Self.shortIntro(introEnd: 17.5, aOutro: 200, swap: true)
        i.outgoing.vocalIntervals = [0...400]
        let plan = try #require(loopPlan(i))
        #expect(plan.loopBars == 8 && plan.overlapBars == 16)
        #expect(abs(plan.loopLengthSec - 16) < 1e-3)
    }

    @Test("a loop never repeats a sung line: an incoming lyric line inside the loop refuses it, one after it does not")
    func loopRefusesSungLines() throws {
        var after = Self.shortIntro()
        after.incoming.vocalIntervals = [9...12]
        let plan = try #require(loopPlan(after), "a line that starts after the loop's end leaves the loop clean")
        #expect(plan.loopStartSec + plan.loopLengthSec <= 9 + 1e-9)
        var inside = Self.shortIntro()
        inside.incoming.vocalIntervals = [4...6, 9...12]
        #expect(loopPlan(inside) == nil, "a line at 4 s sits inside the loop and would be heard again on every repeat")
        var overlapping = Self.shortIntro()
        overlapping.incoming.vocalIntervals = [8...12]
        #expect(loopPlan(overlapping) == nil, "a line that starts before the loop ends")
    }

    @Test("a pair that needs no loop keeps its plain blend: a long intro, a quiet outgoing song, the guard off")
    func noLoopWhenNotNeeded() {
        #expect(loopPlan(Self.shortIntro(introEnd: 40)) == nil, "the intro covers the overlap")
        #expect(loopPlan(Self.shortIntro(aOutro: 150)) == nil, "the outgoing song has stopped singing")
        var off = Self.shortIntro()
        off.vocalGuardEnabled = false
        #expect(loopPlan(off) == nil)
    }

    @Test("no loop for a remote incoming song, an intro under 4 bars, a clash, an untrusted grid or tempos that meet at half time")
    func loopRefusals() {
        var remote = Self.shortIntro()
        remote.incomingLocal = false
        #expect(loopPlan(remote) == nil)
        #expect(loopPlan(Self.shortIntro(introEnd: 5)) == nil, "under 4 bars of intro")
        var clash = Self.shortIntro()
        clash.incoming.grid = BT.grid(period: 0.3, anchor: 0.1, phase: 1, span: 0.1...236)
        #expect(loopPlan(clash) == nil)
        var untrusted = Self.shortIntro()
        untrusted.incoming.grid = BT.grid(anchor: 0.1, phase: 1, confidence: 0.2, span: 0.1...236)
        #expect(loopPlan(untrusted) == nil)
        var half = Self.shortIntro()
        half.incoming.grid = BT.grid(period: 0.25, anchor: 0.1, phase: 1, span: 0.1...236)
        #expect(loopPlan(half) == nil, "the bars do not line up at half or double time")
        var nodown = Self.shortIntro()
        nodown.incoming.grid = BT.grid(anchor: 0.1, phase: nil, span: 0.1...236)
        #expect(loopPlan(nodown) == nil)
        var skip = Self.shortIntro()
        skip.manualSkip = true
        #expect(loopPlan(skip) == nil)
        var album = Self.shortIntro()
        album.albumInOrder = true
        #expect(loopPlan(album) == nil)
    }

    @Test("the planner picks loop extend for a short intro, and never twice in a row")
    func plannerPicks() {
        let first = MusicTransitionPlanner.plan(Self.shortIntro())
        #expect(first.style == .loopExtend && first.loopRepeats > 0)
        var again = Self.shortIntro()
        again.previousStyle = .loopExtend
        let second = MusicTransitionPlanner.plan(again)
        #expect(second.style != .loopExtend && second.loopRepeats == 0 && second.loopBars == 0)
        var remote = Self.shortIntro()
        remote.incomingLocal = false
        #expect(MusicTransitionPlanner.plan(remote).style != .loopExtend)
    }

    @Test("a plan that is not a loop carries no loop fields")
    func otherPlansHaveNoLoop() {
        let plain = MusicTransitionPlanner.plan(BT.inputs())
        #expect(plain.loopRepeats == 0 && plain.loopBars == 0 && plain.loopLengthSec == 0 && plain.loopStartSec == 0)
    }

    // MARK: Picker

    @Test("loop extend is a candidate only when a loop plan fits, ranks first, and is labelled")
    func pickerRules() {
        let base = S(tempoError: 0.01, energyJump: 0.0, keyDistance: 0, gridTrusted: true)
        #expect(!MusicTransitionStylePicker.ranked(base, previous: nil).contains(.loopExtend))
        var fits = base
        fits.loopFits = true
        #expect(MusicTransitionStylePicker.ranked(fits, previous: nil).first == .loopExtend)
        #expect(!MusicTransitionStylePicker.ranked(fits, previous: .loopExtend).contains(.loopExtend))
        #expect(MusicTransitionStyle.pickable.contains(.loopExtend))
        #expect(MusicTransitionStyle.loopExtend.label == "Loop extend" && !MusicTransitionStyle.loopExtend.isCutLike)
    }

    @Test("with loop extend in the mix the picker still never repeats and still returns only pickable styles")
    func neverRepeatsWithLoop() {
        for var signals in MusicStylePickerP2Tests.samples {
            signals.loopFits = true
            for previous in [nil] + MusicTransitionStyle.allCases.map(Optional.some) {
                let ranked = MusicTransitionStylePicker.ranked(signals, previous: previous)
                #expect(!ranked.contains { $0 == previous })
                #expect(ranked.allSatisfy { MusicTransitionStyle.pickable.contains($0) })
                #expect(MusicTransitionStylePicker.pick(signals, previous: previous) != previous)
            }
        }
    }

    // MARK: Service

    /// Rows for a pair whose incoming intro is short under an outgoing song that sings to 230 s.
    private func loopHarness() async -> BeatHarness {
        let h = BeatHarness()
        var a = BeatHarness.row("a", period: 0.5)
        a.outroStart = 230
        await h.reader.set(a)
        await h.reader.set(BeatHarness.row("b", period: 0.5, introEnd: 10))
        let file = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/loop-extend/service-b.m4a")
        for id in ["a", "b", "c"] {
            var stream = MusicSamples.stream(videoId: id, duration: 240)
            if id == "b" { stream = stream.playingFrom(file: file) }
            await h.backend.setStream(stream)
        }
        let tracks = ["a", "b", "c"].map { MusicSamples.track($0, title: "Song \($0)") }
        await h.backend.setRadio(seed: "a", tracks: tracks, continuation: nil)
        h.service.play(tracks[0])
        await h.settle()
        h.engine.emit(.playingChanged(true))
        return h
    }

    @Test("turning a setting off under a ready loop-extend preload withdraws it so the next tick offers the new plan")
    func replanWithdrawsReadyLoop() async throws {
        let h = await loopHarness()
        await h.tick(126)
        await h.tick(170)
        let offered = try #require(h.lastPlan)
        try #require(offered.style == .loopExtend, "plan: \(offered) lines: \(h.service.transitionLines)")
        let mixOut = try #require(offered.mixOutSec)
        await h.tick(mixOut - 20)
        #expect(h.engine.preloadIsReady)
        let cancels = h.engine.cancelPreloadCount
        h.service.setCrossfade(false)
        #expect(h.engine.cancelPreloadCount == cancels + 1, "ready, with the mix-out still ahead: it is withdrawn all the same")
    }
}
