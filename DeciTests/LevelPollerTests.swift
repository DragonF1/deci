// DeciTests/LevelPollerTests.swift
// A VU meter row polls its level on a timer. The poller owns the timer and the level so a tick redraws the
// meter alone, a stopped poller has no timer at all, and a tick that reads the same level redraws nobody.

import Foundation
import Observation
import os
import Testing
@testable import Deci

/// Records that an observation fired, from the nonisolated closure `withObservationTracking` takes.
private nonisolated final class Fired: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

/// A level source that counts how often it is read.
@MainActor
private final class CountingSource {
    var level: Float
    private(set) var reads = 0

    init(level: Float = 0.5) { self.level = level }

    func read() -> Float {
        reads += 1
        return level
    }
}

@MainActor
@Suite("LevelPoller")
struct LevelPollerTests {
    /// An interval no test waits out, so only `tick()` moves the level.
    private static let idle: TimeInterval = 3600
    /// A fast interval for the tests that need the timer to fire.
    private static let fast: TimeInterval = 0.005

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Reads the level once, and says whether `change` afterwards would redraw the meter that read it.
    private func redraws(_ poller: LevelPoller, after change: @MainActor () -> Void) -> Bool {
        let fired = Fired()
        withObservationTracking { _ = poller.level } onChange: { fired.set() }
        change()
        return fired.value
    }

    // MARK: - Rest

    @Test("a new poller is at rest, with no timer")
    func startsAtRest() {
        let poller = LevelPoller(interval: Self.idle)
        #expect(poller.level == 0)
        #expect(poller.isRunning == false)
    }

    @Test("a fixed level can be given for a preview")
    func startsAtGivenLevel() {
        #expect(LevelPoller(level: 0.65, interval: Self.idle).level == 0.65)
    }

    @Test("a tick on a poller that was never started reads nothing")
    func tickWithoutStart() {
        let poller = LevelPoller(interval: Self.idle)
        poller.tick()
        #expect(poller.level == 0)
    }

    // MARK: - Start and stop

    @Test("starting puts a timer up")
    func startRuns() {
        let poller = LevelPoller(interval: Self.idle)
        poller.start { 0 }
        #expect(poller.isRunning)
        poller.stop()
    }

    @Test("a tick reads the source")
    func tickReadsSource() {
        let source = CountingSource(level: 0.7)
        let poller = LevelPoller(interval: Self.idle)
        poller.start(source.read)
        poller.tick()
        #expect(poller.level == 0.7)
        #expect(source.reads == 1)
        poller.stop()
    }

    @Test("stopping takes the timer down and returns the meter to rest")
    func stopRests() {
        let poller = LevelPoller(interval: Self.idle)
        poller.start { 0.9 }
        poller.tick()
        poller.stop()
        #expect(poller.isRunning == false)
        #expect(poller.level == 0)
    }

    @Test("a tick after stopping reads nothing")
    func tickAfterStop() {
        let source = CountingSource()
        let poller = LevelPoller(interval: Self.idle)
        poller.start(source.read)
        poller.stop()
        poller.tick()
        #expect(source.reads == 0)
        #expect(poller.level == 0)
    }

    @Test("starting a running poller swaps the source and keeps one timer")
    func startTwiceSwapsSource() {
        let first = CountingSource(level: 0.2)
        let second = CountingSource(level: 0.8)
        let poller = LevelPoller(interval: Self.idle)
        poller.start(first.read)
        poller.start(second.read)
        poller.tick()
        #expect(first.reads == 0)
        #expect(second.reads == 1)
        #expect(poller.level == 0.8)
        poller.stop()
        #expect(poller.isRunning == false)
    }

    @Test("a stopped poller can start again")
    func restart() {
        let source = CountingSource(level: 0.4)
        let poller = LevelPoller(interval: Self.idle)
        poller.start(source.read)
        poller.stop()
        poller.start(source.read)
        poller.tick()
        #expect(poller.isRunning)
        #expect(poller.level == 0.4)
        poller.stop()
    }

    // MARK: - The timer

    @Test("a running poller reads its source on the timer")
    func timerFires() async {
        let source = CountingSource(level: 0.6)
        let poller = LevelPoller(interval: Self.fast)
        poller.start(source.read)
        let fired = await waitUntil { source.reads >= 3 }
        poller.stop()
        #expect(fired)
        #expect(source.reads >= 3)
    }

    @Test("a stopped poller reads nothing more")
    func timerStops() async {
        let source = CountingSource()
        let poller = LevelPoller(interval: Self.fast)
        poller.start(source.read)
        _ = await waitUntil { source.reads >= 2 }
        poller.stop()
        let readsAtStop = source.reads
        try? await Task.sleep(for: .milliseconds(150))
        #expect(source.reads == readsAtStop)
    }

    // MARK: - Publishing

    @Test("a tick that finds a new level redraws the meter")
    func changedLevelRedraws() {
        let source = CountingSource(level: 0.5)
        let poller = LevelPoller(interval: Self.idle)
        poller.start(source.read)
        let drawn = redraws(poller, after: { poller.tick() })
        #expect(drawn)
        poller.stop()
    }

    @Test("a tick that finds the same level redraws nobody")
    func sameLevelIsSilent() {
        let source = CountingSource(level: 0.5)
        let poller = LevelPoller(interval: Self.idle)
        poller.start(source.read)
        poller.tick()
        let drawn = redraws(poller, after: { poller.tick() })
        #expect(!drawn)
        let drawnAgain = redraws(poller, after: { poller.tick() })
        #expect(!drawnAgain)
        source.level = 0.55
        let drawnThen = redraws(poller, after: { poller.tick() })
        #expect(drawnThen)
        poller.stop()
    }

    @Test("a silent source never redraws")
    func silenceIsSilent() {
        let poller = LevelPoller(interval: Self.idle)
        poller.start { 0 }
        let drawn = redraws(poller, after: { poller.tick() })
        #expect(!drawn)
        poller.stop()
    }

    @Test("stopping a poller already at rest redraws nobody")
    func stopAtRestIsSilent() {
        let poller = LevelPoller(interval: Self.idle)
        poller.start { 0 }
        let drawn = redraws(poller, after: { poller.stop() })
        #expect(!drawn)
    }

    @Test("stopping a poller that has a level redraws the meter once, back to rest")
    func stopWithLevelRedraws() {
        let poller = LevelPoller(interval: Self.idle)
        poller.start { 0.5 }
        poller.tick()
        let drawn = redraws(poller, after: { poller.stop() })
        #expect(drawn)
    }

    // MARK: - Running, as the meter reads it

    /// Reads `isRunning` once, and says whether `change` afterwards would redraw the meter that read it.
    private func redrawsOnRunning(_ poller: LevelPoller, after change: @MainActor () -> Void) -> Bool {
        let fired = Fired()
        withObservationTracking { _ = poller.isRunning } onChange: { fired.set() }
        change()
        return fired.value
    }

    @Test("starting redraws a meter that reads whether the poller runs")
    func startRedrawsRunningReader() {
        let poller = LevelPoller(interval: Self.idle)
        let drawn = redrawsOnRunning(poller, after: { poller.start { 0 } })
        #expect(drawn)
        poller.stop()
    }

    @Test("stopping redraws a meter that reads whether the poller runs, even when the level was already 0")
    func stopRedrawsRunningReader() {
        let poller = LevelPoller(interval: Self.idle)
        poller.start { 0 }
        let drawn = redrawsOnRunning(poller, after: { poller.stop() })
        #expect(drawn)
        #expect(!poller.isRunning)
    }

    @Test("starting a running poller, or stopping a stopped one, redraws nobody")
    func repeatedStartStopIsSilentForRunning() {
        let poller = LevelPoller(interval: Self.idle)
        poller.start { 0 }
        let again = redrawsOnRunning(poller, after: { poller.start { 0.2 } })
        #expect(!again)
        poller.stop()
        let stoppedTwice = redrawsOnRunning(poller, after: { poller.stop() })
        #expect(!stoppedTwice)
    }

    @Test("a tick does not redraw a meter that only reads whether the poller runs")
    func tickIsSilentForRunning() {
        let poller = LevelPoller(interval: Self.idle)
        poller.start { 0.5 }
        let drawn = redrawsOnRunning(poller, after: { poller.tick() })
        #expect(!drawn)
        poller.stop()
    }
}
