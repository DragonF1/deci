// DeciTests/Music/LiveChecks/MixStyleLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): the filter sweep and the drop swap, forced on real song pairs and played through the
// real MusicService and the real two-deck engine into the muted capture. The style is forced with the DEBUG-only picker
// hook, so nothing here is reachable from the UI. Numbers go to style-report.txt next to the other live reports.

import Foundation
import Testing
@testable import Deci

/// A 2nd order RBJ biquad (Butterworth Q), run twice for a 4th order band edge.
nonisolated struct LiveBiquad {
    private var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(highpass: Bool, hz: Double, sampleRate: Double) {
        let w = 2 * Double.pi * hz / sampleRate
        let alpha = sin(w) / (2 * 0.70710678)
        let c = cos(w)
        let a0 = 1 + alpha
        if highpass {
            b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = (1 + c) / 2 / a0
        } else {
            b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = (1 - c) / 2 / a0
        }
        a1 = -2 * c / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    static func filter(_ input: [Float], highpass: Bool, hz: Double, sampleRate: Double) -> [Double] {
        var one = LiveBiquad(highpass: highpass, hz: hz, sampleRate: sampleRate)
        var two = LiveBiquad(highpass: highpass, hz: hz, sampleRate: sampleRate)
        return input.map { two.process(one.process(Double($0))) }
    }
}

@MainActor
@Suite("MixStyleLiveCheckTests", .serialized, .enabled(if: liveGate))
struct MixStyleLiveCheckTests {
    typealias T = MusicTransitionPlannerTests

    static let reportURL = LiveDirs.root.appendingPathComponent("style-report.txt")

    static func note(_ line: String) {
        print("LIVE-STYLE \(line)")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: reportURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: reportURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Pairs

    static func inputs(_ world: LiveWorld, _ a: LiveSong, _ b: LiveSong) -> MusicTransitionInputs? {
        guard let rowA = world.rows[a.videoId], let rowB = world.rows[b.videoId] else { return nil }
        var sideA = T.side(a.videoId, duration: a.duration, analysis: rowA)
        var sideB = T.side(b.videoId, duration: b.duration, analysis: rowB)
        sideA.grid = rowA.usableGrid
        sideB.grid = rowB.usableGrid
        var i = T.inputs(a: sideA, b: sideB)
        i.bassSwapAvailable = true
        return i
    }

    /// Ordered pairs whose pure plan, with `style` forced, is that style.
    static func pairs(_ world: LiveWorld, style: MusicTransitionStyle, among: [(LiveSong, LiveSong)]) -> [(LiveSong, LiveSong)] {
        MusicTransitionStylePicker.debugForcedStyle = style
        defer { MusicTransitionStylePicker.debugForcedStyle = nil }
        return among.filter { a, b in
            guard let i = inputs(world, a, b) else { return false }
            return MusicTransitionPlanner.plan(i).style == style
        }
    }

    static func allPairs(_ world: LiveWorld, incoming: [LiveSong]? = nil) -> [(LiveSong, LiveSong)] {
        var out: [(LiveSong, LiveSong)] = []
        for a in world.songs {
            for b in incoming ?? world.songs where a.videoId != b.videoId { out.append((a, b)) }
        }
        return out
    }

    struct Played {
        var transition: LiveTransition
        var capture: LiveRunner.Capture?
        var style: String
    }

    /// Plays a to b once through the real engine with `style` forced.
    static func play(_ world: LiveWorld, _ audio: LiveAudio, style: MusicTransitionStyle, _ a: LiveSong, _ b: LiveSong) async -> Played? {
        MusicTransitionStylePicker.debugForcedStyle = style
        MusicRenderRecorder.mutesOutput = true
        defer { MusicTransitionStylePicker.debugForcedStyle = nil }
        let checks = LiveChecks(world: world)
        checks.audio = audio
        var captured: LiveRunner.Capture?
        let out = await checks.realRun(audio, beatMix: true, count: 1, tracks: [a.track(), b.track()], capture: { captured = $0 })
        guard let transition = out.transitions.first, transition.crossfaded else {
            note("  \(a.videoId) > \(b.videoId): no overlap (\(out.transitions.first?.failure ?? "none"))")
            return nil
        }
        let styleLine = transition.lines.compactMap(LiveLine.init).last { $0.name == "transition_style" }
        return Played(transition: transition, capture: captured, style: styleLine?.kv["style"] ?? "none")
    }

    // MARK: Measurements

    static func meanSquareDb(_ x: ArraySlice<Double>) -> Double {
        guard !x.isEmpty else { return -200 }
        let ms = x.reduce(0) { $0 + $1 * $1 } / Double(x.count)
        return 10 * log10(ms + 1e-14)
    }

    struct Stream {
        var samples: [Float] = []
        /// Start index and item time of each record, and its length.
        var spans: [(start: Int, item: Double, count: Int)] = []
        var rate = 48_000.0
    }

    static func stream(_ capture: LiveRunner.Capture, role: String) -> Stream? {
        guard let token = capture.roles.first(where: { $0.value == role })?.key else { return nil }
        var out = Stream()
        for r in capture.heard.records.filter({ $0.token == token }).sorted(by: { $0.sampleOffset < $1.sampleOffset }) {
            let end = min(capture.heard.samples.count, r.sampleOffset + r.frames)
            guard r.sampleOffset < end else { continue }
            out.rate = r.sampleRate
            out.spans.append((out.samples.count, r.sourceStart, end - r.sampleOffset))
            out.samples.append(contentsOf: capture.heard.samples[r.sampleOffset..<end])
        }
        return out
    }

    /// The indices of the records whose item time is in `range`, as one list of sample ranges.
    static func slice(_ s: Stream, items range: Range<Double>) -> [Range<Int>] {
        s.spans.filter { $0.item.isFinite && range.contains($0.item) }.map { $0.start..<($0.start + $0.count) }
    }

    static func gather(_ x: [Double], _ ranges: [Range<Int>]) -> ArraySlice<Double> {
        ranges.flatMap { x[$0] }[...]
    }

    static func maxJump(_ x: [Float], _ ranges: [Range<Int>]) -> Float {
        var worst: Float = 0
        for r in ranges where r.count > 1 {
            for k in (r.lowerBound + 1)..<r.upperBound { worst = max(worst, abs(x[k] - x[k - 1])) }
        }
        return worst
    }

    /// Least squares line t = a + b w, returns the wall time where it reaches `target`.
    static func wallWhere(_ points: [(w: Double, t: Double)], reaches target: Double) -> Double? {
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        let mw = points.reduce(0) { $0 + $1.w } / n, mt = points.reduce(0) { $0 + $1.t } / n
        var sxx = 0.0, sxy = 0.0
        for p in points { sxx += (p.w - mw) * (p.w - mw); sxy += (p.w - mw) * (p.t - mt) }
        guard sxx > 0, sxy != 0 else { return nil }
        let slope = sxy / sxx
        return mw + (target - mt) / slope
    }

    // MARK: Filter sweep

    @Test("filter sweep through the real engine: no dropout, no click, the outgoing lows really go")
    func filterSweep() async throws {
        let world = try await LiveWorld.shared()
        guard let audio = await LiveAudio.shared(world: world) else { Issue.record("capture not proven: \(LiveAudio.failure ?? "?")"); return }
        defer { LiveAudio.end(); MusicTransitionStylePicker.debugForcedStyle = nil }
        try? FileManager.default.createDirectory(at: LiveDirs.root, withIntermediateDirectories: true)
        Self.note("== filter sweep \(Date())")
        let found = Self.pairs(world, style: .filterSweep, among: Self.allPairs(world))
        // Spread over distinct outgoing songs.
        var seen = Set<String>()
        let candidates = found.filter { seen.insert($0.0.videoId).inserted }.prefix(6)
        Self.note("pure-plan sweep pairs: \(found.count) of \(world.songs.count * (world.songs.count - 1)); trying up to \(candidates.count)")
        var proved = false
        for (a, b) in candidates {
            guard let played = await Self.play(world, audio, style: .filterSweep, a, b) else { continue }
            let t = played.transition
            Self.note("  \(a.videoId) (\(a.index)) > \(b.videoId) (\(b.index)): style=\(played.style) dropouts=\(t.dropouts) nonFinite=\(t.nonFinite) stalls=\(t.stalls) glitch=\(t.glitchLines) \(t.dropoutDetail)")
            guard played.style == MusicTransitionStyle.filterSweep.rawValue, let capture = played.capture,
                  let mixOut = t.mixOut, let fade = t.planFade, fade > 2 else { continue }
            guard let out = Self.stream(capture, role: "outgoing deck") else { Self.note("  no outgoing stream"); continue }
            let rate = out.rate
            let low = LiveBiquad.filter(out.samples, highpass: false, hz: 200, sampleRate: rate)
            let high = LiveBiquad.filter(out.samples, highpass: true, hz: 3_000, sampleRate: rate)
            let q1 = Self.slice(out, items: mixOut..<(mixOut + fade * 0.25))
            let q4 = Self.slice(out, items: (mixOut + fade * 0.75)..<(mixOut + fade))
            // Skip the first 0.3 s of each quarter's neighbours' filter warm-up by using whole records only.
            let lowFirst = Self.meanSquareDb(Self.gather(low, q1)), lowLast = Self.meanSquareDb(Self.gather(low, q4))
            let highFirst = Self.meanSquareDb(Self.gather(high, q1)), highLast = Self.meanSquareDb(Self.gather(high, q4))
            let rawDrop = lowFirst - lowLast
            let normalisedDrop = (lowFirst - highFirst) - (lowLast - highLast)
            // Clicks: the biggest sample-to-sample step in the overlap against the song's own steps before it.
            let before = Self.slice(out, items: (mixOut - 8)..<mixOut)
            let during = Self.slice(out, items: mixOut..<(mixOut + fade))
            let edge = Self.slice(out, items: (mixOut - 0.1)..<(mixOut + 0.2)) + Self.slice(out, items: (mixOut + fade - 0.2)..<(mixOut + fade + 0.1))
            let jumpBefore = Self.maxJump(out.samples, before)
            let jumpDuring = Self.maxJump(out.samples, during)
            let jumpEdge = Self.maxJump(out.samples, edge)
            Self.note("  sweep \(a.videoId) > \(b.videoId): mixOut \(liveF(mixOut)) fade \(liveF(fade)) records q1 \(q1.count) q4 \(q4.count); low-band (<200 Hz) first quarter \(liveF(lowFirst, 1)) dB, last quarter \(liveF(lowLast, 1)) dB, raw drop \(liveF(rawDrop, 1)) dB; vs >3 kHz band normalised drop \(liveF(normalisedDrop, 1)) dB; max step before \(liveF(Double(jumpBefore), 4)), during \(liveF(Double(jumpDuring), 4)), at start/end edges \(liveF(Double(jumpEdge), 4)); peak \(liveF(Double(t.capturePeak), 3))")
            #expect(t.dropouts == 0, "dropouts \(t.dropoutDetail)")
            #expect(t.nonFinite == 0)
            #expect(!q1.isEmpty && !q4.isEmpty)
            #expect(rawDrop >= 12, "low band fell only \(rawDrop) dB")
            #expect(normalisedDrop >= 12, "low band relative to highs fell only \(normalisedDrop) dB")
            #expect(jumpDuring <= max(jumpBefore * 1.1, 0.02), "a step of \(jumpDuring) against the song's own \(jumpBefore)")
            #expect(jumpEdge <= max(jumpBefore * 1.1, 0.02), "a step of \(jumpEdge) at the sweep edges against the song's own \(jumpBefore)")
            proved = true
            break
        }
        #expect(proved, "no real pair played a filter sweep")
    }

    // MARK: Drop swap

    @Test("drop swap through the real engine: no dropout, and the incoming drop lands on the outgoing phrase end")
    func dropSwap() async throws {
        let world = try await LiveWorld.shared()
        guard let audio = await LiveAudio.shared(world: world) else { Issue.record("capture not proven: \(LiveAudio.failure ?? "?")"); return }
        defer { LiveAudio.end(); MusicTransitionStylePicker.debugForcedStyle = nil }
        try? FileManager.default.createDirectory(at: LiveDirs.root, withIntermediateDirectories: true)
        Self.note("== drop swap \(Date())")
        var drops: [(song: LiveSong, drop: MusicDrop)] = []
        var confidences: [String] = []
        for song in world.songs {
            guard let row = world.rows[song.videoId] else { continue }
            let all = MusicDropDetector.drops(in: row) ?? []
            if let top = all.map(\.confidence).max() { confidences.append("\(song.index):\(liveF(Double(top), 2))") }
            if let best = MusicDropDetector.best(in: row) { drops.append((song, best)) }
        }
        drops.sort { $0.drop.confidence > $1.drop.confidence }
        Self.note("songs with any drop (top confidence): \(confidences.joined(separator: " ")); songs with a usable drop: \(drops.count)")
        guard !drops.isEmpty else {
            Self.note("NO song in the set has a confident drop (floor \(MusicDropDetector.confidenceFloor)); nothing to play")
            Issue.record("no song with a confident drop")
            return
        }
        var proved = false
        var tried = 0
        for (song, drop) in drops where tried < 4 {
            let partners = Self.pairs(world, style: .dropSwap, among: Self.allPairs(world, incoming: [song]).filter { $0.0.videoId != song.videoId })
            Self.note("incoming \(song.videoId) (\(song.index)) drop at \(liveF(drop.timeSec)) s, rise \(liveF(Double(drop.riseDb), 1)) dB, confidence \(liveF(Double(drop.confidence), 2)); beat-mixing partners by pure plan: \(partners.count)")
            for (a, b) in partners.prefix(2) {
                tried += 1
                guard let played = await Self.play(world, audio, style: .dropSwap, a, b) else { continue }
                let t = played.transition
                Self.note("  \(a.videoId) (\(a.index)) > \(b.videoId): style=\(played.style) dropouts=\(t.dropouts) nonFinite=\(t.nonFinite) stalls=\(t.stalls) glitch=\(t.glitchLines) \(t.dropoutDetail)")
                guard played.style == MusicTransitionStyle.dropSwap.rawValue, let mixOut = t.mixOut, let fade = t.planFade else { continue }
                // The phrase end P is where the plan ends the outgoing song; the drop D is in the incoming item's own time.
                let phraseEnd = mixOut + fade
                let inside = t.samples.filter { $0.tA.isFinite && $0.tB.isFinite }.suffix(40)
                let aPoints = inside.map { (w: $0.wall, t: $0.tA) }
                let bPoints = inside.map { (w: $0.wall, t: $0.tB) }
                guard let wallP = Self.wallWhere(aPoints, reaches: phraseEnd), let wallD = Self.wallWhere(bPoints, reaches: drop.timeSec) else {
                    Self.note("  not enough deck samples (\(inside.count))"); continue
                }
                let errorMs = (wallD - wallP) * 1000
                Self.note("  drop swap \(a.videoId) > \(b.videoId): mixOut \(liveF(mixOut)) fade \(liveF(fade)) phrase end \(liveF(phraseEnd)) s, drop \(liveF(drop.timeSec)) s, rate \(liveF(t.rate, 4)), mixIn \(liveF(t.mixIn ?? .nan)); on the real deck timeline the drop lands \(liveF(errorMs, 1)) ms from the phrase end; peak \(liveF(Double(t.capturePeak), 3))")
                #expect(t.dropouts == 0, "dropouts \(t.dropoutDetail)")
                #expect(t.nonFinite == 0)
                #expect(abs(errorMs) <= 20, "drop landed \(errorMs) ms from the phrase end")
                proved = true
                break
            }
            if proved { break }
        }
        #expect(proved, "no real pair played a drop swap")
    }
}
