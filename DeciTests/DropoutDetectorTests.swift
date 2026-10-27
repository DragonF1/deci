// DeciTests/DropoutDetectorTests.swift
//
// Pure-value tests for DropoutDetector: a run of exact-zero frames that cuts audible audio, with
// signal coming back soon, is an upstream app missing its deadline. The detector counts those
// and must not count pauses, fades, quiet passages, or a single silent channel.

import Testing
import Foundation
@testable import Deci

private let testRate = 48_000.0

/// A 440 Hz tone, interleaved. The phase offset keeps every sample off sin's exact zero, so no
/// frame of it is silent. `start` continues a tone across calls.
private func tone(frames: Int, channels: Int = 2, amplitude: Float = 0.5, from start: Int = 0) -> [Float] {
    var out: [Float] = []
    out.reserveCapacity(frames * channels)
    for n in start..<(start + frames) {
        let value = amplitude * Float(sin(2 * Double.pi * 440 * Double(n) / testRate + 0.3))
        for _ in 0..<channels { out.append(value) }
    }
    return out
}

/// Alternating +amplitude, -amplitude: every frame has exactly that peak.
private func square(frames: Int, channels: Int = 2, amplitude: Float) -> [Float] {
    var out: [Float] = []
    out.reserveCapacity(frames * channels)
    for n in 0..<frames {
        let value = n.isMultiple(of: 2) ? amplitude : -amplitude
        for _ in 0..<channels { out.append(value) }
    }
    return out
}

private func silence(frames: Int, channels: Int = 2) -> [Float] {
    [Float](repeating: 0, count: frames * channels)
}

/// An exponential decay from `amplitude` with the given half-life, on both channels, cut to exact zero after `frames`.
private func fade(frames: Int, amplitude: Float = 0.5, halfLifeSeconds: Double) -> [Float] {
    var out: [Float] = []
    out.reserveCapacity(frames * 2)
    for n in 0..<frames {
        let value = amplitude * Float(pow(0.5, Double(n) / (halfLifeSeconds * testRate)))
        out.append(value)
        out.append(value)
    }
    return out
}

private extension DropoutDetector {
    mutating func feed(_ samples: [Float], channels: Int = 2) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            process(base, frames: samples.count / channels, channels: channels)
        }
    }

    /// The samples cut into callback-sized buffers.
    mutating func feedChunked(_ samples: [Float], chunkFrames: Int, channels: Int = 2) {
        var offset = 0
        let chunk = chunkFrames * channels
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            feed(Array(samples[offset..<end]), channels: channels)
            offset = end
        }
    }
}

@Suite("DropoutDetector: what counts as a dropout")
struct DropoutDetectorCountTests {

    @Test("a 10 ms gap in loud audio counts once, with its length in seconds")
    func shortGapCounts() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        d.feed(silence(frames: 480))
        #expect(d.dropoutCount == 0, "the gap is only known to be a gap once signal returns")
        d.feed(tone(frames: 4_800, from: 5_280))
        #expect(d.dropoutCount == 1)
        #expect(abs(d.lastDropoutSeconds - 0.010) < 1e-9)
    }

    @Test("a gap that spans two buffers counts once")
    func gapSpansBuffers() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        d.feed(silence(frames: 200))
        d.feed(silence(frames: 280))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 1)
        #expect(abs(d.lastDropoutSeconds - 0.010) < 1e-9)
    }

    @Test("a gap that starts mid-buffer and ends mid-buffer counts once, however the callbacks fall")
    func gapInsideChunks() {
        for chunk in [1, 7, 100, 480, 512, 1_000] {
            var d = DropoutDetector(sampleRate: testRate)
            var signal = tone(frames: 3_000)
            signal += silence(frames: 480)
            signal += tone(frames: 3_000, from: 3_480)
            d.feedChunked(signal, chunkFrames: chunk)
            #expect(d.dropoutCount == 1, "chunk \(chunk)")
            #expect(abs(d.lastDropoutSeconds - 0.010) < 1e-9, "chunk \(chunk)")
        }
    }

    @Test("two separate gaps count twice, and the latest length is the second one's")
    func twoGaps() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        d.feed(silence(frames: 480))
        d.feed(tone(frames: 4_800))
        d.feed(silence(frames: 960))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 2)
        #expect(abs(d.lastDropoutSeconds - 0.020) < 1e-9)
    }

    @Test("a 0.5 ms gap is a zero crossing or a rounding, not a dropout")
    func tooShort() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        d.feed(silence(frames: 24))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 0)
        #expect(d.lastDropoutSeconds == 0)
    }

    @Test("the shortest gap is 1 ms: 47 frames at 48 kHz do not count, 48 do")
    func minimumBoundary() {
        for (frames, expected) in [(47, UInt32(0)), (48, UInt32(1))] {
            var d = DropoutDetector(sampleRate: testRate)
            d.feed(tone(frames: 4_800))
            d.feed(silence(frames: frames))
            d.feed(tone(frames: 4_800))
            #expect(d.dropoutCount == expected, "\(frames) frames")
        }
    }

    @Test("the longest gap is 250 ms: 12000 frames at 48 kHz count, 12001 are a pause")
    func maximumBoundary() {
        for (frames, expected) in [(12_000, UInt32(1)), (12_001, UInt32(0))] {
            var d = DropoutDetector(sampleRate: testRate)
            d.feed(tone(frames: 4_800))
            d.feed(silence(frames: frames))
            d.feed(tone(frames: 4_800))
            #expect(d.dropoutCount == expected, "\(frames) frames")
        }
    }

    @Test("a 300 ms gap is a pause: neither it nor its resume counts, and a real dropout after it still does")
    func pauseIsNotADropout() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        d.feed(silence(frames: 14_400))
        d.feed(tone(frames: 4_800, from: 19_200))
        #expect(d.dropoutCount == 0, "the resume of a pause must not count")

        d.feed(silence(frames: 480))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 1, "the detector is armed again once audio has played")
    }

    @Test("a pause fed in callback-sized pieces is still a pause")
    func pauseInChunks() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        d.feedChunked(silence(frames: 20_000), chunkFrames: 512)
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 0)
    }

    @Test("a very long silence stays disarmed and cannot overflow the run")
    func veryLongSilence() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        for _ in 0..<2_000 { d.addSilence(frames: 1_000_000) }
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 0)
    }

    @Test("zeros from the very start of the stream, before any audio, are not a dropout")
    func silentStart() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(silence(frames: 480))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 0)
    }

    @Test("a natural fade-out to digital silence, then a short gap, is not a dropout; an abrupt cut is")
    func fadeOutIsNotADropout() {
        // 20 ms half-life: the level follows the signal down to about -84 dBFS before the zeros begin.
        var faded = DropoutDetector(sampleRate: testRate)
        faded.feed(tone(frames: 4_800))
        faded.feed(fade(frames: 12_480, halfLifeSeconds: 0.020))
        faded.feed(silence(frames: 480))
        faded.feed(tone(frames: 4_800))
        #expect(faded.dropoutCount == 0)

        var cut = DropoutDetector(sampleRate: testRate)
        cut.feed(tone(frames: 4_800))
        cut.feed(silence(frames: 480))
        cut.feed(tone(frames: 4_800))
        #expect(cut.dropoutCount == 1)
    }

    @Test("quiet audio is not audible enough: the gap counts from -50 dBFS (0.003) up")
    func audibleThreshold() {
        for (amplitude, expected) in [(Float(0.0029), UInt32(0)), (Float(0.003), UInt32(1)), (Float(0.3), UInt32(1))] {
            var d = DropoutDetector(sampleRate: testRate)
            d.feed(square(frames: 4_800, amplitude: amplitude))
            d.feed(silence(frames: 480))
            d.feed(square(frames: 4_800, amplitude: amplitude))
            #expect(d.dropoutCount == expected, "amplitude \(amplitude)")
        }
    }

    @Test("the recent level halves every 5 ms: audio that died away over 20 ms is still audible, over 30 ms is not")
    func levelHalvesInFiveMilliseconds() {
        // 0.1 loud, then a 1e-6 whisper (never zero) for a while, then the gap. Starting at 0.1, the level
        // reaches 0.003 after 5 ms x log2(0.1 / 0.003), about 25 ms.
        for (whisperFrames, expected) in [(960, UInt32(1)), (1_440, UInt32(0))] {
            var d = DropoutDetector(sampleRate: testRate)
            d.feed(square(frames: 4_800, amplitude: 0.1))
            d.feed(square(frames: whisperFrames, amplitude: 0.000_001))
            d.feed(silence(frames: 480))
            d.feed(tone(frames: 4_800))
            #expect(d.dropoutCount == expected, "\(whisperFrames) whisper frames")
        }
    }

    @Test("negative zero is zero")
    func negativeZero() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        d.feed([Float](repeating: -0.0, count: 480 * 2))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 1)
    }

    @Test("a non-finite sample is signal, not silence, and does not poison what follows")
    func nonFiniteSample() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        d.feed([Float.nan, Float.nan])
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 0)

        d.feed(silence(frames: 480))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 1)
    }
}

@Suite("DropoutDetector: channels")
struct DropoutDetectorChannelTests {

    @Test("a stereo signal with one silent channel is not a gap")
    func oneSilentChannel() {
        var d = DropoutDetector(sampleRate: testRate)
        var oneSided: [Float] = []
        for sample in tone(frames: 9_600, channels: 1) { oneSided += [sample, 0] }
        d.feed(oneSided)
        #expect(d.dropoutCount == 0)

        // Left stays silent while the right has the gap: still no frame with every channel at zero.
        var rightOnly: [Float] = []
        for sample in tone(frames: 4_800, channels: 1) { rightOnly += [0, sample] }
        d.feed(rightOnly)
        #expect(d.dropoutCount == 0)
    }

    @Test("a real two-channel gap in the same stream does count")
    func bothChannelsZero() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        d.feed(silence(frames: 480))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 1)
    }

    @Test("a frame is silent only when all of six channels are")
    func sixChannels() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800, channels: 6), channels: 6)
        var lastChannelOnly = silence(frames: 480, channels: 6)
        for frame in 0..<480 { lastChannelOnly[frame * 6 + 5] = 0.1 }
        d.feed(lastChannelOnly, channels: 6)
        d.feed(tone(frames: 4_800, channels: 6), channels: 6)
        #expect(d.dropoutCount == 0)

        d.feed(silence(frames: 480, channels: 6), channels: 6)
        d.feed(tone(frames: 4_800, channels: 6), channels: 6)
        #expect(d.dropoutCount == 1)
    }

    @Test("mono works")
    func mono() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800, channels: 1), channels: 1)
        d.feed(silence(frames: 480, channels: 1), channels: 1)
        d.feed(tone(frames: 4_800, channels: 1), channels: 1)
        #expect(d.dropoutCount == 1)
        #expect(abs(d.lastDropoutSeconds - 0.010) < 1e-9)
    }
}

@Suite("DropoutDetector: silent-buffer fast path, reset and configuration")
struct DropoutDetectorStateTests {

    private enum Segment {
        case audio(Int)
        case silent(Int)
    }

    private func run(_ script: [Segment], rate: Double = testRate) -> (scanned: [DropoutDetector], fast: [DropoutDetector]) {
        var scanned = DropoutDetector(sampleRate: rate)
        var fast = DropoutDetector(sampleRate: rate)
        var scannedStates: [DropoutDetector] = []
        var fastStates: [DropoutDetector] = []
        for segment in script {
            switch segment {
            case .audio(let frames):
                let samples = tone(frames: frames)
                scanned.feed(samples)
                fast.feed(samples)
            case .silent(let frames):
                scanned.feed(silence(frames: frames))
                fast.addSilence(frames: frames)
            }
            scannedStates.append(scanned)
            fastStates.append(fast)
        }
        return (scannedStates, fastStates)
    }

    @Test("the all-zero fast path leaves the detector exactly as scanning the zeros does")
    func fastPathMatchesScan() {
        let scripts: [[Segment]] = [
            [.audio(4_800), .silent(480), .audio(4_800)],
            [.audio(4_800), .silent(200), .silent(280), .audio(4_800)],
            [.audio(4_800), .silent(14_400), .audio(4_800), .silent(480), .audio(4_800)],
            [.silent(480), .audio(4_800)],
            [.audio(4_800), .silent(12_000), .audio(100), .silent(12_001), .audio(100)],
            [.audio(4_800), .silent(24), .audio(10), .silent(48), .audio(10), .silent(3_000), .audio(10)],
        ]
        for script in scripts {
            let states = run(script)
            #expect(states.scanned == states.fast)
        }
        let counted = run(scripts[0])
        #expect(counted.fast.last?.dropoutCount == 1)
        #expect(counted.scanned.last?.dropoutCount == 1)
    }

    @Test("the fast path ignores empty and negative frame counts")
    func fastPathNoOps() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        let before = d
        d.addSilence(frames: 0)
        d.addSilence(frames: -10)
        #expect(d == before)
    }

    @Test("empty buffers change nothing")
    func emptyBuffers() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        let before = d
        let sample: [Float] = [0.5, 0.5]
        sample.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            d.process(base, frames: 0, channels: 2)
            d.process(base, frames: 1, channels: 0)
            d.process(base, frames: -3, channels: 2)
        }
        #expect(d == before)
    }

    @Test("reset clears the level and a run in progress but keeps the count and the latest length")
    func resetKeepsTheCount() {
        var d = DropoutDetector(sampleRate: testRate)
        d.feed(tone(frames: 4_800))
        d.feed(silence(frames: 480))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 1)

        d.reset()
        #expect(d.dropoutCount == 1)
        #expect(abs(d.lastDropoutSeconds - 0.010) < 1e-9)

        // No level left: a gap right after the reset has no audible audio before it.
        d.feed(silence(frames: 480))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 1)

        // The count only grows from there.
        d.feed(silence(frames: 480))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 2)

        // A run that was open when the tap changed hands is gone: the rest of it has no audible audio before it.
        d.feed(tone(frames: 4_800))
        d.feed(silence(frames: 200))
        d.reset()
        d.feed(silence(frames: 280))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 2)
    }

    @Test("reset keeps the thresholds: a gap counts again afterwards")
    func resetKeepsConfiguration() {
        var d = DropoutDetector(sampleRate: 16_000)
        d.reset()
        #expect(d.minGapFrames == 16)
        #expect(d.maxGapFrames == 4_000)

        d.feed(tone(frames: 1_600))
        d.feed(silence(frames: 160))
        d.feed(tone(frames: 1_600))
        #expect(d.dropoutCount == 1)
        #expect(abs(d.lastDropoutSeconds - 0.010) < 1e-9)
    }

    @Test("thresholds follow the sample rate: 1 ms and 250 ms in frames")
    func thresholdsFollowTheRate() {
        let cases: [(rate: Double, min: Int, max: Int)] = [
            (48_000, 48, 12_000),
            (44_100, 44, 11_025),
            (16_000, 16, 4_000),
            (8_000, 8, 2_000),
            (96_000, 96, 24_000),
        ]
        for c in cases {
            let d = DropoutDetector(sampleRate: c.rate)
            #expect(d.minGapFrames == c.min, "min at \(c.rate)")
            #expect(d.maxGapFrames == c.max, "max at \(c.rate)")
        }
    }

    @Test("a 10 ms gap counts at 16 kHz and a 0.5 ms one does not")
    func lowRateGaps() {
        var d = DropoutDetector(sampleRate: 16_000)
        d.feed(tone(frames: 1_600))
        d.feed(silence(frames: 8))
        d.feed(tone(frames: 1_600))
        #expect(d.dropoutCount == 0)
        d.feed(silence(frames: 160))
        d.feed(tone(frames: 1_600))
        #expect(d.dropoutCount == 1)
        #expect(abs(d.lastDropoutSeconds - 0.010) < 1e-9)
    }

    @Test("an unusable rate falls back to 48 kHz, as the output gate windows do")
    func invalidRates() {
        let reference = DropoutDetector(sampleRate: 48_000)
        for bad in [0.0, -44_100, .nan, .infinity, -.infinity] {
            #expect(DropoutDetector(sampleRate: bad) == reference)
        }
        #expect(DropoutDetector() == reference, "the default is 48 kHz")
    }

    @Test("configure re-rates the thresholds and starts the run over, keeping the count")
    func configureResets() {
        var d = DropoutDetector(sampleRate: 48_000)
        d.feed(tone(frames: 4_800))
        d.feed(silence(frames: 480))
        d.feed(tone(frames: 4_800))
        #expect(d.dropoutCount == 1)

        d.configure(sampleRate: 16_000)
        #expect(d.dropoutCount == 1)
        #expect(d.minGapFrames == 16)
        #expect(d.maxGapFrames == 4_000)

        // A 10 ms gap at the new rate is 160 frames, and it adds to the count.
        d.feed(tone(frames: 1_600))
        d.feed(silence(frames: 160))
        d.feed(tone(frames: 1_600))
        #expect(d.dropoutCount == 2)
    }

    @Test("two thousand dropouts in a long stream are all counted")
    func manyDropouts() {
        var d = DropoutDetector(sampleRate: testRate)
        // 50 ms of tone and a 10 ms gap, over and over, in one reused buffer.
        var cycle = tone(frames: 2_400)
        cycle += silence(frames: 480)
        for _ in 0..<2_000 { d.feed(cycle) }
        d.feed(tone(frames: 2_400))
        #expect(d.dropoutCount == 2_000)
        #expect(abs(d.lastDropoutSeconds - 0.010) < 1e-9)
    }
}
