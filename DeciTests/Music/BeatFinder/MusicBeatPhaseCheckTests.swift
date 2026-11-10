// DeciTests/Music/BeatFinder/MusicBeatPhaseCheckTests.swift
// Tier 4c A2: a beat_this grid that sits half a beat off the strongest onsets (measured on 2 of 54 real songs) is moved.

import Foundation
import Testing
@testable import Deci

@Suite struct MusicBeatPhaseCheckTests {
    static let rate = 22_050.0

    /// Decaying noise bursts: `strong` at every beat of a 0.5 s line anchored at `onsetAnchor`, `weak` at the half beats.
    static func audio(seconds: Double, period: Double = 0.5, onsetAnchor: Double, strong: Float = 1, weak: Float = 0) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        var state: UInt64 = 12345
        func noise() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2001 - 1000) / 1000
        }
        func burst(at t: Double, gain: Float) {
            guard gain > 0 else { return }
            let start = Int(t * rate)
            for i in 0..<Int(0.04 * rate) where start + i >= 0 && start + i < out.count {
                out[start + i] += gain * 0.5 * noise() * Float(exp(-Double(i) / (0.008 * rate)))
            }
        }
        var k = 0
        while onsetAnchor + Double(k) * period < seconds {
            burst(at: onsetAnchor + Double(k) * period, gain: strong)
            burst(at: onsetAnchor + (Double(k) + 0.5) * period, gain: weak)
            k += 1
        }
        return out
    }

    static func grid(anchor: Double, period: Double = 0.5, phase: Int? = 2) -> MusicBeatGrid {
        MusicBeatGrid(
            periodSec: period, anchorSec: anchor, downbeatPhase: phase, beatConfidence: 0.98,
            downbeatConfidence: phase == nil ? 0 : 0.8, intervalSpread: 0.02, driftSec: 0,
            spanStartSec: anchor, spanEndSec: 58
        )
    }

    @Test func gridOnTheOnsetsIsKept() {
        let audio = Self.audio(seconds: 60, onsetAnchor: 0.3)
        let grid = Self.grid(anchor: 0.3)
        #expect(MusicBeatPhaseCheck.corrected(grid, samples: audio, rate: Self.rate) == grid)
    }

    @Test func gridHalfABeatOffIsMovedAndLosesItsDownbeat() throws {
        let audio = Self.audio(seconds: 60, onsetAnchor: 0.3 + 0.25)
        let fixed = MusicBeatPhaseCheck.corrected(Self.grid(anchor: 0.3), samples: audio, rate: Self.rate)
        #expect(abs(fixed.anchorSec - 0.55) < 1e-9)
        #expect(fixed.periodSec == 0.5)
        #expect(fixed.downbeatPhase == nil && fixed.downbeatConfidence == 0)
        #expect(fixed.beatConfidence == 0.98)
    }

    @Test func eighthNotesWithTheStrongHitOnTheGridAreKept() {
        // Offbeat hits at 60% strength: the beat is still where the strong hits are.
        let audio = Self.audio(seconds: 60, onsetAnchor: 0.3, strong: 1, weak: 0.6)
        let grid = Self.grid(anchor: 0.3)
        #expect(MusicBeatPhaseCheck.corrected(grid, samples: audio, rate: Self.rate) == grid)
    }

    @Test func strongOffbeatWithWeakGridHitsIsMoved() {
        let audio = Self.audio(seconds: 60, onsetAnchor: 0.3, strong: 0.5, weak: 1)
        let fixed = MusicBeatPhaseCheck.corrected(Self.grid(anchor: 0.3), samples: audio, rate: Self.rate)
        #expect(abs(fixed.anchorSec - 0.55) < 1e-9)
    }

    @Test(arguments: [0, 1, 7])
    func tooLittleEvidenceKeepsTheGrid(seconds: Int) {
        let audio = Self.audio(seconds: Double(seconds), onsetAnchor: 0.55)
        let grid = Self.grid(anchor: 0.3)
        #expect(MusicBeatPhaseCheck.corrected(grid, samples: audio, rate: Self.rate) == grid)
    }

    @Test func silenceAndEmptyAudioKeepTheGrid() {
        let grid = Self.grid(anchor: 0.3)
        #expect(MusicBeatPhaseCheck.corrected(grid, samples: [], rate: Self.rate) == grid)
        #expect(MusicBeatPhaseCheck.corrected(grid, samples: [Float](repeating: 0, count: Int(30 * Self.rate)), rate: Self.rate) == grid)
        #expect(MusicBeatPhaseCheck.corrected(grid, samples: [Float](repeating: 0.1, count: 100), rate: .nan) == grid)
    }

    @Test func nonFiniteSamplesDoNotTrap() {
        var audio = Self.audio(seconds: 30, onsetAnchor: 0.55)
        audio[1000] = .nan
        audio[2000] = .infinity
        let grid = Self.grid(anchor: 0.3)
        _ = MusicBeatPhaseCheck.corrected(grid, samples: audio, rate: Self.rate)
    }
}
