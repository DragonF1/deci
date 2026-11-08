// DeciTests/Music/BeatFinder/MusicBeatGridAccuracyTests.swift
// The beat grid on synthetic drum tracks with known beat times: phase accuracy after the bass refinement, downbeat,
// and the cases that must give a low confidence or no grid at all.

import Foundation
import Testing
@testable import Deci

@Suite("MusicBeatGridAccuracy")
struct MusicBeatGridAccuracyTests {
    /// The route the app takes: streaming decimator in chunks, the finder on its output, then the grid.
    static func grid(_ track: BeatSynth.Track) -> MusicBeatGrid? {
        let decimator = MusicBeatDecimator(inputRate: track.sampleRate)
        let samples = track.samples
        var frame = 0
        while frame < samples.count {
            let n = min(8192, samples.count - frame)
            samples.withUnsafeBufferPointer { decimator.consume(interleaved: $0.baseAddress! + frame, frames: n, channels: 1) }
            frame += n
        }
        let (audio, rate) = decimator.finish()
        let result = MusicBeatFinder.analyze(decimated: audio, rate: rate)
        return MusicBeatFinder.grid(from: result, decimated: audio, rate: rate)
    }

    /// Signed error of the grid's beat nearest to each true beat inside the span, in seconds.
    static func beatErrors(_ grid: MusicBeatGrid, _ truth: [Double]) -> [Double] {
        truth.filter { $0 >= grid.spanStartSec - 0.05 && $0 <= grid.spanEndSec + 0.05 }.map { beat in
            let k = ((beat - grid.anchorSec) / grid.periodSec).rounded()
            return grid.beatTime(Int(k)) - beat
        }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.map(abs).sorted()
        return sorted[min(sorted.count - 1, Int(p * Double(sorted.count - 1) + 0.5))]
    }

    static func report(_ name: String, _ errors: [Double]) {
        print(String(format: "GRIDERR %@ n=%d median=%.2fms p95=%.2fms", name, errors.count,
                     percentile(errors, 0.5) * 1000, percentile(errors, 0.95) * 1000))
    }

    @Test("kick tracks: grid beats within 5 ms median and 10 ms p95 of the true kicks",
          arguments: [90.0, 120, 128, 140, 174], [44_100.0, 48_000])
    func kicks(bpm: Double, rate: Double) throws {
        let track = BeatSynth.pulse(bpm: bpm, seconds: 40, sampleRate: rate, offset: 0.13, click: false)
        let grid = try #require(Self.grid(track))
        let errors = Self.beatErrors(grid, track.beats)
        Self.report("kick \(Int(bpm)) @\(Int(rate))", errors)
        #expect(abs(grid.bpm / bpm - 1) < 0.002, "bpm \(grid.bpm)")
        #expect(errors.count >= track.beats.count - 4)
        #expect(Self.percentile(errors, 0.5) <= 0.005)
        #expect(Self.percentile(errors, 0.95) <= 0.010)
        #expect(grid.beatConfidence >= 0.9, "confidence \(grid.beatConfidence)")
        #expect(abs(grid.driftSec) < 0.001)
        #expect(grid.spanStartSec >= 0 && grid.spanEndSec <= 40)
    }

    @Test("slow-attack kick under louder hats: within 12 ms (a 25 ms ramp has no sharper onset)")
    func slowAttack() throws {
        let rate = 44_100.0
        var samples = [Float](repeating: 0, count: Int(40 * rate))
        let rise = Int(0.025 * rate)
        var kick = BeatSynth.kickTemplate(sampleRate: rate)
        for index in 0..<rise { kick[index] *= Float(index) / Float(rise) }
        let hat = BeatSynth.noiseTemplate(sampleRate: rate, ms: 25, decay: 150, seed: 13)
        let quarter = 60.0 / 124
        var beats: [Double] = []
        var time = 0.13
        while time < 39.5 {
            beats.append(time)
            BeatSynth.mix(kick, into: &samples, at: time, sampleRate: rate, gain: 0.6)
            BeatSynth.mix(hat, into: &samples, at: time, sampleRate: rate, gain: 0.7)
            BeatSynth.mix(hat, into: &samples, at: time + quarter / 2, sampleRate: rate, gain: 0.7)
            time += quarter
        }
        let track = BeatSynth.Track(samples: samples, sampleRate: rate, beats: beats)
        let grid = try #require(Self.grid(track))
        let errors = Self.beatErrors(grid, beats)
        Self.report("slow attack 124", errors)
        #expect(abs(grid.bpm / 124 - 1) < 0.002)
        #expect(Self.percentile(errors, 0.5) <= 0.012)
        #expect(Self.percentile(errors, 0.95) <= 0.012)
    }

    @Test("swung groove: quarter notes within 10 ms", arguments: [100.0, 130])
    func groove(bpm: Double) throws {
        let track = BeatSynth.swungGroove(bpm: bpm, seconds: 40)
        let grid = try #require(Self.grid(track))
        let errors = Self.beatErrors(grid, track.beats)
        Self.report("groove \(Int(bpm))", errors)
        #expect(abs(grid.bpm / bpm - 1) < 0.005)
        #expect(Self.percentile(errors, 0.5) <= 0.005)
        #expect(Self.percentile(errors, 0.95) <= 0.010)
    }

    /// Kicks on every beat of `bpm`, the ones with index % 4 == `accent` loud; hats between.
    static func accented(accent: Int?, bpm: Double = 120) -> BeatSynth.Track {
        let rate = 44_100.0
        var samples = [Float](repeating: 0, count: Int(40 * rate))
        let kick = BeatSynth.kickTemplate(sampleRate: rate)
        let hat = BeatSynth.noiseTemplate(sampleRate: rate, ms: 20, decay: 200, seed: 17)
        let quarter = 60 / bpm
        var beats: [Double] = []
        var time = 0.3
        var index = 0
        while time < 39.5 {
            beats.append(time)
            BeatSynth.mix(kick, into: &samples, at: time, sampleRate: rate, gain: index % 4 == accent ? 0.95 : 0.5)
            BeatSynth.mix(hat, into: &samples, at: time + quarter / 2, sampleRate: rate, gain: 0.2)
            time += quarter
            index += 1
        }
        return BeatSynth.Track(samples: samples, sampleRate: rate, beats: beats)
    }

    @Test("accent on every fourth kick: the downbeat phase matches the true bar start", arguments: [0, 1, 2, 3])
    func downbeat(accent: Int) throws {
        let track = Self.accented(accent: accent)
        let grid = try #require(Self.grid(track))
        let phase = try #require(grid.downbeatPhase, "no downbeat, confidence \(grid.downbeatConfidence)")
        #expect(grid.downbeatConfidence >= 0.25)
        // Which true beat is the grid's beat 0, and so which grid phase is the accented one.
        let nearest = Int(((grid.anchorSec - track.beats[0]) / grid.periodSec).rounded())
        let expected = ((accent - nearest) % 4 + 4) % 4
        #expect(phase == expected, "phase \(phase) expected \(expected)")
        // And the first bar the grid reports is a true accented beat.
        let bar = try #require(grid.barTime(0))
        let trueIndex = Int(((bar - track.beats[0]) / grid.periodSec).rounded())
        #expect(((trueIndex % 4) + 4) % 4 == accent)
    }

    @Test("equal kicks have no downbeat")
    func flatPulse() throws {
        let track = BeatSynth.pulse(bpm: 120, seconds: 40, offset: 0.13, click: false)
        let grid = try #require(Self.grid(track))
        #expect(grid.downbeatPhase == nil, "phase \(String(describing: grid.downbeatPhase)) at \(grid.downbeatConfidence)")
        #expect(grid.beatConfidence >= 0.9)
    }

    @Test("a click track: the bass tail of each click still gives a steady grid within 10 ms")
    func clicks() throws {
        let track = BeatSynth.pulse(bpm: 120, seconds: 30, offset: 0.13, click: true)
        let grid = try #require(Self.grid(track))
        let errors = Self.beatErrors(grid, track.beats)
        Self.report("click 120", errors)
        #expect(Self.percentile(errors, 0.95) <= 0.010)
        #expect(grid.downbeatPhase == nil)
    }

    @Test("noise gives no grid, or one far below the planner's confidence gate")
    func noise() {
        let rate = 44_100.0
        for seed in (1...20).map({ UInt32($0) * 7_919 }) {
            let samples = BeatSynth.noiseTemplate(sampleRate: rate, ms: 30_000, decay: 0, seed: seed).map { $0 * 0.3 }
            let track = BeatSynth.Track(samples: samples, sampleRate: rate, beats: [])
            let grid = Self.grid(track)
            #expect(grid == nil || grid!.beatConfidence < 0.3, "seed \(seed) grid \(String(describing: grid))")
        }
    }

    @Test("silence and short clips give no grid")
    func degenerate() {
        let rate = 44_100.0
        #expect(Self.grid(BeatSynth.Track(samples: [Float](repeating: 0, count: Int(20 * rate)), sampleRate: rate, beats: [])) == nil)
        #expect(Self.grid(BeatSynth.pulse(bpm: 120, seconds: 3, click: false)) == nil)
    }

    @Test("a shifted copy moves the anchor by the shift")
    func shiftTracksAnchor() throws {
        let base = BeatSynth.pulse(bpm: 126, seconds: 40, offset: 0.13, click: false)
        let shifted = BeatSynth.pulse(bpm: 126, seconds: 40, offset: 0.13 + 0.037, click: false)
        let a = try #require(Self.grid(base)), b = try #require(Self.grid(shifted))
        var delta = (b.anchorSec - a.anchorSec).truncatingRemainder(dividingBy: a.periodSec)
        if delta > a.periodSec / 2 { delta -= a.periodSec }
        if delta < -a.periodSec / 2 { delta += a.periodSec }
        #expect(abs(delta - 0.037) < 0.003, "delta \(delta)")
    }
}
