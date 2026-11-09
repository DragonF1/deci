// DeciTests/Music/MusicFilterSweepTests.swift
// Tier 4b P2: the filter sweep DSP, offline. The cutoff curve, the high-pass response, stability under a full-speed sweep,
// silence, bad input and the state reset on a new request.

import Foundation
import Testing
@testable import Deci

@Suite("MusicFilterSweep")
struct MusicFilterSweepTests {
    static let rate = 48_000.0

    static func sine(_ hz: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let frames = Int(seconds * rate)
        var out = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * Double.pi * hz * Double(frame) / rate))
            out[frame * 2] = value
            out[frame * 2 + 1] = value
        }
        return out
    }

    /// A deterministic white noise in -1...1, stereo.
    static func noise(frames: Int, seed: UInt64 = 7) -> [Float] {
        var state = seed
        return (0..<frames * 2).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
        }
    }

    static func rms(_ samples: [Float], from: Int) -> Float {
        let tail = samples[(from * 2)...]
        return (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
    }

    static func hold(_ hz: Float) -> MusicSweepSettings {
        MusicSweepSettings(startFrame: 0, durationFrames: 1, fromHz: hz, toHz: hz, highpass: true)
    }

    static func sweep(_ settings: MusicSweepSettings) -> MusicFilterSweep {
        let filter = MusicFilterSweep(sampleRate: rate)
        filter.start(settings)
        return filter
    }

    @Test("the cutoff curve starts at the from frequency and ends at the to frequency")
    func endpoints() {
        #expect(abs(MusicFilterSweep.cutoffHz(from: 30, to: 1_500, progress: 0) - 30) < 0.01)
        #expect(abs(MusicFilterSweep.cutoffHz(from: 30, to: 1_500, progress: 1) - 1_500) < 0.5)
        #expect(MusicFilterSweep.cutoffHz(from: 30, to: 1_500, progress: -3) == MusicFilterSweep.cutoffHz(from: 30, to: 1_500, progress: 0))
        #expect(MusicFilterSweep.cutoffHz(from: 30, to: 1_500, progress: 9) == MusicFilterSweep.cutoffHz(from: 30, to: 1_500, progress: 1))
        #expect(abs(MusicFilterSweep.cutoffHz(from: 30, to: 1_500, progress: .nan) - 30) < 0.01)
    }

    @Test("the ramp is logarithmic: the midpoint is the geometric mean and equal steps are equal ratios")
    func logShape() {
        let mid = MusicFilterSweep.cutoffHz(from: 30, to: 1_500, progress: 0.5)
        #expect(abs(mid - Float((30.0 * 1_500.0).squareRoot())) < 0.05)
        var ratios: [Float] = []
        var last = MusicFilterSweep.cutoffHz(from: 30, to: 1_500, progress: 0)
        for step in 1...10 {
            let next = MusicFilterSweep.cutoffHz(from: 30, to: 1_500, progress: Double(step) / 10)
            ratios.append(next / last)
            last = next
        }
        for ratio in ratios { #expect(abs(ratio - ratios[0]) < 1e-3) }
        #expect(ratios[0] > 1)
    }

    @Test("the target holds the start until the sweep starts, rises across the duration, and holds the end after it")
    func targetOverTime() {
        let filter = Self.sweep(MusicSweepSettings(startFrame: 1_000, durationFrames: 10_000, fromHz: 30, toHz: 1_500, highpass: true))
        #expect(abs(filter.targetHz(afterFrames: 0) - 30) < 0.01)
        #expect(abs(filter.targetHz(afterFrames: 1_000) - 30) < 0.01)
        #expect(abs(filter.targetHz(afterFrames: 6_000) - Float((30.0 * 1_500.0).squareRoot())) < 0.1)
        #expect(abs(filter.targetHz(afterFrames: 11_000) - 1_500) < 0.5)
        #expect(abs(filter.targetHz(afterFrames: 900_000) - 1_500) < 0.5)
    }

    @Test("a high-pass at 100 Hz passes 1 kHz and removes 25 Hz")
    func highpassResponse() {
        let pass = Self.sweep(Self.hold(100)).render(Self.sine(1_000, seconds: 1))
        let stop = Self.sweep(Self.hold(100)).render(Self.sine(25, seconds: 1))
        let reference = Self.rms(Self.sine(1_000, seconds: 1), from: Int(Self.rate / 2))
        #expect(abs(Self.rms(pass, from: Int(Self.rate / 2)) / reference - 1) < 0.05)
        #expect(Self.rms(stop, from: Int(Self.rate / 2)) / reference < 0.12)
    }

    @Test("DC is removed")
    func dc() {
        let input = [Float](repeating: 0.5, count: Int(Self.rate) * 2)
        let out = Self.sweep(Self.hold(30)).render(input)
        #expect(Self.rms(out, from: Int(Self.rate / 2)) < 1e-4)
        // And the first sample is the input: the filter starts from zero state, so there is no step.
        #expect(abs(out[0] - 0.5) < 0.01)
    }

    @Test("a full-speed sweep over noise stays finite and bounded")
    func stableUnderFastSweep() {
        let frames = 96_000
        for (from, to) in [(Float(20), Float(20_000)), (20_000, 20), (30, 1_500), (5, 22_000)] {
            let settings = MusicSweepSettings(startFrame: 0, durationFrames: 64, fromHz: from, toHz: to, highpass: true)
            for block in [1, 7, 16, 100, 512] {
                let out = Self.sweep(settings).render(Self.noise(frames: frames), block: block)
                #expect(out.allSatisfy { $0.isFinite })
                #expect((out.map { abs($0) }.max() ?? 0) < 6, "from \(from) to \(to) block \(block)")
            }
        }
    }

    @Test("the low-pass flavour stays bounded too and keeps DC")
    func lowpass() {
        let settings = MusicSweepSettings(startFrame: 0, durationFrames: 64, fromHz: 20, toHz: 20_000, highpass: false)
        let out = Self.sweep(settings).render([Float](repeating: 0.5, count: 96_000))
        #expect(out.allSatisfy { $0.isFinite })
        #expect(abs(out[out.count - 2] - 0.5) < 0.01)
    }

    @Test("silence in is silence out")
    func silence() {
        let settings = MusicSweepSettings(startFrame: 100, durationFrames: 20_000, fromHz: 30, toHz: 1_500, highpass: true)
        let out = Self.sweep(settings).render([Float](repeating: 0, count: 100_000))
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test("a sweep over a loud tone has no steps: the output moves no faster than the tone itself")
    func noZipper() {
        // 2 kHz at 0.5 moves at most 0.5 * 2 pi * 2000 / 48000 = 0.131 per frame; the filter passes it (cutoff <= 1.5 kHz).
        let settings = MusicSweepSettings(startFrame: 0, durationFrames: Int(Self.rate / 2), fromHz: 30, toHz: 1_500, highpass: true)
        let out = Self.sweep(settings).render(Self.sine(2_000, seconds: 0.6), block: 37)
        var biggest: Float = 0
        for frame in 1..<(out.count / 2) { biggest = max(biggest, abs(out[frame * 2] - out[(frame - 1) * 2])) }
        #expect(biggest < 0.2, "largest step \(biggest)")
    }

    @Test("a NaN or infinite sample never poisons the state: the next blocks are finite")
    func badInput() {
        var input = Self.noise(frames: 4_096)
        input[300] = .nan
        input[301] = .infinity
        input[1_000] = -.infinity
        let out = Self.sweep(Self.hold(200)).render(input)
        #expect(out.allSatisfy { $0.isFinite })
        #expect(Self.rms(out, from: 3_000) > 0.1, "the filter still passes audio after the bad samples")
    }

    @Test("a new request starts from a clean state: nothing of the old sweep rings into the new one")
    func resetOnNewGeneration() {
        let filter = Self.sweep(Self.hold(60))
        _ = filter.render(Self.noise(frames: 8_000))
        // Without a reset the tail of the noise is still in the filter.
        var ringing = [Float](repeating: 0, count: 2_000)
        ringing.withUnsafeMutableBufferPointer { filter.process($0.baseAddress!, frames: 1_000) }
        #expect(ringing.contains { $0 != 0 })
        _ = filter.render(Self.noise(frames: 8_000))
        filter.start(Self.hold(60))
        #expect(filter.renderedFrames == 0)
        let clean = filter.render([Float](repeating: 0, count: 4_000))
        #expect(clean.allSatisfy { $0 == 0 })
        // reset() does the same for a seek or a load.
        _ = filter.render(Self.noise(frames: 2_000))
        filter.reset()
        #expect(filter.render([Float](repeating: 0, count: 4_000)).allSatisfy { $0 == 0 })
    }

    @Test("settings are made safe: negative frames, non-finite or silly frequencies")
    func safeSettings() {
        for settings in [
            MusicSweepSettings(startFrame: -5, durationFrames: 0, fromHz: .nan, toHz: .infinity, highpass: true),
            MusicSweepSettings(startFrame: 0, durationFrames: 1, fromHz: -10, toHz: 1e9, highpass: true),
        ] {
            let out = Self.sweep(settings).render(Self.noise(frames: 4_000))
            #expect(out.allSatisfy { $0.isFinite })
        }
    }

    @Test("a filter that was never started leaves the signal alone (a renderer that runs before the request lands is inert)")
    func unstartedIsInert() {
        let filter = MusicFilterSweep(sampleRate: Self.rate)
        let input = Self.noise(frames: 4_000)
        #expect(filter.render(input) == input)
        // reset() is not a start.
        filter.reset()
        #expect(filter.render(input) == input)
        // And once started it does filter.
        filter.start(Self.hold(1_000))
        #expect(filter.render(input) != input)
    }
}
