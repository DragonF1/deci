// DeciTests/Music/LiveChecks/MixLoopSpikeLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): the spike behind Tier 4b P2b LOOP EXTEND. Can an AVMutableComposition that repeats
// 8 bars of a song's intro play gaplessly, sample accurately and through the DSP tap? Measured offline (decode the
// composition and the original, compare at every seam) and played (an AVPlayer with the real tap on the composition
// track, the render recorder, the dropout scan of check 10). Numbers go to loop-spike-report.txt.

import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import Deci

nonisolated enum LoopSpike {
    static let rate = 48_000.0

    /// loopStart = first downbeat, loopEnd = loopStart + `bars` bars, both on the sample grid.
    struct Range { var start: Double; var end: Double; var length: Double { end - start } }

    static func snap(_ t: Double) -> Double { (t * rate).rounded() / rate }

    static func composition(asset: AVURLAsset, loop: Range, repeats: Int) async throws -> (AVMutableComposition, Double) {
        let duration = try await asset.load(.duration).seconds
        guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadUnknown) }
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileReadUnknown)
        }
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 48_000) }
        var at = 0.0
        try track.insertTimeRange(CMTimeRange(start: .zero, end: t(loop.end)), of: source, at: t(at))
        at = loop.end
        for _ in 0..<repeats {
            try track.insertTimeRange(CMTimeRange(start: t(loop.start), end: t(loop.end)), of: source, at: t(at))
            at += loop.length
        }
        try track.insertTimeRange(CMTimeRange(start: t(loop.end), end: t(duration)), of: source, at: t(at))
        return (comp, duration)
    }

    /// Mono float samples at 48 kHz, from `start` for `seconds` (the whole item when nil).
    static func decode(_ asset: AVAsset, from start: Double, seconds: Double?) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadUnknown) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ]
        let output: AVAssetReaderOutput
        if asset is AVComposition {
            output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        } else {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        }
        reader.add(output)
        if let seconds {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), duration: CMTime(seconds: seconds, preferredTimescale: 48_000))
        }
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var out: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            out.append(contentsOf: chunk)
        }
        return out
    }

    /// Lag (samples, positive = `a` is late against `b`) of the best normalised match within +-`maxLag`.
    static func bestLag(_ a: [Float], _ b: [Float], maxLag: Int) -> (lag: Int, corr: Double) {
        let n = min(a.count, b.count) - 2 * maxLag
        guard n > 100 else { return (0, 0) }
        var best = (lag: 0, corr: -2.0)
        for lag in -maxLag...maxLag {
            var ab = 0.0, aa = 0.0, bb = 0.0
            for i in 0..<n {
                let x = Double(a[i + maxLag + lag]), y = Double(b[i + maxLag])
                ab += x * y; aa += x * x; bb += y * y
            }
            let c = ab / max(1e-12, (aa * bb).squareRoot())
            if c > best.corr { best = (lag, c) }
        }
        return best
    }

    static func maxStep(_ x: ArraySlice<Float>) -> Float {
        var worst: Float = 0
        var previous: Float?
        for v in x { if let p = previous { worst = max(worst, abs(v - p)) }; previous = v }
        return worst
    }
}

@MainActor
@Suite("MixLoopSpikeLiveCheckTests", .serialized, .enabled(if: liveGate))
struct MixLoopSpikeLiveCheckTests {
    static let report = LiveDirs.root.appendingPathComponent("loop-spike-report.txt")

    static func note(_ line: String) {
        print("LIVE-LOOP \(line)")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: report) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? text.write(to: report, atomically: true, encoding: .utf8)
        }
    }

    /// Songs with a trusted grid and a downbeat, long enough that 8 bars plus 8 bars of room exist.
    static func songs(_ world: LiveWorld, bars: Int) -> [(song: LiveSong, loop: LoopSpike.Range, grid: MusicBeatGrid)] {
        var out: [(LiveSong, LoopSpike.Range, MusicBeatGrid)] = []
        for song in world.songs {
            guard let row = world.rows[song.videoId], let grid = row.usableGrid, MusicBeatPlanner.trusted(grid),
                  let first = grid.barTime(0) else { continue }
            let start = LoopSpike.snap(first)
            let end = LoopSpike.snap(first + Double(bars) * 4 * grid.periodSec)
            guard end < min(grid.spanEndSec, song.duration - 15), start < 40 else { continue }
            out.append((song, LoopSpike.Range(start: start, end: end), grid))
        }
        return out
    }

    @Test("a composition that repeats 8 bars is sample accurate at every seam, plays without a dropout and renders through the tap")
    func spike() async throws {
        let world = try await LiveWorld.shared()
        guard let audio = await LiveAudio.shared(world: world) else { Issue.record("capture not proven"); return }
        defer { LiveAudio.end() }
        try? FileManager.default.createDirectory(at: LiveDirs.root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: Self.report)
        let picks = Array(Self.songs(world, bars: 8).prefix(3))
        Self.note("== loop spike \(Date()); songs with a trusted grid and 8 bars of room: \(picks.count)")
        #expect(picks.count == 3, "need 3 songs")
        let repeats = 2
        for pick in picks {
            let song = pick.song, loop = pick.loop
            let asset = AVURLAsset(url: song.url)
            let (comp, duration) = try await LoopSpike.composition(asset: asset, loop: loop, repeats: repeats)
            let extra = Double(repeats) * loop.length
            Self.note("-- \(song.videoId) (\(song.index)) bpm \(String(format: "%.1f", pick.grid.bpm)), loop \(liveF(loop.start)) to \(liveF(loop.end)) s (\(liveF(loop.length)) s), composition \(liveF(comp.duration.seconds)) s = song \(liveF(duration)) + \(liveF(extra))")
            #expect(abs(comp.duration.seconds - (duration + extra)) < 0.01)

            // Offline: decode the composition and the original around the loop.
            let window = 0.5
            let from = loop.end - window
            let span = 2 * loop.length + 2 * window + 0.3
            let compSamples = try await LoopSpike.decode(comp, from: from, seconds: span)
            let orig = try await LoopSpike.decode(asset, from: loop.start - 1, seconds: loop.length + 3)
            let origOffset = loop.start - 1
            func original(_ t0: Double, _ seconds: Double) -> [Float] {
                let i = Int(((t0 - origOffset) * LoopSpike.rate).rounded())
                let n = Int(seconds * LoopSpike.rate)
                guard i >= 0, i + n <= orig.count else { return [] }
                return Array(orig[i..<(i + n)])
            }
            let rate = LoopSpike.rate
            let normal = LoopSpike.maxStep(orig[Int(1 * rate)..<min(orig.count, Int((1 + loop.length) * rate))])
            var worstLagMs = 0.0
            var worstJump: Float = 0
            // Seams at comp times loop.end, loop.end + L, loop.end + 2L; the content after each is source loopStart (twice) then loopEnd.
            for (k, seam) in [loop.end, loop.end + loop.length, loop.end + 2 * loop.length].enumerated() {
                let afterSource = k < repeats ? loop.start : loop.end
                let beforeSource = loop.end
                let i = Int(((seam - from) * rate).rounded())
                guard i - Int(window * rate) >= 0, i + Int(window * rate) <= compSamples.count else {
                    Self.note("   seam \(k + 1): outside the decoded window"); continue
                }
                let before = Array(compSamples[(i - Int(window * rate))..<i])
                let after = Array(compSamples[i..<(i + Int(window * rate))])
                let wantBefore = original(beforeSource - window, window)
                let wantAfter = original(afterSource, window)
                guard !wantBefore.isEmpty, !wantAfter.isEmpty else { Self.note("   seam \(k + 1): no reference"); continue }
                // The match needs the lag search room: compare the middle of each half.
                let maxLag = Int(0.02 * rate)
                func trimmed(_ x: [Float]) -> [Float] { Array(x[maxLag..<(x.count - maxLag)]) }
                let lb = LoopSpike.bestLag(before, wantBefore, maxLag: maxLag)
                let la = LoopSpike.bestLag(after, wantAfter, maxLag: maxLag)
                _ = trimmed
                let jump = abs(compSamples[i] - compSamples[i - 1])
                let around = LoopSpike.maxStep(compSamples[(i - 8)...(i + 8)])
                worstLagMs = max(worstLagMs, abs(Double(lb.lag)) / rate * 1000, abs(Double(la.lag)) / rate * 1000)
                worstJump = max(worstJump, around)
                Self.note("   seam \(k + 1) at comp \(liveF(seam)) s: lag before \(liveF(Double(lb.lag) / rate * 1000, 2)) ms (corr \(liveF(lb.corr, 4))), lag after \(liveF(Double(la.lag) / rate * 1000, 2)) ms (corr \(liveF(la.corr, 4))); step at the seam \(liveF(Double(jump), 4)), worst within 8 samples \(liveF(Double(around), 4)); song's own worst step in the loop \(liveF(Double(normal), 4))")
            }
            Self.note("   offline: worst timing offset \(liveF(worstLagMs, 3)) ms, worst seam step \(liveF(Double(worstJump), 4)) vs normal \(liveF(Double(normal), 4))")
            #expect(worstLagMs <= 5, "timing offset \(worstLagMs) ms")
            #expect(worstJump <= normal * 1.05 + 1e-4, "seam step \(worstJump) against the song's own \(normal)")

            // Played: an AVPlayer on the composition with the real tap (the engine's own path: makeAudioMix on the asset).
            let recorder = MusicRenderRecorder(seconds: 90)
            MusicRenderRecorder.current = recorder
            MusicRenderRecorder.mutesOutput = true
            let chain = MusicDSPChain(sampleRate: 48_000)
            chain.setTargetGain(1, snap: true)
            let deck = MusicTapDeck(role: .active)
            let mix = await MusicAudioTap.$currentDeck.withValue(deck) {
                await MusicAudioTap.makeAudioMix(for: comp, chain: chain)
            }
            #expect(mix != nil, "the tap builds on a composition track")
            let item = AVPlayerItem(asset: comp)
            item.audioTimePitchAlgorithm = .spectral
            item.audioMix = mix
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            let startAt = max(0, loop.end - 3)
            await player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            let playSeconds = 3 + extra + 3
            let finished = await waitUntil(timeout: .seconds(playSeconds + 25)) { player.currentTime().seconds >= startAt + playSeconds }
            player.pause()
            #expect(finished, "the composition kept playing")
            let heard = recorder.snapshot()
            MusicRenderRecorder.current = nil
            var detail: [String] = []
            let scan = LiveScan.chainDropouts(heard, fadeStart: nil, fadeEnd: nil, rateEvents: [], roles: [:], samples: [], detail: &detail)
            let times = heard.records.map(\.sourceStart).filter(\.isFinite)
            let coversSeams = (times.min() ?? .infinity) <= loop.end && (times.max() ?? 0) >= loop.end + extra
            Self.note("   played: \(heard.records.count) render calls, item time \(liveF(times.min() ?? .nan)) to \(liveF(times.max() ?? .nan)) s, peak \(liveF(Double(scan.peak), 3)), dropouts \(scan.count), non-finite \(scan.nonFinite), covers every seam \(coversSeams) \(detail.joined(separator: " | "))")
            #expect(scan.peak > 0.01, "the tap renders the composition")
            #expect(scan.count == 0, "dropouts \(detail)")
            #expect(scan.nonFinite == 0)
            #expect(coversSeams)
            // The tap's item time is continuous across the seams (composition time, no jump back).
            var worstStep = 0.0
            let ordered = heard.records.sorted { $0.sampleOffset < $1.sampleOffset }
            for i in 1..<max(1, ordered.count) where ordered[i].sourceStart.isFinite && ordered[i - 1].sourceStart.isFinite {
                worstStep = max(worstStep, abs(ordered[i].sourceStart - ordered[i - 1].sourceStart - Double(ordered[i - 1].frames) / ordered[i - 1].sampleRate))
            }
            Self.note("   item-time continuity: worst deviation between render calls \(liveF(worstStep * 1000, 2)) ms")
            #expect(worstStep < 0.05)
            player.replaceCurrentItem(with: nil)
        }
        MusicRenderRecorder.mutesOutput = false
    }
}
