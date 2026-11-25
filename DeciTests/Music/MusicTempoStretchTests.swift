// DeciTests/Music/MusicTempoStretchTests.swift
// Tempo match: the incoming song is taken to the outgoing tempo for the overlap, glides back over 8 of its bars and plays
// at its own tempo to its end (wjyijr: a song must never stay slowed down). The tempo is in the item, never in the player's
// rate, so `incomingRate` stays 1.

import AVFoundation
import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicTempoStretch")
struct MusicTempoStretchTests {
    typealias S = MusicTempoStretch
    typealias B = MusicBeatPlanner
    typealias U = MusicUnityRateTests

    /// 128 bpm brought to 130.1: mix-in at 8 s, 8 bars of overlap.
    static func spec(rate: Double = 1.0166, mixIn: Double = 8, overlap: Double = 15, bar: Double = 1.875) -> S.Spec {
        S.Spec(mixIn: mixIn, rate: rate, overlap: overlap, bar: bar)
    }

    /// Every rate from 5 percent slow to 5 percent fast the spec can have.
    static var rates: [Double] { (973...1075).map { Double($0) / 1024 }.filter { $0 != 1 } }

    static func wall(_ plan: TransitionPlan) -> Double { plan.overlapSec }

    // MARK: Pieces

    @Test("rates snap to a whole number of 1/1024ths, the stretcher's own resolution")
    func snapping() {
        for rate in stride(from: 0.95, through: 1.05, by: 0.0013) {
            let snapped = S.snapRate(rate)
            #expect(snapped * 1024 == (snapped * 1024).rounded())
            #expect(abs(snapped - rate) <= 0.5 / 1024 + 1e-12)
        }
        #expect(Self.spec(rate: 1.0166).rate == 1041.0 / 1024)
    }

    @Test("a pair may match when both beats are trusted and 5 percent apart at most, same time or double; an unknown song may too")
    func mayMatch() {
        func row(_ bpm: Double, confidence: Float = 0.9) -> MusicAnalysis {
            var row = BeatHarness.row("b", period: 60 / bpm, grid: false)
            row.beatGrid = MusicBeatPlannerTests.grid(period: 60 / bpm, confidence: confidence).encode()
            return row
        }
        func may(_ out: MusicAnalysis?, _ into: MusicAnalysis?) -> Bool { MusicTempoStretch.mayMatch(outgoing: out, incoming: into) }
        #expect(may(row(87), row(87.5)))
        #expect(may(row(100), row(104.9)))
        #expect(!may(row(97.99), row(104.01)), "6.1 percent is past what a song is stretched by")
        #expect(may(row(70), row(139)), "double time")
        #expect(!may(row(104), row(69.5)), "3 to 2 is no match")
        #expect(may(nil, nil) && may(row(120), nil) && may(nil, row(120)))
        let weak = row(120, confidence: 0.1), gridless = BeatHarness.row("b", period: 0.5, grid: false)
        #expect(!may(row(120), weak) && !may(weak, row(120)) && !may(nil, gridless) && !may(gridless, nil))
    }

    @Test("the pieces cover the song with no gap, the first and the last are native, and every scaled one is at exactly k/1024")
    func piecesAreExact() throws {
        for rate in Self.rates {
            let spec = Self.spec(rate: rate)
            let pieces = S.pieces(spec, songEnd: 200)
            #expect(pieces.first?.start == 0 && pieces.last?.end == S.ticks(200))
            #expect(pieces.first?.isNative == true && pieces.last?.isNative == true)
            for (left, right) in zip(pieces, pieces.dropFirst()) { #expect(left.end == right.start) }
            for piece in pieces {
                let k = piece.rate * 1024
                #expect(k == k.rounded())
                // The stretcher truncates what it is given: the ratio must fall in step k and not the one under it.
                let given = Double(piece.songTicks) / Double(piece.itemTicks) * 1024
                #expect(Int(given) == Int(k), "rate \(piece.rate) came out as \(given)")
                if piece.isNative { #expect(piece.itemTicks == piece.songTicks) }
            }
        }
    }

    @Test("the last piece is never scaled: the song is at its own tempo from the end of the glide to its end")
    func restIsNative() throws {
        for rate in Self.rates {
            let spec = Self.spec(rate: rate)
            let pieces = S.pieces(spec, songEnd: 240)
            let last = try #require(pieces.last)
            #expect(last.rate == 1 && last.itemTicks == last.songTicks)
            // A small match has glide steps that snap to 1: those bars already belong to the native piece.
            #expect(Double(last.start) / 48_000 <= spec.end + 1e-4, "glide ends at \(spec.end)")
            if abs(rate - 1) >= 9.0 / 1024 { #expect(abs(Double(last.start) / 48_000 - spec.end) < 1e-4) }
            #expect(Double(last.songTicks) / 48_000 > 200, "nearly the whole song is the native piece")
        }
    }

    @Test("the glide goes one way, from the matched rate to the song's own")
    func glideIsMonotone() {
        for rate in [0.95, 0.9833, 1.0166, 1.05] {
            let pieces = S.pieces(Self.spec(rate: rate), songEnd: 200)
            let scaled = pieces.dropFirst()
            for (left, right) in zip(scaled, scaled.dropFirst()) {
                #expect(abs(right.rate - 1) < abs(left.rate - 1), "\(rate): \(left.rate) then \(right.rate)")
            }
        }
    }

    @Test("every seam after the mix-in is 3/8 of a beat after a beat, off every hit")
    func seamsAreOffTheBeat() {
        let spec = Self.spec()
        let beat = spec.bar / 4
        for piece in S.pieces(spec, songEnd: 200).dropFirst() where piece.end != S.ticks(200) {
            let beats = (Double(piece.end) / 48_000 - spec.mixIn - spec.overlap) / beat
            #expect(abs(beats - beats.rounded(.down) - S.seamBeats) < 1e-3)
        }
    }

    @Test("a mix-in at 0 has no first piece, and a song too short for the glide has no pieces at all")
    func edges() {
        let atZero = S.pieces(Self.spec(mixIn: 0), songEnd: 200)
        #expect(atZero.first?.start == 0 && atZero.first?.isNative == false)
        let spec = Self.spec()
        #expect(S.pieces(spec, songEnd: spec.end + 0.5).isEmpty)
        #expect(!S.pieces(spec, songEnd: spec.end + 1.5).isEmpty)
        #expect(S.pieces(spec, songEnd: .nan).isEmpty)
        #expect(MusicTempoMap([]) == nil)
        #expect(MusicTempoMap(S.pieces(spec, songEnd: 200).dropLast()) == nil, "a song that never gets back to its own tempo")
    }

    @Test("a spec over 5 percent, at the song's own tempo, or with bad numbers is not valid")
    func validity() {
        #expect(Self.spec().isValid && Self.spec(rate: 0.95).isValid && Self.spec(rate: 1.05).isValid)
        for bad in [Self.spec(rate: 1), Self.spec(rate: 1.0001), Self.spec(rate: 1.06), Self.spec(rate: 0.94),
                    Self.spec(mixIn: -1), Self.spec(overlap: 0), Self.spec(bar: 0), Self.spec(mixIn: .nan)] {
            #expect(!bad.isValid)
            #expect(S.pieces(bad, songEnd: 200).isEmpty)
        }
    }

    // MARK: Map

    @Test("the map: the same time up to the mix-in, the matched rate in the overlap, one to one after the glide, and back again")
    func map() throws {
        let spec = Self.spec()
        let map = try #require(MusicTempoMap(S.pieces(spec, songEnd: 200)))
        #expect(map.songTime(5) == 5 && map.itemTime(5) == 5)
        #expect(abs(map.itemTime(8) - 8) < 1e-9 && abs(map.songTime(8) - 8) < 1e-9)
        // Ten wall seconds into the overlap the song has moved ten matched seconds.
        #expect(abs(map.songTime(18) - (8 + 10 * spec.rate)) < 1e-4)
        #expect(abs(map.stretchEnd - spec.end) < 1e-4)
        let end = map.itemTime(map.stretchEnd)
        #expect(abs(map.songTime(end + 60) - map.songTime(end) - 60) < 1e-9, "a second a second after the glide")
        var last = -1.0
        for song in stride(from: 0.0, through: 220, by: 0.137) {
            #expect(abs(map.songTime(map.itemTime(song)) - song) < 1e-9)
            #expect(map.itemTime(song) > last)
            last = map.itemTime(song)
        }
        #expect(map.itemTime(200) < 200, "a faster song is shorter: \(map.itemTime(200))")
    }

    // MARK: Plan to edit

    static func plan(rate: Double = 1.0166, style: MusicTransitionStyle = .longBlend) -> TransitionPlan {
        var plan = TransitionPlan(
            mode: .beat, incomingStartSec: 8, outgoingEndSec: 116, fadeStartSec: 100, fadeSeconds: 16,
            incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok)
        plan.style = style
        plan.mixOutSec = 100
        plan.mixInSec = 8
        plan.overlapBars = 8
        plan.overlapSec = 16
        plan.barSec = 2
        plan.stretchRate = rate
        plan.stretchGlideBars = S.glideBars
        plan.stretchBarSec = 1.875
        return plan
    }

    @Test("a plan's edit: the overlap in song seconds is the wall length at the matched rate, on a blend and on a sweep")
    func specFromPlan() throws {
        for style in [MusicTransitionStyle.longBlend, .filterSweep] {
            let spec = try #require(S.spec(from: Self.plan(style: style)))
            #expect(spec.rate == 1041.0 / 1024 && spec.mixIn == 8 && spec.glideBars == 8 && spec.bar == 1.875)
            #expect(abs(spec.overlap - 16 * 1.0166) < 1e-9)
            #expect(MusicItemEdit.edit(from: Self.plan(style: style)) == .stretch(spec))
        }
    }

    @Test("no edit without a matched tempo, a beat plan, a mix-in or a bar, or over the limit")
    func noSpec() {
        #expect(S.spec(from: nil) == nil)
        #expect(S.spec(from: Self.plan(rate: 1)) == nil)
        #expect(S.spec(from: Self.plan(rate: 1.2)) == nil)
        var smart = Self.plan(); smart.mode = .smart
        var noMixIn = Self.plan(); noMixIn.mixInSec = nil
        var noBar = Self.plan(); noBar.stretchBarSec = 0
        for plan in [smart, noMixIn, noBar] {
            #expect(S.spec(from: plan) == nil && MusicItemEdit.edit(from: plan) == nil)
        }
        #expect(S.spec(from: TransitionPlan(
            mode: .beat, incomingStartSec: 0, outgoingEndSec: nil, fadeStartSec: nil, fadeSeconds: 0, incomingGainDb: 0,
            incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok)) == nil, "the default plays plain")
    }

    @Test("a loop and a tempo match are never both: the loop wins, and clearing takes both away")
    func loopWins() throws {
        var plan = Self.plan(style: .loopExtend)
        plan.loopStartSec = 8
        plan.loopBars = 4
        plan.loopLengthSec = 8
        plan.loopRepeats = 2
        guard case .loop? = MusicItemEdit.edit(from: plan) else { Issue.record("not a loop"); return }
        plan.clearItemEdit()
        #expect(MusicItemEdit.edit(from: plan) == nil)
        #expect(plan.style == .longBlend && plan.loopRepeats == 0 && plan.stretchRate == 1 && plan.stretchBarSec == 0)
        #expect(plan.mode == .beat && plan.mixInSec == 8, "the blend is untouched")
    }

    // MARK: Composition

    private func tone(seconds: Double) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/tempo-engine", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tone-\(UUID().uuidString).m4a")
        let rate = 44_100.0
        var samples = [Float](repeating: 0, count: Int(seconds * rate) * 2)
        for frame in 0..<Int(seconds * rate) {
            let value = Float(0.2 * sin(2 * Double.pi * 440 * Double(frame) / rate))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        try await ToneFile.write(interleavedStereo: samples, sampleRate: rate, to: url)
        return url
    }

    @Test("the composition's segments are the pieces, and its last one is not scaled")
    func composition() async throws {
        let url = try await tone(seconds: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        let spec = Self.spec(mixIn: 4, overlap: 8, bar: 1)
        let asset = AVURLAsset(url: url)
        let built = try await S.composition(asset: asset, spec: spec, songDuration: 40, origin: .trackCache)
        let track = try #require(built.composition.tracks.first)
        let pieces = S.pieces(spec, songEnd: 40)
        #expect(track.segments.count == pieces.count)
        for (segment, piece) in zip(track.segments, pieces) {
            #expect(segment.timeMapping.source.duration == CMTime(value: piece.songTicks, timescale: 48_000))
            #expect(segment.timeMapping.target.duration == CMTime(value: piece.itemTicks, timescale: 48_000))
        }
        let last = try #require(track.segments.last)
        #expect(last.timeMapping.source.duration == last.timeMapping.target.duration)
        #expect(abs(built.map.stretchEnd - spec.end) < 1e-4)
        #expect(abs(built.composition.duration.seconds - built.map.itemTime(40)) < 1e-3)
    }

    @Test("a remote origin, a bad spec and a song too short are refused")
    func compositionRefusals() async throws {
        let url = try await tone(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        await #expect(throws: S.Failure.remote) {
            _ = try await S.composition(asset: asset, spec: Self.spec(), songDuration: 12, origin: .network)
        }
        await #expect(throws: S.Failure.badSpec) {
            _ = try await S.composition(asset: asset, spec: Self.spec(rate: 1), songDuration: 12, origin: .download)
        }
        await #expect(throws: S.Failure.rangeOutsideAsset) {
            _ = try await S.composition(asset: asset, spec: Self.spec(), songDuration: 12, origin: .download)
        }
    }

    // MARK: Planner

    static func local(_ outBpm: Double, _ inBpm: Double, deckRate: Double = 1) -> MusicTransitionInputs {
        var i = U.pair(outBpm, inBpm, deckRate: deckRate)
        i.incomingLocal = true
        return i
    }

    static func planned(_ i: MusicTransitionInputs) -> TransitionPlan {
        B.plan(i, smart: MusicTransitionPlanner.smartPlan(i))
    }

    @Test("a song on this Mac up to 5 percent off is tempo matched; the same song streamed is a tempo clash as before")
    func plannerMatchesLocal() throws {
        for inBpm in [114.4, 116, 118.3, 121.7, 124, 126.2] {
            let i = Self.local(120, inBpm)
            let plan = Self.planned(i)
            #expect(plan.mode == .beat && plan.fallbackReason == nil && plan.style == .longBlend, "\(inBpm): \(plan)")
            #expect(plan.stretchRate == S.snapRate(120 / inBpm), "\(inBpm)")
            #expect(plan.incomingRate == 1, "the tempo is in the item, never in the player's rate")
            #expect(plan.stretchGlideBars == S.glideBars && abs(plan.stretchBarSec - 240 / inBpm) < 1e-9)
            #expect(S.spec(from: plan) != nil)
            var remote = i
            remote.incomingLocal = false
            let refused = Self.planned(remote)
            #expect(refused.fallbackReason == B.Fallback.tempoClash.rawValue && refused.stretchRate == 1, "\(inBpm)")
        }
    }

    @Test("over 5 percent nothing is matched, local or not")
    func plannerLimit() {
        for inBpm in [112.0, 127.5] {
            let plan = Self.planned(Self.local(120, inBpm))
            #expect(plan.fallbackReason == B.Fallback.tempoClash.rawValue && plan.stretchRate == 1, "\(inBpm): \(plan)")
        }
    }

    @Test("a pair already on the beat at its own tempo is left alone, one whose beats would drift past 15 ms is matched")
    func tightPairsPlayAsTheyAre() {
        let tight = Self.planned(Self.local(120, 120 / 1.001))
        #expect(tight.mode == .beat && tight.fallbackReason == nil && tight.stretchRate == 1)
        let same = Self.planned(Self.local(120, 120))
        #expect(same.mode == .beat && same.stretchRate == 1 && same.stretchBarSec == 0)
        let loose = Self.planned(Self.local(120, 120 / 1.0025))
        #expect(loose.mode == .beat && loose.stretchRate == S.snapRate(1.0025))
        var remote = U.pair(120, 120 / 1.0025)
        remote.incomingLocal = false
        #expect(Self.planned(remote).stretchRate == 1 && Self.planned(remote).fallbackReason == nil, "streamed it plays as before")
    }

    @Test("half and double time are matched too: 120 against 59 and 243")
    func multiples() {
        for inBpm in [59.0, 62.0] {
            let plan = Self.planned(Self.local(120, inBpm))
            #expect(plan.mode == .beat && plan.fallbackReason == nil, "\(inBpm): \(plan)")
            #expect(plan.stretchRate == S.snapRate(60 / inBpm))
        }
    }

    /// The snapped rate is at most half a step off, and the start is centred on what that drifts across the overlap: at 8 bars
    /// of 120 bpm no beat is more than 4 ms off.
    @Test("measured on both grids through the plan's own map: every beat of the overlap is on an outgoing one, to half a rate step")
    func beatsMeet() throws {
        for (out, inn, deck) in [(120.0, 118.3, 1.0), (126, 130, 1), (120, 114.4, 1), (128, 128, 1.03), (100, 103.7, 1)] {
            let i = Self.local(out, inn, deckRate: deck)
            let plan = Self.planned(i)
            #expect(plan.mode == .beat && plan.stretchRate != 1, "\(out) \(inn): \(plan)")
            let a = try #require(i.outgoing.grid), b = try #require(i.incoming.grid)
            let mixOut = try #require(plan.mixOutSec), mixIn = try #require(plan.mixInSec)
            let spec = try #require(S.spec(from: plan))
            let map = try #require(MusicTempoMap(S.pieces(spec, songEnd: 236)))
            var checked = 0
            var index = 0
            while true {
                let aBeat = a.beatTime(index)
                index += 1
                guard aBeat >= mixOut else { continue }
                let wall = (aBeat - mixOut) / deck
                guard wall <= plan.overlapSec else { break }
                let song = map.songTime(mixIn + wall)
                let nearest = b.beatTime(Int(((song - b.anchorSec) / b.periodSec).rounded()))
                let allowed = 0.0003 + plan.overlapSec * 0.5 / 1024 / 2
                #expect(abs(song - nearest) < allowed, "\(out) \(inn) beat at \(wall) s off by \(song - nearest)")
                checked += 1
            }
            #expect(checked >= 30)
        }
    }

    @Test("a song with no room for the overlap, the glide and the rest is not matched")
    func noRoomNoMatch() {
        var i = Self.local(120, 118.3)
        i.incoming.durationSeconds = 48
        i.incoming.analysis?.silenceEnd = 48
        let plan = Self.planned(i)
        #expect(plan.stretchRate == 1, "\(plan)")
    }

    @Test("across the whole bpm sweep a matched plan always has a valid spec, rate 1 on the player, and no loop")
    func sweepOfPairs() {
        var matched = 0
        for (out, inn, deck) in U.bpmPairs {
            let plan = Self.planned(Self.local(out, inn, deckRate: deck))
            #expect(plan.incomingRate == 1)
            guard plan.stretchRate != 1 else { continue }
            matched += 1
            #expect(S.spec(from: plan) != nil && plan.loopRepeats == 0 && abs(plan.stretchRate - 1) <= 0.0505)
        }
        #expect(matched > 40, "only \(matched) matched")
    }

    @Test("the mix-out is never before the earliest one the service allows, which holds it out of a song's own matched part")
    func earliestMixOut() throws {
        var i = Self.local(120, 118.3)
        let free = try #require(Self.planned(i).mixOutSec)
        i.earliestMixOutSec = free + 1
        let held = Self.planned(i)
        #expect(held.mixOutSec == nil || held.mixOutSec! >= free + 1)
    }

    // MARK: Log

    @Test("the plan line names the tempo match only when there is one")
    func logLine() {
        let matched = MusicTransitionLog.beatPlanLine(from: "a", to: "b", plan: Self.plan(rate: 1041.0 / 1024), bpmA: 130, bpmB: 128)
        #expect(matched.hasSuffix(" stretch=1.0166 glide=8"))
        let plain = MusicTransitionLog.beatPlanLine(from: "a", to: "b", plan: Self.plan(rate: 1), bpmA: 130, bpmB: 128)
        #expect(!plain.contains("stretch") && !plain.contains("glide"))
    }
}
