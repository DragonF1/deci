// DeciTests/Music/BeatFinder/MusicBeatGridTests.swift
// The beat grid value type: payload round trip, bad payloads, beat and bar arithmetic.

import Foundation
import Testing
@testable import Deci

@Suite("MusicBeatGrid")
struct MusicBeatGridTests {
    static func sample(phase: Int? = 2) -> MusicBeatGrid {
        MusicBeatGrid(
            periodSec: 0.5, anchorSec: 0.2, downbeatPhase: phase, beatConfidence: 0.9, downbeatConfidence: 0.6,
            intervalSpread: 0.01, driftSec: -0.0005, spanStartSec: 0.2, spanEndSec: 180.2
        )
    }

    @Test("encode then decode returns the same grid, with and without a downbeat", arguments: [0, 1, 2, 3, nil] as [Int?])
    func roundTrip(phase: Int?) throws {
        let grid = Self.sample(phase: phase)
        let data = grid.encode()
        #expect(data.count == 50)
        #expect(MusicBeatGrid.decode(data) == grid)
    }

    @Test("a truncated payload decodes to nil at every length")
    func truncated() {
        let data = Self.sample().encode()
        for length in 0..<data.count { #expect(MusicBeatGrid.decode(data.prefix(length)) == nil, "length \(length)") }
    }

    @Test("a wrong payload version decodes to nil")
    func wrongVersion() {
        var data = Self.sample().encode()
        data[0] = 2
        #expect(MusicBeatGrid.decode(data) == nil)
        data[0] = 0
        #expect(MusicBeatGrid.decode(data) == nil)
    }

    @Test("NaN, infinity, a non-positive period and a reversed span are rejected")
    func invalidNumbers() {
        var grid = Self.sample()
        for period in [Double.nan, .infinity, 0, -0.5] {
            grid.periodSec = period
            #expect(MusicBeatGrid.decode(grid.encode()) == nil, "period \(period)")
        }
        grid = Self.sample(); grid.anchorSec = .nan
        #expect(MusicBeatGrid.decode(grid.encode()) == nil)
        grid = Self.sample(); grid.beatConfidence = .nan
        #expect(MusicBeatGrid.decode(grid.encode()) == nil)
        grid = Self.sample(); grid.driftSec = .infinity
        #expect(MusicBeatGrid.decode(grid.encode()) == nil)
        grid = Self.sample(); grid.spanEndSec = grid.spanStartSec - 1
        #expect(MusicBeatGrid.decode(grid.encode()) == nil)
    }

    @Test("an absurd period or a huge anchor or span is rejected, and extrapolation never traps")
    func corruptRanges() {
        var grid = Self.sample()
        for period in [1e-300, 0.19, 2.01, 1e300] {
            grid.periodSec = period
            #expect(MusicBeatGrid.decode(grid.encode()) == nil, "period \(period)")
        }
        for period in [0.2, 2.0] {
            grid.periodSec = period
            #expect(MusicBeatGrid.decode(grid.encode()) != nil, "period \(period)")
        }
        grid = Self.sample(); grid.anchorSec = 1e9
        #expect(MusicBeatGrid.decode(grid.encode()) == nil)
        grid = Self.sample(); grid.anchorSec = -1e9
        #expect(MusicBeatGrid.decode(grid.encode()) == nil)
        grid = Self.sample(); grid.spanEndSec = 1e9
        #expect(MusicBeatGrid.decode(grid.encode()) == nil)
        // Built directly (not decoded): the helpers must still not trap.
        var raw = Self.sample(phase: 1)
        raw.periodSec = 1e-300
        _ = raw.nextBeat(atOrAfter: 1e9)
        _ = raw.barTime(0)
        raw = Self.sample(phase: 1); raw.anchorSec = 1e300
        _ = raw.nextBeat(atOrAfter: -1e300)
        _ = raw.barTime(3)
        raw.periodSec = .nan
        _ = raw.nextBeat(atOrAfter: 5)
        #expect(raw.barTime(0) == nil)
    }

    @Test("a phase byte between 4 and 254 is rejected")
    func badPhase() {
        var data = Self.sample().encode()
        data[17] = 7
        #expect(MusicBeatGrid.decode(data) == nil)
    }

    @Test("bpm and beat times extrapolate both ways")
    func beatTimes() {
        let grid = Self.sample()
        #expect(abs(grid.bpm - 120) < 1e-9)
        #expect(abs(grid.beatTime(0) - 0.2) < 1e-12)
        #expect(abs(grid.beatTime(10) - 5.2) < 1e-12)
        #expect(abs(grid.beatTime(-2) + 0.8) < 1e-12)
    }

    @Test("nextBeat returns the first beat at or after the time")
    func nextBeat() {
        let grid = Self.sample()
        #expect(grid.nextBeat(atOrAfter: 0.2).index == 0)
        #expect(grid.nextBeat(atOrAfter: 0.2000001).index == 1)
        let hit = grid.nextBeat(atOrAfter: 3.0)
        #expect(hit.index == 6 && abs(hit.time - 3.2) < 1e-12)
        #expect(grid.nextBeat(atOrAfter: -0.4).index == -1)
        #expect(grid.nextBeat(atOrAfter: 0.7).index == 1)
    }

    @Test("barTime counts bars from the first downbeat inside the span")
    func barTime() throws {
        // Downbeats at k = 2, 6, 10 ...: k = 2 is at 1.2 s.
        let grid = Self.sample(phase: 2)
        #expect(abs(try #require(grid.barTime(0)) - 1.2) < 1e-12)
        #expect(abs(try #require(grid.barTime(1)) - 3.2) < 1e-12)
        #expect(abs(try #require(grid.barTime(8)) - 17.2) < 1e-12)
        var shifted = grid
        shifted.spanStartSec = 1.3
        #expect(abs(try #require(shifted.barTime(0)) - 3.2) < 1e-12)
        var early = grid
        early.anchorSec = -5.1   // k = 0 is before the span; first downbeat with k mod 4 == 2 at or after 0.2
        early.spanStartSec = 0.2
        let bar = try #require(early.barTime(0))
        #expect(bar >= 0.2 - 1e-9 && bar < 0.2 + 4 * 4 * 0.5)
        let k = Int(((bar - early.anchorSec) / 0.5).rounded())
        #expect(((k % 4) + 4) % 4 == 2)
    }

    @Test("barTime is nil without a downbeat")
    func noDownbeat() {
        #expect(Self.sample(phase: nil).barTime(0) == nil)
    }
}
