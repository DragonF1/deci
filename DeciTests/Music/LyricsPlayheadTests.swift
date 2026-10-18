// DeciTests/Music/LyricsPlayheadTests.swift
// The playhead the lyrics view reads between player ticks: last observed time plus wall-clock elapsed.

import Foundation
import Testing
@testable import Deci

@Suite("Lyrics playhead")
struct LyricsPlayheadTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Paused: the observed time, however much wall-clock passes")
    func paused() {
        let head = LyricsPlayhead(time: 42, isPlaying: false, observedAt: t0)
        #expect(head.position(at: t0) == 42)
        #expect(head.position(at: t0.addingTimeInterval(30)) == 42)
    }

    @Test("Playing: the observed time plus the elapsed wall-clock")
    func playing() {
        let head = LyricsPlayhead(time: 42, isPlaying: true, observedAt: t0)
        #expect(head.position(at: t0) == 42)
        #expect(abs(head.position(at: t0.addingTimeInterval(0.3)) - 42.3) < 0.0001)
    }

    @Test("A player that stopped ticking cannot run the playhead away")
    func extrapolationIsCapped() {
        let head = LyricsPlayhead(time: 42, isPlaying: true, observedAt: t0)
        #expect(head.position(at: t0.addingTimeInterval(1)) == 43)
        #expect(head.position(at: t0.addingTimeInterval(60)) == 43)
        #expect(LyricsPlayhead.maxExtrapolation == 1)
    }

    @Test("A clock that stepped back does not move the playhead back")
    func clockSkew() {
        let head = LyricsPlayhead(time: 42, isPlaying: true, observedAt: t0)
        #expect(head.position(at: t0.addingTimeInterval(-5)) == 42)
    }

    @Test("The position is never negative or non-finite")
    func sanitised() {
        #expect(LyricsPlayhead(time: -3, isPlaying: false, observedAt: t0).position(at: t0) == 0)
        #expect(LyricsPlayhead(time: .nan, isPlaying: true, observedAt: t0).position(at: t0) == 0)
        #expect(LyricsPlayhead(time: .infinity, isPlaying: true, observedAt: t0).position(at: t0) == 0)
    }

    @Test("The initial playhead is at zero and still")
    func initial() {
        #expect(LyricsPlayhead.zero.position(at: t0) == 0)
        #expect(!LyricsPlayhead.zero.isPlaying)
    }
}
