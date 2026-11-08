// DeciTests/Music/LiveChecks/LiveRun.swift
// Plays real transitions through a real MusicService and the real two-deck engine, and measures them. Each song is seeked
// to shortly before the preload window, then to about 10 s before the planned mix start, so a transition takes its
// overlap plus about 15 s of wall time instead of the whole song.

import Foundation
import AVFoundation
import CoreMedia
@testable import Deci

/// A service log line as data: "transition_beat_plan from=a to=b rate=0.95 ..." is name + key/value pairs.
nonisolated struct LiveLine: Sendable {
    var name: String
    var kv: [String: String]

    init?(_ text: String) {
        let parts = text.split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        name = first
        var dict: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            dict[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        kv = dict
    }

    func number(_ key: String) -> Double? { kv[key].flatMap(Double.init) }
}

nonisolated struct LiveSample: Sendable {
    var wall: Double
    var tA: Double
    var tB: Double
    var peak: Float
}

nonisolated struct LiveTransition: Sendable {
    var from: String
    var to: String
    var lines: [String] = []
    var mode = "none"
    var planFade: Double?
    var mixOut: Double?
    var mixIn: Double?
    var rate: Double = 1
    var overlapSec = 0.0
    var samples: [LiveSample] = []
    var stalls = 0
    var glitchLines = 0
    var chainPeak: Float = 0
    var capturePeak: Float = 0
    var nonFinite = 0
    var dropouts = 0
    var glideSeen = false
    var dropoutDetail = ""
    var fallbackCount = 0
    var failure: String?
    var crossfaded = false
    var beatApplied = false

    func line(_ name: String) -> LiveLine? {
        lines.compactMap(LiveLine.init).first { $0.name == name }
    }
}

nonisolated enum LiveScan {
    /// Dropouts: a run of digital silence of 30 ms or more with signal on both sides, in the capture of an overlap.
    static func dropouts(_ samples: [Float], sampleRate: Double, detail: inout [String]) -> Int {
        let minRun = Int(0.03 * sampleRate)
        let window = Int(0.1 * sampleRate)
        var count = 0
        var i = window
        while i < samples.count - window {
            if abs(samples[i]) < 1e-6 {
                var j = i
                while j < samples.count, abs(samples[j]) < 1e-6 { j += 1 }
                if j - i >= minRun, j + window < samples.count {
                    func rms(_ a: Int, _ b: Int) -> Float {
                        var sum: Float = 0
                        for k in a..<b { sum += samples[k] * samples[k] }
                        return (sum / Float(max(1, b - a))).squareRoot()
                    }
                    if rms(i - window, i) > 0.01, rms(j, j + window) > 0.01 {
                        count += 1
                        detail.append("\(liveF(Double(i) / sampleRate, 2)) s into the capture, \(liveF(Double(j - i) / sampleRate * 1000, 0)) ms of \(capacityNote(samples.count, sampleRate)) captured")
                    }
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        return count
    }

    private static func capacityNote(_ count: Int, _ rate: Double) -> String { liveF(Double(count) / rate, 1) + " s" }

    static func nonFinite(_ samples: [Float]) -> Int { samples.reduce(0) { $0 + ($1.isFinite ? 0 : 1) } }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return .nan }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// `x` wrapped into -period/2...period/2.
    static func wrap(_ x: Double, period: Double) -> Double {
        guard period > 0 else { return x }
        var r = x.truncatingRemainder(dividingBy: period)
        if r > period / 2 { r -= period }
        if r < -period / 2 { r += period }
        return r
    }
}

/// A rate change the runner saw on a deck while it sampled (host time in ns).
nonisolated struct LiveRateEvent: Sendable {
    var host: UInt64
    var deck: String
    var rate: Float
}

nonisolated extension LiveScan {
    /// Silences of 30 ms or more with signal on both sides, per lease, in what the recorder saw. Each is described with its
    /// item time, which side it was on, whether it fell inside the crossfade, and what happened within 0.3 s of it: an
    /// item-time jump (a seek), a rate change, the crossfade's start or end (a deck switch) or the lease's first frames.
    static func chainDropouts(
        _ snap: (records: [MusicRenderRecorder.Record], samples: [Float]),
        fadeStart: UInt64?, fadeEnd: UInt64?, glideEnd: UInt64? = nil, minMs: Double = 30, rateEvents: [LiveRateEvent], roles: [Int: String], leases: [Int: MusicRenderLease] = [:], samples timeline: [LiveSample], detail: inout [String]
    ) -> (count: Int, nonFinite: Int, peak: Float) {
        var count = 0
        let sorted = snap.records.sorted { $0.sampleOffset < $1.sampleOffset }
        let tokens = Array(Set(sorted.map(\.token)))
        var peak: Float = 0
        var nonFinite = 0
        for r in sorted {
            for k in r.sampleOffset..<min(snap.samples.count, r.sampleOffset + r.frames) {
                let v = snap.samples[k]
                if !v.isFinite { nonFinite += 1 } else { peak = max(peak, abs(v)) }
            }
        }
        for token in tokens.sorted() {
            let recs = sorted.filter { $0.token == token }
            guard let first = recs.first, first.sampleRate > 0 else { continue }
            let rate = first.sampleRate
            var stream: [Float] = []
            var starts: [Int] = []
            for r in recs {
                starts.append(stream.count)
                let end = min(snap.samples.count, r.sampleOffset + r.frames)
                if r.sampleOffset < end { stream.append(contentsOf: snap.samples[r.sampleOffset..<end]) }
            }
            // Item-time jumps between consecutive callbacks of the lease.
            var jumps: [UInt64] = []
            for i in 1..<max(1, recs.count) where recs[i].sourceStart.isFinite && recs[i - 1].sourceStart.isFinite {
                let step = recs[i].sourceStart - recs[i - 1].sourceStart
                if abs(step - Double(recs[i - 1].frames) / rate) > 0.25 { jumps.append(recs[i].hostNanos) }
            }
            let side = roles[token] ?? "other lease"
            let minRun = Int(minMs / 1000 * rate), window = Int(0.1 * rate)
            let before = count
            var maxGap = 0.0
            for i in 1..<max(1, recs.count) { maxGap = max(maxGap, Double(recs[i].hostNanos &- recs[i - 1].hostNanos) / 1e6) }
            defer {
                if count > before, let lastRec = recs.last {
                    func rel(_ h: UInt64, _ base: UInt64?) -> String {
                        guard let base else { return "-" }
                        return liveF((Double(h) - Double(base)) / 1e6, 0) + " ms"
                    }
                    detail.append("lease \(token) summary: \(recs.count) callbacks, \(liveF(Double(stream.count) / rate, 2)) s rendered, item \(liveF(first.sourceStart, 2)) to \(liveF(lastRec.sourceStart, 2)) s, first callback \(rel(first.hostNanos, fadeStart)) vs crossfade start, last callback \(rel(lastRec.hostNanos, fadeEnd)) vs crossfade end, item-time jumps \(jumps.count), longest gap between callbacks \(liveF(maxGap, 0)) ms, chain silenced \(leases[token].map { String($0.debugCounters.silencedFrames) } ?? "?") frames of \(leases[token].map { String($0.debugCounters.fullFrames + $0.debugCounters.gainOnlyFrames + $0.debugCounters.silencedFrames) } ?? "?")")
                }
            }
            var i = window
            while i < stream.count - window {
                guard abs(stream[i]) < 1e-6 else { i += 1; continue }
                var j = i
                while j < stream.count, abs(stream[j]) < 1e-6 { j += 1 }
                if j - i >= minRun, j + window < stream.count {
                    func rms(_ a: Int, _ b: Int) -> Float {
                        var sum: Float = 0
                        for k in a..<b { sum += stream[k] * stream[k] }
                        return (sum / Float(max(1, b - a))).squareRoot()
                    }
                    if rms(i - window, i) > 0.01, rms(j, j + window) > 0.01 {
                        count += 1
                        let ri = starts.lastIndex { $0 <= i } ?? 0
                        let rec = recs[ri]
                        let within = Double(i - starts[ri]) / rate
                        let host = rec.hostNanos + UInt64(within * 1e9)
                        func near(_ h: UInt64?) -> Bool {
                            guard let h else { return false }
                            return (h > host ? h - host : host - h) < 300_000_000
                        }
                        var tags: [String] = []
                        if jumps.contains(where: { near($0) }) { tags.append("seek (item-time jump)") }
                        if let ev = rateEvents.first(where: { near($0.host) }) { tags.append("rate change on \(ev.deck) to \(liveF(Double(ev.rate), 4))") }
                        if near(fadeStart) { tags.append("crossfade start (deck switch)") }
                        if near(fadeEnd) { tags.append("crossfade end (deck switch)") }
                        if near(first.hostNanos) || starts[ri] < window * 3 { tags.append("stream start") }
                        // Item time from the runner's 100 ms position samples (the tap's own range counts from the lease's first call).
                        let hostSec = Double(host) / 1e9
                        var item = Double.nan
                        let useA = side.hasPrefix("outgoing")
                        let pts = timeline.map { (w: $0.wall, t: useA ? $0.tA : $0.tB) }.filter { $0.t.isFinite }
                        if let k = pts.lastIndex(where: { $0.w <= hostSec }), k + 1 < pts.count {
                            let f = (hostSec - pts[k].w) / max(1e-6, pts[k + 1].w - pts[k].w)
                            item = pts[k].t + f * (pts[k + 1].t - pts[k].t)
                        }
                        if let ge = glideEnd, let fe = fadeEnd, host > fe, host < ge { tags.append("during glide ticks") }
                        var inFade = false
                        if let fs = fadeStart, host >= fs, host <= (fadeEnd ?? .max) { inFade = true }
                        let sinceEnd = fadeEnd.map { liveF((Double(host) - Double($0)) / 1e6, 0) + " ms vs crossfade end" } ?? "-"
                        detail.append("\(side) lease \(token): item \(item.isFinite ? liveF(item, 2) : "n/a") s, \(liveF(Double(j - i) / rate * 1000, 0)) ms, \(inFade ? "during fade" : "outside fade") (\(sinceEnd)), aligned with: \(tags.isEmpty ? "nothing" : tags.joined(separator: ", "))")
                    }
                }
                i = j + 1
            }
        }
        return (count, nonFinite, peak)
    }
}

@MainActor
final class LiveRunner {
    let world: LiveWorld
    let service: MusicService
    let player: Deci.MusicPlayer
    let engine: AVPlaybackEngine
    let chain: MusicDSPChain
    let audio: LiveAudio
    /// Songs that were the current one when each loop started, in play order.
    private(set) var played: [String] = []
    private(set) var glitchLines = 0

    init(world: LiveWorld, rig: LiveWorld.Rig, engine: AVPlaybackEngine, chain: MusicDSPChain, audio: LiveAudio) {
        self.world = world
        service = rig.service
        player = rig.player
        self.engine = engine
        self.chain = chain
        self.audio = audio
        engine.onGlitchLine = { [weak self] _ in self?.glitchLines += 1 }
    }

    private func lines(from: String, to: String) -> [String] {
        service.transitionLines.filter { $0.contains("from=\(from) to=\(to)") }
    }

    /// Waits for the first song to play, then plays `count` transitions. `stopAfterCurrent` ends the run on a song that
    /// has no next one.
    func run(count: Int, onTransition: (LiveTransition) -> Void = { _ in }) async -> [LiveTransition] {
        var out: [LiveTransition] = []
        for _ in 0..<count {
            guard let current = service.queue.current else { break }
            if played.last != current.videoId { played.append(current.videoId) }
            let ready = await waitUntil(timeout: .seconds(40)) {
                self.player.isPlaying && self.player.duration > 0 && self.engine.position > 0.3
            }
            var record = LiveTransition(from: current.videoId, to: service.queue.upcoming.first?.videoId ?? service.queue.autoplay.first?.videoId ?? "")
            guard ready else {
                record.failure = "song \(current.videoId) never played"
                out.append(record)
                break
            }
            let next = record.to
            // 1. Into the preload window.
            let windowStart = max(0, player.duration - MusicService.beatLead + 3)
            if engine.position < windowStart - 2 { service.seek(to: windowStart) }
            // 2. Wait for the plan the service offers.
            let planned = await waitUntil(timeout: .seconds(60)) {
                self.service.transitionLines.contains { $0.hasPrefix("transition_plan") && $0.contains("from=\(current.videoId) ") }
            }
            let stallsBefore = engine.stallCount
            let glitchBefore = glitchLines
            guard planned else {
                record.failure = "no plan offered for \(current.videoId) within 60 s"
                record.lines = lines(from: current.videoId, to: next)
                out.append(record)
                service.seek(to: max(engine.position, player.duration - 12))
                _ = await waitUntil(timeout: .seconds(40)) { self.service.queue.current?.videoId != current.videoId }
                continue
            }
            record.to = service.transitionLines.compactMap(LiveLine.init)
                .last { $0.name == "transition_plan" && $0.kv["from"] == current.videoId }?.kv["to"] ?? next
            record.lines = lines(from: current.videoId, to: record.to)
            let plan = record.line("transition_plan")
            record.mode = plan?.kv["mode"] ?? "none"
            record.planFade = plan?.number("fade")
            let beat = record.line("transition_beat_plan")
            record.mixOut = beat?.number("mixOut")
            record.mixIn = beat?.number("mixIn")
            record.rate = beat?.number("rate") ?? 1
            let mixPoint: Double
            if let mixOut = record.mixOut {
                mixPoint = mixOut
            } else if let start = plan?.number("start") {
                mixPoint = start
            } else {
                mixPoint = player.duration - (record.planFade ?? 6)
            }
            // 3. Close to the mix start (the plan's preload is parked by now).
            let chainNoise = chain.consumePeak()
            _ = chainNoise
            // A seek is its own gap in the signal: the capture starts only after it has settled (2.5 s), well before the mix.
            if mixPoint - 10 > engine.position + 1 {
                service.seek(to: mixPoint - 10)
                try? await Task.sleep(for: .seconds(2.5))
            }
            let recorder = MusicRenderRecorder(seconds: 150)
            MusicRenderRecorder.current = recorder
            let wait = max(15, mixPoint - engine.position + 40)
            var diag: [String] = []
            var lastSample = ContinuousClock.now - .seconds(5)
            let started = await waitUntil(timeout: .seconds(wait)) {
                if ContinuousClock.now - lastSample > .seconds(1) {
                    lastSample = ContinuousClock.now
                    let sb = self.engine.standbyAvPlayer
                    diag.append("pos \(liveF(self.engine.position, 1)) pre=\(self.engine.preloadedVideoId ?? "-") sbItem=\(sb.currentItem?.status.rawValue ?? -1) sbRate=\(sb.rate) repark=\(self.engine.debugReparkPending) given=\(self.engine.debugBeatGivenUp)")
                }
                return self.engine.isCrossfading
            }
            print("LIVE diag \(current.videoId) > \(record.to) mixPoint \(mixPoint) started=\(started): " + diag.joined(separator: " | "))
            guard started else {
                MusicRenderRecorder.current = nil
                record.failure = "no overlap started for \(current.videoId) into \(record.to) (mode \(record.mode)); repark=\(engine.debugReparkPending) beatGivenUp=\(engine.debugBeatGivenUp) pos=\(engine.position) mixPoint=\(mixPoint) dur=\(player.duration) preloaded=\(engine.preloadedVideoId ?? "-")"
                record.lines = lines(from: current.videoId, to: record.to)
                out.append(record)
                break
            }
            record.crossfaded = true
            // 4. Sample the overlap.
            let begun = ContinuousClock.now
            let clock = CMClockGetHostTimeClock()
            let fadeStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            var rateEvents: [LiveRateEvent] = []
            var roles: [Int: String] = [:]
            var leaseRefs: [Int: MusicRenderLease] = [:]
            if let t = engine.debugActiveTap?.debugLease { roles[t.debugToken] = "incoming deck"; leaseRefs[t.debugToken] = t }
            if let t = engine.debugDrainingTap?.debugLease { roles[t.debugToken] = "outgoing deck"; leaseRefs[t.debugToken] = t }
            var lastRates: (Float, Float) = (-1, -1)
            while engine.isCrossfading, ContinuousClock.now - begun < .seconds(120) {
                let a = engine.debugDrainingPlayer?.currentTime().seconds ?? .nan
                let b = engine.avPlayer.currentTime().seconds
                let rates = (engine.avPlayer.rate, engine.debugDrainingPlayer?.rate ?? -1)
                if rates.0 != lastRates.0 { rateEvents.append(LiveRateEvent(host: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), deck: "active", rate: rates.0)) }
                if rates.1 != lastRates.1 { rateEvents.append(LiveRateEvent(host: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), deck: "draining", rate: rates.1)) }
                lastRates = rates
                let peak = chain.consumePeak()
                record.chainPeak = max(record.chainPeak, peak)
                record.samples.append(LiveSample(wall: CMClockGetTime(clock).seconds, tA: a, tB: b, peak: peak))
                try? await Task.sleep(for: .milliseconds(100))
            }
            let span = begun.duration(to: .now)
            record.overlapSec = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
            let fadeEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            // A nudged beat mix: keep capturing the incoming deck through the whole glide back to 1 (it starts once the
            // outgoing deck has drained, ticks every 0.1 s and ends with a set to exactly 1).
            var glideEnd: UInt64?
            if abs(record.rate - 1) > 0.0005 {
                let limit = ContinuousClock.now + .seconds(25)
                var seenGlide = false
                var lastActive: Float = engine.avPlayer.rate
                while ContinuousClock.now < limit {
                    let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    let r = engine.avPlayer.rate
                    if r != lastActive { rateEvents.append(LiveRateEvent(host: now, deck: "active", rate: r)); lastActive = r }
                    if engine.debugGlide != nil { seenGlide = true }
                    if seenGlide, engine.debugGlide == nil { glideEnd = now; rateEvents.append(LiveRateEvent(host: now, deck: "glide end", rate: r)); break }
                    if !seenGlide, ContinuousClock.now > limit - .seconds(22) { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            record.glideSeen = glideEnd != nil
            try? await Task.sleep(for: .seconds(1.5))
            MusicRenderRecorder.current = nil
            let heard = recorder.snapshot()
            var detail: [String] = []
            let scan = LiveScan.chainDropouts(heard, fadeStart: fadeStart, fadeEnd: fadeEnd, glideEnd: glideEnd, rateEvents: rateEvents, roles: roles, leases: leaseRefs, samples: record.samples, detail: &detail)
            record.capturePeak = scan.peak
            record.nonFinite = scan.nonFinite
            record.dropouts = scan.count
            record.dropoutDetail = detail.joined(separator: "; ")
            record.stalls = engine.stallCount - stallsBefore
            record.glitchLines = glitchLines - glitchBefore
            _ = await waitUntil(timeout: .seconds(20)) { self.service.queue.current?.videoId == record.to }
            record.lines = lines(from: current.videoId, to: record.to)
            record.fallbackCount = record.lines.filter { $0.hasPrefix("transition_fallback") }.count
            record.beatApplied = record.lines.contains { $0.hasPrefix("transition_beat_applied") }
            out.append(record)
            onTransition(record)
        }
        if let current = service.queue.current, played.last != current.videoId { played.append(current.videoId) }
        return out
    }

    /// Beat phase error of a record in ms, per sample inside the overlap (first and last half second left out).
    func phaseErrorsMs(_ t: LiveTransition) -> [Double] {
        guard let a = world.byId[t.from], let b = world.byId[t.to], t.mode == "beat" else { return [] }
        let usable = t.samples.dropFirst(5).dropLast(5)
        var errors: [Double] = []
        for s in usable where s.tA.isFinite && s.tB.isFinite {
            guard let na = a.nearestBeat(to: s.tA), let nb = b.nearestBeat(to: s.tB) else { continue }
            let eA = na.delta
            let eB = nb.delta / t.rate
            errors.append(LiveScan.wrap(eA - eB, period: a.period(near: s.tA)) * 1000)
        }
        return errors
    }
}
