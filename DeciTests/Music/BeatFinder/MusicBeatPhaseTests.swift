// DeciTests/Music/BeatFinder/MusicBeatPhaseTests.swift
// Tier 3b finder accuracy P1: the bass refiner finds the phase the bass attacks support whatever grid it starts from,
// and the attack time it measures on kicks with known onsets is exact to a few milliseconds.

import Foundation
import Testing
@testable import Deci

@Suite("MusicBeatPhase")
struct MusicBeatPhaseTests {
    static func decimated(_ track: BeatSynth.Track) -> (audio: [Float], rate: Double) {
        let decimator = MusicBeatDecimator(inputRate: track.sampleRate)
        track.samples.withUnsafeBufferPointer { decimator.consume(interleaved: $0.baseAddress!, frames: track.samples.count, channels: 1) }
        let (audio, rate) = decimator.finish()
        return (audio, rate)
    }

    /// Distance from `anchor` to the nearest true beat, signed, in seconds.
    static func phaseError(anchor: Double, period: Double, truth: Double) -> Double {
        var d = anchor - truth
        d -= (d / period).rounded() * period
        return d
    }

    @Test("a grid that starts half a beat, a quarter beat or 80 ms off is re-locked onto the kicks",
          arguments: [0.5, 0.25, -0.25, 0.4, 0.16])
    func relocks(fraction: Double) {
        let bpm = 120.0, offset = 0.3
        let period = 60 / bpm
        let track = BeatSynth.pulse(bpm: bpm, seconds: 40, offset: offset, click: false)
        let (audio, rate) = Self.decimated(track)
        let start = offset + fraction * period
        let result = MusicBeatFinder.refineOnBass(decimated: audio, rate: rate, period: period, anchor: start)
        let error = Self.phaseError(anchor: result.anchor, period: period, truth: offset)
        #expect(abs(error) <= 0.005, "error \(error * 1000) ms")
        #expect(result.confidence >= 0.9, "confidence \(result.confidence)")
    }

    @Test("the refined phase does not depend on where the search starts")
    func startIndependent() {
        let period = 0.5
        let track = BeatSynth.pulse(bpm: 120, seconds: 40, offset: 0.3, click: false)
        let (audio, rate) = Self.decimated(track)
        let anchors = [0.3, 0.38, 0.46, 0.14, 0.05].map {
            MusicBeatFinder.refineOnBass(decimated: audio, rate: rate, period: period, anchor: $0).anchor
        }
        for anchor in anchors {
            #expect(abs(Self.phaseError(anchor: anchor, period: period, truth: anchors[0])) <= 0.002)
        }
    }

    @Test("kicks with known onsets are measured within 3 ms, whatever their level", arguments: [90.0, 128, 150])
    func exactOnsets(bpm: Double) {
        // Alternate loud and soft kicks: a threshold relative to the peak must not move the start with the level.
        var samples = [Float](repeating: 0, count: 44_100 * 40)
        let kick = BeatSynth.kickTemplate(sampleRate: 44_100)
        var truth: [Double] = []
        var time = 0.4
        var index = 0
        while time < 38 {
            truth.append(time)
            BeatSynth.mix(kick, into: &samples, at: time, sampleRate: 44_100, gain: index % 2 == 0 ? 0.9 : 0.3)
            time += 60 / bpm
            index += 1
        }
        let (audio, rate) = Self.decimated(BeatSynth.Track(samples: samples, sampleRate: 44_100, beats: truth))
        let band = MusicBeatFinder.bassBand(audio, rate: rate)
        let onsets = MusicBeatFinder.bassOnsets(in: band)
        var errors: [Double] = []
        for beat in truth {
            if let near = onsets.min(by: { abs($0.time - beat) < abs($1.time - beat) }) { errors.append(near.time - beat) }
        }
        let sorted = errors.map(abs).sorted()
        let median = sorted[sorted.count / 2], worst = sorted[min(sorted.count - 1, Int(0.95 * Double(sorted.count)))]
        #expect(errors.count == truth.count)
        #expect(median <= 0.003 && worst <= 0.003, "median \(median * 1000) p95 \(worst * 1000) ms")
    }

    @Test("a lopsided cloud: the anchor sits on the dense core of the attacks, not their mean")
    func denseCore() {
        // Every beat has a kick; every third beat also a bass note 14 ms later that would pull a least squares line.
        var samples = [Float](repeating: 0, count: 44_100 * 40)
        let kick = BeatSynth.kickTemplate(sampleRate: 44_100)
        var time = 0.3
        var index = 0
        while time < 38 {
            BeatSynth.mix(kick, into: &samples, at: time, sampleRate: 44_100, gain: 0.9)
            if index % 3 == 0 { BeatSynth.mix(kick, into: &samples, at: time + 0.014, sampleRate: 44_100, gain: 0.6) }
            time += 0.5
            index += 1
        }
        let (audio, rate) = Self.decimated(BeatSynth.Track(samples: samples, sampleRate: 44_100, beats: []))
        let result = MusicBeatFinder.refineOnBass(decimated: audio, rate: rate, period: 0.5, anchor: 0.3)
        let error = Self.phaseError(anchor: result.anchor, period: 0.5, truth: 0.3)
        #expect(abs(error) <= 0.004, "error \(error * 1000) ms")
        #expect(result.confidence >= 0.6, "confidence \(result.confidence)")
    }
}
