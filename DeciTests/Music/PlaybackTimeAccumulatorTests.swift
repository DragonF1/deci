// DeciTests/Music/PlaybackTimeAccumulatorTests.swift
// The history ping fires once per playback session after 30 s of real listening:
// pauses, seeks and jumps must not count toward it.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("PlaybackTimeAccumulator")
struct PlaybackTimeAccumulatorTests {

    /// Plays `seconds` of audio in 0.5 s ticks starting at `from`. Returns how many ticks fired and the end position.
    private func play(
        _ accumulator: inout PlaybackTimeAccumulator,
        seconds: TimeInterval,
        from start: TimeInterval = 0,
        isPlaying: Bool = true
    ) -> (fired: Int, end: TimeInterval) {
        var position = start
        var fired = 0
        for _ in 0..<Int(seconds / 0.5) {
            position += 0.5
            if accumulator.record(position: position, isPlaying: isPlaying) { fired += 1 }
        }
        return (fired, position)
    }

    /// One tick evaluated outside `#expect`, which cannot mutate its operands.
    private func tick(_ accumulator: inout PlaybackTimeAccumulator, _ position: TimeInterval, isPlaying: Bool = true) -> Bool {
        accumulator.record(position: position, isPlaying: isPlaying)
    }

    @Test("starts empty")
    func startsEmpty() {
        let accumulator = PlaybackTimeAccumulator()
        #expect(accumulator.playedSeconds == 0)
        #expect(accumulator.hasFired == false)
    }

    @Test("fires exactly once after 30 s of continuous playback")
    func firesOnceAtThirty() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        let result = play(&accumulator, seconds: 60)
        #expect(result.fired == 1)
        #expect(accumulator.hasFired)
    }

    @Test("fires on the tick that crosses 30 s, not before")
    func firesOnTheCrossingTick() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        let before = play(&accumulator, seconds: 29.5)
        #expect(before.fired == 0)
        #expect(accumulator.playedSeconds == 29.5)
        let crossed = tick(&accumulator, before.end + 0.5)
        #expect(crossed)
        #expect(accumulator.playedSeconds == 30)
    }

    @Test("does not fire for 29.5 s")
    func doesNotFireEarly() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        let result = play(&accumulator, seconds: 29.5)
        #expect(result.fired == 0)
        #expect(accumulator.hasFired == false)
    }

    @Test("the first tick sets a baseline and counts nothing")
    func firstTickIsBaseline() {
        var accumulator = PlaybackTimeAccumulator()
        let fired = tick(&accumulator, 120)
        #expect(fired == false)
        #expect(accumulator.playedSeconds == 0)
    }

    @Test("ticks while paused do not count")
    func pausedDoesNotCount() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        let paused = play(&accumulator, seconds: 60, isPlaying: false)
        #expect(paused.fired == 0)
        #expect(accumulator.playedSeconds == 0)
    }

    @Test("a pause in the middle holds the total")
    func pauseHoldsTotal() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        let first = play(&accumulator, seconds: 10)
        _ = play(&accumulator, seconds: 120, from: first.end, isPlaying: false)
        #expect(accumulator.playedSeconds == 10)
    }

    @Test("a forward seek does not count")
    func forwardSeekDoesNotCount() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        _ = play(&accumulator, seconds: 5)
        let fired = tick(&accumulator, 200)
        #expect(fired == false)
        #expect(accumulator.playedSeconds == 5)
    }

    @Test("counting resumes from the new position after a seek")
    func countingResumesAfterSeek() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        _ = play(&accumulator, seconds: 5)
        _ = accumulator.record(position: 200, isPlaying: true)
        _ = play(&accumulator, seconds: 5, from: 200)
        #expect(accumulator.playedSeconds == 10)
    }

    @Test("a backward seek does not count and does not go negative")
    func backwardSeekDoesNotCount() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 100, isPlaying: true)
        _ = play(&accumulator, seconds: 4, from: 100)
        let fired = tick(&accumulator, 10)
        #expect(fired == false)
        #expect(accumulator.playedSeconds == 4)
    }

    @Test("repeated seeks cannot reach 30 s")
    func seekingAroundNeverFires() {
        var accumulator = PlaybackTimeAccumulator()
        var fired = false
        for index in 0..<200 {
            if accumulator.record(position: TimeInterval(index) * 30, isPlaying: true) { fired = true }
        }
        #expect(fired == false)
        #expect(accumulator.playedSeconds == 0)
    }

    @Test("a delta at the 1.5 s cap counts, anything above is a jump")
    func capBoundary() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        _ = accumulator.record(position: 1.5, isPlaying: true)
        #expect(accumulator.playedSeconds == 1.5)
        _ = accumulator.record(position: 3.1, isPlaying: true)
        #expect(accumulator.playedSeconds == 1.5)
    }

    @Test("an unchanged position adds nothing")
    func stalledAddsNothing() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 4, isPlaying: true)
        _ = accumulator.record(position: 4, isPlaying: true)
        _ = accumulator.record(position: 4, isPlaying: true)
        #expect(accumulator.playedSeconds == 0)
    }

    @Test("seeking while paused does not count after resuming")
    func seekWhilePausedAbsorbed() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        _ = play(&accumulator, seconds: 3)
        _ = accumulator.record(position: 90, isPlaying: false)
        _ = play(&accumulator, seconds: 2, from: 90)
        #expect(accumulator.playedSeconds == 5)
    }

    @Test("non-finite positions are ignored")
    func nonFinitePositions() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 1, isPlaying: true)
        let nanFired = tick(&accumulator, .nan)
        let infiniteFired = tick(&accumulator, .infinity)
        #expect(nanFired == false)
        #expect(infiniteFired == false)
        _ = accumulator.record(position: 1.5, isPlaying: true)
        #expect(accumulator.playedSeconds == 0.5)
    }

    @Test("does not fire a second time after the threshold")
    func neverFiresTwice() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        let first = play(&accumulator, seconds: 31)
        let second = play(&accumulator, seconds: 120, from: first.end)
        #expect(first.fired == 1)
        #expect(second.fired == 0)
    }

    @Test("reset starts a fresh session that can fire again")
    func resetStartsOver() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 0, isPlaying: true)
        _ = play(&accumulator, seconds: 31)
        accumulator.reset()
        #expect(accumulator.playedSeconds == 0)
        #expect(accumulator.hasFired == false)
        _ = accumulator.record(position: 0, isPlaying: true)
        let again = play(&accumulator, seconds: 31)
        #expect(again.fired == 1)
    }

    @Test("reset forgets the old position so the next tick is a new baseline")
    func resetForgetsPosition() {
        var accumulator = PlaybackTimeAccumulator()
        _ = accumulator.record(position: 500, isPlaying: true)
        accumulator.reset()
        _ = accumulator.record(position: 0, isPlaying: true)
        _ = accumulator.record(position: 0.5, isPlaying: true)
        #expect(accumulator.playedSeconds == 0.5)
    }
}
