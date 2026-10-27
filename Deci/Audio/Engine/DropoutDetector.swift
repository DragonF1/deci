// Deci/Audio/Engine/DropoutDetector.swift
import Foundation

/// Counts mid-stream dropouts in a tap's input: a short run of exact-zero frames that cuts audible audio,
/// with signal coming back soon after. That is what an app missing its render deadline looks like from
/// outside (the buffer it should have filled arrives as zeros); a pause or a fade-out does not look like it.
///
/// A run of zero frames (every channel exactly 0) counts as one dropout when, once signal returns:
/// - it lasted `minGapSeconds` to `maxGapSeconds`: shorter is a zero crossing or a rounding, longer is a pause;
/// - audible audio came right before it: a level that follows the signal and halves every
///   `levelHalfLifeSeconds` was at least `audibleLevel` when the run began, so a fade that already reached
///   silence, or quiet material under -50 dBFS, is not a cut.
/// A run that outlives `maxGapSeconds` disarms the detector (the level goes to zero), so the resume of a pause is
/// not counted; the next audible audio arms it again. State carries across buffers, so a gap that straddles two
/// callbacks counts once.
///
/// Real-time safe: a plain value with no allocation, locks, logging or ObjC, and no `pow` or `exp` on the audio
/// path. Everything that depends on the sample rate is computed in `configure`, on the main thread, before the
/// callback runs. One writer (the primary callback); the main thread may read the two counters (torn reads are
/// harmless: a count can be stale by a buffer, never invalid).
struct DropoutDetector: Equatable {
    /// Shortest run that counts, longest run that counts.
    static let minGapSeconds = 0.001
    static let maxGapSeconds = 0.250
    /// The recent-level memory: the level halves in this time while the signal is quieter than it.
    static let levelHalfLifeSeconds = 0.005
    /// The level the audio before a run must have had (-50 dBFS).
    static let audibleLevel: Float = 0.003
    /// A frame's peak is clamped here before it enters the level, so one huge or infinite sample cannot hold it up.
    private static let levelCeiling: Float = 4
    /// Below this the level is dropped to zero, which keeps the decay out of subnormal numbers.
    private static let levelFloor: Float = 1e-12

    /// Dropouts counted over the detector's life. Never goes back (`reset` and `configure` keep it), so a reader
    /// that takes differences gets the exact growth across a tap restart or a rate change. Wraps.
    private(set) var dropoutCount: UInt32 = 0
    /// Length of the latest counted dropout, in seconds. 0 until one is counted; kept across a reset like the count.
    private(set) var lastDropoutSeconds: Double = 0

    /// Thresholds in frames, computed by `configure`.
    private(set) var minGapFrames = 0
    private(set) var maxGapFrames = 0

    private var sampleRate = OutputGateWindows.fallbackSampleRate
    /// Frames for the level to halve, and the per-frame factor that does it.
    private var halfLifeFrames = 1
    private var decay: Float = 1

    /// The recent level of the signal: the larger of the frame peak and the previous level decayed.
    private var level: Float = 0
    /// Length of the zero run in progress, 0 when none. Saturates at `maxGapFrames + 1` ("longer than a gap").
    private var runFrames = 0
    /// The level was `audibleLevel` or more when the run in progress began.
    private var runWasAudible = false

    init(sampleRate: Double = OutputGateWindows.fallbackSampleRate) {
        configure(sampleRate: sampleRate)
    }

    /// Sets the thresholds for `sampleRate` and starts over. Main thread, before the callback runs on this value.
    /// An unusable rate falls back to 48 kHz, as `OutputGateWindows` does.
    mutating func configure(sampleRate rate: Double) {
        let usable = (rate.isFinite && rate > 0) ? rate : OutputGateWindows.fallbackSampleRate
        sampleRate = usable
        minGapFrames = max(1, Self.frames(usable * Self.minGapSeconds))
        maxGapFrames = max(minGapFrames, Self.frames(usable * Self.maxGapSeconds))
        halfLifeFrames = max(1, Self.frames(usable * Self.levelHalfLifeSeconds))
        decay = Float(exp2(-1.0 / Double(halfLifeFrames)))
        reset()
    }

    /// Clears the count, the latest length, the level and any run in progress. The thresholds stay.
    /// Forgets the level and any run in progress, so audio before a tap restart cannot arm a gap after it. The count
    /// and the latest length stay.
    mutating func reset() {
        level = 0
        runFrames = 0
        runWasAudible = false
    }

    /// Feeds one buffer of interleaved Float samples. A frame is silent only when all its channels are exactly 0
    /// (a NaN is signal). Real-time safe.
    mutating func process(_ samples: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        var index = 0
        for _ in 0..<frames {
            var peak: Float = 0
            var silent = true
            for _ in 0..<channels {
                let sample = samples[index]
                if sample != 0 {
                    // A NaN is not zero, so it makes the frame signal; it never raises the peak (it compares false).
                    silent = false
                    let magnitude = sample.magnitude
                    if magnitude > peak { peak = magnitude }
                }
                index += 1
            }
            if silent {
                extendRun(by: 1)
            } else {
                if runFrames > 0 { endRun() }
                let clamped = peak < Self.levelCeiling ? peak : Self.levelCeiling
                let decayed = level * decay
                level = clamped > decayed ? clamped : (decayed < Self.levelFloor ? 0 : decayed)
            }
        }
    }

    /// Feeds `frames` frames of exact zeros without scanning them: the same state `process` reaches on a buffer of
    /// zeros, in constant time. For a buffer already known to be silent. Real-time safe.
    mutating func addSilence(frames: Int) {
        guard frames > 0 else { return }
        extendRun(by: frames)
    }

    /// Adds `count` zero frames to the run in progress, starting one if there is none. A run past `maxGapFrames`
    /// is a pause: it stops growing and the level goes, so its resume is not a dropout.
    private mutating func extendRun(by count: Int) {
        if runFrames == 0 { runWasAudible = level >= Self.audibleLevel }
        guard runFrames <= maxGapFrames else { return }
        if count > maxGapFrames - runFrames {
            runFrames = maxGapFrames + 1
            runWasAudible = false
            level = 0
        } else {
            runFrames += count
        }
    }

    /// Signal is back after a zero run: count the run if it was a dropout, and let the level decay through it.
    private mutating func endRun() {
        let length = runFrames
        runFrames = 0
        if length >= minGapFrames, length <= maxGapFrames, runWasAudible {
            dropoutCount &+= 1
            lastDropoutSeconds = Double(length) / sampleRate
        }
        runWasAudible = false
        // The level halves per half-life of zeros; whole halvings only (never lower than the true level by more than 2x).
        let halvings = min(length / halfLifeFrames, 100)
        if halvings > 0 {
            level *= Float(sign: .plus, exponent: -halvings, significand: 1)
            if level < Self.levelFloor { level = 0 }
        }
    }

    private static func frames(_ value: Double) -> Int {
        value.isFinite && value < Double(Int32.max) ? Int(value.rounded()) : Int(Int32.max)
    }
}
