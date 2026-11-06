// Deci/Music/Analysis/MusicAudioAnalyzer.swift
// Song analysis: a pure streaming DSP core (silence edges, 100 ms energy curve, intro and outro, ITU BS.1770-4
// integrated loudness, sample peak) and a thin AVAssetReader front end that feeds it. The core never touches
// AVFoundation; it keeps filter state across blocks and only the per-window and per-100 ms curves in memory.

import Foundation
import Accelerate
import AVFoundation
import CoreMedia
import AudioToolbox
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicAnalysis")

/// One second-order section with a0 normalised to 1.
nonisolated struct MusicBiquad: Sendable, Equatable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    /// Magnitude response in dB at `frequency`.
    func gainDb(frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        // H(z) with z^-1 = e^(-jw).
        let (c1, s1) = (cos(w), -sin(w))
        let (c2, s2) = (cos(2 * w), -sin(2 * w))
        let numRe = b0 + b1 * c1 + b2 * c2, numIm = b1 * s1 + b2 * s2
        let denRe = 1 + a1 * c1 + a2 * c2, denIm = a1 * s1 + a2 * s2
        let num = numRe * numRe + numIm * numIm
        let den = denRe * denRe + denIm * denIm
        return 10 * log10(num / den)
    }
}

/// Everything measured from one song. `MusicAnalysis` minus identity, format, YouTube numbers and reserved slots.
nonisolated struct MusicAnalysisMeasurement: Sendable, Equatable {
    var silenceStart: Double
    var silenceEnd: Double
    var introEnd: Double
    var outroStart: Double
    /// nil when every block was gated out.
    var integratedLUFS: Double?
    /// Sample peak (not true peak) in dBFS; -infinity for digital silence.
    var samplePeakDb: Double
    var introLUFS: Double?
    var outroLUFS: Double?
    var energy: [UInt8]
    var duration: Double
    /// No window rose above -60 dBFS (or there was no audio): the analysis is not worth storing.
    var isSilent: Bool
}

nonisolated struct MusicAudioAnalyzer: Sendable {
    static let silenceThresholdDb: Float = -60
    static let silenceWindowSeconds = 0.01
    /// The absolute gate of BS.1770-4.
    static let absoluteGateLUFS = -70.0
    static let relativeGateLU = 10.0
    /// Loudness span used for introLUFS and outroLUFS.
    static let edgeLoudnessSeconds = 8.0
    private static let maxSlice = 8192

    let sampleRate: Double
    let channels: Int

    private let shelf: MusicBiquad
    private let highpass: MusicBiquad
    private let shelfCoefficients: [Double]
    private let highpassCoefficients: [Double]
    private let windowFrames: Int
    private let subFrames: Int

    // Per channel filter workspaces (2 history values, then maxSlice samples).
    private var raw: [[Double]]
    private var shelfOut: [[Double]]
    private var highpassOut: [[Double]]

    // Window (10 ms) and sub-block (100 ms) accumulators.
    private var windowSums: [Double]
    private var windowFill = 0
    private var subRawSum = 0.0
    private var subKSum = 0.0
    private var subFill = 0

    private var totalFrames = 0
    private var peak = 0.0
    private var windowDb: [Float] = []
    private var energyDb: [Float] = []
    /// Sum over channels of the K-weighted mean square of each full 100 ms sub-block.
    private var kSubBlocks: [Double] = []

    init(sampleRate: Double, channels: Int) {
        let channels = max(1, channels)
        self.sampleRate = sampleRate
        self.channels = channels
        let (shelf, highpass) = Self.kWeightingCoefficients(sampleRate: sampleRate)
        self.shelf = shelf
        self.highpass = highpass
        shelfCoefficients = [shelf.b0, shelf.b1, shelf.b2, shelf.a1, shelf.a2]
        highpassCoefficients = [highpass.b0, highpass.b1, highpass.b2, highpass.a1, highpass.a2]
        windowFrames = max(1, Int((Self.silenceWindowSeconds * sampleRate).rounded()))
        subFrames = max(1, Int((MusicAnalysis.energyBlockSeconds * sampleRate).rounded()))
        let space = [Double](repeating: 0, count: Self.maxSlice + 2)
        raw = Array(repeating: space, count: channels)
        shelfOut = raw
        highpassOut = raw
        windowSums = Array(repeating: 0, count: channels)
    }

    // MARK: Coefficients

    /// BS.1770-4 stage 1 (high shelf) and stage 2 (high-pass), derived for any sample rate.
    static func kWeightingCoefficients(sampleRate: Double) -> (shelf: MusicBiquad, highpass: MusicBiquad) {
        let shelfK = tan(Double.pi * 1681.974450955533 / sampleRate)
        let shelfQ = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        let shelfA0 = 1 + shelfK / shelfQ + shelfK * shelfK
        let shelf = MusicBiquad(
            b0: (vh + vb * shelfK / shelfQ + shelfK * shelfK) / shelfA0,
            b1: 2 * (shelfK * shelfK - vh) / shelfA0,
            b2: (vh - vb * shelfK / shelfQ + shelfK * shelfK) / shelfA0,
            a1: 2 * (shelfK * shelfK - 1) / shelfA0,
            a2: (1 - shelfK / shelfQ + shelfK * shelfK) / shelfA0
        )
        let hpK = tan(Double.pi * 38.13547087602444 / sampleRate)
        let hpQ = 0.5003270373238773
        let hpA0 = 1 + hpK / hpQ + hpK * hpK
        let highpass = MusicBiquad(
            b0: 1, b1: -2, b2: 1,
            a1: 2 * (hpK * hpK - 1) / hpA0,
            a2: (1 - hpK / hpQ + hpK * hpK) / hpA0
        )
        return (shelf, highpass)
    }

    // MARK: Streaming input

    /// One buffer per channel, any block length. State carries across calls.
    mutating func consume(planar: [UnsafeBufferPointer<Float>]) {
        guard planar.count == channels, let frames = planar.map(\.count).min(), frames > 0 else { return }
        var offset = 0
        while offset < frames {
            let n = min(Self.maxSlice, frames - offset)
            for channel in 0..<channels {
                guard let base = planar[channel].baseAddress else { return }
                raw[channel].withUnsafeMutableBufferPointer { out in
                    vDSP_vspdp(base + offset, 1, out.baseAddress! + 2, 1, vDSP_Length(n))
                }
            }
            process(n)
            offset += n
        }
    }

    /// Interleaved frames (`frames * channels` floats).
    mutating func consume(interleaved: UnsafeBufferPointer<Float>, frames: Int) {
        guard let base = interleaved.baseAddress else { return }
        let frames = min(frames, interleaved.count / channels)
        var offset = 0
        while offset < frames {
            let n = min(Self.maxSlice, frames - offset)
            for channel in 0..<channels {
                raw[channel].withUnsafeMutableBufferPointer { out in
                    vDSP_vspdp(base + offset * channels + channel, vDSP_Stride(channels), out.baseAddress! + 2, 1, vDSP_Length(n))
                }
            }
            process(n)
            offset += n
        }
    }

    /// Filters the `n` new samples in `raw` and folds them into the window and sub-block accumulators.
    private mutating func process(_ n: Int) {
        for channel in 0..<channels {
            raw[channel].withUnsafeMutableBufferPointer { rawPtr in
                var channelPeak = 0.0
                vDSP_maxmgvD(rawPtr.baseAddress! + 2, 1, &channelPeak, vDSP_Length(n))
                peak = max(peak, channelPeak)
                shelfOut[channel].withUnsafeMutableBufferPointer { s1 in
                    vDSP_deq22D(rawPtr.baseAddress!, 1, shelfCoefficients, s1.baseAddress!, 1, vDSP_Length(n))
                    highpassOut[channel].withUnsafeMutableBufferPointer { s2 in
                        vDSP_deq22D(s1.baseAddress!, 1, highpassCoefficients, s2.baseAddress!, 1, vDSP_Length(n))
                        s2[0] = s2[n]; s2[1] = s2[n + 1]
                    }
                    s1[0] = s1[n]; s1[1] = s1[n + 1]
                }
                rawPtr[0] = rawPtr[n]; rawPtr[1] = rawPtr[n + 1]
            }
        }
        // The history copy only touched indices 0 and 1; the new samples sit at 2...n+1.
        var position = 0
        while position < n {
            let step = min(n - position, windowFrames - windowFill, subFrames - subFill)
            for channel in 0..<channels {
                var rawSum = 0.0, kSum = 0.0
                raw[channel].withUnsafeBufferPointer { vDSP_svesqD($0.baseAddress! + 2 + position, 1, &rawSum, vDSP_Length(step)) }
                highpassOut[channel].withUnsafeBufferPointer { vDSP_svesqD($0.baseAddress! + 2 + position, 1, &kSum, vDSP_Length(step)) }
                windowSums[channel] += rawSum
                subRawSum += rawSum
                subKSum += kSum
            }
            windowFill += step
            subFill += step
            totalFrames += step
            position += step
            if windowFill == windowFrames { closeWindow() }
            if subFill == subFrames { closeSubBlock(full: true) }
        }
    }

    private mutating func closeWindow() {
        guard windowFill > 0 else { return }
        let loudest = (windowSums.max() ?? 0) / Double(windowFill)
        windowDb.append(Self.decibels(power: loudest))
        for channel in 0..<channels { windowSums[channel] = 0 }
        windowFill = 0
    }

    private mutating func closeSubBlock(full: Bool) {
        guard subFill > 0 else { return }
        energyDb.append(Self.decibels(power: subRawSum / Double(subFill * channels)))
        if full { kSubBlocks.append(subKSum / Double(subFill)) }
        subRawSum = 0
        subKSum = 0
        subFill = 0
    }

    private static func decibels(power: Double) -> Float {
        power > 0 ? Float(10 * log10(power)) : -.infinity
    }

    // MARK: Result

    /// `exactDuration` replaces the decoded length when the caller knows the true one (fragmented mp4 reports
    /// a doubled duration); anything decoded past it is ignored.
    func finish(exactDuration: Double?) -> MusicAnalysisMeasurement {
        var state = self
        state.closeWindow()
        state.closeSubBlock(full: false)
        let decoded = Double(state.totalFrames) / sampleRate
        let duration = exactDuration.map { max(0, $0) } ?? decoded

        let windowSeconds = Double(windowFrames) / sampleRate
        let subSeconds = Double(subFrames) / sampleRate
        let windows = Array(state.windowDb.prefix(Int(ceil(duration / windowSeconds - 1e-9))))
        let blockCount = Int(ceil(duration / MusicAnalysis.energyBlockSeconds - 1e-9))
        var levels = Array(state.energyDb.prefix(blockCount)).map { max($0, MusicAnalysis.energyFloorDb) }
        if levels.count < blockCount {
            levels += [Float](repeating: MusicAnalysis.energyFloorDb, count: blockCount - levels.count)
        }
        let energy = Self.quantizeEnergy(levels)
        let peakDb = state.peak > 0 ? 20 * log10(state.peak) : -.infinity

        guard duration > 0, let edges = Self.silenceEdges(
            windowRMSdB: windows, window: windowSeconds, thresholdDb: Self.silenceThresholdDb, duration: duration
        ) else {
            return MusicAnalysisMeasurement(
                silenceStart: 0, silenceEnd: duration, introEnd: 0, outroStart: duration, integratedLUFS: nil,
                samplePeakDb: peakDb, introLUFS: nil, outroLUFS: nil, energy: energy, duration: duration, isSilent: true
            )
        }

        let fullSubs = min(state.kSubBlocks.count, Int(duration / subSeconds + 1e-9))
        let subs = Array(state.kSubBlocks.prefix(fullSubs))
        var blocks: [Double] = []
        if subs.count >= 4 {
            blocks.reserveCapacity(subs.count - 3)
            for index in 0...(subs.count - 4) {
                let sum: Double = subs[index] + subs[index + 1] + subs[index + 2] + subs[index + 3]
                blocks.append(sum / 4)
            }
        }

        let (introEnd, outroStart) = Self.introOutro(
            energyDb: levels, silenceStart: edges.start, silenceEnd: edges.end,
            duration: duration, block: MusicAnalysis.energyBlockSeconds
        )
        return MusicAnalysisMeasurement(
            silenceStart: edges.start, silenceEnd: edges.end, introEnd: introEnd, outroStart: outroStart,
            integratedLUFS: Self.integratedLUFS(blockMeanSquares: blocks),
            samplePeakDb: peakDb,
            introLUFS: Self.spanLUFS(blocks: blocks, from: edges.start, to: edges.start + Self.edgeLoudnessSeconds, hop: subSeconds),
            outroLUFS: Self.spanLUFS(blocks: blocks, from: edges.end - Self.edgeLoudnessSeconds, to: edges.end, hop: subSeconds),
            energy: energy, duration: duration, isSilent: false
        )
    }

    // MARK: Pure helpers

    /// -0.691 + 10 log10(z).
    static func blockLUFS(meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }

    /// BS.1770-4 gating over 400 ms block mean squares: absolute -70 LUFS, then 10 LU under the mean of the rest.
    static func integratedLUFS(blockMeanSquares: [Double]) -> Double? {
        let aboveAbsolute = blockMeanSquares.filter { blockLUFS(meanSquare: $0) > absoluteGateLUFS }
        guard !aboveAbsolute.isEmpty else { return nil }
        let relativeGate = blockLUFS(meanSquare: aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) - relativeGateLU
        let kept = aboveAbsolute.filter { blockLUFS(meanSquare: $0) > relativeGate }
        guard !kept.isEmpty else { return nil }
        return blockLUFS(meanSquare: kept.reduce(0, +) / Double(kept.count))
    }

    /// Gated loudness of the 400 ms blocks that lie inside [from, to]; nil with under 3 s of non-gated audio.
    private static func spanLUFS(blocks: [Double], from: Double, to: Double, hop: Double) -> Double? {
        guard !blocks.isEmpty else { return nil }
        let first = max(0, Int(ceil(from / hop - 1e-9)))
        let last = min(blocks.count - 1, Int(floor(to / hop + 1e-9)) - 4)
        guard first <= last else { return nil }
        let span = Array(blocks[first...last])
        let audible = span.filter { blockLUFS(meanSquare: $0) > absoluteGateLUFS }.count
        guard Double(audible) * hop + 0.3 >= 3 else { return nil }
        return integratedLUFS(blockMeanSquares: span)
    }

    /// First and last window above `thresholdDb`: the start of the first and the end of the last. nil when none is.
    static func silenceEdges(
        windowRMSdB: [Float], window: Double, thresholdDb: Float = silenceThresholdDb, duration: Double
    ) -> (start: Double, end: Double)? {
        guard let first = windowRMSdB.firstIndex(where: { $0 > thresholdDb }),
              let last = windowRMSdB.lastIndex(where: { $0 > thresholdDb }) else { return nil }
        let end = min(Double(last + 1) * window, duration)
        return (min(Double(first) * window, end), end)
    }

    static func quantizeEnergy(_ db: [Float]) -> [UInt8] {
        db.map { MusicAnalysis.energyCode(forDb: $0) }
    }

    /// The intro and outro rule: smooth the energy over 1 s inside the silence edges, take the 90th percentile as
    /// the body, and find where the song first and last sits within 6 dB of it. Always
    /// silenceStart <= introEnd <= outroStart <= silenceEnd.
    static func introOutro(
        energyDb: [Float], silenceStart: Double, silenceEnd: Double, duration: Double, block: Double
    ) -> (introEnd: Double, outroStart: Double) {
        let end = max(silenceStart, silenceEnd)
        guard !energyDb.isEmpty, block > 0 else { return (silenceStart, end) }
        let first = max(0, min(energyDb.count - 1, Int(floor(silenceStart / block + 1e-9))))
        let last = max(first, min(energyDb.count - 1, Int(ceil(end / block - 1e-9)) - 1))

        // Centered 1 s moving average (10 blocks), clipped to the span.
        let span = Array(energyDb[first...last].map { max($0, MusicAnalysis.energyFloorDb) })
        var prefix = [Double](repeating: 0, count: span.count + 1)
        for (index, value) in span.enumerated() { prefix[index + 1] = prefix[index] + Double(value) }
        let smooth: [Float] = span.indices.map { index in
            let lo = max(0, index - 5), hi = min(span.count - 1, index + 4)
            return Float((prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1))
        }
        let sorted = smooth.sorted()
        let body = sorted[Int(0.9 * Double(sorted.count - 1))]
        let enterLevel = body - 6, holdLevel = body - 9
        let holdBlocks = Int((2.0 / block).rounded())

        var introEnd = silenceStart
        for index in smooth.indices where smooth[index] >= enterLevel {
            let horizon = min(smooth.count - 1, index + holdBlocks)
            if smooth[index...horizon].allSatisfy({ $0 >= holdLevel }) {
                introEnd = max(silenceStart, Double(first + index) * block)
                break
            }
        }
        introEnd = min(introEnd, max(silenceStart, 0.4 * duration))

        var outroStart = end
        if let index = smooth.lastIndex(where: { $0 >= enterLevel }) {
            outroStart = min(end, Double(first + index + 1) * block)
        }
        outroStart = max(outroStart, 0.6 * duration)
        if end - outroStart < 1.0 { outroStart = end }

        introEnd = min(max(introEnd, silenceStart), end)
        outroStart = min(max(outroStart, introEnd), end)
        return (introEnd, outroStart)
    }
}

// MARK: - File front end

/// Reads an audio file with AVAssetReader at a low QoS, feeds the core, and reports a measurement.
nonisolated enum MusicFileAnalyzer {
    enum Failure: Error, Equatable { case unreadable, cancelled, empty }

    struct Result: Sendable, Equatable {
        var measurement: MusicAnalysisMeasurement
        var format: MusicAnalysis.Format
        /// Audio the reader produced, in seconds, before clamping to `exactDuration` (the doubled-duration probe).
        var decodedSeconds: Double
    }

    /// `probe` runs once on the decode task before any work (tests use it to check the thread).
    static func analyze(
        file: URL,
        exactDuration: Double?,
        priority: TaskPriority = .utility,
        probe: (@Sendable () -> Void)? = nil
    ) async throws -> Result {
        let exact = exactDuration.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        let task = Task.detached(priority: priority) {
            try await decode(file: file, exactDuration: exact, probe: probe)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func decode(file: URL, exactDuration: Double?, probe: (@Sendable () -> Void)?) async throws -> Result {
        probe?()
        let started = ContinuousClock.now
        if Task.isCancelled { throw Failure.cancelled }

        let asset = AVURLAsset(url: file)
        let track: AVAssetTrack
        let description: CMFormatDescription
        do {
            guard let first = try await asset.loadTracks(withMediaType: .audio).first,
                  let firstDescription = try await first.load(.formatDescriptions).first else { throw Failure.unreadable }
            track = first
            description = firstDescription
        } catch is CancellationError {
            throw Failure.cancelled
        } catch {
            throw Failure.unreadable
        }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { throw Failure.unreadable }
        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)

        guard let reader = try? AVAssetReader(asset: asset) else { throw Failure.unreadable }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.unreadable }
        reader.add(output)
        if let exactDuration {
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: exactDuration, preferredTimescale: 600))
        }
        guard reader.startReading() else { throw Failure.unreadable }

        var analyzer = MusicAudioAnalyzer(sampleRate: sampleRate, channels: channels)
        let frameLimit = exactDuration.map { Int(($0 * sampleRate).rounded()) } ?? Int.max
        var scratch = [Float]()
        var decoded = 0
        var hitLimit = false
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw Failure.cancelled
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = length / (MemoryLayout<Float>.size * channels)
            guard frames > 0 else { continue }
            if scratch.count < frames * channels { scratch = [Float](repeating: 0, count: frames * channels) }
            let status = scratch.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * channels * MemoryLayout<Float>.size, destination: raw.baseAddress!)
            }
            guard status == noErr else {
                reader.cancelReading()
                throw Failure.unreadable
            }
            let take = min(frames, frameLimit - decoded)
            scratch.withUnsafeBufferPointer { analyzer.consume(interleaved: $0, frames: take) }
            decoded += take
            if decoded >= frameLimit { hitLimit = true; break }
        }
        if Task.isCancelled {
            reader.cancelReading()
            throw Failure.cancelled
        }
        if hitLimit { reader.cancelReading() } else if reader.status == .failed { throw Failure.unreadable }
        guard decoded > 0 else { throw Failure.empty }

        let measurement = analyzer.finish(exactDuration: exactDuration)
        guard !measurement.isSilent else { throw Failure.empty }
        let format = MusicAnalysis.Format(
            codec: codecString(asbd), itag: 0, durationMs: Int(((exactDuration ?? measurement.duration) * 1000).rounded())
        )
        let elapsed = started.duration(to: .now)
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let lufs = measurement.integratedLUFS.map { String(format: "%.2f", $0) } ?? "nil"
        logger.notice("analysis_done id=\(file.deletingPathExtension().lastPathComponent, privacy: .public) ms=\(ms) lufs=\(lufs, privacy: .public)")
        return Result(measurement: measurement, format: format, decodedSeconds: Double(decoded) / sampleRate)
    }

    private static func codecString(_ asbd: AudioStreamBasicDescription) -> String {
        if asbd.mFormatID == kAudioFormatMPEG4AAC {
            return "mp4a.40.\(asbd.mFormatFlags == 0 ? 2 : asbd.mFormatFlags)"
        }
        let id = asbd.mFormatID
        let bytes = [UInt8((id >> 24) & 0xFF), UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)]
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Mapping to the stored entry

extension MusicAnalysis {
    /// Builds the entry for a measurement. All-gated loudness becomes -infinity (stored as NULL), a non-finite peak -200.
    init(
        videoId: String,
        measurement m: MusicAnalysisMeasurement,
        format: Format,
        source: Source,
        analyzedAt: Date = Date(),
        youtubeLoudnessDb: Double? = nil,
        youtubePerceptualLoudnessDb: Double? = nil
    ) {
        self.init(
            videoId: videoId, version: MusicAnalysis.currentVersion, format: format, analyzedAt: analyzedAt, source: source,
            silenceStart: m.silenceStart, silenceEnd: m.silenceEnd, introEnd: m.introEnd, outroStart: m.outroStart,
            integratedLUFS: m.integratedLUFS ?? -.infinity,
            samplePeakDb: m.samplePeakDb.isFinite ? m.samplePeakDb : -200,
            introLUFS: m.introLUFS, outroLUFS: m.outroLUFS, energy: m.energy,
            youtubeLoudnessDb: youtubeLoudnessDb, youtubePerceptualLoudnessDb: youtubePerceptualLoudnessDb
        )
    }

    /// Builds the entry from a file analysis result.
    init(
        videoId: String,
        result: MusicFileAnalyzer.Result,
        source: Source,
        analyzedAt: Date = Date(),
        youtubeLoudnessDb: Double? = nil,
        youtubePerceptualLoudnessDb: Double? = nil
    ) {
        self.init(
            videoId: videoId, measurement: result.measurement, format: result.format, source: source,
            analyzedAt: analyzedAt, youtubeLoudnessDb: youtubeLoudnessDb,
            youtubePerceptualLoudnessDb: youtubePerceptualLoudnessDb
        )
    }
}
