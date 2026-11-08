// DeciTests/Music/Vocals/VocalGuardEvalTests.swift
// Tier 3c P3: the structural vocal guard on real songs. Opt-in, same gate as the P1 spike:
//   TEST_RUNNER_DECI_VOCAL_EVAL=1 run-tests.sh p3-eval VocalGuardEvalTests
// Runs the production analyzer on every song in the songs folder, plans all ordered pairs with the guard off and on
// through the real planners, and measures the TRUE collision of every plan against the synced-lyrics silver truth
// (a song sings where one of its lyric lines is on). Output: /Volumes/Storage/_test/deci-3c/p3-structural.txt.

import Foundation
import CryptoKit
import Testing
@testable import Deci

private nonisolated let guardEval = ProcessInfo.processInfo.environment["DECI_VOCAL_EVAL"] == "1"

private nonisolated struct GSong: Sendable {
    var id: String
    var analysis: MusicAnalysis
    var duration: Double
    var spans: [(Double, Double)]

    func sings(_ t: Double) -> Bool { spans.contains { t >= $0.0 && t < $0.1 } }
}

@Suite("Vocal guard eval", .serialized, .enabled(if: guardEval))
struct VocalGuardEvalTests {
    /// The lyric silver truth as time spans (same line rules as the P1 spike).
    private nonisolated static func spans(lyricsPath: String) -> [(Double, Double)]? {
        guard let data = FileManager.default.contents(atPath: lyricsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = json["lines"] as? [[String: Any]] else { return nil }
        var spans: [(Double, Double)] = []
        for (i, line) in lines.enumerated() {
            guard let start = (line["time"] as? NSNumber)?.doubleValue,
                  let text = line["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let next = i + 1 < lines.count ? (lines[i + 1]["time"] as? NSNumber)?.doubleValue : nil
            let end = min((line["end"] as? NSNumber)?.doubleValue ?? next ?? start + 8, start + 8)
            if end > start { spans.append((start, end)) }
        }
        return spans
    }

    /// Wall seconds both songs sing together in an overlap, by the lyric truth, sampled every 50 ms.
    private nonisolated static func trueCollision(
        _ a: GSong, _ b: GSong, outStart: Double, inStart: Double, rate: Double, length: Double
    ) -> Double {
        guard length > 0, length.isFinite else { return 0 }
        let step = 0.05
        var total = 0.0
        var t = step / 2
        while t < length {
            if a.sings(outStart + t), b.sings(inStart + rate * t) { total += step }
            t += step
        }
        return total
    }

    /// Where a plan overlaps: outgoing start, incoming start, rate, wall length. nil = no overlap (gapless, clean).
    private nonisolated static func overlap(_ plan: TransitionPlan, aDuration: Double) -> (Double, Double, Double, Double)? {
        guard plan.fadeSeconds > 0 else { return nil }
        if plan.mode == .beat, let out = plan.mixOutSec, let into = plan.mixInSec {
            return (out, into, plan.incomingRate, plan.overlapSec)
        }
        let end = plan.outgoingEndSec ?? aDuration
        return (plan.fadeStartSec ?? (end - plan.fadeSeconds), plan.incomingStartSec, 1, plan.fadeSeconds)
    }

    private nonisolated static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private nonisolated static func f(_ x: Double) -> String { String(format: "%.2f", x) }

    @Test("tier 3c P3: guard off vs on over every ordered pair of the real songs")
    func structuralEval() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = env["DECI_VOCAL_SONGS"] ?? "/Volumes/Storage/_test/deci-3c/songs"
        let ids = try String(contentsOfFile: root + "/ids.txt", encoding: .utf8).split(separator: "\n").map(String.init)
        let lyricsDir = NSString(string: "~/Library/Caches/com.abraham.Deci/Music/Lyrics").expandingTildeInPath

        var songs: [GSong] = []
        var report = "STRUCTURAL VOCAL GUARD P3\n"
        for id in ids {
            guard let file = (try? FileManager.default.contentsOfDirectory(atPath: root))?
                .first(where: { $0.hasPrefix(id + ".") && !$0.hasSuffix(".part") }) else { continue }
            let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            guard let spans = Self.spans(lyricsPath: lyricsDir + "/" + hash + ".json") else { continue }
            let result = try await MusicFileAnalyzer.analyze(file: URL(fileURLWithPath: root + "/" + file), exactDuration: nil)
            let analysis = MusicAnalysis(videoId: id, result: result, source: .playbackCache)
            songs.append(GSong(id: id, analysis: analysis, duration: result.measurement.duration, spans: spans))
            report += "song \(id): dur=\(Self.f(result.measurement.duration)) introEnd=\(Self.f(analysis.introEnd))"
                + " outroStart=\(Self.f(analysis.outroStart)) bpm=\(analysis.usableGrid.map { Self.f($0.bpm) } ?? "-")"
                + " lyricSpans=\(spans.count)\n"
        }
        #expect(songs.count >= 2)

        // The same songs as e32c82b stored them: the only downbeat that estimator found on the 12 songs was Txnqzr_DZYg
        // phase 1 (3b accuracy P2 diagnosis), and the planner reads nothing but the stored grid.
        var songsBefore = songs
        for index in songsBefore.indices {
            guard var grid = songsBefore[index].analysis.usableGrid else { continue }
            grid.downbeatPhase = songsBefore[index].id == "Txnqzr_DZYg" ? 1 : nil
            songsBefore[index].analysis.beatGrid = grid.encode()
        }

        struct Row {
            var plan: TransitionPlan
            var truth: Double
            var proxy: Double
        }
        func run(_ set: [GSong]) -> (off: [Row], on: [Row], detail: String) {
        var off: [Row] = [], on: [Row] = []
        var detail = ""
        for a in set {
            for b in set where a.id != b.id {
                func inputs(_ guardOn: Bool) -> MusicTransitionInputs {
                    var i = MusicTransitionInputs(
                        outgoing: MusicTransitionSide(videoId: a.id, durationSeconds: a.duration, analysis: a.analysis),
                        incoming: MusicTransitionSide(videoId: b.id, durationSeconds: b.duration, analysis: b.analysis),
                        crossfadeOn: true, settingSeconds: 6, bassSwapAvailable: true, vocalGuardEnabled: guardOn
                    )
                    i.beatMixEnabled = true
                    return i
                }
                func row(_ plan: TransitionPlan) -> Row {
                    guard let o = Self.overlap(plan, aDuration: a.duration) else { return Row(plan: plan, truth: 0, proxy: 0) }
                    let truth = Self.trueCollision(a, b, outStart: o.0, inStart: o.1, rate: o.2, length: o.3)
                    let proxy = MusicVocalGuard.collisionSec(
                        outgoing: a.analysis, incoming: b.analysis, outStart: o.0, inStart: o.1, rate: o.2, length: o.3
                    ) ?? 0
                    return Row(plan: plan, truth: truth, proxy: proxy)
                }
                let r0 = row(MusicTransitionPlanner.plan(inputs(false)))
                let r1 = row(MusicTransitionPlanner.plan(inputs(true)))
                off.append(r0)
                on.append(r1)
                detail += "\(a.id)>\(b.id) off=\(r0.plan.mode.rawValue)/\(Self.f(r0.plan.fadeSeconds))s/bars\(r0.plan.overlapBars)"
                    + " proxy=\(Self.f(r0.proxy)) truth=\(Self.f(r0.truth))"
                    + " | on=\(r1.plan.mode.rawValue)/\(Self.f(r1.plan.fadeSeconds))s/bars\(r1.plan.overlapBars)"
                    + " action=\(r1.plan.vocalAction ?? "-") fb=\(r1.plan.fallbackReason ?? "-")"
                    + " proxy=\(Self.f(r1.proxy)) truth=\(Self.f(r1.truth))\n"
            }
        }
        return (off, on, detail)
        }
        let (offBefore, onBefore, _) = run(songsBefore)
        let (off, on, detail) = run(songs)

        let budget = MusicVocalGuard.budgetSec
        func summary(_ name: String, _ rows: [Row]) -> String {
            var modes: [String: Int] = [:]
            for r in rows { modes[r.plan.mode.rawValue, default: 0] += 1 }
            var actions: [String: Int] = [:]
            for r in rows { actions[r.plan.vocalAction ?? "untouched", default: 0] += 1 }
            var fallbacks: [String: Int] = [:]
            for r in rows { fallbacks[r.plan.fallbackReason ?? "-", default: 0] += 1 }
            let fades = rows.filter { $0.plan.mode != .beat && $0.plan.fadeSeconds > 0 }.map(\.plan.fadeSeconds)
            let overlaps = rows.filter { $0.plan.mode == .beat }.map(\.plan.overlapSec)
            let bars = Dictionary(grouping: rows.filter { $0.plan.mode == .beat }, by: \.plan.overlapBars).mapValues(\.count)
            return """
            [\(name)] pairs=\(rows.count)
              modes: \(modes.sorted { $0.key < $1.key })
              vocalAction: \(actions.sorted { $0.key < $1.key })
              fallbackReason: \(fallbacks.sorted { $0.key < $1.key })
              beat overlap bars: \(bars.sorted { $0.key < $1.key })
              beat plans with a bass swap: \(rows.filter { $0.plan.mode == .beat && $0.plan.bassSwapAtSec != nil }.count)
              beat plans with a bass swap by bars: \(Dictionary(grouping: rows.filter { $0.plan.mode == .beat && $0.plan.bassSwapAtSec != nil }, by: \.plan.overlapBars).mapValues(\.count).sorted { $0.key < $1.key })
              median fade (non-beat plans, n=\(fades.count)): \(Self.f(Self.median(fades))) s
              median overlap (beat plans, n=\(overlaps.count)): \(Self.f(Self.median(overlaps))) s
              fades == 3.00 s (non-beat): \(fades.filter { abs($0 - 3) < 1e-9 }.count)
              TRUE collision > \(budget) s (lyric truth): \(rows.filter { $0.truth > budget }.count) of \(rows.count)
              proxy collision > \(budget) s: \(rows.filter { $0.proxy > budget }.count) of \(rows.count)
              median TRUE collision: \(Self.f(Self.median(rows.map(\.truth)))) s, mean \(Self.f(rows.map(\.truth).reduce(0, +) / Double(max(rows.count, 1)))) s
            """
        }
        report += "\n" + summary("BEFORE downbeats, guard OFF", offBefore) + "\n\n" + summary("BEFORE downbeats, guard ON", onBefore) + "\n"
        report += "\n" + summary("guard OFF", off) + "\n\n" + summary("guard ON", on) + "\n"
        report += "\ngrids with a downbeat: before \(songsBefore.filter { $0.analysis.usableGrid?.downbeatPhase != nil }.count), after \(songs.filter { $0.analysis.usableGrid?.downbeatPhase != nil }.count) of \(songs.count)\n"
        let changed = zip(off, on).filter { $0.0.plan != $0.1.plan }
        let worse = zip(off, on).filter { $0.1.truth > $0.0.truth + 1e-9 }.count
        let better = zip(off, on).filter { $0.1.truth < $0.0.truth - 1e-9 }.count
        let fixed = zip(off, on).filter { $0.0.truth > budget && $0.1.truth <= budget }.count
        let broken = zip(off, on).filter { $0.0.truth <= budget && $0.1.truth > budget }.count
        report += """

        pairs whose plan changed: \(changed.count) of \(off.count)
        true collision lower with the guard: \(better), higher: \(worse)
        pairs taken from true collision > \(budget) s to <= \(budget) s: \(fixed); the other way: \(broken)

        """
        report += "\nPER PAIR\n" + detail
        try report.write(toFile: "/Volumes/Storage/_test/deci-3c/p3-structural.txt", atomically: true, encoding: .utf8)
    }
}
