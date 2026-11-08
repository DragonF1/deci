// Deci/Music/Analysis/MusicKeyDetector.swift
// Musical key from the decoded audio: a mono downmix near 22 kHz, a 4096-point FFT every 2048 samples,
// bins from 65 Hz to 2 kHz folded to 12 pitch classes, then the best of 24 key profiles. Fed from the
// analyzer's own decode loop, so the file is read once.

import Accelerate
import Foundation

nonisolated final class MusicKeyDetector {
    static let fftSize = 4096
    static let hop = 2048
    private static let lowHz: Float = 65
    private static let highHz: Float = 2000
    /// Frames quieter than this (sum of magnitudes) say nothing about key or brightness.
    private static let silenceFloor: Float = 1e-3

    private static let krumhanslMajor: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let krumhanslMinor: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    private static let temperleyMajor: [Float] = [5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0]
    private static let temperleyMinor: [Float] = [5.0, 2.0, 3.5, 4.5, 2.0, 4.0, 2.0, 4.5, 3.5, 2.0, 1.5, 4.0]

    private let factor: Int
    private let rate: Double
    private let window: [Float]
    /// Bins from 65 Hz to 2 kHz, their pitch classes (index 0 is bin `chromaBins.lowerBound`).
    private let chromaBins: Range<Int>
    private let binClass: [Int8]
    private let binHz: [Float]
    private let setup: FFTSetup?
    private var pending: [Float] = []
    private var start = 0
    private var leftover: [Float] = []
    private var mono: [Float] = []
    private var reduced: [Float] = []
    private var chroma = [Float](repeating: 0, count: 12)
    private var centroidSum: Double = 0
    private var centroidFrames = 0
    private var real = [Float](repeating: 0, count: MusicKeyDetector.fftSize / 2)
    private var imag = [Float](repeating: 0, count: MusicKeyDetector.fftSize / 2)
    private var magnitude = [Float](repeating: 0, count: MusicKeyDetector.fftSize / 2)
    private var compressed = [Float](repeating: 0, count: MusicKeyDetector.fftSize / 2)
    private var frame = [Float](repeating: 0, count: MusicKeyDetector.fftSize)

    init(sampleRate: Double) {
        let valid = sampleRate.isFinite && sampleRate >= 8000 && sampleRate <= 1e6
        factor = valid ? max(1, Int((sampleRate / 22_050).rounded())) : 1
        rate = valid ? sampleRate / Double(factor) : 22_050
        let n = Self.fftSize
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        var classes: [Int8] = []
        var first = n / 2, last = 0
        var hz = [Float](repeating: 0, count: n / 2)
        for bin in 1..<(n / 2) {
            let f = Float(Double(bin) * rate / Double(n))
            hz[bin] = f
            guard f >= Self.lowHz, f <= Self.highHz else { continue }
            first = min(first, bin)
            last = max(last, bin)
            let semitones = (12 * log2(Double(f) / 440)).rounded()
            classes.append(Int8(((Int(semitones) + 9) % 12 + 12) % 12))
        }
        chromaBins = first <= last ? first..<(last + 1) : 0..<0
        binClass = classes
        binHz = hz
        setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))
    }

    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

    /// Interleaved float frames of any channel count; mixed to mono and decimated to about 22 kHz.
    func consume(interleaved: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0, setup != nil else { return }
        // Mono mix of this call, after the samples left over from the last one.
        let carried = leftover.count
        let total = carried + frames
        if mono.count < total { mono = [Float](repeating: 0, count: total) }
        for index in 0..<carried { mono[index] = leftover[index] }
        let length = vDSP_Length(frames)
        mono.withUnsafeMutableBufferPointer { out in
            let target = out.baseAddress! + carried
            vDSP_vclr(target, 1, length)
            for channel in 0..<channels {
                vDSP_vadd(target, 1, interleaved + channel, vDSP_Stride(channels), target, 1, length)
            }
        }
        let groups = total / factor
        let used = groups * factor
        if groups > 0 {
            if reduced.count < groups { reduced = [Float](repeating: 0, count: groups) }
            mono.withUnsafeBufferPointer { source in
                reduced.withUnsafeMutableBufferPointer { out in
                    vDSP_vclr(out.baseAddress!, 1, vDSP_Length(groups))
                    for offset in 0..<factor {
                        vDSP_vadd(out.baseAddress!, 1, source.baseAddress! + offset, vDSP_Stride(factor), out.baseAddress!, 1, vDSP_Length(groups))
                    }
                    var scale = 1 / Float(channels * factor)
                    vDSP_vsmul(out.baseAddress!, 1, &scale, out.baseAddress!, 1, vDSP_Length(groups))
                    pending.append(contentsOf: UnsafeBufferPointer(rebasing: out[0..<groups]))
                }
            }
        }
        leftover = Array(mono[used..<total])
        while pending.count - start >= Self.fftSize {
            process(from: start)
            start += Self.hop
        }
        if start >= 1 << 15 {
            pending.removeFirst(start)
            start = 0
        }
    }

    private func process(from offset: Int) {
        guard let setup else { return }
        let n = Self.fftSize, half = n / 2
        pending.withUnsafeBufferPointer { source in
            vDSP_vmul(source.baseAddress! + offset, 1, window, 1, &frame, 1, vDSP_Length(n))
        }
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                frame.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 12, FFTDirection(kFFTDirection_Forward))
                vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(half))
            }
        }
        magnitude[0] = 0
        // Normalise to a per-sample amplitude scale.
        var norm = 1 / Float(n)
        vDSP_vsmul(magnitude, 1, &norm, &magnitude, 1, vDSP_Length(half))
        var total: Float = 0
        vDSP_sve(magnitude, 1, &total, vDSP_Length(half))
        guard total > Self.silenceFloor else { return }

        var weighted: Float = 0
        vDSP_dotpr(magnitude, 1, binHz, 1, &weighted, vDSP_Length(half))
        centroidSum += Double(weighted / total)
        centroidFrames += 1

        // Only the pitched range: one peak, one compressed copy, then fold into the 12 classes.
        let count = vDSP_Length(chromaBins.count)
        var peak: Float = 0
        magnitude.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + chromaBins.lowerBound, 1, &peak, count) }
        guard peak > 0 else { return }
        var scale = 20 / peak
        magnitude.withUnsafeBufferPointer { vDSP_vsmul($0.baseAddress! + chromaBins.lowerBound, 1, &scale, &compressed, 1, count) }
        var length = Int32(chromaBins.count)
        vvlog1pf(&compressed, compressed, &length)
        for (offset, pc) in binClass.enumerated() { chroma[Int(pc)] += compressed[offset] }
    }

    /// The 12-bin chroma so far, C first, scaled to a peak of 1 (all zero for silence).
    func finish() -> [Float] {
        let top = chroma.max() ?? 0
        guard top > 0 else { return [Float](repeating: 0, count: 12) }
        return chroma.map { $0 / top }
    }

    /// Mean spectral centroid in Hz over the frames that were not silent; 0 when there were none.
    var meanCentroidHz: Float { centroidFrames > 0 ? Float(centroidSum / Double(centroidFrames)) : 0 }

    /// Best of 24 keys by the mean of Pearson correlations with the Krumhansl and Temperley profiles.
    /// Confidence is the best score minus the second best, so a flat or empty chroma gives about 0.
    static func classify(chroma: [Float]) -> (tonic: Int, isMinor: Bool, confidence: Float) {
        guard chroma.count == 12, chroma.allSatisfy(\.isFinite) else { return (0, false, 0) }
        let mean = chroma.reduce(0, +) / 12
        let centered = chroma.map { $0 - mean }
        let norm = sqrt(centered.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-6 else { return (0, false, 0) }

        func unit(_ profile: [Float]) -> [Float] {
            let m = profile.reduce(0, +) / 12
            let c = profile.map { $0 - m }
            let n = sqrt(c.reduce(0) { $0 + $1 * $1 })
            return c.map { $0 / n }
        }
        let majors = [unit(krumhanslMajor), unit(temperleyMajor)]
        let minors = [unit(krumhanslMinor), unit(temperleyMinor)]
        var scores: [(score: Float, tonic: Int, minor: Bool)] = []
        for tonic in 0..<12 {
            for (minor, profiles) in [(false, majors), (true, minors)] {
                var total: Float = 0
                for profile in profiles {
                    var dot: Float = 0
                    for pc in 0..<12 { dot += centered[(tonic + pc) % 12] * profile[pc] }
                    total += dot / norm
                }
                scores.append((total / Float(profiles.count), tonic, minor))
            }
        }
        scores.sort { $0.score > $1.score }
        return (scores[0].tonic, scores[0].minor, max(0, scores[0].score - scores[1].score))
    }
}
