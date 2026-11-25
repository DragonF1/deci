// DeciTests/Music/LiveChecks/MixSetLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): whole sets of real songs. Many shuffled orders of the analysed library are planned one pair
// after the other, each knowing the moves before it, next to the same orders planned with no history: which moves come up, how
// often the same one comes twice or more in a row, how far apart the effects are and why each was picked. Then a few handovers
// between tempos that do not meet go through the real MusicService and two-deck engine into the muted capture. The genres are the
// ones MixGenreLiveCheckTests stored. Numbers go to style-report.txt.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MixSetLiveCheckTests", .serialized, .enabled(if: liveGate))
struct MixSetLiveCheckTests {
    typealias Style = MixStyleLiveCheckTests

    private struct PlannedSet {
        var plans: [TransitionPlan] = []
        var titles: [String] = []
    }

    private func inputs(_ world: LiveWorld, _ a: LiveSong, _ b: LiveSong) -> MusicTransitionInputs? {
        guard var i = Style.inputs(world, a, b) else { return nil }
        i.outgoing.vocalIntervals = world.lyricIntervals[a.videoId]
        i.incoming.vocalIntervals = world.lyricIntervals[b.videoId]
        i.outgoing.lyricCues = world.lyricLines[a.videoId].map { MusicLyricCues.from(lines: $0, duration: a.duration) }
        i.incoming.lyricCues = world.lyricLines[b.videoId].map { MusicLyricCues.from(lines: $0, duration: b.duration) }
        i.vocalGuardEnabled = true
        i.djLength = true
        i.outgoing.genres = world.genreTags[a.videoId] ?? []
        i.incoming.genres = world.genreTags[b.videoId] ?? []
        return i
    }

    private func note(_ name: String, _ sets: [PlannedSet]) {
        let plans = sets.flatMap(\.plans)
        func share(_ count: Int) -> String { "\(count) (\(liveF(100 * Double(count) / Double(max(1, plans.count)), 1))%)" }
        func table(_ key: (TransitionPlan) -> String) -> String {
            Dictionary(grouping: plans, by: key).mapValues(\.count).sorted { $0.value > $1.value }.map { "\($0.key)=\(share($0.value))" }.joined(separator: " ")
        }
        var runs: [Int: Int] = [:], longest: [String: Int] = [:], gaps: [Int: Int] = [:]
        for set in sets {
            var last: String?, run = 0, effect: Int?
            for (k, plan) in set.plans.enumerated() {
                let move = Self.move(plan)
                if move == last { run += 1 } else { if run > 0 { runs[run, default: 0] += 1 }; run = 1; last = move }
                longest[move] = max(longest[move] ?? 0, run)
                if plan.style.isEffect { if let effect { gaps[k - effect, default: 0] += 1 }; effect = k }
            }
            if run > 0 { runs[run, default: 0] += 1 }
        }
        Style.note("  \(name): \(plans.count) transitions")
        Style.note("    styles \(table { $0.style.rawValue })")
        Style.note("    moves  \(table(Self.move))")
        Style.note("    why    \(table { $0.intent?.rawValue ?? "-" }); for variety \(share(plans.filter(\.forVariety).count)); at a DJ exit \(share(plans.filter { $0.djSection != nil }.count)); singers together \(share(plans.filter { $0.vocalAction == "min" }.count))")
        Style.note("    longest run \(longest.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")); runs \(runs.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: " "))")
        Style.note("    songs from one effect to the next \(gaps.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: " "))")
    }

    /// What is heard: the style, and for a blend which kind.
    private static func move(_ plan: TransitionPlan) -> String {
        guard plan.mode == .beat else { return "smart" }
        guard plan.style == .longBlend else { return plan.style.rawValue }
        if plan.handsOverByEQ { return plan.floorAligned ? "handover" : "quickHandover" }
        return plan.overlapBars > 0 ? "blend\(plan.overlapBars)" : plan.floorAligned ? "floorAligned" : "floorOpen"
    }

    @Test("sets of real songs have variety, with a reason for every move")
    func sets() async throws {
        let world = try await LiveWorld.shared()
        guard let audio = await LiveAudio.shared(world: world) else { Issue.record("capture not proven: \(LiveAudio.failure ?? "?")"); return }
        LiveSong.forceLocal = true
        let tagsURL = LiveDirs.root.appendingPathComponent("genre-tags.json")
        world.genreTags = (try? Data(contentsOf: tagsURL)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        defer { LiveAudio.end(); LiveSong.forceLocal = false; world.genreTags = [:] }
        Style.note("== Sets \(Date())")
        let songs = world.songs.filter { world.rows[$0.videoId] != nil }
        var seed = LiveSeed(state: 20_261_124)
        var with: [PlannedSet] = [], without: [PlannedSet] = []
        var early: [(String, TransitionPlan, Double)] = []
        for _ in 0..<40 {
            let order = songs.shuffled(using: &seed)
            var history = MusicMixHistory(), a = PlannedSet(), b = PlannedSet()
            for (out, into) in zip(order, order.dropFirst()) {
                guard var i = inputs(world, out, into) else { continue }
                a.plans.append(MusicTransitionPlanner.plan(i))
                i.history = history
                let plan = MusicTransitionPlanner.plan(i)
                b.plans.append(plan)
                history.add(plan.style)
                if plan.style.isCutLike, (plan.mixOutSec ?? out.duration) < out.duration - 30 {
                    early.append(("\(out.title) > \(into.title)", plan, out.duration))
                }
            }
            without.append(a)
            with.append(b)
        }
        note("no history", without)
        note("history", with)
        Style.note("  first set: \(with.first?.plans.map { "\(Self.move($0))/\($0.intent?.rawValue ?? "-")\($0.forVariety ? "/variety" : "")" }.joined(separator: ", ") ?? "")")
        // A cut or an echo in the middle of a song is only ever at a section end.
        for (name, plan, _) in early { #expect(plan.djSection != nil, "\(name)") }
        for set in with {
            let effects = set.plans.indices.filter { set.plans[$0].style.isEffect }
            for (x, y) in zip(effects, effects.dropFirst()) { #expect(y - x >= 4) }
        }

        var seen = Set<String>(), played = 0, kinds: [String: Int] = [:]
        for (a, b) in Style.allPairs(world) where played < 6 && !seen.contains(a.videoId) && !seen.contains(b.videoId) {
            guard let i = inputs(world, a, b) else { continue }
            let plan = MusicTransitionPlanner.plan(i)
            let kind = Self.move(plan)
            guard ["handover", "quickHandover", "dropSwap"].contains(kind), kinds[kind, default: 0] < (kind == "handover" ? 3 : 2) else { continue }
            if await play(world, audio, a, b, plan) {
                played += 1
                kinds[kind, default: 0] += 1
                seen.formUnion([a.videoId, b.videoId])
            }
        }
        #expect(played >= 4, "only \(played) real pairs were played")
    }

    private func play(_ world: LiveWorld, _ audio: LiveAudio, _ a: LiveSong, _ b: LiveSong, _ pure: TransitionPlan) async -> Bool {
        MusicRenderRecorder.mutesOutput = true
        let checks = LiveChecks(world: world)
        checks.audio = audio
        let out = await checks.realRun(audio, beatMix: true, count: 1, tracks: [a.track(), b.track()], leavesAt: pure.djSection == nil ? nil : pure.mixOutSec)
        let name = "\(a.title) > \(b.title)"
        guard let t = out.transitions.first, t.crossfaded else {
            Style.note("  \(name): not played (\(out.transitions.first?.failure ?? "no overlap"))"); return false
        }
        let lines = t.lines.compactMap(LiveLine.init)
        let style = lines.last { $0.name == "transition_style" }
        let beat = lines.last { $0.name == "transition_beat_plan" }
        Style.note("  \(name): pure \(Self.move(pure)) \(liveF(pure.overlapSec)) s, played \(style?.kv["style"] ?? "-") why=\(style?.kv["why"] ?? "-") byEQ=\(beat?.kv["byEQ"] ?? "-"), left at \(liveF(t.mixOut ?? .nan)) of \(liveF(a.duration)) s, heard overlap \(liveF(t.overlapSec)) s; dropouts=\(t.dropouts) nonFinite=\(t.nonFinite) stalls=\(t.stalls) rateWrites=\(t.engineRateWrites) peak \(liveF(Double(t.capturePeak), 3)) \(t.dropoutDetail)")
        #expect(t.dropouts == 0, "dropouts \(t.dropoutDetail)")
        #expect(t.nonFinite == 0)
        #expect(t.engineRateWrites == 0)
        return true
    }
}

/// The same orders every time.
private struct LiveSeed: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
