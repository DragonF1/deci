// DeciTests/Music/MusicSectionDetectorTests.swift
// Tier 4b P3: section detection from the energy curve and the beat grid. Synthetic verse/chorus envelopes give chorus ends on
// downbeats; a flat envelope, a missing or untrusted grid, a lone chorus or a short song give no sections at all.

import Foundation
import Testing
@testable import Deci

/// Synthetic energy envelopes: low phrases at -24 dB, the phrases in `high` at -14 dB.
enum SectionFixtures {
    static let lowDb: Float = -24, highDb: Float = -14

    /// A phrase is `phraseSec` long and the first one starts at `anchor`; blocks before it are low.
    static func envelope(
        seconds: Double, phraseSec: Double = 16, anchor: Double = 0.2, high: Set<Int>, lowDb: Float = lowDb, highDb: Float = highDb
    ) -> [UInt8] {
        let blocks = Int(seconds / MusicAnalysis.energyBlockSeconds)
        return (0..<blocks).map { i in
            let t = Double(i) * MusicAnalysis.energyBlockSeconds + 1e-6
            let phrase = t < anchor ? -1 : Int((t - anchor) / phraseSec)
            return MusicAnalysis.energyCode(forDb: high.contains(phrase) ? highDb : lowDb)
        }
    }

    /// One level (dB) per 2 s bar from 0.2 s, 100 ms blocks.
    static func bars(_ levels: [Float], seconds: Double = 240) -> [UInt8] {
        let blocks = Int(seconds / MusicAnalysis.energyBlockSeconds)
        return (0..<blocks).map { i in
            let t = Double(i) * MusicAnalysis.energyBlockSeconds + 1e-6
            let bar = t < 0.2 ? 0 : min(levels.count - 1, Int((t - 0.2) / 2))
            return MusicAnalysis.energyCode(forDb: levels[bar])
        }
    }

    static func analysis(energy: [UInt8], duration: Double = 240) -> MusicAnalysis {
        var row = MusicTransitionPlannerTests.analysis("aaaaaaaaaaa", duration: duration, silenceEnd: duration - 4, outroStart: duration - 40)
        row.energy = energy
        return row
    }
}

@Suite("Music section detector")
struct MusicSectionDetectorTests {
    private let grid = MusicBeatPlannerTests.grid()   // 120 bpm, bars of 2 s, downbeats at 0.2 + 2n

    private func onDownbeat(_ time: Double) -> Bool {
        let bars = (time - 0.2) / 2
        return abs(bars - bars.rounded()) * 2 < 0.001
    }

    @Test("verse, chorus, verse, chorus (and a third) gives chorus ends on downbeats at the phrase ends")
    func chorusEnds() {
        // 8-bar phrases of 16 s: phrases 2, 5 and 8 are loud.
        let energy = SectionFixtures.envelope(seconds: 240, high: [2, 5, 8])
        let map = MusicSectionMap.derive(energy: energy, grid: grid)
        let ends = map.chorusEnds
        #expect(ends.count == 3)
        for (end, expected) in zip(ends, [48.2, 96.2, 144.2]) {
            #expect(abs(end - expected) < 0.001, "end \(end)")
            #expect(onDownbeat(end), "end \(end) is on a downbeat")
        }
        #expect(map.sections.filter { $0.kind == .chorus }.count == 3)
    }

    @Test("an unaligned phrase edge is moved to the bar line where the level falls")
    func snapsToTheFall() {
        // The loud stretches end 2 bars (4 s) after the phrase boundaries.
        var energy = SectionFixtures.envelope(seconds: 240, high: [2, 5, 8])
        for start in [48.2, 96.2, 144.2] {
            let first = Int((start / 0.1).rounded()), last = Int(((start + 4) / 0.1).rounded())
            for i in first..<last { energy[i] = MusicAnalysis.energyCode(forDb: SectionFixtures.highDb) }
        }
        let ends = MusicSectionMap.derive(energy: energy, grid: grid).chorusEnds
        #expect(ends.count == 3)
        for (end, expected) in zip(ends, [52.2, 100.2, 148.2]) {
            #expect(abs(end - expected) < 0.001, "end \(end)")
            #expect(onDownbeat(end))
        }
    }

    @Test("a flat envelope has no sections")
    func flat() {
        #expect(MusicSectionMap.derive(energy: SectionFixtures.envelope(seconds: 240, high: []), grid: grid).sections.isEmpty)
        // A small wobble (under 3 dB across the song) is still flat.
        let wobble = SectionFixtures.envelope(seconds: 240, high: [2, 5, 8], lowDb: -20, highDb: -18.5)
        #expect(MusicSectionMap.derive(energy: wobble, grid: grid).sections.isEmpty)
    }

    @Test("no downbeat, an untrusted grid or no grid at all gives no sections")
    func noGrid() {
        let energy = SectionFixtures.envelope(seconds: 240, high: [2, 5, 8])
        let phaseless = MusicBeatPlannerTests.grid(phase: nil)
        #expect(MusicSectionMap.derive(energy: energy, grid: phaseless).sections.isEmpty)
        let row = SectionFixtures.analysis(energy: energy)
        #expect(MusicSectionMap.derive(analysis: row, grid: nil).sections.isEmpty, "no stored grid")
        #expect(MusicSectionMap.derive(analysis: row, grid: MusicBeatPlannerTests.grid(confidence: 0.2)).sections.isEmpty, "untrusted")
        #expect(!MusicSectionMap.derive(analysis: row, grid: grid).sections.isEmpty, "the same row with a trusted grid")
    }

    @Test("one chorus, a chorus that runs to the end, a short song and a lopsided pair give nothing")
    func ambiguous() {
        #expect(MusicSectionMap.derive(energy: SectionFixtures.envelope(seconds: 240, high: [4]), grid: grid).sections.isEmpty)
        // The second loud stretch never ends before the song does.
        #expect(MusicSectionMap.derive(energy: SectionFixtures.envelope(seconds: 240, high: [2, 10, 11, 12, 13, 14]), grid: grid)
            .sections.isEmpty)
        #expect(MusicSectionMap.derive(energy: SectionFixtures.envelope(seconds: 50, high: [1, 3]), grid: grid).sections.isEmpty)
        // Two loud stretches 6 dB apart are not the same section.
        var uneven = SectionFixtures.envelope(seconds: 240, high: [2, 5, 8])
        for i in Int(80 / 0.1)..<Int(96.2 / 0.1) { uneven[i] = MusicAnalysis.energyCode(forDb: -8) }
        #expect(MusicSectionMap.derive(energy: uneven, grid: grid).sections.isEmpty)
        #expect(MusicSectionMap.derive(energy: [], grid: grid).sections.isEmpty)
    }

    @Test("garbage input never crashes and gives nothing")
    func garbage() {
        var bad = grid
        bad.periodSec = .nan
        #expect(MusicSectionMap.derive(energy: SectionFixtures.envelope(seconds: 240, high: [2, 5]), grid: bad).sections.isEmpty)
        #expect(MusicSectionMap.derive(energy: [UInt8](repeating: 255, count: 3000), grid: grid).sections.isEmpty)
    }

    @Test("a 4 bar intro puts the phrases off bar 0: the chorus ends still land where the level falls")
    func introOffset() {
        // Phrases of 16 s start at 8.2 (bar 4): the loud phrases 2, 5 and 8 end at 56.2, 104.2 and 152.2.
        let energy = SectionFixtures.envelope(seconds: 240, anchor: 8.2, high: [2, 5, 8])
        let ends = MusicSectionMap.derive(energy: energy, grid: grid).chorusEnds
        #expect(ends.count == 3)
        for (end, expected) in zip(ends, [56.2, 104.2, 152.2]) {
            #expect(abs(end - expected) < 0.001, "end \(end)")
            #expect(onDownbeat(end))
        }
        // A 2 bar pickup is found the same way.
        let pickup = SectionFixtures.envelope(seconds: 240, anchor: 4.2, high: [2, 5, 8])
        let pickupEnds = MusicSectionMap.derive(energy: pickup, grid: grid).chorusEnds
        #expect(zip(pickupEnds, [52.2, 100.2, 148.2]).allSatisfy { abs($0 - $1) < 0.001 } && pickupEnds.count == 3, "\(pickupEnds)")
    }

    @Test("a loud stretch that fades out over many bars has no clear end: no sections")
    func slowFadeHasNoEnd() {
        // 8 quiet bars, 8 loud, then a ramp down of 0.6 dB a bar over 16 bars (under 1.5 dB at best), three times.
        func levels(ramp: Bool) -> [Float] {
            var out: [Float] = []
            for _ in 0..<3 {
                out += [Float](repeating: -24, count: 8)
                out += [Float](repeating: -14, count: 8)
                out += ramp ? (1...16).map { -14 - 0.6 * Float($0) } : [Float](repeating: -24, count: 16)
            }
            return out + [Float](repeating: -24, count: 120 - out.count)
        }
        #expect(!MusicSectionMap.derive(energy: SectionFixtures.bars(levels(ramp: false)), grid: grid).sections.isEmpty, "the same shape with a sharp fall")
        #expect(MusicSectionMap.derive(energy: SectionFixtures.bars(levels(ramp: true)), grid: grid).sections.isEmpty)
    }

    @Test("the map of a song is worked out once, then read back")
    func cached() {
        let row = SectionFixtures.analysis(energy: SectionFixtures.envelope(seconds: 240, high: [2, 5, 8]))
        let before = MusicSectionMap.computeCount
        let first = MusicSectionMap.derive(analysis: row, grid: grid)
        for _ in 0..<20 { #expect(MusicSectionMap.derive(analysis: row, grid: grid) == first) }
        #expect(MusicSectionMap.computeCount - before <= 1, "twenty more reads did not derive again")
        var other = row
        other.energy = SectionFixtures.envelope(seconds: 240, high: [3, 6, 9])
        #expect(MusicSectionMap.derive(analysis: other, grid: grid) != first, "another energy curve is another map")
    }
}
