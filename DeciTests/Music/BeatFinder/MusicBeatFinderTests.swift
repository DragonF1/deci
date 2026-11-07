// DeciTests/Music/BeatFinder/MusicBeatFinderTests.swift
// The beat finder on synthetic drum tracks with known beat times, and on degenerate input.

import Foundation
import Testing
@testable import Deci

@Suite("MusicBeatFinder")
struct MusicBeatFinderTests {
    private static func expectNoNaN(_ result: MusicBeatResult) {
        #expect(result.bpm.isFinite)
        #expect(result.confidence.isFinite)
        #expect(result.intervalSpread.isFinite)
        #expect(result.beats.allSatisfy { $0.isFinite })
        #expect(result.beats == result.beats.sorted())
        if let downbeat = result.downbeat { #expect(downbeat.confidence.isFinite && (0..<4).contains(downbeat.phase)) }
    }

    private static func expectExact(_ result: MusicBeatResult, _ track: BeatSynth.Track, bpm: Double) {
        expectNoNaN(result)
        #expect(abs(result.bpm / bpm - 1) < 0.005, "tempo \(result.bpm) for \(bpm)")
        #expect(result.beats.count == track.beats.count, "beat count \(result.beats.count) vs \(track.beats.count)")
        #expect(BeatSynth.worstError(estimated: result.beats, reference: track.beats) < 0.010)
        #expect(BeatSynth.fMeasure(estimated: result.beats, reference: track.beats) == 1.0)
    }

    @Test("kick tracks: tempo within 0.5 percent, beats within 10 ms, F-measure 1", arguments: [90.0, 120, 128, 140, 174])
    func kicks(bpm: Double) {
        let track = BeatSynth.pulse(bpm: bpm, seconds: 30, click: false)
        Self.expectExact(MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate), track, bpm: bpm)
    }

    @Test("click tracks: tempo within 0.5 percent, beats within 10 ms, F-measure 1", arguments: [90.0, 120, 128, 140, 174])
    func clicks(bpm: Double) {
        let track = BeatSynth.pulse(bpm: bpm, seconds: 30, click: true)
        Self.expectExact(MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate), track, bpm: bpm)
    }

    @Test("other sample rates give the same answer", arguments: [22_050.0, 32_000, 48_000, 96_000])
    func sampleRates(rate: Double) {
        let track = BeatSynth.pulse(bpm: 128, seconds: 20, sampleRate: rate, click: false)
        Self.expectExact(MusicBeatFinder.analyze(samples: track.samples, sampleRate: rate), track, bpm: 128)
    }

    @Test("swung and syncopated groove: quarter notes are found", arguments: [100.0, 130])
    func swing(bpm: Double) {
        let track = BeatSynth.swungGroove(bpm: bpm, seconds: 40)
        let result = MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate)
        Self.expectNoNaN(result)
        #expect(abs(result.bpm / bpm - 1) < 0.01, "tempo \(result.bpm)")
        #expect(BeatSynth.fMeasure(estimated: result.beats, reference: track.beats) >= 0.95)
    }

    @Test("near the 60 and 200 edges the tempo is right or an exact octave", arguments: [62.0, 65, 190, 198])
    func edges(bpm: Double) {
        let track = BeatSynth.pulse(bpm: bpm, seconds: 40, click: false)
        let result = MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate)
        Self.expectNoNaN(result)
        let ratio = result.bpm / bpm
        let matches = [1.0, 0.5, 2.0].contains { abs(ratio / $0 - 1) < 0.005 }
        #expect(matches, "tempo \(result.bpm) for \(bpm)")
        // Whatever octave it chose, every beat sits on a real hit.
        #expect(BeatSynth.worstError(estimated: result.beats, reference: track.beats) < 0.010)
    }

    @Test("accented third beat: downbeat phase 2")
    func downbeat() throws {
        let track = BeatSynth.accentedBars(bpm: 120, seconds: 40)
        let result = MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate)
        let first = try #require(result.beats.first)
        #expect(abs(first - track.beats[0]) < 0.010)
        let downbeat = try #require(result.downbeat)
        #expect(downbeat.phase == 2)
        #expect(downbeat.confidence > 0.05)
    }

    @Test("a flat pulse has no preferred bar start")
    func flatDownbeat() {
        let track = BeatSynth.pulse(bpm: 120, seconds: 30, click: false)
        let result = MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate)
        #expect((result.downbeat?.confidence ?? 0) < 0.2)
    }

    // MARK: Degenerate input

    @Test("empty, silent and very short input give an empty result")
    func degenerate() {
        #expect(MusicBeatFinder.analyze(samples: [], sampleRate: 44_100).isEmpty)
        #expect(MusicBeatFinder.analyze(samples: [0.5], sampleRate: 44_100).isEmpty)
        #expect(MusicBeatFinder.analyze(samples: [Float](repeating: 0, count: 44_100 * 30), sampleRate: 44_100).isEmpty)
        let shortTrack = BeatSynth.pulse(bpm: 120, seconds: 2, click: false)
        #expect(MusicBeatFinder.analyze(samples: shortTrack.samples, sampleRate: shortTrack.sampleRate).isEmpty)
        #expect(MusicBeatFinder.analyze(samples: shortTrack.samples, sampleRate: 0).isEmpty)
        #expect(MusicBeatFinder.analyze(samples: shortTrack.samples, sampleRate: .nan).isEmpty)
        #expect(MusicBeatFinder.analyze(samples: shortTrack.samples, sampleRate: -44_100).isEmpty)
    }

    @Test("non-finite samples give an empty result, never NaN")
    func nonFinite() {
        var track = BeatSynth.pulse(bpm: 120, seconds: 20, click: false)
        track.samples[1_000] = .nan
        let nan = MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate)
        #expect(nan.isEmpty)
        track.samples[1_000] = .infinity
        #expect(MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate).isEmpty)
    }

    @Test("a constant level, white noise and a pure tone never crash or produce NaN")
    func structureless() {
        let rate = 44_100.0
        let count = Int(rate * 20)
        let constant = [Float](repeating: 0.3, count: count)
        let noise = BeatSynth.noiseTemplate(sampleRate: rate, ms: 20_000, decay: 0, seed: 3)
        let tone = (0..<count).map { Float(sin(2 * Double.pi * 440 * Double($0) / rate)) * 0.5 }
        for samples in [constant, noise, tone] {
            let result = MusicBeatFinder.analyze(samples: samples, sampleRate: rate)
            Self.expectNoNaN(result)
            if !result.isEmpty { #expect(result.bpm >= 30 && result.bpm <= 400) }
        }
    }

    @Test("the same input gives the same result twice")
    func deterministic() {
        let track = BeatSynth.swungGroove(bpm: 118, seconds: 30)
        let first = MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate)
        let second = MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate)
        #expect(first == second)
    }

    @Test("a very quiet track still tracks (the envelope is level independent)")
    func quiet() {
        var track = BeatSynth.pulse(bpm: 120, seconds: 30, click: false)
        track.samples = track.samples.map { $0 * 0.0005 }
        let result = MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate)
        #expect(abs(result.bpm / 120 - 1) < 0.005)
    }

    @Test("a four minute song is analysed within the budget")
    func runtime() {
        let track = BeatSynth.swungGroove(bpm: 124, seconds: 240)
        let clock = ContinuousClock()
        var result = MusicBeatResult.empty
        let elapsed = clock.measure { result = MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate) }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("beat finder 4 min: \(String(format: "%.3f", seconds)) s")
        #expect(abs(result.bpm / 124 - 1) < 0.01)
        #if DEBUG
        #expect(seconds < 3, "debug budget")
        #else
        #expect(seconds < 1, "release budget")
        #endif
    }

    @Test("a tiny-amplitude track (subnormal power) gives an empty result, never NaN")
    func tiny() {
        var track = BeatSynth.pulse(bpm: 120, seconds: 20, click: false)
        track.samples = track.samples.map { $0 * 1e-24 }
        let result = MusicBeatFinder.analyze(samples: track.samples, sampleRate: track.sampleRate)
        Self.expectNoNaN(result)
        #expect(result.isEmpty)
    }

    @Test("decodeMono stops at maxSeconds and the default cap is ten minutes")
    func decodeCap() async throws {
        #expect(MusicBeatDecoder.defaultMaxSeconds == 600)
        let url = URL(fileURLWithPath: "/Volumes/Storage/_test/deci-3a/decode-cap.m4a")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let track = BeatSynth.pulse(bpm: 120, seconds: 6, click: false)
        var stereo = [Float](repeating: 0, count: track.samples.count * 2)
        for (index, value) in track.samples.enumerated() { stereo[index * 2] = value; stereo[index * 2 + 1] = value }
        try? FileManager.default.removeItem(at: url)
        try await ToneFile.write(interleavedStereo: stereo, sampleRate: 44_100, to: url)
        let capped = try await MusicBeatDecoder.decodeMono(file: url, maxSeconds: 2)
        #expect(capped.sampleRate == 44_100)
        #expect(abs(Double(capped.samples.count) / 44_100 - 2) < 0.2)
        let full = try await MusicBeatDecoder.decodeMono(file: url)
        #expect(Double(full.samples.count) / 44_100 > 5)
    }
}
