// DeciTests/Music/LiveChecks/MixDJLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): the DJ exits and entries on real songs. First the numbers on paper for every ordered pair
// of the live songs (how many leave at a chorus, hook or drop, how much of the song that plays, what the next one comes in on),
// then three pairs through the real MusicService and two-deck engine into the muted capture: the song is left where the plan
// says, the next one starts past its intro where the plan says, and there is no hole. Numbers go to style-report.txt.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MixDJLiveCheckTests", .serialized, .enabled(if: liveGate))
struct MixDJLiveCheckTests {
    typealias Style = MixStyleLiveCheckTests

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

    private func spread(_ x: [Double]) -> String {
        let s = x.sorted()
        guard !s.isEmpty else { return "-" }
        return [0, 0.25, 0.5, 0.75, 1].map { liveF(s[Int((Double(s.count - 1) * $0).rounded())], 2) }.joined(separator: " / ")
    }

    @Test("real songs are left at a chorus, hook or drop and come in past their intro, with no hole")
    func exitsAndEntries() async throws {
        let world = try await LiveWorld.shared()
        guard let audio = await LiveAudio.shared(world: world) else { Issue.record("capture not proven: \(LiveAudio.failure ?? "?")"); return }
        LiveSong.forceLocal = true
        defer { LiveAudio.end(); LiveSong.forceLocal = false }
        try? FileManager.default.createDirectory(at: LiveDirs.root, withIntermediateDirectories: true)
        Style.note("== DJ exits and entries \(Date())")

        var plans: [(a: LiveSong, b: LiveSong, plan: TransitionPlan)] = []
        for (a, b) in Style.allPairs(world) {
            guard let i = inputs(world, a, b) else { continue }
            plans.append((a, b, MusicTransitionPlanner.plan(i)))
        }
        let left = plans.filter { $0.plan.djSection != nil }, entered = plans.filter { $0.plan.djEntry != nil }
        let sections = Dictionary(grouping: left) { $0.plan.djSection?.rawValue ?? "" }.mapValues(\.count)
        let kinds = Dictionary(grouping: entered) { $0.plan.djEntry?.rawValue ?? "" }.mapValues(\.count)
        Style.note("pairs \(plans.count): left early \(left.count) \(sections), entered late \(entered.count) \(kinds), both \(left.filter { $0.plan.djEntry != nil }.count)")
        Style.note("share of the song played when left early, min / q1 / median / q3 / max: \(spread(left.map { ($0.plan.mixOutSec ?? 0) / $0.a.duration }))")
        Style.note("seconds in when entered late: \(spread(entered.map { $0.plan.mixInSec ?? 0 }))")
        let styles = Dictionary(grouping: plans.filter { $0.plan.djSection != nil || $0.plan.djEntry != nil }) { $0.plan.style.rawValue }.mapValues(\.count)
        Style.note("their styles: \(styles)")

        // One pair a style, the ones that do both first, each song once.
        var seen = Set<String>(), usedStyles = Set<String>()
        var order: [(a: LiveSong, b: LiveSong, plan: TransitionPlan)] = []
        for p in left.filter({ $0.plan.djEntry != nil }) + left + entered
        where !seen.contains(p.a.videoId) && !seen.contains(p.b.videoId) && !usedStyles.contains(p.plan.style.rawValue) {
            seen.formUnion([p.a.videoId, p.b.videoId]); usedStyles.insert(p.plan.style.rawValue)
            order.append(p)
        }
        for p in left.filter({ $0.plan.djEntry != nil }) where !seen.contains(p.a.videoId) && !seen.contains(p.b.videoId) {
            seen.formUnion([p.a.videoId, p.b.videoId]); order.append(p)
        }
        var proved = 0
        for p in order where proved < 4 {
            if await check(world, audio, p.a, p.b, p.plan) { proved += 1 }
        }
        #expect(proved >= 3, "only \(proved) real pairs played a DJ exit or entry")
    }

    /// Plays a to b and checks it; false when the live plan was not a DJ one.
    private func check(_ world: LiveWorld, _ audio: LiveAudio, _ a: LiveSong, _ b: LiveSong, _ pure: TransitionPlan) async -> Bool {
        MusicRenderRecorder.mutesOutput = true
        let checks = LiveChecks(world: world)
        checks.audio = audio
        let leaves = pure.djSection == nil ? nil : pure.mixOutSec
        let out = await checks.realRun(audio, beatMix: true, count: 1, tracks: [a.track(), b.track()], leavesAt: leaves)
        let name = "\(a.videoId) (\(a.index)) > \(b.videoId) (\(b.index))"
        guard let t = out.transitions.first, t.crossfaded else {
            Style.note("  \(name): no overlap (\(out.transitions.first?.failure ?? "none"))"); return false
        }
        guard let dj = t.line("transition_dj"), let mixOut = t.mixOut, let mixIn = t.mixIn else {
            Style.note("  \(name): mode \(t.mode), pure plan \(pure.djSection?.rawValue ?? "end") \(pure.djEntry?.rawValue ?? "-") \(pure.style.rawValue), no DJ line"); return false
        }
        let style = t.lines.compactMap(LiveLine.init).last { $0.name == "transition_style" }?.kv["style"] ?? "longBlend"
        let outAt = dj.number("outAt") ?? .nan, inAt = dj.number("inAt")
        // The outgoing song's place against the incoming one's, through the overlap (a cut is too short for anything but all of
        // it). A tempo-matched deck's clock is its item's: the map gives the song time, and it runs at the stretch.
        let stretch = t.line("transition_beat_plan")?.number("stretch") ?? 1
        let offsets = t.samples.filter { $0.tA.isFinite && $0.tB.isFinite && $0.tB > 0 }.map { s -> Double in
            let song = t.tempo?.songTime(s.tB) ?? s.tB
            return (s.tA - mixOut) - (song - mixIn) / stretch
        }
        let steady = offsets.count > 20 ? Array(offsets.dropFirst(5).dropLast(5)) : offsets
        let offset = steady.isEmpty ? Double.nan : LiveScan.median(steady)
        Style.note("  \(name): \(style) section=\(dj.kv["section"] ?? "-") outAt=\(liveF(outAt)) of \(liveF(a.duration)) s (\(liveF(outAt / a.duration * 100, 0))%), entry=\(dj.kv["entry"] ?? "-") inAt=\(inAt.map { liveF($0) } ?? "-"); heard overlap \(liveF(t.overlapSec)) s, decks against the plan median \(liveF(offset * 1000, 1)) ms, first \(liveF((offsets.first ?? .nan) * 1000, 1)) ms, stretch \(liveF(stretch, 4)); dropouts=\(t.dropouts) nonFinite=\(t.nonFinite) stalls=\(t.stalls) rateWrites=\(t.engineRateWrites) peak \(liveF(Double(t.capturePeak), 3)) \(t.dropoutDetail)")
        #expect(abs(outAt - mixOut) < 0.02)
        if let inAt { #expect(abs(inAt - mixIn) < 0.02) }
        #expect(abs(offset) < 0.1, "the decks are \(offset) s from the plan")
        #expect(t.dropouts == 0, "dropouts \(t.dropoutDetail)")
        #expect(t.nonFinite == 0)
        #expect(t.engineRateWrites == 0)
        return true
    }
}
