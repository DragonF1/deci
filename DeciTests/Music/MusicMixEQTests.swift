// DeciTests/Music/MusicMixEQTests.swift
// The mids and highs of the mixer EQ, offline on test buffers: flat is the input, every move is a cut of its own band, and the
// moves keep their time.

import Foundation
import Testing
@testable import Deci

@Suite("MusicMixEQ")
struct MusicMixEQTests {
    private let rate = 48_000.0

    private func stereo(_ mono: [Float]) -> [Float] { mono.flatMap { [$0, $0] } }

    private func sine(_ frequency: Double, frames: Int, amplitude: Float = 0.3) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    /// Runs `mono` through `eq` in blocks of `chunk` frames and returns the left channel.
    private func run(_ eq: MusicMixEQ, _ mono: [Float], chunk: Int = 480) -> [Float] {
        var samples = stereo(mono)
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for start in stride(from: 0, to: mono.count, by: chunk) {
                eq.process(base + start * 2, frames: min(chunk, mono.count - start))
            }
        }
        return stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))).squareRoot()
    }

    /// dB a held setting changes a sine by, past the filters' settling.
    private func change(_ frequency: Double, mid: Float, high: Float) -> Double {
        let eq = MusicMixEQ(sampleRate: rate)
        eq.begin(MusicMixEQSettings(mid: [.init(frame: 0, gain: mid)], high: [.init(frame: 0, gain: high)]))
        let signal = sine(frequency, frames: 48_000)
        let out = run(eq, signal)
        return 20 * log10(rms(out[24_000...]) / rms(signal[24_000...]))
    }

    @Test("off, and open, the output is the input bit for bit")
    func flatIsTheInput() {
        let signal = sine(440, frames: 9_600).enumerated().map { $1 + ($0 % 7 == 0 ? 0.1 : -0.02) }
        #expect(run(MusicMixEQ(sampleRate: rate), signal) == signal)
        let open = MusicMixEQ(sampleRate: rate)
        open.begin(MusicMixEQSettings(mid: [.init(frame: 0, gain: 1)], high: []))
        #expect(run(open, signal) == signal)
        // After its last point a band that is open costs nothing again.
        let opened = MusicMixEQ(sampleRate: rate)
        opened.begin(MusicMixEQSettings(mid: [.init(frame: 0, gain: 0.3), .init(frame: 4_800, gain: 1)], high: []))
        let out = run(opened, signal)
        #expect(out[0..<2_400] != signal[0..<2_400] && Array(out[5_000...]) == Array(signal[5_000...]))
    }

    @Test("a mid cut takes the mids and leaves the lows and highs, a high cut takes the highs; nothing is ever louder")
    func bands() {
        #expect(abs(change(800, mid: 0.2, high: 1) + 14) < 1, "\(change(800, mid: 0.2, high: 1)) dB at 800 Hz")
        #expect(change(40, mid: 0.2, high: 1) > -1.2)
        #expect(change(14_000, mid: 0.2, high: 1) > -1.5)
        #expect(abs(change(14_000, mid: 1, high: 0.4) + 8) < 1)
        #expect(change(800, mid: 1, high: 0.4) > -0.5)
        for frequency in [30.0, 60, 120, 160, 250, 500, 1_000, 2_000, 3_500, 6_000, 12_000, 18_000] {
            for (mid, high) in [(Float(0.05), Float(1)), (0.35, 1), (0.5, 0.4), (1, 0.4), (0.2, 0.05)] {
                let value = change(frequency, mid: mid, high: high)
                #expect(value < 0.05, "\(frequency) Hz at mid \(mid) high \(high): \(value) dB")
            }
        }
    }

    @Test("a gain above 1, below the floor or not a number is held to the range")
    func clamped() {
        #expect(MusicMixEQSettings.clamped(3) == 1 && MusicMixEQSettings.clamped(-1) == 0.05 && MusicMixEQSettings.clamped(.nan) == 1)
        #expect(change(800, mid: 4, high: 4) == 0)
    }

    @Test("a move is even in decibels, held before and after, and the same in any block size")
    func movesKeepTime() {
        let eq = MusicMixEQ(sampleRate: rate)
        eq.begin(MusicMixEQSettings(mid: [.init(frame: 9_600, gain: 0.25), .init(frame: 19_200, gain: 1), .init(frame: 28_800, gain: 1)], high: []))
        var seen: [Double] = []
        let block = [Float](repeating: 0.1, count: 4_800)
        for _ in 0..<4 {
            _ = run(eq, block)
            seen.append(eq.debugGains.mid)
        }
        // Read at the middle of each stretch's last 16 frames, just before 4,800, 9,600, 14,400 and 19,200.
        #expect(abs(seen[0] - 0.25) < 1e-6 && abs(seen[1] - 0.25) < 1e-6 && abs(seen[2] - 0.5) < 0.002 && abs(seen[3] - 1) < 0.002, "\(seen)")
        let settings = MusicMixEQSettings(mid: [.init(frame: 100, gain: 0.3), .init(frame: 9_000, gain: 1)], high: [.init(frame: 0, gain: 0.5), .init(frame: 7_000, gain: 1)])
        let signal = sine(700, frames: 12_000)
        let whole = MusicMixEQ(sampleRate: rate), chunked = MusicMixEQ(sampleRate: rate)
        whole.begin(settings)
        chunked.begin(settings)
        let a = run(whole, signal, chunk: 12_000), b = run(chunked, signal, chunk: 160)
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    @Test("skipped frames count: a move is where it would have been")
    func skipKeepsTime() {
        let eq = MusicMixEQ(sampleRate: rate)
        eq.begin(MusicMixEQSettings(mid: [.init(frame: 0, gain: 0.25), .init(frame: 9_600, gain: 1), .init(frame: 20_000, gain: 1)], high: []))
        _ = run(eq, [Float](repeating: 0.1, count: 480))
        eq.skip(4_320 - 16)
        _ = run(eq, [Float](repeating: 0.1, count: 16))
        #expect(abs(eq.debugGains.mid - 0.5) < 0.002, "\(eq.debugGains.mid)")
    }

    @Test("a move has no step: a steady tone through a full swing never jumps more than the tone itself does")
    func noClicks() {
        let eq = MusicMixEQ(sampleRate: rate)
        eq.begin(MusicMixEQSettings(mid: [.init(frame: 4_800, gain: 1), .init(frame: 12_000, gain: 0.2), .init(frame: 16_000, gain: 0.2), .init(frame: 30_000, gain: 1)], high: [.init(frame: 4_800, gain: 1), .init(frame: 14_400, gain: 0.4), .init(frame: 30_000, gain: 1)]))
        let signal = sine(1_000, frames: 36_000)
        let out = run(eq, signal)
        func steepest(_ samples: [Float]) -> Float { zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }
        #expect(steepest(out) <= steepest(signal) * 1.02)
    }

    @Test("a release opens from where the bands are and then leaves the signal alone; end is immediate")
    func releaseAndEnd() {
        let eq = MusicMixEQ(sampleRate: rate)
        eq.begin(MusicMixEQSettings(mid: [.init(frame: 0, gain: 0.25)], high: [.init(frame: 0, gain: 0.4)]))
        let block = sine(900, frames: 4_800)
        _ = run(eq, block)
        eq.release(frames: 2_400)
        let out = run(eq, block)
        #expect(abs(eq.debugGains.mid - 1) < 1e-9 && abs(eq.debugGains.high - 1) < 1e-9)
        #expect(Array(out[2_500...]) == Array(block[2_500...]))
        // A release with nothing begun, or after it is over, changes nothing.
        eq.release(frames: 100)
        #expect(run(eq, block) == block)
        eq.begin(MusicMixEQSettings(mid: [.init(frame: 0, gain: 0.25)], high: []))
        _ = run(eq, block)
        eq.end()
        #expect(run(eq, block) == block && !eq.isActive)
    }

    @Test("a new begin replaces the moves in progress and takes no release that came before it")
    func beginReplaces() {
        let eq = MusicMixEQ(sampleRate: rate)
        eq.begin(MusicMixEQSettings(mid: [.init(frame: 0, gain: 0.25)], high: []))
        _ = run(eq, [Float](repeating: 0.1, count: 480))
        eq.release(frames: 100_000)
        eq.begin(MusicMixEQSettings(mid: [.init(frame: 0, gain: 0.5)], high: []))
        _ = run(eq, [Float](repeating: 0.1, count: 480))
        #expect(abs(eq.debugGains.mid - 0.5) < 1e-6)
    }

    @Test("a release asked for after a begin that has not been rendered yet still opens the bands")
    func releaseBeforeFirstRender() {
        let eq = MusicMixEQ(sampleRate: rate)
        eq.release(frames: 100)
        eq.begin(MusicMixEQSettings(mid: [.init(frame: 0, gain: 0.2), .init(frame: 480_000, gain: 1)], high: []))
        eq.release(frames: 1_440)
        let signal = sine(800, frames: 9_600)
        let out = run(eq, signal)
        #expect(Array(out[4_800...]) == Array(signal[4_800...]))
    }

    @Test("a broken sample does not stay in the filters")
    func badInput() {
        let eq = MusicMixEQ(sampleRate: rate)
        eq.begin(MusicMixEQSettings(mid: [.init(frame: 0, gain: 0.25)], high: [.init(frame: 0, gain: 0.5)]))
        var signal = sine(500, frames: 4_800)
        signal[100] = .nan
        signal[200] = .infinity
        let out = run(eq, signal)
        #expect(out.allSatisfy { $0.isFinite })
        #expect(rms(out[2_400...]) > 0.01)
    }

    @Test("more points than a band holds are dropped, not written past it")
    func pointLimit() {
        let eq = MusicMixEQ(sampleRate: rate)
        let many = (0..<40).map { MusicMixEQPoint(frame: $0 * 100, gain: 0.5) }
        eq.begin(MusicMixEQSettings(mid: many, high: many))
        #expect(eq.debugRequest.settings.mid.count == MusicMixEQSettings.maxPoints)
        #expect(run(eq, sine(500, frames: 4_800)).allSatisfy { $0.isFinite })
    }
}
