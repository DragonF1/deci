// DeciTests/Music/MixShuffle/MusicKeyDetectorTests.swift
// Key detection from chroma, the Camelot table, the stored key payload and the energy rating.

import Foundation
import Testing
@testable import Deci

@Suite("MusicKeyDetector")
struct MusicKeyDetectorTests {
    /// Chroma with weight on the given pitch classes, a little on the rest.
    private static func chroma(_ classes: [Int], weight: Float = 1) -> [Float] {
        var out = [Float](repeating: 0.05, count: 12)
        for pc in classes { out[pc % 12] = weight }
        return out
    }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Mono audio of chords one after another (three harmonics per note), fed to the detector in odd-sized pieces.
    private static func detect(
        chords: [[Double]], secondsPerChord: Double = 2, repeats: Int = 1, sampleRate: Double = 44_100
    ) -> (tonic: Int, isMinor: Bool, confidence: Float) {
        let per = Int(secondsPerChord * sampleRate)
        let frames = per * chords.count * repeats
        var samples = [Float](repeating: 0, count: frames)
        for (slot, notes) in (0..<(chords.count * repeats)).map({ ($0, chords[$0 % chords.count]) }) {
            for note in notes {
                for (harmonic, gain) in [(1.0, 1.0), (2.0, 0.5), (3.0, 0.25)] {
                    let step = 2 * Double.pi * note * harmonic / sampleRate
                    for index in 0..<per { samples[slot * per + index] += Float(gain * 0.1 * sin(step * Double(index))) }
                }
            }
        }
        let detector = MusicKeyDetector(sampleRate: sampleRate)
        var offset = 0
        while offset < frames {
            let take = min(1777, frames - offset)
            samples.withUnsafeBufferPointer { detector.consume(interleaved: $0.baseAddress! + offset, frames: take, channels: 1) }
            offset += take
        }
        return MusicKeyDetector.classify(chroma: detector.finish())
    }

    private static func detect(notes: [Double], sampleRate: Double = 44_100, seconds: Double = 8) -> (tonic: Int, isMinor: Bool, confidence: Float) {
        detect(chords: [notes], secondsPerChord: seconds, sampleRate: sampleRate)
    }

    // Triads in the octave around middle C.
    private static let C = [261.63, 329.63, 392.0], F = [174.61, 220.0, 261.63], G = [196.0, 246.94, 293.66]
    private static let Am = [220.0, 261.63, 329.63]

    @Test("an I-IV-V-vi progression in C is a trusted 8B")
    func progressionIsTrusted() {
        let result = Self.detect(chords: [Self.C, Self.F, Self.G, Self.Am], repeats: 2)
        print("FINDING I-IV-V-vi tonic=\(result.tonic) minor=\(result.isMinor) confidence=\(result.confidence)")
        let info = MusicKeyInfo(tonic: result.tonic, isMinor: result.isMinor, confidence: result.confidence, energy: 0)
        #expect(info.trustedCamelot == "8B", "got \(info.camelot) at \(result.confidence)")
    }

    @Test("a vi-IV-I-V progression in C is a trusted 8A or 8B")
    func minorFirstProgression() {
        let result = Self.detect(chords: [Self.Am, Self.F, Self.C, Self.G], repeats: 2)
        print("FINDING vi-IV-I-V tonic=\(result.tonic) minor=\(result.isMinor) confidence=\(result.confidence)")
        let info = MusicKeyInfo(tonic: result.tonic, isMinor: result.isMinor, confidence: result.confidence, energy: 0)
        let code = info.trustedCamelot
        #expect(code == "8A" || code == "8B", "got \(info.camelot) at \(result.confidence)")
    }

    @Test("room tone far under the music does not move the key")
    func quietFramesIgnored() {
        let rate = 44_100.0
        var generator = SeededGenerator(state: 7)
        let tone = Self.detect(chords: [Self.C], secondsPerChord: 6)
        #expect(tone.tonic == 0 && !tone.isMinor)
        // Loud C chord, then a long very quiet A minor tail (about 50 dB down).
        let loud = Int(4 * rate), quiet = Int(12 * rate)
        var samples = [Float](repeating: 0, count: loud + quiet)
        for note in Self.C { for index in 0..<loud { samples[index] += Float(0.1 * sin(2 * Double.pi * note * Double(index) / rate)) } }
        for note in [220.0, 277.18, 329.63] {
            for index in 0..<quiet { samples[loud + index] += Float(0.0003 * sin(2 * Double.pi * note * Double(index) / rate)) }
        }
        _ = generator.next()
        let detector = MusicKeyDetector(sampleRate: rate)
        samples.withUnsafeBufferPointer { detector.consume(interleaved: $0.baseAddress!, frames: samples.count, channels: 1) }
        let result = MusicKeyDetector.classify(chroma: detector.finish())
        #expect(result.tonic == 0 && !result.isMinor, "tonic \(result.tonic) minor \(result.isMinor)")
    }

    @Test("a C major triad in chroma is C major, 8B")
    func cMajorChroma() {
        let result = MusicKeyDetector.classify(chroma: Self.chroma([0, 4, 7]))
        #expect(result.tonic == 0 && !result.isMinor)
        #expect(MusicKeyInfo(tonic: result.tonic, isMinor: result.isMinor, confidence: result.confidence, energy: 0).camelot == "8B")
    }

    @Test("an A minor triad in chroma is A minor, 8A")
    func aMinorChroma() {
        let result = MusicKeyDetector.classify(chroma: Self.chroma([9, 0, 4]))
        #expect(result.tonic == 9 && result.isMinor)
        #expect(MusicKeyInfo(tonic: result.tonic, isMinor: result.isMinor, confidence: result.confidence, energy: 0).camelot == "8A")
    }

    @Test("rotating the chroma by k rotates the tonic by k")
    func rotation() {
        let base = Self.chroma([0, 4, 7, 2, 9], weight: 1)
        let start = MusicKeyDetector.classify(chroma: base)
        for k in 0..<12 {
            let rotated = (0..<12).map { base[($0 - k + 12) % 12] }
            let result = MusicKeyDetector.classify(chroma: rotated)
            #expect(result.tonic == (start.tonic + k) % 12, "k \(k)")
            #expect(result.isMinor == start.isMinor)
        }
    }

    @Test("a flat chroma and an empty or short one have no confidence")
    func flatChroma() {
        #expect(MusicKeyDetector.classify(chroma: [Float](repeating: 1, count: 12)).confidence < 0.15)
        #expect(MusicKeyDetector.classify(chroma: [Float](repeating: 0, count: 12)).confidence == 0)
        #expect(MusicKeyDetector.classify(chroma: []).confidence == 0)
        #expect(MusicKeyDetector.classify(chroma: [1, 2, 3]).confidence == 0)
    }

    @Test("white noise audio has confidence under 0.15")
    func whiteNoise() {
        var generator = SeededGenerator(state: 42)
        let frames = 22_050 * 8
        let samples = (0..<frames).map { _ in Float.random(in: -0.3...0.3, using: &generator) }
        let detector = MusicKeyDetector(sampleRate: 22_050)
        samples.withUnsafeBufferPointer { detector.consume(interleaved: $0.baseAddress!, frames: frames, channels: 1) }
        let result = MusicKeyDetector.classify(chroma: detector.finish())
        #expect(result.confidence < 0.15, "confidence \(result.confidence)")
    }

    @Test("synthetic C major chord audio is C major at 44.1 kHz")
    func cMajorAudio() {
        let result = Self.detect(notes: Self.C)
        #expect(result.tonic == 0 && !result.isMinor, "tonic \(result.tonic) minor \(result.isMinor)")
        #expect(result.confidence > 0.05)
    }

    @Test("synthetic A minor chord audio is A minor at 48 kHz")
    func aMinorAudio() {
        let result = Self.detect(notes: [220.0, 261.63, 329.63], sampleRate: 48_000)
        #expect(result.tonic == 9 && result.isMinor, "tonic \(result.tonic) minor \(result.isMinor)")
    }

    @Test("stereo input is mixed down and silence gives a zero chroma")
    func stereoAndSilence() {
        let detector = MusicKeyDetector(sampleRate: 44_100)
        let silence = [Float](repeating: 0, count: 44_100 * 2 * 3)
        silence.withUnsafeBufferPointer { detector.consume(interleaved: $0.baseAddress!, frames: 44_100 * 3, channels: 2) }
        let chroma = detector.finish()
        #expect(chroma.count == 12)
        #expect(chroma.allSatisfy { $0 == 0 })
        #expect(detector.meanCentroidHz == 0)
    }

    @Test("every tonic and mode maps to one of 24 distinct Camelot codes")
    func camelotTable() {
        let majors = ["8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"]
        let minors = ["5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"]
        var seen = Set<String>()
        for tonic in 0..<12 {
            let major = MusicKeyInfo(tonic: tonic, isMinor: false, confidence: 1, energy: 0).camelot
            let minor = MusicKeyInfo(tonic: tonic, isMinor: true, confidence: 1, energy: 0).camelot
            #expect(major == majors[tonic], "major \(tonic) \(major)")
            #expect(minor == minors[tonic], "minor \(tonic) \(minor)")
            seen.insert(major); seen.insert(minor)
        }
        #expect(seen.count == 24)
    }

    @Test("encode and decode round-trip; truncated, padded and out-of-range data is nil")
    func payload() throws {
        let info = MusicKeyInfo(tonic: 6, isMinor: true, confidence: 0.42, energy: 0.77)
        #expect(MusicKeyInfo.decode(info.encode()) == info)
        let data = info.encode()
        for cut in 0..<data.count { #expect(MusicKeyInfo.decode(data.prefix(cut)) == nil, "cut \(cut)") }
        #expect(MusicKeyInfo.decode(data + Data([0])) == nil)
        var bad = data; bad[1] = 12
        #expect(MusicKeyInfo.decode(bad) == nil)
        var unknown = data; unknown[0] = 99
        #expect(MusicKeyInfo.decode(unknown) == nil)
        #expect(MusicKeyInfo.decode(Data()) == nil)
        for (confidence, energy) in [(Float.nan, Float(0.5)), (-0.1, 0.5), (2.5, 0.5), (0.5, 1.5), (0.5, -0.1), (.infinity, 0.5)] {
            let odd = MusicKeyInfo(tonic: 1, isMinor: false, confidence: confidence, energy: energy).encode()
            #expect(MusicKeyInfo.decode(odd) == nil, "confidence \(confidence) energy \(energy)")
        }
    }

    @Test("below 0.1 confidence the key is unknown to later phases but still decodes")
    func trusted() {
        let weak = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.09, energy: 0.5)
        let strong = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.1, energy: 0.5)
        #expect(weak.trustedCamelot == nil)
        #expect(strong.trustedCamelot == "8B")
        #expect(MusicKeyInfo.decode(weak.encode()) == weak)
    }

    @Test("rating rises with loudness and onset rate, and always sits in 0...1")
    func ratingMonotonic() {
        var previous: Float = -1
        for lufs in stride(from: -40.0, through: 0.0, by: 2.5) {
            let value = MusicEnergyRating.rate(lufs: lufs, bpm: 120, onsetRate: 1.5, centroidHz: 2000)
            #expect(value >= previous && (0...1).contains(value), "lufs \(lufs)")
            previous = value
        }
        previous = -1
        for onset in stride(from: 0.0, through: 6.0, by: 0.5) {
            let value = MusicEnergyRating.rate(lufs: -14, bpm: 120, onsetRate: onset, centroidHz: 2000)
            #expect(value >= previous && (0...1).contains(value), "onset \(onset)")
            previous = value
        }
        let quiet = MusicEnergyRating.rate(lufs: -30, bpm: 60, onsetRate: 0, centroidHz: 500)
        let loud = MusicEnergyRating.rate(lufs: -5, bpm: 180, onsetRate: 3, centroidHz: 5000)
        #expect(quiet == 0 && loud == 1)
    }

    @Test("rating copes with missing tempo and non-finite input")
    func ratingEdges() {
        let noTempo = MusicEnergyRating.rate(lufs: -14, bpm: nil, onsetRate: 1, centroidHz: 2000)
        #expect((0...1).contains(noTempo))
        #expect(MusicEnergyRating.rate(lufs: -.infinity, bpm: 120, onsetRate: 1, centroidHz: 2000) <= 1)
        #expect((0...1).contains(MusicEnergyRating.rate(lufs: .nan, bpm: .nan, onsetRate: .nan, centroidHz: .nan)))
    }

    @Test("onset rate counts rising edges of 3 dB or more")
    func onsetRate() {
        // 100 ms blocks, 0.5 dB per code: two jumps of 8 codes (4 dB) in 2 s, one small step of 4 codes (2 dB).
        var codes = [UInt8](repeating: 100, count: 20)
        for index in 5..<20 { codes[index] = 108 }
        for index in 12..<20 { codes[index] = 112 }
        for index in 15..<20 { codes[index] = 120 }
        let rate = MusicEnergyRating.onsetRate(energy: codes, duration: 2)
        #expect(abs(rate - 1.0) < 0.001, "rate \(rate)")
        #expect(MusicEnergyRating.onsetRate(energy: [], duration: 2) == 0)
        #expect(MusicEnergyRating.onsetRate(energy: codes, duration: 0) == 0)
    }
}
