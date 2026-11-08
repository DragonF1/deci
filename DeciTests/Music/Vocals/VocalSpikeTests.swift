// DeciTests/Music/Vocals/VocalSpikeTests.swift
// Tier 3c P1: the vocal detection spike. Is Apple SoundAnalysis `.version1` "singing" good enough to drive a vocal guard
// (two singers never overlap in a transition)? Opt-in, reads real songs from the songs folder:
//   TEST_RUNNER_DECI_VOCAL_EVAL=1 run-tests.sh p1-spike VocalSpikeTests
// Optional: TEST_RUNNER_DECI_VOCAL_SONGS (default /Volumes/Storage/_test/deci-3c/songs, with an ids.txt),
// TEST_RUNNER_DECI_VOCAL_OVERLAPS (default "0.5,0.75": the second is the one allowed retune).
// Silver truth is the synced lyric cache. Output: /Volumes/Storage/_test/deci-3c/p1-results.txt and out/labels.txt.

import Foundation
import AVFoundation
import Accelerate
import CryptoKit
import SoundAnalysis
import Testing
@testable import Deci

private nonisolated let vocalEval = ProcessInfo.processInfo.environment["DECI_VOCAL_EVAL"] == "1"

private nonisolated struct VWindow: Sendable {
    var centre: Double
    var scores: [String: Float]
}

private nonisolated final class VObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var found: [VWindow] = []
    var windows: [VWindow] { lock.lock(); defer { lock.unlock() }; return found.sorted { $0.centre < $1.centre } }
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        var scores: [String: Float] = [:]
        for item in result.classifications { scores[item.identifier] = Float(item.confidence) }
        let centre = result.timeRange.start.seconds + result.timeRange.duration.seconds / 2
        lock.lock(); found.append(VWindow(centre: centre, scores: scores)); lock.unlock()
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {}
    func requestDidComplete(_ request: SNRequest) {}
}

private nonisolated struct VSong: Sendable {
    var id: String
    var samples: [Float]
    var rate: Double
    var duration: Double
    var truth: [Bool]
    var scored: [Bool]
    var frameCount: Int
    var isRap: Bool
    var isTune: Bool
}

private nonisolated enum VocalSpike {
    static let frame = 0.5
    static let tuneIds: Set<String> = ["B3tXcWTpgvQ", "MKQzx3vODio", "NjR7JpMqiAc", "RCaoGyIXI6Y", "jLmRqtKBchc", "wXEwMBdTaow"]
    static let rapIds: Set<String> = ["Txnqzr_DZYg", "jLmRqtKBchc"]

    // MARK: decode (the production path: reader at native rate into MusicBeatDecimator)

    static func decode(_ url: URL) async throws -> (samples: [Float], rate: Double) {
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

    // MARK: classifiers

    static func makeRequest(overlap: Double) throws -> SNClassifySoundRequest {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.overlapFactor = overlap
        return request
    }

    static func classifyStream(_ samples: [Float], rate: Double, overlap: Double) throws -> [VWindow] {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = VObserver()
        try analyzer.add(try makeRequest(overlap: overlap), withObserver: observer)
        var position = 0
        while position < samples.count {
            let count = min(4096, samples.count - position)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + position, count: count)
            }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
            position += count
        }
        analyzer.completeAnalysis()
        return observer.windows
    }

    static func classifyFile(_ url: URL, overlap: Double) throws -> [VWindow] {
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let observer = VObserver()
        try analyzer.add(try makeRequest(overlap: overlap), withObserver: observer)
        analyzer.analyze()
        return observer.windows
    }

    // MARK: frames and metrics

    /// Score per 0.5 s frame: the window whose centre is nearest the frame centre.
    static func frames(_ windows: [VWindow], count: Int, score: (VWindow) -> Float) -> [Float] {
        guard !windows.isEmpty else { return [Float](repeating: 0, count: count) }
        var out = [Float](repeating: 0, count: count)
        var j = 0
        for i in 0..<count {
            let t = (Double(i) + 0.5) * frame
            while j + 1 < windows.count, abs(windows[j + 1].centre - t) <= abs(windows[j].centre - t) { j += 1 }
            out[i] = score(windows[j])
        }
        return out
    }

    static func truth(lyricsPath: String, count: Int) -> (vocal: [Bool], scored: [Bool])? {
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
        var vocal = [Bool](repeating: false, count: count)
        var scored = [Bool](repeating: true, count: count)
        for i in 0..<count {
            let t = (Double(i) + 0.5) * frame
            for (s, e) in spans {
                if t >= s && t < e { vocal[i] = true }
                if abs(t - s) < frame || abs(t - e) < frame { scored[i] = false }
            }
        }
        return (vocal, scored)
    }

    struct Score { var tp = 0, fp = 0, fn = 0, tn = 0
        var precision: Double { tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp) }
        var recall: Double { tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn) }
        var f1: Double { let p = precision, r = recall; return p + r == 0 ? 0 : 2 * p * r / (p + r) }
    }

    static func score(_ values: [Float], threshold: Float, song: VSong) -> Score {
        var s = Score()
        for i in 0..<min(values.count, song.frameCount) where song.scored[i] {
            let predicted = values[i] >= threshold
            switch (predicted, song.truth[i]) {
            case (true, true): s.tp += 1
            case (true, false): s.fp += 1
            case (false, true): s.fn += 1
            default: s.tn += 1
            }
        }
        return s
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Close gaps shorter than 1 s, then drop blips shorter than 1 s (frames of 0.5 s: runs of 1).
    static func clean(_ bools: [Bool]) -> [Bool] {
        func fix(_ input: [Bool], value: Bool) -> [Bool] {
            var out = input
            var i = 0
            while i < out.count {
                var j = i
                while j < out.count, out[j] == value { j += 1 }
                if j > i, Double(j - i) * frame < 1.0, i > 0, j < out.count { for k in i..<j { out[k] = !value } }
                i = max(j, i + 1)
            }
            return out
        }
        return fix(fix(bools, value: false), value: true)
    }

    // MARK: DSP baseline (c): mid-band energy ratio 200 Hz to 4 kHz, weighted by spectral flux

    static func dspScores(_ samples: [Float], rate: Double, count: Int) -> [Float] {
        let log2n = 13, n = 1 << log2n
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = rate / Double(n)
        let lo = Int(200 / binHz), hi = Int(4000 / binHz), floorBin = max(1, Int(20 / binHz))
        var ratios = [Float](repeating: 0, count: count)
        var fluxes = [Float](repeating: 0, count: count)
        var previous = [Float](repeating: 0, count: hi - lo)
        for i in 0..<count {
            let centre = Int((Double(i) + 0.5) * frame * rate)
            let start = centre - n / 2
            var block = [Float](repeating: 0, count: n)
            for k in 0..<n where start + k >= 0 && start + k < samples.count { block[k] = samples[start + k] * window[k] }
            var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
            var mags = [Float](repeating: 0, count: n / 2)
            real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                block.withUnsafeBufferPointer { b in
                    b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            } }
            var total: Float = 0, mid: Float = 0
            for k in floorBin..<(n / 2) { total += mags[k]; if k >= lo && k < hi { mid += mags[k] } }
            ratios[i] = total > 1e-9 ? mid / total : 0
            var cur = [Float](repeating: 0, count: hi - lo)
            var flux: Float = 0, norm: Float = 0
            for k in lo..<hi { cur[k - lo] = mags[k].squareRoot(); norm += cur[k - lo]; flux += max(0, cur[k - lo] - previous[k - lo]) }
            fluxes[i] = norm > 1e-9 ? flux / norm : 0
            previous = cur
        }
        let medFlux = max(1e-6, Float(median(fluxes.map(Double.init))))
        return (0..<count).map { ratios[$0] * min(1, 0.6 + 0.4 * fluxes[$0] / (2 * medFlux)) }
    }

    static func peakRSS() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)
    }
}

@MainActor
@Suite("Vocal spike", .serialized, .enabled(if: vocalEval))
struct VocalSpikeTests {
    @Test("tier 3c P1: SoundAnalysis singing vs lyric silver truth on real songs")
    func spike() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = env["DECI_VOCAL_SONGS"] ?? "/Volumes/Storage/_test/deci-3c/songs"
        let outDir = "/Volumes/Storage/_test/deci-3c/out"
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let overlaps = (env["DECI_VOCAL_OVERLAPS"] ?? "0.5,0.75").split(separator: ",").compactMap { Double($0) }
        let ids = try String(contentsOfFile: root + "/ids.txt", encoding: .utf8).split(separator: "\n").map(String.init)
        let lyricsDir = NSString(string: "~/Library/Caches/com.abraham.Deci/Music/Lyrics").expandingTildeInPath

        // Songs: decode once through the production decimator path.
        var songs: [VSong] = []
        var urls: [String: URL] = [:]
        for id in ids {
            guard let file = (try? FileManager.default.contentsOfDirectory(atPath: root))?.first(where: { $0.hasPrefix(id + ".") && !$0.hasSuffix(".part") }) else { continue }
            let url = URL(fileURLWithPath: root + "/" + file)
            let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            let decoded = try await VocalSpike.decode(url)
            let duration = Double(decoded.samples.count) / decoded.rate
            let count = Int((duration / VocalSpike.frame).rounded(.up))
            guard let truth = VocalSpike.truth(lyricsPath: lyricsDir + "/" + hash + ".json", count: count) else { continue }
            songs.append(VSong(id: id, samples: decoded.samples, rate: decoded.rate, duration: duration, truth: truth.vocal,
                               scored: truth.scored, frameCount: count, isRap: VocalSpike.rapIds.contains(id),
                               isTune: VocalSpike.tuneIds.contains(id)))
            urls[id] = url
        }
        var report = "VOCAL SPIKE P1: \(songs.count) songs (\(songs.filter(\.isTune).count) tune, \(songs.filter { !$0.isTune }.count) holdout)\n"
        report += "songs: " + songs.map { $0.id + ($0.isRap ? "(rap)" : "") + ($0.isTune ? "[tune]" : "[hold]") }.joined(separator: " ") + "\n"
        let baselineRSS = VocalSpike.peakRSS()

        for overlap in overlaps {
            report += "\n===== overlapFactor \(overlap) =====\n"
            // Classifier facts.
            let probe = try VocalSpike.makeRequest(overlap: overlap)
            let labels = probe.knownClassifications.sorted()
            try labels.joined(separator: "\n").write(toFile: outDir + "/labels.txt", atomically: true, encoding: .utf8)
            let rapLabels = labels.filter { $0.lowercased().contains("rapping") || $0.lowercased() == "rap" }
            report += "labels: \(labels.count); has singing=\(labels.contains("singing")) choir=\(labels.contains("choir")) speech=\(labels.contains("speech")) rap-like=\(rapLabels)\n"
            report += "windowDuration=\(probe.windowDuration.seconds)s overlapFactor=\(probe.overlapFactor) constraint=\(probe.windowDurationConstraint)\n"

            // Classify every song through the stream path (utility QoS, timed twice), and the file path once.
            var streamWins: [String: [VWindow]] = [:]
            var fileWins: [String: [VWindow]] = [:]
            var timings: [(id: String, cold: Double, warm: Double, per4min: Double)] = []
            let beforeClassify = VocalSpike.peakRSS()
            for song in songs {
                let samples = song.samples, rate = song.rate
                var times: [Double] = []
                var wins: [VWindow] = []
                for _ in 0..<2 {
                    let result = try await Task(priority: .utility) { () throws -> ([VWindow], Double) in
                        let start = ContinuousClock.now
                        let w = try VocalSpike.classifyStream(samples, rate: rate, overlap: overlap)
                        let d = start.duration(to: .now)
                        return (w, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
                    }.value
                    wins = result.0
                    times.append(result.1)
                }
                streamWins[song.id] = wins
                timings.append((song.id, times[0], times[1], times[1] * 240 / song.duration))
                fileWins[song.id] = try VocalSpike.classifyFile(urls[song.id]!, overlap: overlap)
            }
            let rssGrowthMB = Double(VocalSpike.peakRSS() - beforeClassify) / 1_048_576
            let decodeBaselineMB = Double(beforeClassify - baselineRSS) / 1_048_576
            _ = decodeBaselineMB

            // Variants
            typealias Variant = (name: String, score: (VWindow) -> Float)
            let variants: [Variant] = [
                ("singing", { $0.scores["singing"] ?? 0 }),
                ("max(singing,choir,rap)", { w in ([ "singing", "choir" ] + rapLabels).map { w.scores[$0] ?? 0 }.max() ?? 0 }),
                ("singing-0.5*speech", { max(0, ($0.scores["singing"] ?? 0) - 0.5 * ($0.scores["speech"] ?? 0)) }),
            ]
            let thresholds: [Float] = stride(from: 0.02, through: 0.8, by: 0.02).map { Float($0) }
            let tune = songs.filter(\.isTune), hold = songs.filter { !$0.isTune }
            var best: (variant: Int, threshold: Float, median: Double) = (0, 0.5, -1)
            report += "\nTUNE (median F1 over \(tune.count) tune songs)\n"
            for (vi, variant) in variants.enumerated() {
                var line = "  \(variant.name):"
                for th in thresholds {
                    let m = VocalSpike.median(tune.map {
                        VocalSpike.score(VocalSpike.frames(streamWins[$0.id]!, count: $0.frameCount, score: variant.score), threshold: th, song: $0).f1
                    })
                    line += String(format: " %.2f@%.2f", m, th)
                    if m > best.median { best = (vi, th, m) }
                }
                report += line + "\n"
            }
            let chosen = variants[best.variant]
            report += String(format: "chosen: %@ threshold %.2f (tune median F1 %.3f)\n", chosen.name, best.threshold, best.median)

            // Baseline (c) tuned the same way.
            var dsp: [String: [Float]] = [:]
            for song in songs { dsp[song.id] = VocalSpike.dspScores(song.samples, rate: song.rate, count: song.frameCount) }
            var bestDsp: (threshold: Float, median: Double) = (0.5, -1)
            for th in stride(from: 0.02, through: 0.98, by: 0.02).map({ Float($0) }) {
                let m = VocalSpike.median(tune.map { VocalSpike.score(dsp[$0.id]!, threshold: th, song: $0).f1 })
                if m > bestDsp.median { bestDsp = (th, m) }
            }
            report += String(format: "baseline (c) DSP: threshold %.2f (tune median F1 %.3f)\n", bestDsp.threshold, bestDsp.median)

            // Holdout, scored once.
            report += "\nHOLDOUT per song (frame F1 / precision / recall / baseline F1 / file-vs-stream agreement / stream s per 4 min)\n"
            var f1s: [Double] = [], f1sNonRap: [Double] = [], dspNonRap: [Double] = []
            var pooled = VocalSpike.Score()
            var agreements: [Double] = []
            func agreement(_ song: VSong) -> Double {
                let a = VocalSpike.frames(streamWins[song.id]!, count: song.frameCount, score: chosen.score)
                let b = VocalSpike.frames(fileWins[song.id]!, count: song.frameCount, score: chosen.score)
                var same = 0
                for i in 0..<song.frameCount where (a[i] >= best.threshold) == (b[i] >= best.threshold) { same += 1 }
                return Double(same) / Double(max(1, song.frameCount))
            }
            for song in songs {
                let values = VocalSpike.frames(streamWins[song.id]!, count: song.frameCount, score: chosen.score)
                let s = VocalSpike.score(values, threshold: best.threshold, song: song)
                let d = VocalSpike.score(dsp[song.id]!, threshold: bestDsp.threshold, song: song)
                let ag = agreement(song)
                agreements.append(ag)
                let t = timings.first { $0.id == song.id }!
                let tag = song.isTune ? "tune" : "hold"
                report += String(format: "  %@ %@%@ F1 %.3f P %.3f R %.3f | dsp F1 %.3f | agree %.4f | %.2fs (cold %.2f warm %.2f)\n",
                                 tag, song.id, song.isRap ? " (rap)" : "", s.f1, s.precision, s.recall, d.f1, ag, t.per4min, t.cold, t.warm)
                if !song.isTune {
                    f1s.append(s.f1)
                    if !song.isRap { f1sNonRap.append(s.f1); dspNonRap.append(d.f1) }
                    pooled.tp += s.tp; pooled.fn += s.fn; pooled.fp += s.fp; pooled.tn += s.tn
                }
            }
            let medianAll = VocalSpike.median(f1s), medianNonRap = VocalSpike.median(f1sNonRap)
            let minNonRap = f1sNonRap.min() ?? 0
            let dspMedian = VocalSpike.median(dspNonRap)

            // Pair test: all ordered pairs, 16 bars at 128 bpm (30 s), last 8-bar phrase boundary of A against the start of B.
            func pairResult(_ pool: [VSong]) -> (agree: Double, precision: Double, recall: Double, n: Int, positives: Int) {
                var tp = 0, fp = 0, fn = 0, tn = 0
                for a in pool { for b in pool where a.id != b.id {
                    guard a.duration >= 30 + 15 else { continue }
                    let mixOutFrame = Int((((a.duration - 30) / 15).rounded(.down) * 15) / VocalSpike.frame)
                    let detA = VocalSpike.clean(VocalSpike.frames(streamWins[a.id]!, count: a.frameCount, score: chosen.score).map { $0 >= best.threshold })
                    let detB = VocalSpike.clean(VocalSpike.frames(streamWins[b.id]!, count: b.frameCount, score: chosen.score).map { $0 >= best.threshold })
                    var truthSec = 0.0, detSec = 0.0
                    for s in 0..<60 {
                        let x = (Double(s) + 0.5) / 60
                        guard cos(Double.pi / 2 * x) >= 0.25, sin(Double.pi / 2 * x) >= 0.25 else { continue }
                        let ia = mixOutFrame + s
                        guard ia < a.frameCount, s < b.frameCount else { continue }
                        if a.truth[ia] && b.truth[s] { truthSec += VocalSpike.frame }
                        if detA[ia] && detB[s] { detSec += VocalSpike.frame }
                    }
                    switch (detSec > 2, truthSec > 2) {
                    case (true, true): tp += 1
                    case (true, false): fp += 1
                    case (false, true): fn += 1
                    default: tn += 1
                    }
                } }
                let n = tp + fp + fn + tn
                return (Double(tp + tn) / Double(max(1, n)), tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp),
                        tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn), n, tp + fn)
            }
            let pairAll = pairResult(songs), pairHold = pairResult(hold)

            let runtimeWorst = timings.map(\.per4min).max() ?? 0
            let coldFirst = (timings.first?.cold ?? 0) * 240 / (songs.first?.duration ?? 240)
            let meanAgree = agreements.reduce(0, +) / Double(max(1, agreements.count))
            let minAgree = agreements.min() ?? 0
            func verdict(_ ok: Bool) -> String { ok ? "PASS" : "FAIL" }
            report += "\nNUMBERS\n"
            report += String(format: "  holdout median F1 all %.3f, excluding rap %.3f; min (excl rap) %.3f; pooled recall %.3f precision %.3f\n",
                             medianAll, medianNonRap, minNonRap, pooled.recall, pooled.precision)
            report += String(format: "  pairs all 12: agree %.3f precision %.3f recall %.3f (n=%d, positives=%d)\n", pairAll.agree, pairAll.precision, pairAll.recall, pairAll.n, pairAll.positives)
            report += String(format: "  pairs holdout only: agree %.3f precision %.3f recall %.3f (n=%d, positives=%d)\n", pairHold.agree, pairHold.precision, pairHold.recall, pairHold.n, pairHold.positives)
            report += String(format: "  stream vs file agreement: mean %.4f min %.4f\n", meanAgree, minAgree)
            report += String(format: "  runtime per 4 min at utility QoS: worst warm %.2f s, cold first song %.2f s; peak RSS growth during classification %.1f MB\n", runtimeWorst, coldFirst, rssGrowthMB)
            report += String(format: "  baseline (c) holdout median F1 excl rap %.3f; delta %.3f\n", dspMedian, medianNonRap - dspMedian)
            report += "CRITERIA (overlap \(overlap))\n"
            let c1 = medianNonRap >= 0.80, c2 = minNonRap >= 0.60, c3 = pooled.recall >= 0.85
            let c4 = pairAll.agree >= 0.85 && pairAll.precision >= 0.80 && pairAll.recall >= 0.80
            let c5 = meanAgree >= 0.97
            let c6 = max(runtimeWorst, coldFirst) <= 4 && rssGrowthMB < 60
            let c7 = medianNonRap - dspMedian >= 0.10
            report += "  \(verdict(c1)) holdout median F1 >= 0.80\n  \(verdict(c2)) no holdout song below 0.60 (excl rap)\n  \(verdict(c3)) pooled recall >= 0.85\n"
            report += "  \(verdict(c4)) pair collision > 2 s: agree >= 0.85, precision >= 0.80, recall >= 0.80\n  \(verdict(c5)) stream vs file >= 0.97\n"
            report += "  \(verdict(c6)) runtime <= 4 s per 4 min and RSS < 60 MB\n  \(verdict(c7)) beats baseline (c) by >= 0.10 median F1\n"
            report += "  OVERALL \(verdict(c1 && c2 && c3 && c4 && c5 && c6 && c7))\n"
        }
        try report.write(toFile: "/Volumes/Storage/_test/deci-3c/p1-results.txt", atomically: true, encoding: .utf8)
        print(report)
        #expect(!songs.isEmpty)
    }
}
