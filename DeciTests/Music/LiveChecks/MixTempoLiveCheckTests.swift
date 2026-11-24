// DeciTests/Music/LiveChecks/MixTempoLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): the tempo match on real song pairs, through the real MusicService and the real
// two-deck engine into the muted capture. It measures what the numbers on paper can not: whether the matched deck's audio
// is where the deck's clock says it is (a stretcher that adds a delay would put every beat late), the beats of both songs
// against each other, the seams, and the song's own tempo after the glide. Numbers go to style-report.txt.

import Foundation
import AVFoundation
import Testing
@testable import Deci

@MainActor
@Suite("MixTempoLiveCheckTests", .serialized, .enabled(if: liveGate))
struct MixTempoLiveCheckTests {
    typealias Style = MixStyleLiveCheckTests

    /// Onset strength every millisecond: how fast the level above 1.5 kHz rises.
    static func onsets(_ samples: [Float], rate: Double) -> [Double] {
        let high = LiveBiquad.filter(samples, highpass: true, hz: 1_500, sampleRate: rate)
        let hop = rate / 1000
        let half = Int(hop * 3)
        var sums = [0.0]
        sums.reserveCapacity(high.count + 1)
        for x in high { sums.append(sums[sums.count - 1] + x * x) }
        let count = Int(Double(high.count) / hop)
        let level = (0..<count).map { k -> Double in
            let mid = Int(Double(k) * hop)
            let lo = max(0, mid - half), hi = min(high.count, mid + half)
            return log10((sums[hi] - sums[lo]) / Double(max(1, hi - lo)) + 1e-7)
        }
        return level.indices.map { k in k >= 8 ? max(0, level[k] - level[k - 8]) : 0 }
    }

    /// The song time at the start of `heard` (1 ms onsets), when it plays at `rate` song seconds a second. `reference` is
    /// the song's onsets from song time `refStart`; `near` is the guess, good to a second.
    static func locate(_ heard: [Double], in reference: [Double], refStart: Double, near: Double, rate: Double) -> (song: Double, corr: Double)? {
        let n = heard.count
        guard n > 500 else { return nil }
        let mean = heard.reduce(0, +) / Double(n)
        let x = heard.map { $0 - mean }
        let xx = x.reduce(0) { $0 + $1 * $1 }
        guard xx > 0 else { return nil }
        func score(_ start: Double) -> Double {
            var sum = 0.0, sq = 0.0, dot = 0.0
            for j in 0..<n {
                let at = (start - refStart) * 1000 + Double(j) * rate
                let k = Int(at.rounded(.down))
                guard k >= 0, k + 1 < reference.count else { return -2 }
                let v = reference[k] + (reference[k + 1] - reference[k]) * (at - Double(k))
                sum += v; sq += v * v; dot += v * x[j]
            }
            let yy = sq - sum * sum / Double(n)
            return yy > 0 ? dot / (xx * yy).squareRoot() : -2
        }
        var best = (lag: 0, corr: -2.0)
        for lag in -1_000...1_000 {
            let c = score(near + Double(lag) / 1000)
            if c > best.corr { best = (lag, c) }
        }
        guard best.corr > 0 else { return nil }
        let a = score(near + Double(best.lag - 1) / 1000), c = score(near + Double(best.lag + 1) / 1000)
        let bend = a - 2 * best.corr + c
        let part = bend < 0 ? 0.5 * (a - c) / bend : 0
        return (near + (Double(best.lag) + max(-1, min(1, part))) / 1000, best.corr)
    }

    /// One deck as it was heard: its samples, the host time of each callback and the deck's clock.
    struct Heard {
        var samples: [Float] = []
        var rate = 48_000.0
        var calls: [(start: Int, host: Double)] = []
        /// Item time minus host time (a deck's clock runs at 1).
        var clock = 0.0

        func itemClock(_ host: Double) -> Double { host + clock }
    }

    static func heard(_ capture: LiveRunner.Capture, role: String, clock: [Double]) -> Heard? {
        guard let token = capture.roles.first(where: { $0.value == role })?.key, !clock.isEmpty else { return nil }
        var out = Heard()
        for r in capture.heard.records.filter({ $0.token == token }).sorted(by: { $0.sampleOffset < $1.sampleOffset }) {
            let end = min(capture.heard.samples.count, r.sampleOffset + r.frames)
            guard r.sampleOffset < end else { continue }
            out.rate = r.sampleRate
            out.calls.append((out.samples.count, Double(r.hostNanos) / 1e9))
            out.samples.append(contentsOf: capture.heard.samples[r.sampleOffset..<end])
        }
        out.clock = LiveScan.median(clock)
        return out.calls.isEmpty ? nil : out
    }

    /// How far ahead of the deck's clock the audio it renders is, over `seconds` of audio from item time `from`, ms.
    /// `songTime` and `itemTime` are the deck's map, `slope` the song seconds an item second in that stretch.
    static func lead(
        _ deck: Heard, reference: [Double], refStart: Double, from: Double, seconds: Double, slope: Double,
        songTime: (Double) -> Double, itemTime: (Double) -> Double
    ) -> (ms: Double, corr: Double)? {
        guard let first = deck.calls.first(where: { deck.itemClock($0.host) >= from }) else { return nil }
        let count = Int(seconds * deck.rate)
        guard first.start + count <= deck.samples.count else { return nil }
        let part = onsets(Array(deck.samples[first.start..<(first.start + count)]), rate: deck.rate)
        let guess = songTime(deck.itemClock(first.host))
        guard let found = locate(part, in: reference, refStart: refStart, near: guess, rate: slope) else { return nil }
        let item = itemTime(found.song)
        let leads = deck.calls.filter { $0.start >= first.start && $0.start < first.start + count }.map {
            item + Double($0.start - first.start) / deck.rate - deck.itemClock($0.host)
        }
        return (LiveScan.median(leads) * 1000, found.corr)
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
    }

    @Test("a tempo match through the real engine: the beats stay together, no hole at a seam, its own tempo afterwards")
    func tempoMatch() async throws {
        let world = try await LiveWorld.shared()
        guard let audio = await LiveAudio.shared(world: world) else { Issue.record("capture not proven: \(LiveAudio.failure ?? "?")"); return }
        LiveSong.forceLocal = true
        defer { LiveAudio.end(); LiveSong.forceLocal = false }
        try? FileManager.default.createDirectory(at: LiveDirs.root, withIntermediateDirectories: true)
        Style.note("== tempo match \(Date())")
        var found: [(a: LiveSong, b: LiveSong, rate: Double)] = []
        for (a, b) in Style.allPairs(world) where !a.beats.isEmpty && !b.beats.isEmpty {
            guard let i = Style.inputs(world, a, b) else { continue }
            let plan = MusicTransitionPlanner.plan(i)
            if plan.stretchRate != 1 { found.append((a, b, plan.stretchRate)) }
        }
        Style.note("pairs the pure plan tempo matches: \(found.count) of \(world.songs.count * (world.songs.count - 1))")
        // The furthest up, the furthest down, and the rest spread between, each incoming song once.
        let sorted = found.sorted { $0.rate < $1.rate }
        var order: [(a: LiveSong, b: LiveSong, rate: Double)] = []
        var seen = Set<String>()
        for share in [1.0, 0.0, 0.5, 0.25, 0.75, 0.9, 0.1, 0.4, 0.6] where !sorted.isEmpty {
            let pick = sorted[Int((Double(sorted.count - 1) * share).rounded())]
            if seen.insert(pick.b.videoId).inserted { order.append(pick) }
        }
        var proved = 0
        for pair in order where proved < 3 {
            if try await check(world, audio, pair.a, pair.b) { proved += 1 }
        }
        #expect(proved >= 2, "only \(proved) real pairs played a tempo match")
    }

    /// Plays a to b and checks it; false when the live plan did not tempo match it.
    private func check(_ world: LiveWorld, _ audio: LiveAudio, _ a: LiveSong, _ b: LiveSong) async throws -> Bool {
        MusicRenderRecorder.mutesOutput = true
        let checks = LiveChecks(world: world)
        checks.audio = audio
        var captured: LiveRunner.Capture?
        let out = await checks.realRun(audio, beatMix: true, count: 1, tracks: [a.track(), b.track()], capture: { captured = $0 })
        let name = "\(a.videoId) (\(a.index)) > \(b.videoId) (\(b.index))"
        guard let t = out.transitions.first, t.crossfaded, let capture = captured else {
            Style.note("  \(name): no overlap (\(out.transitions.first?.failure ?? "none"))"); return false
        }
        guard let map = t.tempo, let mixIn = t.mixIn, let mixOut = t.mixOut, let fade = t.planFade else {
            Style.note("  \(name): mode \(t.mode), not tempo matched"); return false
        }
        let line = t.line("transition_beat_plan")
        let rate = line?.number("stretch") ?? 1
        Style.note("  \(name): stretch \(rate), overlap \(liveF(fade)) s, mixIn \(liveF(mixIn)), own tempo from \(liveF(map.stretchEnd)) s; dropouts=\(t.dropouts) nonFinite=\(t.nonFinite) stalls=\(t.stalls) glitch=\(t.glitchLines) rateWrites=\(t.engineRateWrites) peak \(liveF(Double(t.capturePeak), 3)) \(t.dropoutDetail)")
        #expect(t.dropouts == 0, "dropouts \(t.dropoutDetail)")
        #expect(t.nonFinite == 0)
        #expect(t.engineRateWrites == 0)

        // The beats of both songs against each other, by the decks' clocks.
        let usable = t.samples.dropFirst(5).dropLast(5).filter { $0.tA.isFinite && $0.tB.isFinite }
        let errors = usable.compactMap { s -> Double? in
            guard let na = a.nearestBeat(to: s.tA), let nb = b.nearestBeat(to: map.songTime(s.tB)) else { return nil }
            // The human beats often stop before the mix-out: past the last one they carry on at their own period over 32
            // beats (one gap rounded to 1 ms would drift 40 ms over the overlap).
            var period = a.period(near: s.tA)
            if let last = a.beats.last, s.tA > last.time, a.beats.count > 32 {
                period = (last.time - a.beats[a.beats.count - 33].time) / 32
            }
            return LiveScan.wrap(na.delta - nb.delta / rate, period: period) * 1000
        }
        Style.note("    beats, outgoing against incoming by the decks' clocks: median \(liveF(LiveScan.median(errors), 1)) ms, worst \(liveF(errors.map(abs).max() ?? .nan, 1)) ms, first 10% \(liveF(LiveScan.median(Array(errors.prefix(max(1, errors.count / 10)))), 1)) ms, last 10% \(liveF(LiveScan.median(Array(errors.suffix(max(1, errors.count / 10)))), 1)) ms")

        // Its own tempo after the glide.
        let first = t.tempoProbe.first, last = t.tempoProbe.last
        if let first, let last, last.wall > first.wall {
            let speed = (last.position - first.position) / (last.wall - first.wall)
            let apart = t.tempoProbe.map { abs($0.position - map.songTime($0.item)) * 1000 }.max() ?? .nan
            Style.note("    after the glide: \(liveF(speed, 4)) song seconds a second, position against the map at most \(liveF(apart, 1)) ms")
            #expect(abs(speed - 1) < 0.003, "speed \(speed)")
        } else {
            Issue.record("no probe after the glide")
        }

        // Where the audio is against the deck's clock.
        let clockB = t.samples.filter { $0.tB.isFinite }.map { $0.tB - $0.wall } + t.tempoProbe.map { $0.item - $0.wall }
        let clockA = t.samples.filter { $0.tA.isFinite }.map { $0.tA - $0.wall }
        guard let inDeck = Self.heard(capture, role: "incoming deck", clock: clockB),
              let outDeck = Self.heard(capture, role: "outgoing deck", clock: clockA) else {
            Issue.record("a deck was not captured"); return true
        }
        let startB = max(0, mixIn - 4)
        let songB = try await LoopSpike.decode(AVURLAsset(url: b.url), from: startB, seconds: map.stretchEnd + 14 - startB)
        let refB = Self.onsets(songB, rate: LoopSpike.rate)
        let startA = max(0, mixOut - 10)
        let refA = Self.onsets(try await LoopSpike.decode(AVURLAsset(url: a.url), from: startA, seconds: fade + 18), rate: LoopSpike.rate)
        let overlapItem = map.itemTime(mixIn)
        var overlapLeads: [Double] = [], outLeads: [Double] = []
        for share in [0.25, 0.4, 0.55, 0.7] {
            if let l = Self.lead(inDeck, reference: refB, refStart: startB, from: overlapItem + fade * share, seconds: min(4, fade * 0.25), slope: rate, songTime: map.songTime, itemTime: map.itemTime) {
                Style.note("    incoming audio ahead of its clock at \(Int(share * 100))% of the overlap: \(liveF(l.ms, 1)) ms (match \(liveF(l.corr, 2)))")
                if l.corr > 0.4 { overlapLeads.append(l.ms) }
            }
            if let l = Self.lead(outDeck, reference: refA, refStart: startA, from: mixOut + fade * share, seconds: min(4, fade * 0.25), slope: 1, songTime: { $0 }, itemTime: { $0 }) {
                Style.note("    outgoing audio ahead of its clock at \(Int(share * 100))% of the overlap: \(liveF(l.ms, 1)) ms (match \(liveF(l.corr, 2)))")
                if l.corr > 0.4 { outLeads.append(l.ms) }
            }
        }
        if let l = Self.lead(outDeck, reference: refA, refStart: startA, from: mixOut - 6, seconds: 4, slope: 1, songTime: { $0 }, itemTime: { $0 }) {
            Style.note("    outgoing audio ahead of its clock before the overlap: \(liveF(l.ms, 1)) ms (match \(liveF(l.corr, 2)))")
            if l.corr > 0.4 { outLeads.append(l.ms) }
        }
        var ownLead: Double?
        if let l = Self.lead(inDeck, reference: refB, refStart: startB, from: map.itemTime(map.stretchEnd) + 1, seconds: 4, slope: 1, songTime: map.songTime, itemTime: map.itemTime) {
            Style.note("    incoming audio ahead of its clock after the glide: \(liveF(l.ms, 1)) ms (match \(liveF(l.corr, 2)))")
            if l.corr > 0.4 { ownLead = l.ms }
        }
        let overlapLead = LiveScan.median(overlapLeads)
        Style.note("    matched part \(liveF(overlapLead, 1)) ms, own tempo \(ownLead.map { liveF($0, 1) } ?? "-") ms, outgoing \(liveF(LiveScan.median(outLeads), 1)) ms; matched against own tempo \(ownLead.map { liveF(overlapLead - $0, 1) } ?? "-") ms, matched against outgoing \(liveF(overlapLead - LiveScan.median(outLeads), 1)) ms")

        // The seams after the overlap: the level of every 25 ms against the song's own there.
        if let own = ownLead, let anchor = inDeck.calls.first {
            let offset = anchor.host + inDeck.clock + own / 1000
            var ratios: [(item: Double, db: Double)] = []
            var item = overlapItem + fade + 0.3
            let end = map.itemTime(map.stretchEnd) + 4
            while item < end {
                let i = Int((item - offset) * inDeck.rate), n = Int(0.025 * inDeck.rate)
                let j = Int((map.songTime(item) - startB) * LoopSpike.rate), m = Int(0.025 * LoopSpike.rate)
                if i >= 0, i + n <= inDeck.samples.count, j >= 0, j + m <= songB.count {
                    let ref = Self.rms(songB[j..<(j + m)])
                    if ref > 0.01 { ratios.append((item, 20 * log10((Self.rms(inDeck.samples[i..<(i + n)]) + 1e-6) / ref))) }
                }
                item += 0.0125
            }
            let mid = LiveScan.median(ratios.map(\.db))
            let seamSong = map.stretchEnd
            let nearEnd = ratios.filter { abs(map.songTime($0.item) - seamSong) < 0.1 }.map { $0.db - mid }
            let glide = ratios.filter { map.songTime($0.item) < seamSong - 0.1 }.map { $0.db - mid }
            let native = ratios.filter { map.songTime($0.item) > seamSong + 0.1 }.map { $0.db - mid }
            func low(_ x: [Double]) -> String { x.isEmpty ? "-" : liveF(x.min() ?? 0, 1) }
            // Where the lowest windows are: a dip the song's own transients make sits anywhere, a seam's on a piece boundary.
            let worst = ratios.sorted { $0.db < $1.db }.prefix(6).map { r -> String in
                let song = map.songTime(r.item)
                let j = Int((song - startB) * LoopSpike.rate), m = Int(0.025 * LoopSpike.rate)
                let around = max(0, j - 10 * m)..<min(songB.count, j + 11 * m)
                let share = 20 * log10((Self.rms(songB[j..<(j + m)]) + 1e-6) / (Self.rms(songB[around]) + 1e-6))
                return "\(liveF(r.db - mid, 1)) at song \(liveF(song, 3)) (song itself \(liveF(share, 1)) dB against its half second)"
            }
            Style.note("    lowest windows: \(worst.joined(separator: "; "))")
            Style.note("    level against the song (25 ms, dB from the median): glide lowest \(low(glide)), at the last seam lowest \(low(nearEnd)), own tempo lowest \(low(native)); windows \(ratios.count)")
        }
        return true
    }
}
