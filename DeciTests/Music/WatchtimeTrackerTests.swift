// DeciTests/Music/WatchtimeTrackerTests.swift
// The repeating watchtime pings: when they are due, which stretches of the song each one covers
// (st/et), what a seek, a pause and a long sleep do to them, and the one final ping.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("WatchtimeTracker")
struct WatchtimeTrackerTests {

    /// A listener on the player's 0.5 s ticks. `now` is the schedule's clock (seconds since the session began);
    /// it runs on while paused, the way wall time does.
    private struct Listener {
        var tracker = WatchtimeTracker()
        var position: TimeInterval = 0
        var now: TimeInterval = 0
        var pings: [WatchtimeDetails] = []

        init() {
            _ = tracker.record(position: 0, isPlaying: true, now: 0)
        }

        mutating func play(_ seconds: TimeInterval, volume: Int = 100, muted: Bool = false) {
            for _ in 0..<Int((seconds / 0.5).rounded()) {
                now += 0.5
                position += 0.5
                tick(playing: true, volume: volume, muted: muted)
            }
        }

        /// Paused ticks: the clock runs, the position does not.
        mutating func pause(_ seconds: TimeInterval) {
            for _ in 0..<Int((seconds / 0.5).rounded()) {
                now += 0.5
                tick(playing: false)
            }
        }

        /// Playing ticks whose position does not move (buffering).
        mutating func stall(_ seconds: TimeInterval) {
            for _ in 0..<Int((seconds / 0.5).rounded()) {
                now += 0.5
                tick(playing: true)
            }
        }

        /// A jump that only the tick sees, not `seek(to:)`.
        mutating func jump(to target: TimeInterval) {
            now += 0.5
            position = target
            tick(playing: true)
        }

        mutating func seek(to target: TimeInterval) {
            position = target
            tracker.seek(to: target)
        }

        mutating func open() -> WatchtimeDetails? {
            tracker.open(position: position, now: now)
        }

        mutating func finish() -> WatchtimeDetails? {
            tracker.finish(position: position, now: now)
        }

        private mutating func tick(playing: Bool, volume: Int = 100, muted: Bool = false) {
            if let ping = tracker.record(position: position, isPlaying: playing, now: now, volume: volume, muted: muted) {
                pings.append(ping)
            }
        }
    }

    private func segment(_ start: TimeInterval, _ end: TimeInterval, volume: Int = 100, muted: Bool = false) -> WatchtimeSegment {
        WatchtimeSegment(start: start, end: end, volume: volume, muted: muted)
    }

    // MARK: - Opening

    @Test("nothing is reported until the playback ping has opened it")
    func silentUntilOpened() {
        var listener = Listener()
        listener.play(100)
        #expect(listener.pings.isEmpty)
        #expect(listener.tracker.isOpen == false)
    }

    @Test("opening reports everything heard so far as one stretch, with the next ping 40 s out")
    func openCoversWhatWasHeard() throws {
        var listener = Listener()
        listener.play(30)
        let sent = listener.open()
        let ping = try #require(sent)

        #expect(ping.segments == [segment(0, 30)])
        #expect(ping.realTime == 30)
        #expect(ping.nextRealTime == 70)
        #expect(ping.scheduledRealTime == nil)
        #expect(ping.isPlaying)
        #expect(ping.isFinal == false)
        #expect(listener.tracker.isOpen)
    }

    @Test("the next ping is anchored on the next whole second")
    func nextPingAnchoredOnWholeSecond() throws {
        var listener = Listener()
        listener.play(30)
        listener.now = 30.2
        let sent = listener.open()
        let ping = try #require(sent)
        #expect(ping.nextRealTime == 71)
    }

    @Test("opening twice reports nothing the second time")
    func openOnce() {
        var listener = Listener()
        listener.play(30)
        #expect(listener.open() != nil)
        #expect(listener.open() == nil)
    }

    // MARK: - Cadence

    @Test("after the opening ping one ping goes out per 40 s of playing, each covering only its own stretch")
    func cadence() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(130)

        #expect(listener.pings.map(\.segments) == [[segment(30, 70)], [segment(70, 110)], [segment(110, 150)]])
        #expect(listener.pings.map(\.realTime) == [70, 110, 150])
        #expect(listener.pings.map(\.scheduledRealTime) == [70, 110, 150])
        #expect(listener.pings.map(\.nextRealTime) == [110, 150, 190])
        #expect(listener.pings.allSatisfy { $0.isPlaying && !$0.isFinal })
    }

    @Test("a ping is not early by a tick")
    func notEarly() {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(39.5)
        #expect(listener.pings.isEmpty)
        listener.play(0.5)
        #expect(listener.pings.count == 1)
    }

    @Test("a ping that falls due while nothing plays waits for the next tick that does")
    func stallDelaysThePing() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.stall(45)
        #expect(listener.pings.isEmpty)
        listener.play(0.5)

        let ping = try #require(listener.pings.first)
        #expect(listener.pings.count == 1)
        #expect(ping.segments == [segment(30, 30.5)])
        #expect(ping.scheduledRealTime == 70)
        #expect(ping.nextRealTime == 110)
    }

    @Test("a long sleep sends one ping, not one per tick of catching up")
    func sleepDoesNotBurst() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.now = 4999.5
        listener.play(0.5)
        listener.play(10)

        let ping = try #require(listener.pings.first)
        #expect(listener.pings.count == 1)
        #expect(ping.nextRealTime == 5040)
    }

    // MARK: - Seeks

    @Test("a seek splits the stretch: both parts ride in the one ping")
    func seekSplits() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(20)
        listener.seek(to: 200)
        listener.play(20)

        let ping = try #require(listener.pings.first)
        #expect(listener.pings.count == 1)
        #expect(ping.segments == [segment(30, 50), segment(200, 220)])
        #expect(ping.realTime == 70)
    }

    @Test("even a short seek splits the stretch")
    func shortSeekSplits() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(10)
        listener.seek(to: 41)
        listener.play(30)

        let ping = try #require(listener.pings.first)
        #expect(ping.segments == [segment(30, 40), segment(41, 71)])
    }

    @Test("a jump the tick sees without a seek call splits it as well, and the jump itself is not heard")
    func jumpSplits() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(20)
        listener.jump(to: 200)
        listener.play(19.5)

        let ping = try #require(listener.pings.first)
        #expect(ping.segments == [segment(30, 50), segment(200, 219.5)])
    }

    @Test("a seek before the opening ping splits the first ping's stretches too")
    func seekBeforeOpen() throws {
        var listener = Listener()
        listener.play(10)
        listener.seek(to: 100)
        listener.play(20)
        let sent = listener.open()
        let ping = try #require(sent)
        #expect(ping.segments == [segment(0, 10), segment(100, 120)])
    }

    // MARK: - Pause

    @Test("a pause flushes what was heard, marked paused, and carries the ping that was due")
    func pauseFlushes() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(10)
        listener.pause(0.5)

        let ping = try #require(listener.pings.first)
        #expect(listener.pings.count == 1)
        #expect(ping.segments == [segment(30, 40)])
        #expect(ping.isPlaying == false)
        #expect(ping.isFinal == false)
        #expect(ping.scheduledRealTime == 70)
        #expect(ping.nextRealTime == nil)
        #expect(ping.realTime == 40.5)
    }

    @Test("no ping goes out while paused, however long the pause")
    func pausedIsSilent() {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(10)
        listener.pause(300)
        #expect(listener.pings.count == 1)
    }

    @Test("resuming restarts the 40 s from the resume, and the pause is in no stretch")
    func resumeHasNoGap() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(10)
        listener.pause(100)
        listener.play(40)
        #expect(listener.pings.count == 1)
        listener.play(1)

        let ping = try #require(listener.pings.last)
        #expect(listener.pings.count == 2)
        #expect(ping.segments == [segment(40, 81)])
        #expect(ping.isPlaying)
        #expect(ping.realTime == 181)
        #expect(ping.scheduledRealTime == 181)
        #expect(ping.nextRealTime == 221)
    }

    @Test("a pause before the opening ping flushes nothing and leaves one unbroken stretch")
    func pauseBeforeOpen() throws {
        var listener = Listener()
        listener.play(20)
        listener.pause(10)
        listener.play(10)
        #expect(listener.pings.isEmpty)
        let sent = listener.open()
        let ping = try #require(sent)
        #expect(ping.segments == [segment(0, 30)])
    }

    @Test("a seek while paused splits the stretch on resume")
    func seekWhilePaused() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(5)
        listener.pause(5)
        listener.seek(to: 300)
        listener.pause(0.5)
        listener.play(10)
        let sent = listener.finish()
        let ping = try #require(sent)
        #expect(ping.segments == [segment(300, 310)])
        #expect(listener.pings.first?.segments == [segment(30, 35)])
    }

    // MARK: - Volume

    @Test("a change of volume or mute starts a new stretch")
    func volumeSplits() throws {
        var listener = Listener()
        listener.play(10)
        listener.play(10, volume: 50)
        listener.play(10, volume: 50, muted: true)
        let sent = listener.open()
        let ping = try #require(sent)
        #expect(ping.segments == [
            segment(0, 10),
            segment(10, 20, volume: 50),
            segment(20, 30, volume: 50, muted: true),
        ])
    }

    // MARK: - Final

    @Test("the final ping flushes what is unsent, marked paused and final, with the ping that was due")
    func finalFlushes() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(10)
        let sent = listener.finish()
        let ping = try #require(sent)

        #expect(ping.segments == [segment(30, 40)])
        #expect(ping.isFinal)
        #expect(ping.isPlaying == false)
        #expect(ping.scheduledRealTime == 70)
        #expect(ping.nextRealTime == nil)
        #expect(ping.realTime == 40)
        #expect(listener.tracker.isFinished)
    }

    @Test("a final ping with nothing new still reports an empty stretch at the position")
    func finalWithNothingNew() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        let sent = listener.finish()
        let ping = try #require(sent)
        #expect(ping.segments == [segment(30, 30)])
        #expect(ping.isFinal)
    }

    @Test("the final ping after a pause flush has nothing left to carry but the position")
    func finalAfterPauseFlush() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(10)
        listener.pause(0.5)
        let sent = listener.finish()
        let ping = try #require(sent)
        #expect(ping.segments == [segment(40, 40)])
        #expect(ping.scheduledRealTime == nil)
    }

    @Test("the final ping counts the step between the last tick and the end, but not a jump")
    func finalCountsTheLastStep() throws {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        listener.play(10)
        let ping = listener.tracker.finish(position: listener.position + 0.5, now: listener.now)
        #expect(ping?.segments == [segment(30, 40.5)])

        var jumped = Listener()
        jumped.play(30)
        _ = jumped.open()
        jumped.play(10)
        let skipped = jumped.tracker.finish(position: jumped.position + 100, now: jumped.now)
        #expect(skipped?.segments == [segment(30, 40)])
    }

    @Test("the final ping goes out once, and nothing follows it")
    func nothingAfterTheFinal() {
        var listener = Listener()
        listener.play(30)
        _ = listener.open()
        #expect(listener.finish() != nil)
        #expect(listener.finish() == nil)

        listener.play(200)
        listener.pause(10)
        listener.seek(to: 5)
        #expect(listener.pings.isEmpty)
        #expect(listener.open() == nil)
    }

    @Test("a session that never opened has no final ping, and can still open later")
    func noFinalWithoutOpen() {
        var listener = Listener()
        listener.play(20)
        #expect(listener.finish() == nil)
        #expect(listener.tracker.isFinished == false)
        listener.play(10)
        #expect(listener.open() != nil)
    }

    // MARK: - Bad input

    @Test("a position that is not a number is ignored")
    func nonFinitePosition() {
        var tracker = WatchtimeTracker()
        #expect(tracker.record(position: .nan, isPlaying: true, now: 1) == nil)
        #expect(tracker.record(position: .infinity, isPlaying: true, now: 2) == nil)
        #expect(tracker.isOpen == false)
    }
}
