import Foundation
import Testing
@testable import Deci

@Suite struct BeatThisResamplerTests {
    private func run(rate: Double, channels: Int, seconds: Double, block: Int, signal: (Int) -> Float) -> [Float] {
        let n = Int(seconds * rate)
        var frames = [Float](repeating: 0, count: n * channels)
        for i in 0..<n { for c in 0..<channels { frames[i * channels + c] = signal(i) } }
        let r = BeatThisResampler(inputRate: rate)
        var offset = 0
        while offset < n {
            let take = min(block, n - offset)
            frames.withUnsafeBufferPointer { r.consume(interleaved: $0.baseAddress! + offset * channels, frames: take, channels: channels) }
            offset += take
        }
        return r.finish()
    }

    @Test func lengthForCommonRates() {
        for rate in [44100.0, 48000.0, 32000.0, 22050.0, 16000.0] {
            let out = run(rate: rate, channels: 2, seconds: 5, block: 4097) { sinf(2 * .pi * 440 * Float($0) / Float(rate)) }
            #expect(abs((Double(out.count)) - ((5 * rate * 22050 / rate).rounded(.up))) <=  1)
        }
    }

    @Test func impulseTimingIsPreserved() {
        for rate in [44100.0, 48000.0] {
            let at = Int(rate * 2.0)
            let out = run(rate: rate, channels: 2, seconds: 4, block: 3001) { $0 == at ? 1 : 0 }
            let peak = out.indices.max { abs(out[$0]) < abs(out[$1]) }!
            print("rate \(rate): impulse at 2.000 s lands at sample \(peak) = \(Double(peak) / 22050) s, peak \(out[peak])")
            #expect(abs((Double(peak) / 22050) - (2.0)) <=  1.0 / 22050)
        }
    }

    @Test func toneAboveTheCutoffIsRemovedAndBelowKept() {
        // 12 kHz would alias to 10.05 kHz at 48 kHz in; 5 kHz must pass.
        let high = run(rate: 48000, channels: 1, seconds: 3, block: 4000) { sinf(2 * .pi * 12000 * Float($0) / 48000) }
        #expect(high[22050..<44100].map(abs).max()! < 0.01)
        let low = run(rate: 48000, channels: 1, seconds: 3, block: 4000) { sinf(2 * .pi * 5000 * Float($0) / 48000) }
        let peak = low[22050..<44100].map(abs).max()!
        #expect(abs((peak) - (1.0)) <=  0.01)
    }

    @Test func stereoIsAveragedAndLevelKept() {
        let out = run(rate: 44100, channels: 2, seconds: 3, block: 5000) { 0.5 * sinf(2 * .pi * 1000 * Float($0) / 44100) }
        let mid = Array(out[22050..<(2 * 22050)])
        let peak = mid.map(abs).max()!
        #expect(abs((peak) - (0.5)) <=  0.02)
    }

    @Test func blockSizeDoesNotChangeTheResult() {
        let sig: (Int) -> Float = { sinf(2 * .pi * 300 * Float($0) / 44100) + 0.3 * sinf(2 * .pi * 5000 * Float($0) / 44100) }
        let a = run(rate: 44100, channels: 1, seconds: 3, block: 512, signal: sig)
        let b = run(rate: 44100, channels: 1, seconds: 3, block: 20000, signal: sig)
        #expect(a == b)
    }
}
