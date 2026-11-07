// DeciTests/Music/BeatFinder/BeatSynth.swift
// Synthetic drum tracks with known beat times, and the scoring the beat finder tests share.

import Foundation
@testable import Deci

enum BeatSynth {
    struct Track {
        var samples: [Float]
        var sampleRate: Double
        /// The quarter-note beat times a listener would tap.
        var beats: [Double]
    }

    static func kickTemplate(sampleRate: Double, base: Double = 50) -> [Float] {
        var phase = 0.0
        return (0..<Int(0.2 * sampleRate)).map { index in
            let t = Double(index) / sampleRate
            phase += 2 * Double.pi * (base + 100 * exp(-t * 40)) / sampleRate
            return Float(sin(phase) * exp(-t * 25))
        }
    }

    /// Deterministic noise burst: a click (3 ms) or a hat or snare, depending on length and decay.
    static func noiseTemplate(sampleRate: Double, ms: Double, decay: Double, seed: UInt32) -> [Float] {
        var state = seed | 1
        return (0..<Int(ms / 1000 * sampleRate)).map { index in
            state = state &* 1_664_525 &+ 1_013_904_223
            let value = Float(Int32(bitPattern: state)) / Float(Int32.max)
            return value * Float(exp(-Double(index) / sampleRate * decay))
        }
    }

    static func mix(_ template: [Float], into buffer: inout [Float], at time: Double, sampleRate: Double, gain: Float) {
        let start = Int((time * sampleRate).rounded())
        guard start >= 0 else { return }
        for index in 0..<template.count where start + index < buffer.count {
            buffer[start + index] += gain * template[index]
        }
    }

    /// One drum hit per beat, `offset` seconds in.
    static func pulse(bpm: Double, seconds: Double, sampleRate: Double = 44_100, offset: Double = 0.3, click: Bool) -> Track {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let hit = click
            ? noiseTemplate(sampleRate: sampleRate, ms: 3, decay: 400, seed: 7)
            : kickTemplate(sampleRate: sampleRate)
        var beats: [Double] = []
        var time = offset
        while time < seconds - 0.25 {
            beats.append(time)
            mix(hit, into: &samples, at: time, sampleRate: sampleRate, gain: 0.85)
            time += 60 / bpm
        }
        return Track(samples: samples, sampleRate: sampleRate, beats: beats)
    }

    /// Kick on 1 and 3, snare on 2 and 4, swung off-beat hats (2/3 of the beat) and two syncopated extra kicks per bar.
    static func swungGroove(bpm: Double, seconds: Double, sampleRate: Double = 44_100) -> Track {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let kick = kickTemplate(sampleRate: sampleRate)
        let snare = noiseTemplate(sampleRate: sampleRate, ms: 120, decay: 30, seed: 11)
        let hat = noiseTemplate(sampleRate: sampleRate, ms: 25, decay: 150, seed: 13)
        let quarter = 60 / bpm
        var beats: [Double] = []
        var bar = 0.3
        while bar + 4 * quarter < seconds - 0.5 {
            for beat in 0..<4 {
                let time = bar + Double(beat) * quarter
                beats.append(time)
                if beat % 2 == 0 {
                    mix(kick, into: &samples, at: time, sampleRate: sampleRate, gain: 0.9)
                } else {
                    mix(snare, into: &samples, at: time, sampleRate: sampleRate, gain: 0.5)
                }
                mix(hat, into: &samples, at: time, sampleRate: sampleRate, gain: 0.25)
                mix(hat, into: &samples, at: time + quarter * 2 / 3, sampleRate: sampleRate, gain: 0.25)
            }
            mix(kick, into: &samples, at: bar + quarter * (1 + 2.0 / 3), sampleRate: sampleRate, gain: 0.7)
            mix(kick, into: &samples, at: bar + quarter * (2 + 2.0 / 3), sampleRate: sampleRate, gain: 0.6)
            bar += 4 * quarter
        }
        return Track(samples: samples, sampleRate: sampleRate, beats: beats)
    }

    /// 4/4 kick pattern whose third beat (index 2 of each bar) is the accented one, with off-beat hats between.
    static func accentedBars(bpm: Double, seconds: Double, sampleRate: Double = 44_100) -> Track {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let loud = kickTemplate(sampleRate: sampleRate, base: 45)
        let soft = kickTemplate(sampleRate: sampleRate, base: 60)
        let hat = noiseTemplate(sampleRate: sampleRate, ms: 20, decay: 200, seed: 17)
        let quarter = 60 / bpm
        var beats: [Double] = []
        var time = 0.3
        var index = 0
        while time < seconds - 0.5 {
            beats.append(time)
            mix(index % 4 == 2 ? loud : soft, into: &samples, at: time, sampleRate: sampleRate, gain: index % 4 == 2 ? 0.95 : 0.5)
            mix(hat, into: &samples, at: time + quarter / 2, sampleRate: sampleRate, gain: 0.2)
            time += quarter
            index += 1
        }
        return Track(samples: samples, sampleRate: sampleRate, beats: beats)
    }

    // MARK: Scoring

    /// mir_eval style: each reference beat matches at most one estimate within `window`; returns F, precision, recall.
    static func fMeasure(estimated: [Double], reference: [Double], window: Double = 0.07) -> Double {
        guard !estimated.isEmpty, !reference.isEmpty else { return 0 }
        var used = Set<Int>()
        var hits = 0
        for beat in estimated {
            let candidates = reference.indices.filter { !used.contains($0) && abs(reference[$0] - beat) <= window }
            if let best = candidates.min(by: { abs(reference[$0] - beat) < abs(reference[$1] - beat) }) {
                used.insert(best)
                hits += 1
            }
        }
        let precision = Double(hits) / Double(estimated.count)
        let recall = Double(hits) / Double(reference.count)
        return precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
    }

    /// Largest distance from an estimated beat to the nearest reference beat.
    static func worstError(estimated: [Double], reference: [Double]) -> Double {
        estimated.map { beat in reference.map { abs($0 - beat) }.min() ?? .infinity }.max() ?? .infinity
    }
}
