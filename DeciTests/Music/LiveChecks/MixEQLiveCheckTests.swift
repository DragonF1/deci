// DeciTests/Music/LiveChecks/MixEQLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): the mixer EQ on real song pairs. First the numbers on paper for every ordered pair of the live
// songs (how many get moves, how many have two singers kept apart), then a few pairs through the real MusicService and two-deck
// engine into the muted capture: each deck's mids and highs against its own song's, so the fade (the same in every band) drops
// out and what is left is the EQ. Numbers go to style-report.txt.

import AVFoundation
import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MixEQLiveCheckTests", .serialized, .enabled(if: liveGate))
struct MixEQLiveCheckTests {
    typealias Style = MixStyleLiveCheckTests
    typealias Tempo = MixTempoLiveCheckTests

    private func inputs(_ world: LiveWorld, _ a: LiveSong, _ b: LiveSong) -> MusicTransitionInputs? {
        guard var i = Style.inputs(world, a, b) else { return nil }
        i.outgoing.vocalIntervals = world.lyricIntervals[a.videoId]
        i.incoming.vocalIntervals = world.lyricIntervals[b.videoId]
        i.outgoing.lyricCues = world.lyricLines[a.videoId].map { MusicLyricCues.from(lines: $0, duration: a.duration) }
        i.incoming.lyricCues = world.lyricLines[b.videoId].map { MusicLyricCues.from(lines: $0, duration: b.duration) }
        i.vocalGuardEnabled = true
        i.djLength = true
        return i
    }

    /// `samples` through four band-pass sections (a steep band around `hz`).
    static func band(_ samples: [Float], hz: Double, q: Double, rate: Double) -> [Float] {
        let w = 2 * Double.pi * hz / rate, alpha = sin(w) / (2 * q), a0 = 1 + alpha
        let b0 = alpha / a0, a1 = -2 * cos(w) / a0, a2 = (1 - alpha) / a0
        var out = samples.map(Double.init)
        for _ in 0..<4 {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for n in out.indices {
                let x = out[n], y = b0 * (x - x2) - a1 * y1 - a2 * y2
                (x2, x1, y2, y1) = (x1, x, y1, y)
                out[n] = y
            }
        }
        return out.map(Float.init)
    }

    @Test("real blends: the new song's mids come in after its highs, the old song's mids and highs step back, with no hole")
    func eqOnRealSongs() async throws {
        let world = try await LiveWorld.shared()
        guard let audio = await LiveAudio.shared(world: world) else { Issue.record("capture not proven: \(LiveAudio.failure ?? "?")"); return }
        LiveSong.forceLocal = true
        defer { LiveAudio.end(); LiveSong.forceLocal = false }
        try? FileManager.default.createDirectory(at: LiveDirs.root, withIntermediateDirectories: true)
        Style.note("== mixer EQ \(Date())")

        var plans: [(a: LiveSong, b: LiveSong, plan: TransitionPlan)] = []
        for (a, b) in Style.allPairs(world) {
            guard let i = inputs(world, a, b) else { continue }
            plans.append((a, b, MusicTransitionPlanner.plan(i)))
        }
        let moved = plans.filter { $0.plan.mixEQ != nil }
        let carved = moved.filter { ($0.plan.mixEQ?.carvedSec ?? 0) > 0 }
        let styles = Dictionary(grouping: moved) { $0.plan.style.rawValue }.mapValues(\.count)
        let seconds = carved.compactMap { $0.plan.mixEQ?.carvedSec }.sorted()
        Style.note("pairs \(plans.count): with moves \(moved.count) \(styles), two singers kept apart in \(carved.count), seconds median \(liveF(seconds.isEmpty ? .nan : seconds[seconds.count / 2])) most \(liveF(seconds.last ?? .nan))")
        for p in moved {
            for moves in [p.plan.mixEQ?.incomingMid ?? [], p.plan.mixEQ?.outgoingMid ?? [], p.plan.mixEQ?.outgoingHigh ?? []] {
                #expect(moves.count <= MusicMixEQSettings.maxPoints && zip(moves, moves.dropFirst()).allSatisfy { $0.at < $1.at })
            }
            #expect(p.plan.mixEQ?.incomingMid.last?.gain == 1, "\(p.a.videoId) > \(p.b.videoId)")
        }

        // A long blend, a sweep, a blend with two singers and the rest: at the songs' own tempo, each song once.
        var seen = Set<String>()
        var order: [(a: LiveSong, b: LiveSong, plan: TransitionPlan)] = []
        let still = moved.filter { $0.plan.stretchRate == 1 && $0.plan.overlapSec >= 6 && $0.plan.style != .loopExtend }
        func take(_ list: [(a: LiveSong, b: LiveSong, plan: TransitionPlan)], _ most: Int) {
            var taken = 0
            for p in list where taken < most && !seen.contains(p.a.videoId) && !seen.contains(p.b.videoId) {
                seen.formUnion([p.a.videoId, p.b.videoId]); order.append(p); taken += 1
            }
        }
        take(still.filter { $0.plan.style == .longBlend && ($0.plan.mixEQ?.carvedSec ?? 0) == 0 }, 2)
        take(still.filter { ($0.plan.mixEQ?.carvedSec ?? 0) >= 2 }, 2)
        take(still.filter { $0.plan.style == .filterSweep }, 2)
        take(still, 3)
        var proved = 0
        for p in order where proved < 4 {
            if try await check(world, audio, p.a, p.b, p.plan) { proved += 1 }
        }
        #expect(proved >= 3, "only \(proved) real pairs played an EQ blend")
    }

    /// Plays a to b and checks it; false when the live plan had no moves (or was tempo matched).
    private func check(_ world: LiveWorld, _ audio: LiveAudio, _ a: LiveSong, _ b: LiveSong, _ pure: TransitionPlan) async throws -> Bool {
        MusicRenderRecorder.mutesOutput = true
        let checks = LiveChecks(world: world)
        checks.audio = audio
        var captured: LiveRunner.Capture?
        let leaves = pure.djSection == nil ? nil : pure.mixOutSec
        let out = await checks.realRun(audio, beatMix: true, count: 1, tracks: [a.track(), b.track()], leavesAt: leaves, capture: { captured = $0 })
        let name = "\(a.videoId) (\(a.index)) > \(b.videoId) (\(b.index))"
        guard let t = out.transitions.first, t.crossfaded, let capture = captured else {
            Style.note("  \(name): no overlap (\(out.transitions.first?.failure ?? "none"))"); return false
        }
        guard let line = t.line("transition_eq"), t.tempo == nil, let mixIn = t.mixIn, let mixOut = t.mixOut, let fade = t.planFade else {
            Style.note("  \(name): mode \(t.mode), no EQ line (pure plan \(pure.style.rawValue))"); return false
        }
        let style = t.lines.compactMap(LiveLine.init).last { $0.name == "transition_style" }?.kv["style"] ?? "longBlend"
        let beat = t.line("transition_beat_plan")
        Style.note("  \(name): \(style) overlap \(liveF(fade)) s, bass full at \(liveF((beat?.number("swapAt") ?? .nan) + (beat?.number("handover") ?? .nan))) s; inMid=\(line.kv["inMid"] ?? "") outMid=\(line.kv["outMid"] ?? "") outHigh=\(line.kv["outHigh"] ?? "") carve=\(line.kv["carve"] ?? ""); dropouts=\(t.dropouts) nonFinite=\(t.nonFinite) stalls=\(t.stalls) rateWrites=\(t.engineRateWrites) peak \(liveF(Double(t.capturePeak), 3)) \(t.dropoutDetail)")
        #expect(t.dropouts == 0, "dropouts \(t.dropoutDetail)")
        #expect(t.nonFinite == 0)
        #expect(t.engineRateWrites == 0)

        let clockB = t.samples.filter { $0.tB.isFinite }.map { $0.tB - $0.wall }
        let clockA = t.samples.filter { $0.tA.isFinite }.map { $0.tA - $0.wall }
        func moves(_ key: String) -> [MusicMixEQPlan.Move] {
            (line.kv[key] ?? "-").split(separator: ",").compactMap { part in
                let pair = part.split(separator: ":").compactMap { Double($0) }
                return pair.count == 2 ? .init(at: pair[0], gain: pair[1]) : nil
            }
        }
        if let deck = Tempo.heard(capture, role: "incoming deck", clock: clockB) {
            try await compare("incoming mids against highs", deck, song: b, start: mixIn, fade: fade, upper: 9_000, lower: 1_000) { t in
                MusicMixEQPlan.gain(moves("inMid"), at: t)
            }
        } else { Issue.record("the incoming deck was not captured") }
        if let swap = beat?.number("swapAt"), let handover = beat?.number("handover") {
            if let deck = Tempo.heard(capture, role: "incoming deck", clock: clockB) {
                try await bassCurve("incoming lows", deck, song: b, start: mixIn, fade: fade, swap: swap, handover: handover, rising: true)
            }
            if style != "filterSweep", let deck = Tempo.heard(capture, role: "outgoing deck", clock: clockA) {
                try await bassCurve("outgoing lows", deck, song: a, start: mixOut, fade: fade, swap: swap, handover: handover, rising: false)
            }
        }
        if style != "filterSweep", let deck = Tempo.heard(capture, role: "outgoing deck", clock: clockA) {
            try await compare("outgoing mids against highs", deck, song: a, start: mixOut, fade: fade, upper: 9_000, lower: 1_000) { t in
                MusicMixEQPlan.gain(moves("outMid"), at: t) / MusicMixEQPlan.gain(moves("outHigh"), at: t)
            }
        }
        return true
    }

    /// Where the lows of a deck pass half their way across the bass handover, in the song's own time from the overlap's start,
    /// in 0.1 s steps around `swap` (both gains at 75 Hz against the song's, where the song has lows at all).
    private func bassCurve(
        _ label: String, _ deck: Tempo.Heard, song: LiveSong, start: Double, fade: Double, swap: Double, handover: Double, rising: Bool
    ) async throws {
        let from = max(0, start - 1)
        let rate = LoopSpike.rate
        let source = try await LoopSpike.decode(AVURLAsset(url: song.url), from: from, seconds: fade + 3)
        let reference = Tempo.onsets(source, rate: rate)
        guard let l = Tempo.lead(deck, reference: reference, refStart: from, from: start + fade * 0.4, seconds: min(4, fade * 0.3), slope: 1, songTime: { $0 }, itemTime: { $0 }), l.corr > 0.4 else {
            Style.note("    \(label): the audio could not be placed"); return
        }
        let lead = l.ms / 1000
        let sourceLow = Self.band(source, hz: 75, q: 1.2, rate: rate), heardLow = Self.band(deck.samples, hz: 75, q: 1.2, rate: deck.rate)
        var points: [(t: Double, gain: Double)] = []
        for step in -10...Int((handover + 1) * 10) {
            let t = swap + Double(step) * 0.1
            guard t > 0.05, t < fade - 0.1, let call = deck.calls.last(where: { deck.itemClock($0.host) + lead <= start + t }) else { continue }
            let i = call.start + Int((start + t - deck.itemClock(call.host) - lead) * deck.rate), n = Int(0.1 * deck.rate)
            let j = Int((start + t - from) * rate), m = Int(0.1 * rate)
            guard i >= 0, i + n <= heardLow.count, j >= 0, j + m <= sourceLow.count else { continue }
            let own = Tempo.rms(sourceLow[j..<(j + m)])
            guard own > 0.01 else { continue }
            // The lows follow the bass gain alone, never the fade (`y = f * x + (b - f) * low`).
            points.append((t + 0.05, Tempo.rms(heardLow[i..<(i + n)]) / own))
        }
        guard points.count > 6 else { Style.note("    \(label): no lows to see"); return }
        // Full gain is only known from lows heard clear of the ramp: a ramp's own points would scale it wrong.
        let clear = points.filter { rising ? $0.t > swap + handover : $0.t < swap }.map(\.gain)
        guard clear.count >= 3 else { Style.note("    \(label): no lows at full gain to measure the ramp against"); return }
        let reference2 = LiveScan.median(clear)
        let half = points.firstIndex { rising ? $0.gain > 0.5 * reference2 : $0.gain < 0.5 * reference2 }
        var crossing = half.map { points[$0].t } ?? .nan
        if let half, half > 0, points[half].t - points[half - 1].t < 0.15 {
            let (a, b) = (points[half - 1], points[half])
            crossing = a.t + (b.t - a.t) * (0.5 * reference2 - a.gain) / (b.gain - a.gain)
        }
        let curve = points.map { "\(liveF($0.t - swap - handover, 2)):\(liveF($0.gain / max(1e-6, reference2), 2))" }.joined(separator: " ")
        Style.note("    \(label): half way at \(liveF(crossing - swap - handover, 2)) s from the bar line (planned \(liveF(-handover / 2, 2))), audio \(liveF(lead * 1000, 0)) ms ahead; gain by seconds from it: \(curve)")
        #expect(abs(crossing - swap - handover / 2) < 0.2, "\(label): the bass changed hands off its line")
    }

    /// The deck's level in the lower band against its upper band, less the song's own, at six points of the overlap, against
    /// what the moves say there.
    private func compare(
        _ label: String, _ deck: Tempo.Heard, song: LiveSong, start: Double, fade: Double, upper: Double, lower: Double,
        expected: (Double) -> Double
    ) async throws {
        let from = max(0, start - 1)
        let source = try await LoopSpike.decode(AVURLAsset(url: song.url), from: from, seconds: fade + 3)
        let rate = LoopSpike.rate
        // The audio a deck renders is ahead of its clock: where in the song a render really is.
        let reference = Tempo.onsets(source, rate: rate)
        var lead = 0.11
        if let l = Tempo.lead(deck, reference: reference, refStart: from, from: start + fade * 0.4, seconds: min(4, fade * 0.3), slope: 1, songTime: { $0 }, itemTime: { $0 }), l.corr > 0.4 {
            lead = l.ms / 1000
        }
        let sourceLow = Self.band(source, hz: lower, q: 1.5, rate: rate), sourceHigh = Self.band(source, hz: upper, q: 1.5, rate: rate)
        let heardLow = Self.band(deck.samples, hz: lower, q: 1.5, rate: deck.rate), heardHigh = Self.band(deck.samples, hz: upper, q: 1.5, rate: deck.rate)
        var errors: [Double] = [], text: [String] = []
        for share in [0.1, 0.25, 0.4, 0.55, 0.7, 0.85] {
            let at = fade * share, length = 0.8
            guard let call = deck.calls.last(where: { deck.itemClock($0.host) <= start + at }) else { continue }
            let i = call.start + Int((start + at - deck.itemClock(call.host)) * deck.rate), n = Int(length * deck.rate)
            let j = Int((start + at + lead - from) * rate), m = Int(length * rate)
            guard i >= 0, i + n <= heardLow.count, j >= 0, j + m <= sourceLow.count else { continue }
            let own = Tempo.rms(sourceLow[j..<(j + m)]) / max(1e-7, Tempo.rms(sourceHigh[j..<(j + m)]))
            let heard = Tempo.rms(heardLow[i..<(i + n)]) / max(1e-7, Tempo.rms(heardHigh[i..<(i + n)]))
            guard Tempo.rms(sourceHigh[j..<(j + m)]) > 1e-4, own > 0, heard > 0 else { continue }
            let measured = 20 * log10(heard / own)
            // The moves are planned in what is heard, and a level is an energy.
            let planned = (0..<16).map { expected(at + lead + (Double($0) + 0.5) * length / 16) }
            let wanted = 10 * log10(planned.map { $0 * $0 }.reduce(0, +) / 16)
            text.append("\(Int(share * 100))%: \(liveF(measured, 1)) (plan \(liveF(wanted, 1)))")
            errors.append(abs(measured - wanted))
        }
        Style.note("    \(label) (audio \(liveF(lead * 1000, 0)) ms ahead), dB: \(text.joined(separator: ", "))")
        if !errors.isEmpty { #expect(LiveScan.median(errors) < 2.5, "\(label): \(text)") }
    }
}
