// DeciTests/Music/MusicEchoDSPTests.swift
// Tier 4b P1: the echo-out delay line and the delayed fade.

import Foundation
import Testing
@testable import Deci

@Suite("MusicEchoDSP")
struct MusicEchoDSPTests {
    static let rate = 48_000.0

    static func settings(delay: Int = 100, cut: Int = 1, feedback: Float = 0.5, hz: Float = 20_000) -> MusicEchoSettings {
        MusicEchoSettings(delayFrames: delay, cutAfterFrames: cut, feedback: feedback, wetGain: 1, lowpassHz: hz)
    }

    static func impulse(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        out[0] = 1
        out[1] = 1
        return out
    }

    static func peak(_ samples: [Float], from: Int, to: Int) -> Float {
        (from..<min(to, samples.count / 2)).map { abs(samples[$0 * 2]) }.max() ?? 0
    }

    @Test("an impulse gives repeats one delay apart that decay by about the feedback")
    func decayingRepeats() {
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        echo.start(Self.settings())
        let frames = 2_000
        let out = echo.render(dry: Self.impulse(frames: frames), faded: [Float](repeating: 0, count: frames * 2))
        #expect(Self.peak(out, from: 0, to: 100) == 0)
        let first = Self.peak(out, from: 100, to: 130)
        let second = Self.peak(out, from: 200, to: 260)
        let third = Self.peak(out, from: 300, to: 400)
        #expect(first > 0.1)
        #expect(second > 0 && second < first)
        #expect(third > 0 && third < second)
        #expect(second / first < 0.8)
    }

    @Test("the tail is far below the start: under -40 dB after the repeats have run")
    func tailEnergy() {
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        echo.start(Self.settings(delay: 4_800))
        let frames = 4_800 * 16
        let out = echo.render(dry: Self.impulse(frames: frames), faded: [Float](repeating: 0, count: frames * 2))
        let head = Self.peak(out, from: 4_800, to: 4_900)
        let tail = Self.peak(out, from: 4_800 * 14, to: frames)
        #expect(head > 0.05)
        #expect(tail < head * 0.01)
    }

    @Test("the line is fed until the cut and not after: the dry that follows is never repeated")
    func fedUntilCut() {
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        echo.start(Self.settings(delay: 100, cut: 500))
        let frames = 3_000
        var dry = [Float](repeating: 0, count: frames * 2)
        for frame in 1_000..<2_000 { dry[frame * 2] = 1; dry[frame * 2 + 1] = 1 }
        let out = echo.render(dry: dry, faded: [Float](repeating: 0, count: frames * 2))
        #expect(Self.peak(out, from: 0, to: 600) == 0)
        #expect(Self.peak(out, from: 700, to: frames) == 0)
    }

    @Test("the dry signal passes through untouched and the repeats are added to it")
    func addsToDry() {
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        echo.start(Self.settings(cut: 1))
        let frames = 600
        let dry = Self.impulse(frames: frames)
        let out = echo.render(dry: dry, faded: dry)
        #expect(out[0] == 1)
        #expect(Self.peak(out, from: 100, to: 130) > 0.1)
    }

    @Test("the line is allocated once: its size never changes across starts and renders")
    func noAllocation() {
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        let capacity = echo.capacity
        #expect(capacity == Int(Self.rate) + 1)
        for delay in [1, 100, 48_000, 90_000, 0, -5] {
            echo.start(Self.settings(delay: delay))
            _ = echo.render(dry: Self.impulse(frames: 700), faded: [Float](repeating: 0, count: 1_400))
            #expect(echo.capacity == capacity)
        }
    }

    static func recordHistory(_ echo: MusicEchoDelay, _ history: [Float], block: Int = 512) {
        var at = 0
        let frames = history.count / 2
        history.withUnsafeBufferPointer { samples in
            while at < frames {
                let n = min(block, frames - at)
                echo.record(samples.baseAddress! + at * 2, frames: n)
                at += n
            }
        }
    }

    static func tone(frames: Int, level: Float = 0.8) -> [Float] {
        [Float](repeating: level, count: frames * 2)
    }

    @Test("the engine's real pattern: the request arrives late, then the last beat, then the cut; the first repeat is that beat")
    func lastBeatIsEchoed() {
        let delay = 4_800
        let cut = 240
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        // Silence, then most of the last beat is played before the request reaches the renderer.
        Self.recordHistory(echo, [Float](repeating: 0, count: 20_000 * 2))
        Self.recordHistory(echo, Self.tone(frames: delay - cut))
        echo.start(MusicEchoSettings(delayFrames: delay, cutAfterFrames: cut, feedback: 0.5, wetGain: 0.35, lowpassHz: 20_000))
        // The last `cut` frames of the beat are fed live; after the cut the song is gone (dry cut at once).
        var dry = Self.tone(frames: cut)
        dry += [Float](repeating: 0, count: (delay * 2) * 2)
        let frames = dry.count / 2
        let out = echo.render(dry: dry, faded: [Float](repeating: 0, count: frames * 2))
        // Nothing before the cut: no wet, no recirculation.
        #expect(Self.peak(out, from: 0, to: cut) == 0)
        // The first repeat holds the whole beat at about wet x level.
        let body = (cut + 500..<cut + delay - 500).map { out[$0 * 2] }
        let mean = body.reduce(0, +) / Float(body.count)
        #expect(abs(mean - 0.35 * 0.8) < 0.02)
        // The repeat is the first beat's start to its end: it starts at the cut and ends one delay later.
        #expect(Self.peak(out, from: cut, to: cut + 50) > 0.1)
        #expect(Self.peak(out, from: cut + delay + 200, to: cut + delay + 600) < 0.35 * 0.8 * 0.55)
    }

    @Test("nothing recirculates before the cut: a long feed adds no feedback to the first repeat")
    func noBuildUpWhileFed() {
        let delay = 1_000
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        echo.start(MusicEchoSettings(delayFrames: delay, cutAfterFrames: 20_000, feedback: 0.8, wetGain: 1, lowpassHz: 20_000))
        let dry = Self.tone(frames: 20_000, level: 1) + [Float](repeating: 0, count: 6_000 * 2)
        let frames = dry.count / 2
        let out = echo.render(dry: dry, faded: [Float](repeating: 0, count: frames * 2))
        #expect(Self.peak(out, from: 0, to: 20_000) == 0)
        // The first repeat after the cut is the song at its own level, not a stacked sum.
        #expect(Self.peak(out, from: 20_000, to: 20_000 + delay) <= 1.0001)
        #expect(Self.peak(out, from: 20_000, to: 20_000 + delay) > 0.9)
    }

    @Test("full-scale periodic input never gives a peak above 1.0 at the output, with the dry still sounding or not")
    func outputNeverClips() {
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        echo.start(MusicEchoSettings(delayFrames: 480, cutAfterFrames: 4_800, feedback: 0.5, wetGain: 1, lowpassHz: 20_000))
        let frames = 20_000
        var dry = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames { let v: Float = (frame / 60) % 2 == 0 ? 1 : -1; dry[frame * 2] = v; dry[frame * 2 + 1] = v }
        let summed = echo.render(dry: dry, faded: dry)
        #expect(Self.peak(summed, from: 0, to: frames) <= 1.0)
        let wetOnly = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        wetOnly.start(MusicEchoSettings(delayFrames: 480, cutAfterFrames: 4_800, feedback: 0.5, wetGain: MusicEchoSettings.defaultWetGain, lowpassHz: 20_000))
        let alone = wetOnly.render(dry: dry, faded: [Float](repeating: 0, count: frames * 2))
        #expect(Self.peak(alone, from: 0, to: frames) <= MusicEchoSettings.defaultWetGain + 0.001)
    }

    @Test("a release fades the wet to nothing across its length with no step, and the echo is over")
    func releaseRamps() {
        let ramp = 900
        let releaseAt = 3_072
        func run(release: Bool) -> (out: [Float], echo: MusicEchoDelay) {
            let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
            echo.start(MusicEchoSettings(delayFrames: 2_000, cutAfterFrames: 2_000, feedback: 0.5, wetGain: 1, lowpassHz: 20_000))
            let samples = Self.tone(frames: 2_000) + [Float](repeating: 0, count: 8_000 * 2)
            let frames = samples.count / 2
            var faded = [Float](repeating: 0, count: frames * 2)
            var at = 0
            while at < frames {
                let n = min(512, frames - at)
                if release && at == releaseAt { echo.beginRelease(frames: ramp) }
                samples.withUnsafeBufferPointer { dry in
                    faded.withUnsafeMutableBufferPointer { wet in
                        _ = echo.capture(dry.baseAddress! + at * 2, frames: n)
                        echo.mix(into: wet.baseAddress! + at * 2, frames: n)
                    }
                }
                at += n
            }
            return (faded, echo)
        }
        let reference = run(release: false).out
        let released = run(release: true)
        let out = released.out
        let frames = out.count / 2
        #expect(out[2_500 * 2] > 0.5)
        // Before the release it is the same signal; inside the ramp it is the reference times a straight line to zero.
        for frame in 2_000..<releaseAt { #expect(out[frame * 2] == reference[frame * 2]) }
        var lastGain: Float = 1
        for frame in releaseAt..<(releaseAt + ramp) {
            let gain = out[frame * 2] / reference[frame * 2]
            #expect(abs(gain - Float(releaseAt + ramp - frame - 1) / Float(ramp)) < 0.01)
            #expect(lastGain - gain < 0.01, "no step: \(lastGain) to \(gain)")
            lastGain = gain
        }
        #expect(Self.peak(out, from: releaseAt + ramp, to: frames) == 0)
        #expect(released.echo.isReleasedOut)
    }

    @Test("the history the line holds survives a start, and a record never overruns the line")
    func historyIsKept() {
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        // More than one line's worth, in odd block sizes, so the write position wraps.
        Self.recordHistory(echo, Self.tone(frames: echo.capacity * 2 + 77, level: 0.5), block: 311)
        echo.start(MusicEchoSettings(delayFrames: 100, cutAfterFrames: 1, feedback: 0.5, wetGain: 1, lowpassHz: 20_000))
        let out = echo.render(dry: [Float](repeating: 0, count: 400 * 2), faded: [Float](repeating: 0, count: 800))
        #expect(Self.peak(out, from: 10, to: 100) > 0.4)
    }

    @Test("a cleared history is silent: the first repeat after a seek holds nothing from before it")
    func clearedHistory() {
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 512)
        Self.recordHistory(echo, Self.tone(frames: 4_000, level: 0.5))
        echo.clearHistory()
        // After the seek only a little new audio (less than the delay) was recorded.
        Self.recordHistory(echo, Self.tone(frames: 100, level: 0.25))
        echo.start(MusicEchoSettings(delayFrames: 1_000, cutAfterFrames: 1, feedback: 0.5, wetGain: 1, lowpassHz: 20_000))
        let out = echo.render(dry: [Float](repeating: 0, count: 1_500 * 2), faded: [Float](repeating: 0, count: 3_000))
        // The repeat that lines up with the pre-seek audio is silent; only the 0.25 burst may come back.
        #expect(Self.peak(out, from: 0, to: 1_500) <= 0.2501)
        #expect(Self.peak(out, from: 0, to: 1_500) > 0.2)
    }

    @Test("a block longer than the copy is skipped, not overrun")
    func oversizedBlock() {
        let echo = MusicEchoDelay(sampleRate: Self.rate, maxBlockFrames: 64)
        echo.start(Self.settings())
        let big = [Float](repeating: 0.5, count: 256)
        let ok = big.withUnsafeBufferPointer { echo.capture($0.baseAddress!, frames: 128) }
        #expect(!ok)
    }

    @Test("a fade with a delay holds at full level, then ramps, the same in one block or many")
    func delayedFade() {
        let fade = MusicFade(value: 1, target: 0, step: -1.0 / 30, remaining: 40, curve: .linear, from: 1, total: 30, delay: 10)
        var whole = [Float](repeating: 1, count: 50)
        whole.withUnsafeMutableBufferPointer { fade.apply(to: $0.baseAddress!, frames: 50, channels: 1) }
        #expect(whole[0..<10].allSatisfy { $0 == 1 })
        #expect(whole[10] < 1 && whole[10] > 0.9)
        #expect(whole[39] == 0 && whole[45] == 0)
        for index in 11..<40 { #expect(whole[index] < whole[index - 1]) }

        var parts = [Float](repeating: 1, count: 50)
        var state = fade
        for chunk in [7, 13, 30] {
            let start = 7 == chunk ? 0 : (13 == chunk ? 7 : 20)
            parts.withUnsafeMutableBufferPointer { state.apply(to: $0.baseAddress! + start, frames: chunk, channels: 1) }
            state = state.advanced(by: chunk)
        }
        for index in 0..<50 { #expect(abs(parts[index] - whole[index]) < 1e-5) }
        #expect(state.remaining == 0 && state.value == 0 && state.delay == 0)
    }

    @Test("an equal-power fade with a delay holds then follows the curve and ends at the target")
    func delayedEqualPower() {
        let fade = MusicFade(value: 1, target: 0, step: 0, remaining: 30, curve: .equalPower, from: 1, total: 20, delay: 10)
        #expect(fade.heard(afterFrames: 5) == 1)
        #expect(fade.heard(afterFrames: 10) == 1)
        #expect(fade.heard(afterFrames: 20) < 1 && fade.heard(afterFrames: 20) > 0)
        #expect(fade.heard(afterFrames: 30) == 0)
    }
}
