// Deci/Music/Playback/MusicFilterSweep.swift
// Tier 4b P2: the filter sweep of a beat blend. A stereo state-variable filter (the trapezoidal, zero-delay form of
// Simper and Zavalishin, stable under fast modulation) that high-passes the outgoing song, its cutoff ramped in log
// frequency from the bass up to the hats across the overlap, so the old song thins out to air while the new one takes
// over. Everything is allocated once with the lease: the state is a handful of floats. The cutoff is held for blocks of at
// most `blockFrames` frames and passed through a one-pole smoother in the log domain, so there is no zipper noise.
// Render safe: no lock, no allocation, no Objective-C.

import Foundation

/// One sweep's settings, in frames, as the engine asks for them.
nonisolated struct MusicSweepSettings: Equatable, Sendable {
    /// Rendered frames from the request until the cutoff starts to move (the incoming song's first frame).
    var startFrame: Int
    /// Frames the ramp takes from `fromHz` to `toHz`; the cutoff holds `toHz` after that.
    var durationFrames: Int
    var fromHz: Float
    var toHz: Float
    /// True for a high-pass (the outgoing song), false for a low-pass.
    var highpass: Bool

    static let defaultFromHz: Float = 30
    static let defaultToHz: Float = 1_500
}

nonisolated final class MusicFilterSweep: @unchecked Sendable {
    /// The longest stretch of frames one coefficient set is held for.
    static let blockFrames = 16
    /// Butterworth damping (1 / Q with Q = 1 / sqrt 2).
    private static let damping = Float(2).squareRoot()
    /// Time constant of the cutoff smoother, in seconds.
    private static let smoothingSeconds = 0.004

    private let sampleRate: Double
    private let nyquistCeiling: Float

    private var settings = MusicSweepSettings(
        startFrame: 0, durationFrames: 1, fromHz: MusicSweepSettings.defaultFromHz,
        toHz: MusicSweepSettings.defaultToHz, highpass: true
    )
    /// Frames rendered since `start`.
    private var position = 0
    /// False until `start`: an unstarted filter passes the signal through untouched.
    private var armed = false
    /// The smoothed cutoff, as ln(Hz).
    private var smoothedLog: Float = 0
    private var smoothing: Float = 1
    private var ic1L: Float = 0, ic2L: Float = 0, ic1R: Float = 0, ic2R: Float = 0

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        nyquistCeiling = Float(rate * 0.45)
        smoothing = Float(1 - exp(-Double(Self.blockFrames) / (rate * Self.smoothingSeconds)))
        smoothedLog = log(settings.fromHz)
    }

    // MARK: Cutoff curve

    /// The cutoff at `progress` (0 before the ramp, 1 at its end), ramped in log frequency: equal steps of progress are
    /// equal musical intervals. Progress is clamped, a non-finite one counts as 0.
    static func cutoffHz(from: Float, to: Float, progress: Double) -> Float {
        let p = progress.isFinite ? Float(min(max(progress, 0), 1)) : 0
        let lo = log(max(from, 1)), hi = log(max(to, 1))
        return exp(lo + (hi - lo) * p)
    }

    /// The cutoff the filter is heading for after `frames` rendered frames of the current sweep.
    func targetHz(afterFrames frames: Int) -> Float {
        let ramp = frames - settings.startFrame
        let progress = ramp <= 0 ? 0 : min(1, Double(ramp) / Double(max(1, settings.durationFrames)))
        return Self.cutoffHz(from: settings.fromHz, to: settings.toHz, progress: progress)
    }

    // MARK: Control (render thread only)

    /// Starts a sweep: the settings take hold, the position and the filter state start from zero.
    func start(_ requested: MusicSweepSettings) {
        var next = requested
        next.startFrame = max(0, requested.startFrame)
        next.durationFrames = max(1, requested.durationFrames)
        next.fromHz = Self.clamped(requested.fromHz, fallback: MusicSweepSettings.defaultFromHz, ceiling: nyquistCeiling)
        next.toHz = Self.clamped(requested.toHz, fallback: MusicSweepSettings.defaultToHz, ceiling: nyquistCeiling)
        settings = next
        armed = true
        reset()
    }

    /// Forgets the state and the position (a seek, a load, a new generation, a sweep that ended). The settings stay.
    func reset() {
        position = 0
        smoothedLog = log(settings.fromHz)
        ic1L = 0; ic2L = 0; ic1R = 0; ic2R = 0
    }

    private static func clamped(_ hz: Float, fallback: Float, ceiling: Float) -> Float {
        min(max(hz.isFinite ? hz : fallback, 5), ceiling)
    }

    // MARK: Render

    /// Filters a stereo interleaved block in place.
    func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard armed else { return }
        var done = 0
        while done < frames {
            let run = min(Self.blockFrames, frames - done)
            // The cutoff of the middle of this stretch, smoothed in the log domain.
            let target = targetHz(afterFrames: position + run / 2)
            smoothedLog += smoothing * (log(target) - smoothedLog)
            let hz = min(max(exp(smoothedLog), 5), nyquistCeiling)
            let g = Float(tan(Double.pi * Double(hz) / sampleRate))
            let k = Self.damping
            let a1 = 1 / (1 + g * (g + k))
            let a2 = g * a1
            let a3 = g * a2
            let highpass = settings.highpass
            for frame in done..<(done + run) {
                let xl = samples[frame * 2], xr = samples[frame * 2 + 1]
                // Left.
                let v3l = xl - ic2L
                let v1l = a1 * ic1L + a2 * v3l
                let v2l = ic2L + a2 * ic1L + a3 * v3l
                ic1L = 2 * v1l - ic1L
                ic2L = 2 * v2l - ic2L
                // Right.
                let v3r = xr - ic2R
                let v1r = a1 * ic1R + a2 * v3r
                let v2r = ic2R + a2 * ic1R + a3 * v3r
                ic1R = 2 * v1r - ic1R
                ic2R = 2 * v2r - ic2R
                var yl = highpass ? xl - k * v1l - v2l : v2l
                var yr = highpass ? xr - k * v1r - v2r : v2r
                if !yl.isFinite || !yr.isFinite {
                    // A broken input never leaves the filter in a bad state.
                    ic1L = 0; ic2L = 0; ic1R = 0; ic2R = 0
                    yl = 0; yr = 0
                }
                samples[frame * 2] = yl
                samples[frame * 2 + 1] = yr
            }
            // Denormals out, once per stretch.
            if abs(ic1L) < 1e-20 { ic1L = 0 }
            if abs(ic2L) < 1e-20 { ic2L = 0 }
            if abs(ic1R) < 1e-20 { ic1R = 0 }
            if abs(ic2R) < 1e-20 { ic2R = 0 }
            position += run
            done += run
        }
    }

    /// Frames rendered since the last `start`.
    var renderedFrames: Int { position }

    // MARK: Offline use (tests)

    /// Runs a whole stereo interleaved signal through the filter in blocks of `block` frames and returns the result.
    func render(_ input: [Float], block: Int = 512) -> [Float] {
        var out = input
        let frames = input.count / 2
        out.withUnsafeMutableBufferPointer { buffer in
            var at = 0
            while at < frames {
                let n = min(block, frames - at)
                process(buffer.baseAddress! + at * 2, frames: n)
                at += n
            }
        }
        return out
    }
}
