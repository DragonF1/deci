// DeciTests/Music/Harmonix/HarmonixBeatEvalTests.swift
// Tier 3d card fwj3ia: Deci's own beat finder and downbeat detector against the Harmonix annotated set. Opt-in, a
// measurement and a report, never a product change. Gate (skipped otherwise): the manifest exists AND either the env var
//   TEST_RUNNER_DECI_HARMONIX_EVAL=1   (xcodebuild hands it to the test process as DECI_HARMONIX_EVAL)
// is set or the flag file <dataset>/RUN_EVAL exists. Dataset (local only, never committed):
//   /Volumes/Storage/_build/scratch/deci-harmonix  (override with DECI_HARMONIX_DIR)
//   manifest.json  songs/  truth/<id>.beats.txt ("time<TAB>beat in bar", 1 = downbeat)
// Alignment: truth/<id>.beats.txt is already in audio time (annotation + offset_sec, applied once by run_align.py).
// Per song, through the production path (MusicFileAnalyzer.analyze, the stored MusicBeatGrid):
//   beat F (70 ms, BeatScoring) over the validated span only and over the whole song, downbeat F the same way,
//   trusted (the MusicBeatPlanner gates), tempo octave class, stored downbeat accepted / wrong, and the downbeat
//   estimate re-gated at margins 1.0 to 3.0 SE (the stored one uses 2.0).
// A downbeat phase is "correct" when the grid's bars at that phase score downbeat F >= 0.5 on the span.
// Output: <dataset>/eval/ours-<git short sha>.json and .txt.

import Foundation
import Testing
@testable import Deci

private nonisolated let harmonixDir = ProcessInfo.processInfo.environment["DECI_HARMONIX_DIR"] ?? "/Volumes/Storage/_build/scratch/deci-harmonix"
private nonisolated let harmonixGate: Bool = {
    let fm = FileManager.default
    guard fm.fileExists(atPath: harmonixDir + "/manifest.json") else { return false }
    return ProcessInfo.processInfo.environment["DECI_HARMONIX_EVAL"] == "1" || fm.fileExists(atPath: harmonixDir + "/RUN_EVAL")
}()

@Suite("Harmonix beat eval", .serialized, .enabled(if: harmonixGate))
struct HarmonixBeatEvalTests {
    nonisolated struct Song {
        var id: String, title: String, artist: String, genre: String
        var songPath: String, truthPath: String
        var offset: Double, bpm: Double?
    }

    nonisolated struct Row {
        var song: Song
        var hasGrid = false
        var trusted = false
        var bpm: Double?, truthBpm: Double = .nan
        var tempoClass = "n/a"
        var confidence: Double = .nan, spread: Double = .nan, drift: Double = .nan
        var spanSec: Double = 0, durationSec: Double = 0
        var beatSpan = BeatScoring.fMeasure(reference: [], estimated: [1])
        var beatWhole = BeatScoring.fMeasure(reference: [], estimated: [1])
        var medianOffsetMs: Double = .nan
        var storedPhase: Int?
        var dbSpan: Double = .nan, dbWhole: Double = .nan
        /// Downbeat F on the span for each phase 0...3 (what the grid would score had that phase been chosen).
        var dbByPhase: [Double] = []
        var storedCorrect: Bool?
        var estimate: MusicBeatFinder.DownbeatEstimate?
        var seconds: Double = 0
    }

    // MARK: Reading the dataset

    private nonisolated static func loadSongs() throws -> [Song] {
        let data = try Data(contentsOf: URL(fileURLWithPath: harmonixDir + "/manifest.json"))
        let json = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]] = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["songs"] as? [[String: Any]]) ?? []
        func path(_ value: Any?, _ fallback: String) -> String {
            guard let s = value as? String, !s.isEmpty else { return fallback }
            return s.hasPrefix("/") ? s : harmonixDir + "/" + s
        }
        return items.compactMap { d in
            guard let id = d["id"] as? String, let offset = (d["offset_sec"] as? NSNumber)?.doubleValue else { return nil }
            return Song(
                id: id, title: d["title"] as? String ?? "", artist: d["artist"] as? String ?? "",
                genre: (d["genre"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown",
                songPath: path(d["song"], harmonixDir + "/songs/\(id).m4a"),
                truthPath: path(d["truth"], harmonixDir + "/truth/\(id).beats.txt"),
                offset: offset, bpm: (d["bpm"] as? NSNumber)?.doubleValue
            )
        }
    }

    /// (all beat times, downbeat times) in the audio's timeline (the truth files already hold annotation time + offset_sec, written by run_align.py, so it is NOT added again).
    private nonisolated static func loadTruth(_ song: Song) throws -> (beats: [Double], downbeats: [Double]) {
        let text = try String(contentsOfFile: song.truthPath, encoding: .utf8)
        var beats: [Double] = [], downbeats: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2, let t = Double(parts[0]), let n = Int(parts[1]) else { continue }
            beats.append(t)
            if n == 1 { downbeats.append(t) }
        }
        return (beats, downbeats)
    }

    private nonisolated static func trusted(_ g: MusicBeatGrid) -> Bool {
        MusicBeatGrid.periodRange.contains(g.periodSec) && g.beatConfidence >= MusicBeatPlanner.minConfidence
            && g.intervalSpread <= MusicBeatPlanner.maxIntervalSpread && abs(g.driftSec) <= MusicBeatPlanner.maxDriftSec
    }

    private nonisolated static func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
    private nonisolated static func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }

    /// Grid beat times (optionally only every 4th from `phase`) inside [from, to].
    private nonisolated static func gridTimes(_ g: MusicBeatGrid, from: Double, to: Double, phase: Int? = nil) -> [Double] {
        guard to > from else { return [] }
        let first = Int(ceil((from - g.anchorSec) / g.periodSec)), last = Int(floor((to - g.anchorSec) / g.periodSec))
        guard first <= last else { return [] }
        return (first...last).compactMap { k in
            if let phase, ((k - phase) % 4 + 4) % 4 != 0 { return nil }
            return g.beatTime(k)
        }
    }

    private nonisolated static func within(_ v: [Double], _ a: Double, _ b: Double) -> [Double] { v.filter { $0 >= a && $0 <= b } }

    private nonisolated static func tempoClass(_ ours: Double, truth: Double) -> String {
        let r = ours / truth
        if abs(r - 1) <= 0.04 { return "ok" }
        if abs(r - 2) <= 0.08 { return "double" }
        if abs(r - 0.5) <= 0.02 { return "half" }
        return "other(x\(String(format: "%.2f", r)))"
    }

    /// Whether the estimate would be accepted with the margin gate set to `margin` (agreement and effect gates unchanged).
    private nonisolated static func accepted(_ e: MusicBeatFinder.DownbeatEstimate, margin: Double) -> Bool {
        e.agrees && e.margin >= margin && e.effect >= MusicBeatFinder.minDownbeatEffect
    }

    // MARK: One song

    private nonisolated static func evaluate(_ song: Song) async throws -> Row {
        let started = Date()
        var row = Row(song: song)
        let truth = try loadTruth(song)
        row.truthBpm = {
            let d = zip(truth.beats.dropFirst(), truth.beats).map { $0 - $1 }
            let m = median(d)
            return m > 0 ? 60 / m : song.bpm ?? .nan
        }()
        let url = URL(fileURLWithPath: song.songPath)
        let result = try await MusicFileAnalyzer.analyze(file: url, exactDuration: nil)
        let analysis = MusicAnalysis(videoId: song.id, result: result, source: .playbackCache)
        let (audio, rate) = try await GridGateDiagnosisTests.decode(url)
        let duration = Double(audio.count) / rate
        row.durationSec = duration
        guard let g = analysis.usableGrid else {
            row.beatSpan = BeatScoring.fMeasure(reference: [], estimated: [1])
            row.beatWhole = BeatScoring.fMeasure(reference: within(truth.beats, 0, duration), estimated: [])
            row.seconds = Date().timeIntervalSince(started)
            return row
        }
        row.hasGrid = true
        row.trusted = trusted(g)
        row.bpm = g.bpm
        row.tempoClass = tempoClass(g.bpm, truth: row.truthBpm)
        row.confidence = Double(g.beatConfidence); row.spread = Double(g.intervalSpread); row.drift = Double(g.driftSec)
        row.spanSec = g.spanEndSec - g.spanStartSec
        row.storedPhase = g.downbeatPhase

        let a = g.spanStartSec, b = g.spanEndSec
        let spanBeats = gridTimes(g, from: a, to: b)
        row.beatSpan = BeatScoring.fMeasure(reference: within(truth.beats, a, b), estimated: spanBeats)
        row.beatWhole = BeatScoring.fMeasure(reference: within(truth.beats, 0, duration), estimated: gridTimes(g, from: 0, to: duration))
        row.medianOffsetMs = (BeatScoring.medianOffset(reference: truth.beats, estimated: spanBeats) ?? .nan) * 1000

        // Downbeat F for each phase on the span, and for the stored phase on the whole song.
        let truthDownSpan = within(truth.downbeats, a, b)
        row.dbByPhase = (0..<4).map { p in
            BeatScoring.fMeasure(reference: truthDownSpan, estimated: gridTimes(g, from: a, to: b, phase: p)).f
        }
        if let p = g.downbeatPhase {
            row.dbSpan = row.dbByPhase[p]
            row.dbWhole = BeatScoring.fMeasure(
                reference: within(truth.downbeats, 0, duration), estimated: gridTimes(g, from: 0, to: duration, phase: p)
            ).f
            row.storedCorrect = row.dbSpan >= 0.5
        }
        // The downbeat estimate, as the production step computes it on the validated beats (trusted grids only).
        if row.trusted {
            let first = Int(ceil((a - g.anchorSec) / g.periodSec)), last = Int(floor((b - g.anchorSec) / g.periodSec))
            if first <= last {
                row.estimate = MusicBeatFinder.estimateDownbeat(decimated: audio, rate: rate, grid: g, beats: first...last)
            }
        }
        row.seconds = Date().timeIntervalSince(started)
        return row
    }

    // MARK: Report

    private nonisolated static func f(_ x: Double, _ d: Int = 3) -> String { x.isNaN ? "n/a" : String(format: "%.\(d)f", x) }
    private nonisolated static func pct(_ n: Int, _ of: Int) -> String { of == 0 ? "n/a" : String(format: "%.1f%% (%d/%d)", 100 * Double(n) / Double(of), n, of) }

    private nonisolated static func reason(_ r: Row) -> String {
        guard r.hasGrid else { return "no grid stored" }
        var parts: [String] = []
        if r.tempoClass != "ok" { parts.append("tempo \(r.tempoClass) (ours \(f(r.bpm ?? .nan, 1)) vs truth \(f(r.truthBpm, 1)))") }
        else if abs(r.medianOffsetMs) > 35 { parts.append("phase off by \(f(r.medianOffsetMs, 0)) ms") }
        else if abs(r.medianOffsetMs) > 15 { parts.append("phase off by \(f(r.medianOffsetMs, 0)) ms (late/early lock)") }
        if !r.trusted { parts.append("untrusted conf \(f(r.confidence, 2)) spread \(f(r.spread, 3)) drift \(f(r.drift, 4))") }
        if parts.isEmpty { parts.append("tempo and phase fine, beats jitter or tempo varies in the song (offset \(f(r.medianOffsetMs, 0)) ms)") }
        return parts.joined(separator: "; ")
    }

    private nonisolated static func summary(_ rows: [Row], sha: String, seconds: Double) -> String {
        var s = "HARMONIX BEAT EVAL, ours-\(sha) (70 ms window, truth already in audio time)\n"
        let grid = rows.filter(\.hasGrid), trusted = grid.filter(\.trusted)
        s += "songs \(rows.count), with a stored grid \(grid.count), trusted \(pct(trusted.count, rows.count)), runtime \(f(seconds, 0)) s\n\n"
        func stats(_ label: String, _ v: [Double]) {
            s += "\(label): mean \(f(mean(v))), median \(f(median(v))) (n \(v.count))\n"
        }
        s += "BEAT F-MEASURE\n"
        stats("  span,  all songs (no grid = 0)", rows.map { $0.hasGrid ? $0.beatSpan.f : 0 })
        stats("  span,  grid songs", grid.map(\.beatSpan.f))
        stats("  span,  trusted songs", trusted.map(\.beatSpan.f))
        stats("  whole, all songs (no grid = 0)", rows.map { $0.beatWhole.f })
        stats("  whole, grid songs", grid.map(\.beatWhole.f))
        stats("  whole, trusted songs", trusted.map(\.beatWhole.f))
        s += "  span precision mean \(f(mean(grid.map(\.beatSpan.precision)))), recall mean \(f(mean(grid.map(\.beatSpan.recall))))\n"
        s += "  trusted grids with span F < 0.5 (trusted but wrong): \(trusted.filter { $0.beatSpan.f < 0.5 }.count) of \(trusted.count)\n"
        s += "  untrusted grids with span F >= 0.8 (good grid refused): \(grid.filter { !$0.trusted && $0.beatSpan.f >= 0.8 }.count) of \(grid.filter { !$0.trusted }.count)\n\n"

        s += "TEMPO (grid vs truth median bpm; ok = within 4%)\n"
        for c in ["ok", "half", "double"] { s += "  \(c): \(pct(grid.filter { $0.tempoClass == c }.count, grid.count))\n" }
        s += "  other: \(pct(grid.filter { !["ok", "half", "double"].contains($0.tempoClass) }.count, grid.count))\n"
        s += "  trusted octave errors: \(trusted.filter { $0.tempoClass == "half" || $0.tempoClass == "double" }.count) of \(trusted.count)\n\n"

        s += "DOWNBEAT (stored phase from the production analyzer; correct = downbeat F >= 0.5 on the span)\n"
        let stored = grid.filter { $0.storedPhase != nil }
        s += "  accept rate, all grid songs: \(pct(stored.count, grid.count)); trusted grids: \(pct(stored.filter(\.trusted).count, trusted.count))\n"
        let wrong = stored.filter { $0.storedCorrect == false }
        s += "  false-accept (accepted and wrong): \(pct(wrong.count, stored.count)) of accepted\n"
        let alignedStored = stored.filter { $0.beatSpan.f >= 0.5 }
        s += "  false-accept where the beat grid itself is right (beat F >= 0.5): \(pct(alignedStored.filter { $0.storedCorrect == false }.count, alignedStored.count))\n"
        stats("  downbeat F span, accepted songs", stored.map(\.dbSpan))
        stats("  downbeat F whole, accepted songs", stored.map(\.dbWhole))
        let beatsRight = trusted.filter { $0.beatSpan.f >= 0.5 && $0.dbByPhase.count == 4 }
        let oracle = beatsRight.map { $0.dbByPhase.max() ?? 0 }
        s += "  ceiling (best phase chosen by oracle) on trusted grids with beat F >= 0.5: mean \(f(mean(oracle))) (n \(oracle.count))\n\n"

        s += "DOWNBEAT MARGIN CALIBRATION (trusted grids with an estimate; agreement and effect gates as production; production = 2.0)\n"
        s += "  margin SE | accepted | wrong of accepted | wrong, beat grid right\n"
        let estimated = trusted.filter { $0.estimate != nil }
        s += "  (trusted grids \(trusted.count), with an estimate \(estimated.count))\n"
        for m in [1.0, 1.5, 2.0, 2.5, 3.0] {
            let acc = estimated.filter { accepted($0.estimate!, margin: m) }
            let bad = acc.filter { $0.dbByPhase.count == 4 && $0.dbByPhase[$0.estimate!.phase] < 0.5 }
            let accRight = acc.filter { $0.beatSpan.f >= 0.5 }
            let badRight = accRight.filter { $0.dbByPhase[$0.estimate!.phase] < 0.5 }
            s += "  \(f(m, 1)) | \(pct(acc.count, estimated.count)) | \(pct(bad.count, acc.count)) | \(pct(badRight.count, accRight.count))\n"
        }
        s += "\n"

        s += "PER GENRE (n | trusted | beat F span grid songs | beat F whole | downbeat accepted | downbeat wrong)\n"
        for genre in Set(rows.map(\.song.genre)).sorted() {
            let r = rows.filter { $0.song.genre == genre }, g = r.filter(\.hasGrid)
            let st = g.filter { $0.storedPhase != nil }
            s += "  \(genre): \(r.count) | \(g.filter(\.trusted).count) | \(f(mean(g.map(\.beatSpan.f)))) | \(f(mean(g.map(\.beatWhole.f))))"
                + " | \(st.count) | \(st.filter { $0.storedCorrect == false }.count)\n"
        }
        s += "\nWORST 5 BY BEAT F ON THE SPAN (no grid counts as 0)\n"
        for r in rows.sorted(by: { ($0.hasGrid ? $0.beatSpan.f : 0) < ($1.hasGrid ? $1.beatSpan.f : 0) }).prefix(5) {
            s += "  \(r.song.id) (\(r.song.artist) - \(r.song.title), \(r.song.genre)): F span \(f(r.hasGrid ? r.beatSpan.f : 0)), whole \(f(r.beatWhole.f)): \(reason(r))\n"
        }
        s += "\nPER SONG\n  id | genre | grid | trusted | bpm ours/truth | tempo | beat F span/whole | offset ms | stored phase | db F span | db correct | est margin/effect/agrees | s\n"
        for r in rows {
            s += "  \(r.song.id) | \(r.song.genre) | \(r.hasGrid ? "yes" : "no") | \(r.trusted ? "yes" : "no") | \(f(r.bpm ?? .nan, 1))/\(f(r.truthBpm, 1))"
                + " | \(r.tempoClass) | \(f(r.beatSpan.f))/\(f(r.beatWhole.f)) | \(f(r.medianOffsetMs, 1)) | \(r.storedPhase.map(String.init) ?? "none")"
                + " | \(f(r.dbSpan)) | \(r.storedCorrect.map { $0 ? "yes" : "no" } ?? "-")"
                + " | \(r.estimate.map { "\(f($0.margin, 2))/\(f($0.effect, 2))/\($0.agrees)" } ?? "-") | \(f(r.seconds, 1))\n"
        }
        return s
    }

    private nonisolated static func json(_ r: Row) -> [String: Any] {
        func v(_ x: Double) -> Any { x.isFinite ? x : NSNull() }
        func score(_ s: BeatScoring.Score) -> [String: Any] {
            ["precision": s.precision, "recall": s.recall, "f": s.f, "hits": s.hits, "estimated": s.estimated, "reference": s.reference]
        }
        var d: [String: Any] = [
            "id": r.song.id, "title": r.song.title, "artist": r.song.artist, "genre": r.song.genre,
            "offset_sec": r.song.offset, "has_grid": r.hasGrid, "trusted": r.trusted,
            "bpm": v(r.bpm ?? .nan), "truth_bpm": v(r.truthBpm), "tempo_class": r.tempoClass,
            "beat_confidence": v(r.confidence), "interval_spread": v(r.spread), "drift_sec": v(r.drift),
            "span_sec": r.spanSec, "duration_sec": r.durationSec,
            "beat_span": score(r.beatSpan), "beat_whole": score(r.beatWhole),
            "median_offset_ms": v(r.medianOffsetMs), "stored_phase": r.storedPhase.map { $0 as Any } ?? NSNull(),
            "downbeat_f_span": v(r.dbSpan), "downbeat_f_whole": v(r.dbWhole),
            "downbeat_f_by_phase": r.dbByPhase, "stored_downbeat_correct": r.storedCorrect.map { $0 as Any } ?? NSNull(),
            "seconds": r.seconds,
        ]
        if let e = r.estimate {
            d["downbeat_estimate"] = [
                "phase": e.phase, "margin": e.margin, "effect": e.effect, "agrees": e.agrees, "blocks": e.blocks,
                "accepted_at_1.0": accepted(e, margin: 1.0), "accepted_at_1.5": accepted(e, margin: 1.5),
                "accepted_at_2.0": accepted(e, margin: 2.0), "accepted_at_2.5": accepted(e, margin: 2.5),
                "accepted_at_3.0": accepted(e, margin: 3.0),
            ] as [String: Any]
        }
        return d
    }

    private nonisolated static func gitSha() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", "/Volumes/Storage/Coding/deci", "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "unknown" }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? "unknown" : out
    }

    @Test("Harmonix: beat and downbeat accuracy of the production analyzer")
    func evaluateAll() async throws {
        let started = Date()
        let songs = try Self.loadSongs()
        #expect(!songs.isEmpty, "manifest has no usable songs")
        var rows: [Row] = []
        var failures: [String] = []
        for song in songs {
            guard FileManager.default.fileExists(atPath: song.songPath), FileManager.default.fileExists(atPath: song.truthPath) else {
                failures.append("\(song.id): missing song or truth file")
                continue
            }
            do { rows.append(try await Self.evaluate(song)) } catch { failures.append("\(song.id): \(error)") }
        }
        let sha = Self.gitSha()
        let dir = harmonixDir + "/eval"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: rows.map(Self.json), options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: "\(dir)/ours-\(sha).json"))
        var text = Self.summary(rows, sha: sha, seconds: Date().timeIntervalSince(started))
        if !failures.isEmpty { text += "\nSKIPPED OR FAILED\n" + failures.map { "  " + $0 }.joined(separator: "\n") + "\n" }
        try text.write(toFile: "\(dir)/ours-\(sha).txt", atomically: true, encoding: .utf8)
        #expect(failures.isEmpty, "\(failures.count) songs failed: \(failures.prefix(3))")
    }
}
