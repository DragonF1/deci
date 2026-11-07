// Deci/Music/Analysis/MusicBeatDecimator.swift
// Streaming twin of `MusicBeatFinder.decimate`: mono average, the same windowed-sinc FIR, keep every factor-th sample.
// It runs inside the analysis decode loop so the beat finder needs no second decode. The output does not depend on how
// the input is chunked, and it stops listening after `maxSeconds` of audio.

import Foundation
import Accelerate

nonisolated final class MusicBeatDecimator {
    let inputRate: Double
    private let maxFrames: Int
    private let factor: Int
    private let taps: Int
    private let half: Int
    private let filter: [Float]
    /// Input not yet consumed by an output, with the leading `half` zeros of the one-shot padding in front.
    private var pending: [Float]
    private var output: [Float] = []
    private var frames = 0
    private var finite = true

    init(inputRate: Double, maxSeconds: Double = 600) {
        self.inputRate = inputRate
        factor = max(1, Int((inputRate / MusicBeatFinder.targetRate).rounded()))
        taps = factor == 1 ? 1 : 16 * factor + 1
        half = (taps - 1) / 2
        maxFrames = maxSeconds.isFinite && maxSeconds > 0 ? Int(maxSeconds * inputRate) : 0
        filter = Self.firFilter(factor: factor, taps: taps)
        pending = [Float](repeating: 0, count: half)
    }

    /// Windowed sinc, unit gain; identical to the one in `MusicBeatFinder.decimate`.
    static func firFilter(factor: Int, taps: Int) -> [Float] {
        guard factor > 1 else { return [1] }
        let cutoff = 0.45 / Double(factor)
        var filter = [Float](repeating: 0, count: taps)
        var total: Float = 0
        let mid = Double(taps - 1) / 2
        for index in 0..<taps {
            let x = Double(index) - mid
            let sinc = x == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * x) / (Double.pi * x)
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(taps - 1))
            filter[index] = Float(sinc * hann)
            total += filter[index]
        }
        for index in 0..<taps { filter[index] /= total }
        return filter
    }

    /// Interleaved frames (`frames * channels` floats); anything past the cap is ignored.
    func consume(interleaved: UnsafePointer<Float>, frames count: Int, channels: Int) {
        let take = min(count, maxFrames - frames)
        guard take > 0, channels > 0 else { return }
        var mono = [Float](repeating: 0, count: take)
        let length = vDSP_Length(take)
        for channel in 0..<channels {
            vDSP_vadd(mono, 1, interleaved + channel, vDSP_Stride(channels), &mono, 1, length)
        }
        if channels > 1 {
            var scale = 1 / Float(channels)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, length)
        }
        var sum: Float = 0
        vDSP_svemg(mono, 1, &sum, vDSP_Length(take))
        if !sum.isFinite { finite = false }
        frames += take
        pending.append(contentsOf: mono)
        emit()
    }

    /// The decimated mono signal. Empty when nothing was heard or any sample was not finite.
    func finish() -> (samples: [Float], rate: Double) {
        guard finite, frames > 0 else { return ([], inputRate) }
        let rate = inputRate / Double(factor)
        let expected = frames / factor
        if factor == 1 { return (Array(output.prefix(expected)), rate) }
        pending.append(contentsOf: [Float](repeating: 0, count: taps))
        emit()
        return (Array(output.prefix(expected)), rate)
    }

    private func emit() {
        if factor == 1 {
            output.append(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
            return
        }
        guard pending.count >= taps else { return }
        let count = (pending.count - taps) / factor + 1
        var out = [Float](repeating: 0, count: count)
        pending.withUnsafeBufferPointer { input in
            vDSP_desamp(input.baseAddress!, vDSP_Stride(factor), filter, &out, vDSP_Length(count), vDSP_Length(taps))
        }
        output.append(contentsOf: out)
        pending.removeFirst(count * factor)
    }
}
