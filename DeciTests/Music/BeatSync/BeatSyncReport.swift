// DeciTests/Music/BeatSync/BeatSyncReport.swift
// Turns the spike's `runs.jsonl` into `report.json` and `report.md`, and judges the runs against the gate.

import Foundation

nonisolated struct BeatSyncGroup: Codable, Sendable {
    var rate: Double
    var algorithm: String
    var clock: String
    var overlapSeconds: Double
    var runs: Int
    var failed: Int
    var startMeanMs: Double
    var startStdevMs: Double
    var startMinMs: Double
    var startMaxMs: Double
    var worstStartMs: Double
    var worstDriftMs: Double
    var meanJitterMs: Double
    var worstJitterMs: Double
    /// The worst start error left once the group's own mean offset is calibrated out.
    var worstCalibratedStartMs: Double
    /// Mean start error minus the baseline (default algorithm, rate 1.00, no shared clock): the algorithm's fixed latency.
    var latencyVsBaselineMs: Double?
}

nonisolated enum BeatSyncVerdict: String, Codable, Sendable {
    case pass = "PASS"
    case passCalibrated = "PASS (constant offset, calibrate out)"
    case fail = "FAIL"
    case noData = "NO DATA"
}

nonisolated enum BeatSyncReport {
    static let limitMs = 10.0

    static func groups(_ records: [BeatSyncRunRecord]) -> [BeatSyncGroup] {
        struct Key: Hashable { var rate: Double; var algorithm: String; var clock: String; var overlap: Double }
        let keyed = Dictionary(grouping: records) {
            Key(rate: $0.rate, algorithm: $0.algorithm, clock: $0.clock, overlap: $0.overlapSeconds)
        }
        var result: [BeatSyncGroup] = keyed.map { key, all in
            let good = all.filter { $0.failure == nil }
            let starts = good.map(\.startErrorMs)
            let summary = BeatSyncSummary(starts)
            return BeatSyncGroup(
                rate: key.rate, algorithm: key.algorithm, clock: key.clock, overlapSeconds: key.overlap,
                runs: good.count, failed: all.count - good.count,
                startMeanMs: summary.mean, startStdevMs: summary.stdev,
                startMinMs: summary.minimum, startMaxMs: summary.maximum,
                worstStartMs: starts.map(abs).max() ?? 0,
                worstDriftMs: good.map(\.driftMs).max() ?? 0,
                meanJitterMs: BeatSyncSummary(good.map(\.jitterMs)).mean,
                worstJitterMs: good.map(\.jitterMs).max() ?? 0,
                worstCalibratedStartMs: starts.map { abs($0 - summary.mean) }.max() ?? 0,
                latencyVsBaselineMs: nil
            )
        }
        result.sort { ($0.clock, $0.overlapSeconds, $0.algorithm, $0.rate) < ($1.clock, $1.overlapSeconds, $1.algorithm, $1.rate) }
        let baseline = result.first { $0.algorithm == "default" && $0.rate == 1 && $0.clock == "none" && $0.overlapSeconds < 30 && $0.runs > 0 }
        if let baseline {
            for index in result.indices where result[index].runs > 0 {
                result[index].latencyVsBaselineMs = result[index].startMeanMs - baseline.startMeanMs
            }
        }
        return result
    }

    /// PASS: every run's start error and drift are inside the limit. PASS (calibrated): the drift is, and the start
    /// errors are inside the limit once each group's constant offset is taken out. Any failed run is a FAIL.
    static func verdict(_ records: [BeatSyncRunRecord]) -> BeatSyncVerdict {
        guard !records.isEmpty else { return .noData }
        guard records.allSatisfy({ $0.failure == nil }) else { return .fail }
        guard records.allSatisfy({ $0.driftMs <= limitMs }) else { return .fail }
        if records.allSatisfy({ abs($0.startErrorMs) <= limitMs }) { return .pass }
        let calibrated = groups(records).allSatisfy { $0.worstCalibratedStartMs <= limitMs }
        return calibrated ? .passCalibrated : .fail
    }

    static func load() -> [BeatSyncRunRecord] {
        guard let text = try? String(contentsOf: BeatSyncPaths.runs, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(BeatSyncRunRecord.self, from: Data($0.utf8)) }
    }

    static func write() throws {
        let records = load()
        let table = groups(records)
        let verdict = Self.verdict(records)
        struct Output: Codable {
            var verdict: BeatSyncVerdict
            var limitMs: Double
            var device: String
            var sampleRate: Double
            var groups: [BeatSyncGroup]
            var runs: [BeatSyncRunRecord]
        }
        let output = Output(
            verdict: verdict, limitMs: limitMs, device: records.first?.device ?? "", sampleRate: records.first?.sampleRate ?? 0,
            groups: table, runs: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output).write(to: BeatSyncPaths.root.appendingPathComponent("report.json"))
        try markdown(records: records, groups: table, verdict: verdict)
            .write(to: BeatSyncPaths.root.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }

    static func markdown(records: [BeatSyncRunRecord], groups: [BeatSyncGroup], verdict: BeatSyncVerdict) -> String {
        func f(_ value: Double) -> String { String(format: "%.2f", value) }
        var lines = [
            "# Beat sync spike",
            "",
            "Verdict: \(verdict.rawValue) (limit \(f(limitMs)) ms start error and drift)",
            "Device: \(records.first?.device ?? "-") at \(Int(records.first?.sampleRate ?? 0)) Hz. Route: muted process tap on the test's own output.",
            "",
            "| clock | overlap s | algorithm | rate | runs (failed) | start mean | start sd | start min..max | worst start | worst drift | jitter mean | worst jitter | worst start after calibration | latency vs baseline |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
        ]
        for g in groups {
            lines.append(
                "| \(g.clock) | \(Int(g.overlapSeconds)) | \(g.algorithm) | \(f(g.rate)) | \(g.runs) (\(g.failed)) | \(f(g.startMeanMs)) | "
                    + "\(f(g.startStdevMs)) | \(f(g.startMinMs))..\(f(g.startMaxMs)) | \(f(g.worstStartMs)) | \(f(g.worstDriftMs)) | "
                    + "\(f(g.meanJitterMs)) | \(f(g.worstJitterMs)) | \(f(g.worstCalibratedStartMs)) | \(g.latencyVsBaselineMs.map(f) ?? "-") |"
            )
        }
        lines.append("")
        lines.append("All times in ms. Start error is B's first beat against A's beat grid; drift is the largest minus the smallest error over the overlap.")
        return lines.joined(separator: "\n") + "\n"
    }
}
