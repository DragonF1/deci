// Deci/Music/Analysis/BeatThis/BeatThisMel.swift
// beat_this (small0) front end: mono 22050 Hz samples to a (time, 128) log-mel matrix at 50 frames per second.
// torchaudio MelSpectrogram settings: n_fft 1024, hop 441, periodic Hann, centre with reflect padding of 512, STFT
// scaled by 1/32, magnitude (power 1), 128 slaney mel bands from 30 to 11000 Hz without area normalisation, then
// ln(1 + 1000 x). The filterbank is the exact matrix the reference used, loaded from a dumped file.

import Foundation
import Accelerate

nonisolated final class BeatThisMel: @unchecked Sendable {
    static let sampleRate = 22050.0
    static let fftSize = 1024
    static let hop = 441
    static let bins = 513
    static let bands = 128
    static let framesPerSecond = 50.0

    enum Failure: Error, Equatable { case badFilterbank }

    /// The filterbank transposed to row-major [bin][band], 513 x 128, for one matrix multiply per block.
    private let filterbankT: [Float]
    private let window: [Float]
    private let fft: FFTSetup
    /// Frames per block: a block's magnitude matrix stays small however long the song is.
    private static let blockFrames = 256

    init(filterbank: [Float]) throws {
        guard filterbank.count == Self.bands * Self.bins else { throw Failure.badFilterbank }
        var transposed = [Float](repeating: 0, count: Self.bands * Self.bins)
        vDSP_mtrans(filterbank, 1, &transposed, 1, vDSP_Length(Self.bins), vDSP_Length(Self.bands))
        filterbankT = transposed
        // Periodic Hann (torch.hann_window(1024)): 0.5 - 0.5 cos(2 pi n / N).
        window = (0..<Self.fftSize).map { 0.5 - 0.5 * cosf(2 * .pi * Float($0) / Float(Self.fftSize)) }
        guard let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else { throw Failure.badFilterbank }
        fft = setup
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// A little-endian float32 file of 128 x 513 values.
    static func loadFilterbank(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count == bands * bins * MemoryLayout<Float>.size else { throw Failure.badFilterbank }
        var values = [Float](repeating: 0, count: bands * bins)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }

    /// Number of frames for `sampleCount` samples: centre padding gives 1 + floor(N / hop).
    static func frameCount(samples sampleCount: Int) -> Int { sampleCount > 0 ? 1 + sampleCount / hop : 0 }

    /// The log-mel matrix, time-major (frame * 128 + band). Empty for fewer than 513 samples (the reflect pad needs them).
    func logMel(_ samples: [Float]) -> [Float] {
        let count = samples.count
        let half = Self.fftSize / 2
        guard count > half else { return [] }
        let frames = Self.frameCount(samples: count)
        var out = [Float](repeating: 0, count: frames * Self.bands)

        var frame = [Float](repeating: 0, count: Self.fftSize)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: Self.blockFrames * Self.bins)
        var products = [Float](repeating: 0, count: Self.blockFrames * Self.bands)
        // vDSP's packed real FFT returns twice the DFT; the STFT is also scaled by 1/32.
        let scale: Float = 1 / (2 * 32)

        var blockStart = 0
        while blockStart < frames {
            if Task.isCancelled { return [] }
            let blockCount = min(Self.blockFrames, frames - blockStart)
            for local in 0..<blockCount {
                let origin = (blockStart + local) * Self.hop - half
                for n in 0..<Self.fftSize {
                    var index = origin + n
                    if index < 0 { index = -index }
                    if index >= count { index = 2 * (count - 1) - index }
                    // A short song can reflect past the other end; clamp (never hit for songs).
                    index = min(max(index, 0), count - 1)
                    frame[n] = samples[index] * window[n]
                }
                real.withUnsafeMutableBufferPointer { r in
                    imag.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        frame.withUnsafeBufferPointer { f in
                            f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(fft, &split, 1, 10, FFTDirection(kFFTDirection_Forward))
                    }
                }
                let base = local * Self.bins
                magnitudes[base] = abs(real[0]) * scale
                magnitudes[base + half] = abs(imag[0]) * scale
                for bin in 1..<half { magnitudes[base + bin] = hypotf(real[bin], imag[bin]) * scale }
            }
            // (blockCount x 513) times (513 x 128) = blockCount x 128; the filterbank is stored [band][bin].
            vDSP_mmul(
                magnitudes, 1, filterbankT, 1, &products, 1,
                vDSP_Length(blockCount), vDSP_Length(Self.bands), vDSP_Length(Self.bins)
            )
            let base = blockStart * Self.bands
            for i in 0..<(blockCount * Self.bands) { out[base + i] = log1pf(1000 * products[i]) }
            blockStart += blockCount
        }
        return out
    }
}
