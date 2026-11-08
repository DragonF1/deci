// DeciTests/Music/Vocals/GridGateDiagnosisTests.swift
// Tier 3c diagnosis: why does MusicBeatPlanner refuse real songs with gridLowConf? Opt-in, same gate as the vocal eval:
//   TEST_RUNNER_DECI_VOCAL_EVAL=1 run-tests.sh grid-diag GridGateDiagnosisTests
// Prints, per real song, the grid exactly as the coordinator stores it (analysis.beatGrid, decoded through usableGrid, which
// is what MusicService passes as side.grid) and which clause of `MusicBeatPlanner.trusted` fails. Output:
// /Volumes/Storage/_test/deci-3c/grid-diagnosis.txt.

import Foundation
import AVFoundation
import Testing
@testable import Deci

private nonisolated let gridDiagEval = ProcessInfo.processInfo.environment["DECI_VOCAL_EVAL"] == "1"

@Suite("Grid gate diagnosis", .serialized, .enabled(if: gridDiagEval))
struct GridGateDiagnosisTests {
    private nonisolated static func f(_ x: Double, _ d: Int = 4) -> String { String(format: "%.\(d)f", x) }

    /// The production decode: AVAssetReader at the native rate into MusicBeatDecimator.
    private nonisolated static func decode(_ url: URL) async throws -> (samples: [Float], rate: Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        let rate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        #expect(reader.startReading())
        let decimator = MusicBeatDecimator(inputRate: rate)
        var scratch = [Float]()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let frames = CMBlockBufferGetDataLength(block) / (MemoryLayout<Float>.size * channels)
            guard frames > 0 else { continue }
            if scratch.count < frames * channels { scratch = [Float](repeating: 0, count: frames * channels) }
            _ = scratch.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * channels * 4, destination: $0.baseAddress!)
            }
            scratch.withUnsafeBufferPointer { decimator.consume(interleaved: $0.baseAddress!, frames: frames, channels: channels) }
        }
        return decimator.finish()
    }

    /// Why a grid's confidence is what it is: per beat of the stored grid, is there a bass onset near it, and how far off.
    private nonisolated static func beatDetail(url: URL, grid g: MusicBeatGrid) async throws -> String {
        let (audio, rate) = try await decode(url)
        let band = MusicBeatFinder.bassBand(audio, rate: rate)
        let first = Int(ceil((g.spanStartSec - g.anchorSec) / g.periodSec)), last = Int(floor((g.spanEndSec - g.anchorSec) / g.periodSec))
        var residuals: [Double] = [], strengths: [Float] = []
        var total = 0
        for k in first...last {
            total += 1
            let predicted = g.anchorSec + Double(k) * g.periodSec
            if let hit = MusicBeatFinder.onset(near: predicted, in: band, window: MusicBeatFinder.refineWindowSec) {
                residuals.append(hit.time - predicted)
                strengths.append(hit.strength)
            }
        }
        // Wide look: the strongest bass rise within half a period of every grid beat, as an offset from the grid. Where
        // do they cluster, and how tightly? (A cluster away from 0 means the grid phase is off; no cluster means the
        // song has no beat-aligned bass.)
        var wide: [Double] = []
        let halfPeriod = g.periodSec / 2
        for k in first...last {
            let predicted = g.anchorSec + Double(k) * g.periodSec
            let centre = Int((predicted * band.rate).rounded()), reach = Int((halfPeriod * band.rate).rounded())
            let lo = max(0, centre - reach), hi = min(band.flux.count - 1, centre + reach)
            guard lo < hi else { continue }
            var peak = lo
            for i in lo...hi where band.flux[i] > band.flux[peak] { peak = i }
            wide.append(Double(peak - centre) / band.rate)
        }
        var bins: [Int: Int] = [:]
        for w in wide { bins[Int((w / 0.01).rounded(.down)), default: 0] += 1 }
        let top = bins.max { $0.value < $1.value }
        let modeMs = Double(top?.key ?? 0) * 10 + 5
        let modeShare = Double(top?.value ?? 0) / Double(max(wide.count, 1))
        let wideNote = " widePeakMode=\(f(modeMs, 0))ms share(10ms bin)=\(f(modeShare, 3)) (uniform would be \(f(0.01 / g.periodSec, 3)))"
        let floorStrength = Float(MusicBeatFinder.onsetFloorFraction) * (strengths.sorted()[strengths.count / 2])
        let strong = zip(residuals, strengths).filter { $0.1 >= floorStrength }.map(\.0)
        func within(_ ms: Double) -> String { f(Double(strong.filter { abs($0) <= ms / 1000 }.count) / Double(max(total, 1)), 3) }
        let medianRes = strong.sorted()[strong.count / 2] * 1000
        let spreadMs = 1.4826 * strong.map { abs($0 - strong.sorted()[strong.count / 2]) }.sorted()[strong.count / 2] * 1000
        return "beats=\(total) onsetFound=\(f(Double(residuals.count) / Double(max(total, 1)), 3)) aboveFloor=\(f(Double(strong.count) / Double(max(total, 1)), 3))"
            + " hit<=10ms=\(within(10)) <=20ms=\(within(20)) <=30ms=\(within(30)) <=60ms=\(within(60))"
            + wideNote + " medianResidual=\(f(medianRes, 1))ms robustSpread=\(f(spreadMs, 1))ms"
    }

    @Test("per song grid statistics against the planner's trust gates")
    func diagnose() async throws {
        let root = "/Volumes/Storage/_test/deci-3c/songs"
        let ids = try String(contentsOfFile: root + "/ids.txt", encoding: .utf8).split(separator: "\n").map(String.init)
        var report = "GRID GATE DIAGNOSIS (production analyzer, grid as stored then decoded)\n"
        report += "gates: period \(MusicBeatGrid.periodRange) | |anchor|,|span| <= \(MusicBeatPlanner.maxGridSeconds) | confidence >= \(MusicBeatPlanner.minConfidence)"
            + " | spread <= \(MusicBeatPlanner.maxIntervalSpread) | |drift| <= \(MusicBeatPlanner.maxDriftSec)\n\n"
        var failCounts: [String: Int] = [:]
        var rows: [(id: String, grid: MusicBeatGrid)] = []
        for id in ids {
            guard let file = (try? FileManager.default.contentsOfDirectory(atPath: root))?
                .first(where: { $0.hasPrefix(id + ".") && !$0.hasSuffix(".part") }) else { continue }
            let result = try await MusicFileAnalyzer.analyze(file: URL(fileURLWithPath: root + "/" + file), exactDuration: nil)
            let analysis = MusicAnalysis(videoId: id, result: result, source: .playbackCache)
            guard let g = analysis.usableGrid else {
                report += "\(id): NO GRID (finder refused or stored grid undecodable); measurement grid nil=\(result.measurement.beatGrid == nil)\n"
                failCounts["noGrid", default: 0] += 1
                continue
            }
            rows.append((id, g))
            let detail = try await Self.beatDetail(url: URL(fileURLWithPath: root + "/" + file), grid: g)
            var fails: [String] = []
            if !MusicBeatGrid.periodRange.contains(g.periodSec) { fails.append("period") }
            if ![g.anchorSec, g.spanStartSec, g.spanEndSec].allSatisfy({ $0.isFinite && abs($0) <= MusicBeatPlanner.maxGridSeconds }) { fails.append("anchorSpan") }
            if g.beatConfidence < MusicBeatPlanner.minConfidence { fails.append("confidence") }
            if g.intervalSpread > MusicBeatPlanner.maxIntervalSpread { fails.append("spread") }
            if abs(g.driftSec) > MusicBeatPlanner.maxDriftSec { fails.append("drift") }
            for x in fails { failCounts[x, default: 0] += 1 }
            if fails.isEmpty { failCounts["PASS", default: 0] += 1 }
            report += "\(id): bpm=\(Self.f(g.bpm, 2)) period=\(Self.f(g.periodSec)) conf=\(Self.f(Double(g.beatConfidence), 3))"
                + " spread=\(Self.f(Double(g.intervalSpread), 4)) drift=\(Self.f(Double(g.driftSec) * 1000, 3))ms/beat"
                + " downbeat=\(g.downbeatPhase.map(String.init) ?? "-")(\(Self.f(Double(g.downbeatConfidence), 2)))"
                + " span=\(Self.f(g.spanStartSec, 2))...\(Self.f(g.spanEndSec, 2)) of \(Self.f(result.measurement.duration, 2))"
                + " FAILS=\(fails.isEmpty ? "none" : fails.joined(separator: ","))\n    \(detail)\n"
        }
        report += "\nfailing clause counts over \(ids.count) songs: \(failCounts.sorted { $0.key < $1.key })\n"
        func range(_ name: String, _ v: [Double]) -> String {
            guard let lo = v.min(), let hi = v.max() else { return "\(name): -" }
            let s = v.sorted()
            return "\(name): min \(Self.f(lo, 4)) median \(Self.f(s[s.count / 2], 4)) max \(Self.f(hi, 4))"
        }
        report += range("confidence", rows.map { Double($0.grid.beatConfidence) }) + "\n"
        report += range("spread", rows.map { Double($0.grid.intervalSpread) }) + "\n"
        report += range("|drift| s/beat", rows.map { abs(Double($0.grid.driftSec)) }) + "\n"
        for gate in [0.5, 0.4, 0.3, 0.2] {
            report += "songs with confidence >= \(gate): \(rows.filter { Double($0.grid.beatConfidence) >= gate }.count) of \(rows.count)\n"
        }
        try report.write(toFile: "/Volumes/Storage/_test/deci-3c/grid-diagnosis.txt", atomically: true, encoding: .utf8)
    }
}
