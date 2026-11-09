// Deci/Music/Playback/MusicEchoDSP.swift
// Tier 4b P1: the echo-out tail. A stereo feedback delay whose line is allocated once, when the lease is made. The line is
// also the lease's dry history: every block a lease renders is recorded into it (`record`), so when the echo is asked for
// it already holds the last second of the song. From the request until the cut the line is only fed (no feedback, no wet
// output); from the cut it only recirculates: repeats of the last beat that decay by the feedback each time, low-passed so
// each repeat is darker than the one before. Render safe: no lock, no allocation, no Objective-C.

import Foundation

/// One echo's settings, in frames, as the engine asks for them.
nonisolated struct MusicEchoSettings: Equatable, Sendable {
    /// One beat, or 0.375 s without a trusted grid.
    var delayFrames: Int
    /// Rendered frames from the request until the cut (the standby's first frame). The line is fed until then.
    var cutAfterFrames: Int
    /// About 0.5.
    var feedback: Float
    /// How loud the repeats are against the dry song.
    var wetGain: Float
    /// One-pole low-pass on the wet path, in Hz.
    var lowpassHz: Float

    static let defaultFeedback: Float = 0.5
    static let defaultWetGain: Float = 0.35
    static let defaultLowpassHz: Float = 3_500
    /// The longest delay the line holds, in seconds.
    static let maxDelaySeconds = 1.0
    /// The delay when the grid is not trusted.
    static let untrustedDelaySeconds = 0.375
}

nonisolated final class MusicEchoDelay: @unchecked Sendable {
    /// The line's length in frames, fixed for the life of the object.
    let capacity: Int
    private let line: UnsafeMutablePointer<Float>
    /// The pre-fade copy of a block, so the dry fade never scales the echo's input.
    private let copy: UnsafeMutablePointer<Float>
    let copyFrames: Int
    private let sampleRate: Double

    private var write = 0
    private var delay = 1
    private var feedback: Float = 0.5
    private var wet: Float = MusicEchoSettings.defaultWetGain
    /// Frames of the wet fade-out left (0 = not releasing) and its length, for an echo that is cut short.
    private var releaseLeft = 0
    private var releaseTotal = 1
    private var releasedOut = false
    private var coefficient: Float = 1
    private var lowL: Float = 0
    private var lowR: Float = 0
    private var untilCut = 0

    init(sampleRate: Double, maxBlockFrames: Int) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        capacity = max(2, Int((MusicEchoSettings.maxDelaySeconds * rate).rounded(.up)) + 1)
        line = .allocate(capacity: capacity * 2)
        line.initialize(repeating: 0, count: capacity * 2)
        copyFrames = max(1, maxBlockFrames)
        copy = .allocate(capacity: copyFrames * 2)
        copy.initialize(repeating: 0, count: copyFrames * 2)
    }

    deinit {
        line.deallocate()
        copy.deallocate()
    }

    /// Starts a new echo: the settings take hold and the history the line holds stays (it is the song's last second).
    /// Render thread only.
    func start(_ settings: MusicEchoSettings) {
        releaseLeft = 0
        releasedOut = false
        lowL = 0
        lowR = 0
        delay = min(max(1, settings.delayFrames), capacity - 1)
        untilCut = max(0, settings.cutAfterFrames)
        feedback = min(max(settings.feedback.isFinite ? settings.feedback : 0.5, 0), 0.9)
        wet = min(max(settings.wetGain.isFinite ? settings.wetGain : MusicEchoSettings.defaultWetGain, 0), 1)
        let hz = min(max(settings.lowpassHz.isFinite ? settings.lowpassHz : 3_500, 200), Float(sampleRate) * 0.45)
        coefficient = Float(1 - exp(-2 * Double.pi * Double(hz) / sampleRate))
    }

    /// Frames left before the cut (0 once it has passed).
    var framesUntilCut: Int { untilCut }

    /// True once a release has faded the wet to nothing: the echo is over.
    var isReleasedOut: Bool { releasedOut }

    /// Fades the wet signal to nothing over `frames` (a seek, a skip or a load cut the tail short). Render thread only.
    func beginRelease(frames: Int) {
        guard !releasedOut, releaseLeft == 0 else { return }
        releaseTotal = max(1, frames)
        releaseLeft = releaseTotal
    }

    /// Forgets the history: the line goes silent, so a later `start` never repeats audio from before a seek. Render thread
    /// only, never while an echo is running (a fixed-size memset of the line, no allocation).
    func clearHistory() {
        memset(line, 0, capacity * 2 * MemoryLayout<Float>.size)
    }

    /// Writes a block of the dry signal into the line without any echo: the history a later `start` finds. Render thread
    /// only, never while an echo is running.
    func record(_ samples: UnsafePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let run = min(frames - done, capacity - write)
            memcpy(line + write * 2, samples + done * 2, run * 2 * MemoryLayout<Float>.size)
            write = write + run == capacity ? 0 : write + run
            done += run
        }
    }

    /// Keeps a copy of a block before the fade is applied to it. False when the block is longer than the copy.
    func capture(_ samples: UnsafePointer<Float>, frames: Int) -> Bool {
        guard frames <= copyFrames else { return false }
        memcpy(copy, samples, frames * 2 * MemoryLayout<Float>.size)
        return true
    }

    /// Runs the line over the captured block (the same `frames`) and adds the repeats to `samples`, which already carry the
    /// faded dry signal. `scale` is the loudness offset the dry side was given.
    func mix(into samples: UnsafeMutablePointer<Float>, frames: Int, scale: Float = 1) {
        let gain = wet * scale
        for frame in 0..<frames {
            // A release ramps the wet to nothing; the line keeps running underneath.
            var ramp: Float = 1
            if releaseLeft > 0 {
                ramp = Float(releaseLeft - 1) / Float(releaseTotal)
                releaseLeft -= 1
                if releaseLeft == 0 { releasedOut = true }
            } else if releasedOut {
                ramp = 0
            }
            let read = write >= delay ? write - delay : write - delay + capacity
            var heardL = line[read * 2]
            var heardR = line[read * 2 + 1]
            // The low-pass sits in the loop, so every pass through it darkens the repeat.
            lowL += coefficient * (heardL - lowL)
            lowR += coefficient * (heardR - lowR)
            if abs(lowL) < 1e-20 { lowL = 0 }
            if abs(lowR) < 1e-20 { lowR = 0 }
            heardL = lowL
            heardR = lowR
            let fed = untilCut > 0
            let inL = fed ? copy[frame * 2] : 0
            let inR = fed ? copy[frame * 2 + 1] : 0
            // While it is fed the line only collects the song (nothing is heard, nothing recirculates): the first repeat is
            // the last beat as it was, and the feedback builds only on what the tail already holds.
            var nextL = fed ? inL : feedback * heardL
            var nextR = fed ? inR : feedback * heardR
            if !nextL.isFinite { nextL = 0 }
            if !nextR.isFinite { nextR = 0 }
            line[write * 2] = nextL
            line[write * 2 + 1] = nextR
            write = write + 1 == capacity ? 0 : write + 1
            if fed {
                untilCut -= 1
            } else {
                // The sum is clamped: the dry that is still fading out and a repeat never clip together.
                samples[frame * 2] = min(1, max(-1, samples[frame * 2] + heardL * gain * ramp))
                samples[frame * 2 + 1] = min(1, max(-1, samples[frame * 2 + 1] + heardR * gain * ramp))
            }
        }
    }

    // MARK: Offline use (tests)

    /// Feeds a whole stereo interleaved signal through the line the way the renderer does, in blocks of `block` frames.
    /// `faded` is what the dry path already produced (zeros for a dry that was cut at once).
    func render(dry: [Float], faded: [Float], block: Int = 512) -> [Float] {
        var out = faded
        let frames = dry.count / 2
        var at = 0
        dry.withUnsafeBufferPointer { drySamples in
            out.withUnsafeMutableBufferPointer { outSamples in
                while at < frames {
                    let n = min(block, frames - at, copyFrames)
                    if capture(drySamples.baseAddress! + at * 2, frames: n) {
                        mix(into: outSamples.baseAddress! + at * 2, frames: n)
                    }
                    at += n
                }
            }
        }
        return out
    }
}
