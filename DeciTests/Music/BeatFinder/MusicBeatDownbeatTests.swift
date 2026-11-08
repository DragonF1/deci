// DeciTests/Music/BeatFinder/MusicBeatDownbeatTests.swift
// Tier 3b accuracy P2: the downbeat on synthetic songs with a known bar. A wrong downbeat is worse than none, so the
// refusal cases matter as much as the finds: no accent, noise, and a 1-vs-3 pattern with no harmonic cue.

import Foundation
import Testing
@testable import Deci

@Suite("MusicBeatDownbeat")
struct MusicBeatDownbeatTests {
    struct Pattern {
        /// Gain per beat of the bar (0 = none).
        var kick: [Float] = [0.9, 0, 0.9, 0]
        var snare: [Float] = [0, 0.5, 0, 0.5]
        /// A new chord every `chordBars` bars, on beat 1; 0 holds one chord for the whole song.
        var chordBars = 1
        var hats = true
    }

    private static let chords: [[Double]] = [
        [261.63, 329.63, 392.00], [220.00, 261.63, 329.63], [174.61, 220.00, 261.63], [196.00, 246.94, 392.00],
    ]

    /// A track whose first beat sits at bar position `startSlot` (0 = it is a beat 1). `anchor` is the first beat's time.
    @MainActor
    static func song(bpm: Double, seconds: Double, startSlot: Int, pattern: Pattern, rate: Double = 44_100)
        -> (track: BeatSynth.Track, anchor: Double) {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        let kick = BeatSynth.kickTemplate(sampleRate: rate)
        let snare = BeatSynth.noiseTemplate(sampleRate: rate, ms: 120, decay: 30, seed: 11)
        let hat = BeatSynth.noiseTemplate(sampleRate: rate, ms: 25, decay: 150, seed: 13)
        let quarter = 60 / bpm
        let anchor = 0.4
        var beats: [Double] = []
        var index = 0
        while anchor + Double(index) * quarter < seconds - 0.5 {
            let time = anchor + Double(index) * quarter
            let position = (index + startSlot) % 4
            beats.append(time)
            if pattern.kick[position] > 0 { BeatSynth.mix(kick, into: &samples, at: time, sampleRate: rate, gain: pattern.kick[position]) }
            if pattern.snare[position] > 0 { BeatSynth.mix(snare, into: &samples, at: time, sampleRate: rate, gain: pattern.snare[position]) }
            if pattern.hats { BeatSynth.mix(hat, into: &samples, at: time + quarter / 2, sampleRate: rate, gain: 0.2) }
            index += 1
        }
        let table = (0..<4096).map { Float(sin(2 * Double.pi * Double($0) / 4096)) }
        // The chord under each sample: it changes where a bar starts (or never).
        for frame in 0..<samples.count {
            let t = Double(frame) / rate
            let bar = max(0, Int(((t - anchor) / quarter + Double(startSlot)) / 4 + 1e-9))
            let chordIndex = pattern.chordBars > 0 ? (bar / pattern.chordBars) % Self.chords.count : 0
            var value: Float = 0
            for f in Self.chords[chordIndex] { value += table[Int(f * t * Double(table.count)) & (table.count - 1)] }
            samples[frame] += 0.08 * value
        }
        return (BeatSynth.Track(samples: samples, sampleRate: rate, beats: beats), anchor)
    }

    /// The grid a finder would give for `track`, built from the known beats so that only the downbeat step is under test.
    @MainActor
    static func estimate(_ built: (track: BeatSynth.Track, anchor: Double), bpm: Double) -> MusicBeatFinder.DownbeatEstimate? {
        let (audio, rate) = MusicBeatPhaseTests.decimated(built.track)
        let period = 60 / bpm
        let last = built.track.beats.count - 1
        let grid = MusicBeatGrid(
            periodSec: period, anchorSec: built.anchor, downbeatPhase: nil, beatConfidence: 1, downbeatConfidence: 0,
            intervalSpread: 0, driftSec: 0, spanStartSec: built.anchor, spanEndSec: built.anchor + Double(last) * period
        )
        return MusicBeatFinder.estimateDownbeat(decimated: audio, rate: rate, grid: grid, beats: 0...last)
    }

    @MainActor
    @Test("kick on 1 and 3, snare on 2 and 4, chord change on 1: the right phase from every starting phase",
          arguments: [90.0, 128, 150], [0, 1, 2, 3])
    func finds(bpm: Double, startSlot: Int) throws {
        let built = Self.song(bpm: bpm, seconds: 50, startSlot: startSlot, pattern: Pattern())
        let found = try #require(Self.estimate(built, bpm: bpm))
        print(String(format: "DOWNBEAT synth %.0f slot %d: phase %d margin %.1f agrees %@ blocks %d", bpm, startSlot, found.phase,
                     found.margin, found.agrees ? "yes" : "no", found.blocks))
        #expect(found.accepted, "margin \(found.margin) agrees \(found.agrees)")
        // Beat index k sits at bar position (k + startSlot) % 4, so beat 1 is the k with (k + startSlot) % 4 == 0.
        #expect(found.phase == (4 - startSlot) % 4)
    }

    @MainActor
    @Test("kick every beat, nothing else accented, one chord: refused", arguments: [90.0, 128, 150], [0, 2])
    func flatLoop(bpm: Double, startSlot: Int) {
        let pattern = Pattern(kick: [0.9, 0.9, 0.9, 0.9], snare: [0, 0, 0, 0], chordBars: 0, hats: true)
        let built = Self.song(bpm: bpm, seconds: 50, startSlot: startSlot, pattern: pattern)
        let found = Self.estimate(built, bpm: bpm)
        print("DOWNBEAT flat \(Int(bpm)): accepted \(found?.accepted ?? false) margin \(found?.margin ?? 0)")
        #expect(found?.accepted != true)
    }

    @MainActor
    @Test("a 1-vs-3 pattern (kick 1 and 3, snare 2 and 4) with no harmonic cue: refused", arguments: [90.0, 128, 150], [0, 1, 2, 3])
    func oneVersusThree(bpm: Double, startSlot: Int) {
        let pattern = Pattern(chordBars: 0)
        let built = Self.song(bpm: bpm, seconds: 50, startSlot: startSlot, pattern: pattern)
        let found = Self.estimate(built, bpm: bpm)
        print("DOWNBEAT 1v3 \(Int(bpm)) slot \(startSlot): accepted \(found?.accepted ?? false) margin \(found?.margin ?? 0)")
        #expect(found?.accepted != true)
    }

    @MainActor
    @Test("white noise: refused")
    func noise() {
        let rate = 44_100.0
        var state: UInt32 = 12_345
        let samples = (0..<Int(70 * rate)).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return 0.3 * Float(Int32(bitPattern: state)) / Float(Int32.max)
        }
        let track = BeatSynth.Track(samples: samples, sampleRate: rate, beats: [])
        let built = (track: BeatSynth.Track(samples: track.samples, sampleRate: rate, beats: (0..<150).map { 0.4 + Double($0) * 0.5 }), anchor: 0.4)
        let found = Self.estimate(built, bpm: 120)
        print("DOWNBEAT noise: accepted \(found?.accepted ?? false) margin \(found?.margin ?? 0)")
        #expect(found?.accepted != true)
    }

    @MainActor
    @Test("fewer bars than the minimum: nil")
    func tooShort() {
        let built = Self.song(bpm: 128, seconds: 12, startSlot: 0, pattern: Pattern())
        #expect(Self.estimate(built, bpm: 128) == nil)
    }

    @MainActor
    @Test("through the whole route (finder, bass refinement, downbeat): louder kick on 1 and 3, snare, chords at 128 bpm")
    func wholeRoute() throws {
        for startSlot in [0, 2] {
            // A kick on every beat (louder on 1 and 3): with kicks on 1 and 3 only the bass refinement's held-out beats are
            // empty and the grid is not trusted, so there is nothing to find a downbeat on.
            let built = Self.song(bpm: 128, seconds: 50, startSlot: startSlot, pattern: Pattern(kick: [0.9, 0.5, 0.9, 0.5]))
            let grid = try #require(MusicBeatGridAccuracyTests.grid(built.track))
            #expect(grid.beatConfidence >= 0.5)
            let phase = try #require(grid.downbeatPhase, "downbeat unknown, confidence \(grid.downbeatConfidence)")
            // The grid's beat 0 may be any of the true beats; map it through the truth.
            let kTrue = Int(((built.track.beats[0] - grid.anchorSec) / grid.periodSec).rounded())
            #expect((phase - kTrue - (4 - startSlot) % 4 + 8) % 4 == 0)
        }
    }
}
