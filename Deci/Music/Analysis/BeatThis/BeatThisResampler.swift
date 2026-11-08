// Deci/Music/Analysis/BeatThis/BeatThisResampler.swift
// Streams decoded audio of any rate and channel count into one mono 22050 Hz Float array, the input of beat_this.
// Channels are averaged, then a polyphase windowed-sinc filter (Kaiser, 128 taps per phase, cutoff 10.6 kHz) converts the
// rate. The filter is centred, so there is no latency: an event at time t in the file sits at sample t * 22050 in the
// output. (AVAudioConverter at its best quality delayed the signal by 26 ms and added a tail, which would shift every
// beat time.)

import Foundation
import Accelerate

nonisolated final class BeatThisResampler {
    static let outputRate = BeatThisMel.sampleRate
    static let taps = 128
    static let cutoffHz = 10_600.0
    static let kaiserBeta = 8.0

    private let up: Int      // output rate / gcd
    private let down: Int    // input rate / gcd
    private let table: [Float]   // up phases of `taps` coefficients each
    private let passthrough: Bool
    private let usable: Bool

    private(set) var samples: [Float] = []
    private var mono: [Float] = []
    /// Input not yet fully used: pending[0] is input sample `base`.
    private var pending: [Float]
    private var base: Int
    private var inputCount = 0
    /// Next output sample number.
    private var next = 0

    /// `isUsable` is false for a rate that is not a whole number of hertz; the caller then skips beat_this.
    init(inputRate: Double, reserveSeconds: Double = 0) {
        let half = Self.taps / 2
        base = -(half - 1)
        pending = [Float](repeating: 0, count: half - 1)
        let rounded = inputRate.rounded()
        guard inputRate > 0, abs(inputRate - rounded) < 1e-6, rounded <= 1_000_000 else {
            up = 1; down = 1; table = []; passthrough = false; usable = false
            return
        }
        let fi = Int(rounded), fo = Int(Self.outputRate)
        var a = fi, b = fo
        while b != 0 { (a, b) = (b, a % b) }
        up = fo / a
        down = fi / a
        passthrough = fi == fo
        usable = true
        table = passthrough ? [] : Self.makeTable(up: up, inputRate: Double(fi))
        if reserveSeconds > 0 { samples.reserveCapacity(Int(reserveSeconds * Self.outputRate)) }
    }

    var isUsable: Bool { usable }

    /// Coefficients for output phase p: tap j weights input sample (i0 - taps/2 + 1 + j), i0 = floor(n * down / up).
    private static func makeTable(up: Int, inputRate: Double) -> [Float] {
        let half = Double(taps / 2)
        let cutoff = min(cutoffHz, 0.46 * inputRate) / inputRate   // cycles per input sample
        func besselI0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1 }
            return sum
        }
        let norm = besselI0(kaiserBeta)
        var table = [Float](repeating: 0, count: up * taps)
        for p in 0..<up {
            var row = [Double](repeating: 0, count: taps)
            for j in 0..<taps {
                let t = Double(p) / Double(up) + half - 1 - Double(j)   // input time minus sample time
                let x = 2 * cutoff * t
                let sinc = abs(x) < 1e-12 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                let r = t / half
                let window = abs(r) >= 1 ? 0 : besselI0(kaiserBeta * (1 - r * r).squareRoot()) / norm
                row[j] = 2 * cutoff * sinc * window
            }
            let sum = row.reduce(0, +)
            for j in 0..<taps { table[p * taps + j] = Float(row[j] / sum) }
        }
        return table
    }

    func consume(interleaved: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard usable, frames > 0, channels > 0 else { return }
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
        mono.withUnsafeMutableBufferPointer { out in
            if channels == 1 {
                out.baseAddress!.update(from: interleaved, count: frames)
            } else {
                var scale = 1 / Float(channels)
                vDSP_vclr(out.baseAddress!, 1, vDSP_Length(frames))
                for channel in 0..<channels {
                    vDSP_vadd(out.baseAddress!, 1, interleaved + channel, vDSP_Stride(channels), out.baseAddress!, 1, vDSP_Length(frames))
                }
                vDSP_vsmul(out.baseAddress!, 1, &scale, out.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        if passthrough {
            samples.append(contentsOf: mono[0..<frames])
            inputCount += frames
            return
        }
        pending.append(contentsOf: mono[0..<frames])
        inputCount += frames
        produce(finalCount: nil)
    }

    /// Drains the filter and returns every sample.
    func finish() -> [Float] {
        guard usable, !passthrough else { return samples }
        pending.append(contentsOf: [Float](repeating: 0, count: Self.taps / 2))
        // Output n sits at input time n * down / up; the song ends at inputCount.
        let total = (inputCount * up + down - 1) / down
        produce(finalCount: total)
        return samples
    }

    private func produce(finalCount: Int?) {
        let half = Self.taps / 2
        var produced = 0
        let start = next
        pending.withUnsafeBufferPointer { buffer in
            table.withUnsafeBufferPointer { coefficients in
                while true {
                    let position = next * down
                    let i0 = position / up, phase = position % up
                    // The last input sample this output reads is i0 + half; it must have arrived (or been padded).
                    let last = i0 + half - base
                    if last >= buffer.count { break }
                    if let finalCount, next >= finalCount { break }
                    if finalCount == nil, i0 >= inputCount { break }
                    var sum: Float = 0
                    vDSP_dotpr(coefficients.baseAddress! + phase * Self.taps, 1, buffer.baseAddress! + (i0 - half + 1 - base), 1, &sum, vDSP_Length(Self.taps))
                    samples.append(sum)
                    next += 1
                    produced += 1
                }
            }
        }
        _ = (start, produced)
        // Drop input no later output needs: the next one starts at floor(next * down / up) - half + 1.
        let keepFrom = (next * down) / up - half + 1
        if keepFrom - base > 65_536 {
            pending.removeFirst(keepFrom - base)
            base = keepFrom
        }
    }
}
