// DeciTests/Music/BeatFinder/MusicBeatDecimatorTests.swift
// The streaming decimator against the one-shot `MusicBeatFinder.decimate`.

import Foundation
import Testing
@testable import Deci

@Suite("MusicBeatDecimator")
struct MusicBeatDecimatorTests {
    static func signal(rate: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { index in
            let t = Double(index) / rate
            return Float(0.5 * sin(2 * Double.pi * 440 * t) + 0.3 * sin(2 * Double.pi * 3_000 * t) + 0.1 * sin(2 * Double.pi * 61 * t))
        }
    }

    static func stream(_ samples: [Float], rate: Double, chunk: Int, channels: Int = 1, maxSeconds: Double = 600) -> (samples: [Float], rate: Double) {
        let decimator = MusicBeatDecimator(inputRate: rate, maxSeconds: maxSeconds)
        var interleaved = [Float]()
        interleaved.reserveCapacity(samples.count * channels)
        for sample in samples { for _ in 0..<channels { interleaved.append(sample) } }
        var frame = 0
        while frame < samples.count {
            let n = min(chunk, samples.count - frame)
            interleaved.withUnsafeBufferPointer {
                decimator.consume(interleaved: $0.baseAddress! + frame * channels, frames: n, channels: channels)
            }
            frame += n
        }
        return decimator.finish()
    }

    @Test("matches the one-shot decimate within 1e-6 for any chunk size", arguments: [44_100.0, 48_000], [1, 512, 4096, 99_999])
    func matchesOneShot(rate: Double, chunk: Int) throws {
        let samples = Self.signal(rate: rate, seconds: chunk == 1 ? 0.5 : 3)
        let expected = try #require(MusicBeatFinder.decimate(samples, sampleRate: rate))
        let got = Self.stream(samples, rate: rate, chunk: chunk)
        #expect(got.rate == expected.1)
        #expect(got.samples.count == expected.0.count, "count \(got.samples.count) vs \(expected.0.count)")
        let worst = zip(got.samples, expected.0).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-6, "worst \(worst)")
    }

    @Test("stereo input is averaged to mono")
    func stereo() throws {
        let samples = Self.signal(rate: 44_100, seconds: 2)
        let mono = Self.stream(samples, rate: 44_100, chunk: 4096, channels: 1)
        let stereo = Self.stream(samples, rate: 44_100, chunk: 4096, channels: 2)
        #expect(mono.samples.count == stereo.samples.count)
        #expect(zip(mono.samples, stereo.samples).map { abs($0 - $1) }.max() ?? 1 < 1e-6)
    }

    @Test("22.05 kHz input passes through unchanged")
    func passThrough() {
        let samples = Self.signal(rate: 22_050, seconds: 1)
        let got = Self.stream(samples, rate: 22_050, chunk: 1000)
        #expect(got.rate == 22_050)
        #expect(got.samples == samples)
    }

    @Test("input past maxSeconds is ignored")
    func cap() {
        let samples = Self.signal(rate: 44_100, seconds: 6)
        let got = Self.stream(samples, rate: 44_100, chunk: 4096, maxSeconds: 2)
        #expect(got.samples.count == 44_100)
        let reference = Self.stream(Array(samples.prefix(88_200)), rate: 44_100, chunk: 4096)
        #expect(got.samples == reference.samples)
    }

    @Test("a non-finite sample or no input gives an empty result")
    func degenerate() {
        var samples = Self.signal(rate: 44_100, seconds: 1)
        samples[1000] = .nan
        #expect(Self.stream(samples, rate: 44_100, chunk: 512).samples.isEmpty)
        #expect(MusicBeatDecimator(inputRate: 44_100).finish().samples.isEmpty)
    }
}
