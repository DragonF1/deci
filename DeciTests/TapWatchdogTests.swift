// DeciTests/TapWatchdogTests.swift
//
// Pure-value tests for TapWatchdog: when a tap that runs but delivers nothing is rebuilt.

import Testing
import Foundation
@testable import Deci

/// A tap that has played for a while, with signal a moment ago and no disturbance.
private func healthy(
    tapAge: Double = 120,
    signalSeen: Bool = true,
    silentFor: Double = 0.1,
    discontinuityAge: Double = .infinity,
    outputSilentFor: Double = 0.1,
    switching: Bool = false,
    playing: Bool = true,
    muted: Bool = false
) -> TapHealthSample {
    TapHealthSample(
        readings: TapHealthReadings(
            isSwitching: switching,
            secondsSinceTapStart: tapAge,
            inputSignalSeen: signalSeen,
            secondsSinceInputSignal: silentFor,
            secondsSinceDiscontinuity: discontinuityAge,
            discontinuityCount: discontinuityAge.isFinite ? 1 : 0,
            secondsSinceHealthyOutput: outputSilentFor
        ),
        appIsPlaying: playing,
        isUserMuted: muted
    )
}

@Suite("TapWatchdog — stuck input")
struct TapWatchdogInputTests {

    @Test("Silence right after an overload rebuilds after 1 s (21:21 incident)")
    func silenceAfterOverload() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 0.5, discontinuityAge: 0.5)) == nil)
        #expect(w.evaluate(healthy(silentFor: 1.2, discontinuityAge: 1.2)) == .silentAfterOverload)
    }

    @Test("A fresh or just-switched tap that delivers nothing rebuilds after 3 s (21:22:53 incident)")
    func silenceAfterTapStart() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(tapAge: 2, signalSeen: false, silentFor: 2)) == nil)
        #expect(w.evaluate(healthy(tapAge: 3.2, signalSeen: false, silentFor: 3.2)) == .silentAfterTapStart)
    }

    @Test("A switched tap that played, then went silent, rebuilds 3 s into the silence")
    func silenceShortlyAfterSwitch() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(tapAge: 3, silentFor: 1.7)) == nil)
        #expect(w.evaluate(healthy(tapAge: 4.4, silentFor: 3.1)) == .silentAfterTapStart)
    }

    @Test("A pause on a long-running tap waits 20 s, rebuilds once, then leaves the silence alone")
    func genuinePauseRebuildsOnce() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 5)) == nil)
        #expect(w.evaluate(healthy(silentFor: 19.9)) == nil)
        #expect(w.evaluate(healthy(silentFor: 20)) == .longSilence)
        // The rebuilt tap is silent too: genuine silence. No tap-start or second long rebuild.
        #expect(w.evaluate(healthy(tapAge: 4, signalSeen: false, silentFor: 4)) == nil)
        #expect(w.evaluate(healthy(tapAge: 40, signalSeen: false, silentFor: 40)) == nil)
    }

    @Test("After an overload rebuild, a silent new tap is not rebuilt again until a new overload")
    func overloadRebuildDoesNotLoop() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 1.5, discontinuityAge: 1.5)) == .silentAfterOverload)
        #expect(w.evaluate(healthy(tapAge: 5, signalSeen: false, silentFor: 5)) == nil)
        // Another stall sticks the new tap: rebuild again.
        #expect(w.evaluate(healthy(tapAge: 8, signalSeen: false, silentFor: 8, discontinuityAge: 1.1)) == .silentAfterOverload)
    }

    @Test("Rebuilds per silence episode are capped")
    func episodeCap() {
        var w = TapWatchdog()
        var rebuilds = 0
        for _ in 0..<10 {
            if w.evaluate(healthy(signalSeen: false, silentFor: 2, discontinuityAge: 1.5)) != nil { rebuilds += 1 }
        }
        #expect(rebuilds == TapWatchdog.maxSilenceRebuilds)
    }

    @Test("Signal coming back starts a new episode")
    func signalResetsEpisode() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 20)) == .longSilence)
        #expect(w.evaluate(healthy(silentFor: 0.2)) == nil)
        #expect(w.silenceRebuilds == 0)
        #expect(w.evaluate(healthy(silentFor: 20)) == .longSilence)
    }

    @Test("An app that stops playing resets every count and is never rebuilt")
    func notPlaying() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 20)) == .longSilence)
        #expect(w.evaluate(healthy(silentFor: 60, discontinuityAge: 1, playing: false)) == nil)
        #expect(w == TapWatchdog())
    }

    @Test("A user-muted or switching tap is left alone")
    func mutedOrSwitching() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 30, discontinuityAge: 2, muted: true)) == nil)
        #expect(w.evaluate(healthy(silentFor: 30, discontinuityAge: 2, switching: true)) == nil)
        #expect(w.silenceRebuilds == 0)
    }

    @Test("An old discontinuity is not a cause")
    func oldDiscontinuity() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 5, discontinuityAge: 16)) == nil)
    }
}

@Suite("TapWatchdog — stuck output")
struct TapWatchdogOutputTests {

    @Test("Live input with silent output for 1.5 s rebuilds (upstream #461)")
    func outputSilent() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(outputSilentFor: 1.0)) == nil)
        #expect(w.evaluate(healthy(outputSilentFor: 1.6)) == .outputSilent)
    }

    @Test("Silent-output rebuilds are capped per playing run and reset when the app stops")
    func outputCap() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(outputSilentFor: 2)) == .outputSilent)
        #expect(w.evaluate(healthy(outputSilentFor: 2)) == .outputSilent)
        #expect(w.evaluate(healthy(outputSilentFor: 2)) == nil)
        _ = w.evaluate(healthy(playing: false))
        #expect(w.evaluate(healthy(outputSilentFor: 2)) == .outputSilent)
    }
}

// MARK: - Zero-run tracking (debug soak instrumentation)

/// Feeds `buffers` identical buffers, one `hostStep` ticks apart, starting at `host`.
/// Returns the host time the next buffer would carry.
@discardableResult
private func feed(
    _ tracker: inout ZeroRunTracker,
    zero: Bool,
    buffers: Int = 1,
    frames: Int = 480,
    rate: Double = 48_000,
    from host: UInt64,
    hostStep: UInt64 = 10_000_000
) -> UInt64 {
    var t = host
    for _ in 0..<buffers {
        tracker.record(isZero: zero, frames: frames, sampleRate: rate, hostTime: t)
        t += hostStep
    }
    return t
}

@Suite("ZeroRunTracker")
struct ZeroRunTrackerTests {

    @Test("A zero run shorter than 100 ms is ignored")
    func shortRunIgnored() {
        var z = ZeroRunTracker()
        let t = feed(&z, zero: true, buffers: 9, from: 1_000)  // 9 x 10 ms
        #expect(!z.ongoingRunCrossed)
        feed(&z, zero: false, from: t)
        #expect(z.completedRuns == 0)
        #expect(z.lastRunStartHostTime == 0)
        #expect(z.lastRunFrames == 0)
    }

    @Test("A run reaching exactly 100 ms is ongoing, with the first zero buffer's host time as onset")
    func ongoingAtThreshold() {
        var z = ZeroRunTracker()
        var t = feed(&z, zero: false, buffers: 5, from: 100)
        let onset = t
        t = feed(&z, zero: true, buffers: 9, from: t)
        #expect(!z.ongoingRunCrossed)
        feed(&z, zero: true, from: t)  // the 10th buffer: 100 ms
        #expect(z.ongoingRunCrossed)
        #expect(z.runStartHostTime == onset)
        #expect(z.runFrames == 4_800)
        #expect(z.completedRuns == 0)
    }

    @Test("The end of a long run latches its onset and length and counts it")
    func endLatches() {
        var z = ZeroRunTracker()
        var t = feed(&z, zero: true, buffers: 30, from: 5_000)
        #expect(z.ongoingRunCrossed)
        t = feed(&z, zero: false, from: t)
        #expect(!z.ongoingRunCrossed)
        #expect(z.completedRuns == 1)
        #expect(z.lastRunStartHostTime == 5_000)
        #expect(z.lastRunFrames == 30 * 480)
        #expect(abs(z.lastRunSeconds - 0.3) < 1e-9)

        let second = t
        t = feed(&z, zero: true, buffers: 12, from: t)
        feed(&z, zero: false, from: t)
        #expect(z.completedRuns == 2)
        #expect(z.lastRunStartHostTime == second)
        #expect(z.lastRunFrames == 12 * 480)
    }

    @Test("Signal resets a run: zero spans on either side of it are not added together")
    func signalResets() {
        var z = ZeroRunTracker()
        var t = feed(&z, zero: true, buffers: 6, from: 0)
        t = feed(&z, zero: false, from: t)
        let restart = t
        feed(&z, zero: true, buffers: 6, from: t)  // 6 + 6 would cross, 6 alone does not
        #expect(!z.ongoingRunCrossed)
        #expect(z.runStartHostTime == restart)
        #expect(z.runFrames == 6 * 480)
        #expect(z.completedRuns == 0)
    }

    @Test("Frames convert to seconds with the sample rate given, 100 ms inclusive")
    func usesGivenSampleRate() {
        var at44 = ZeroRunTracker()
        feed(&at44, zero: true, frames: 4_410, rate: 44_100, from: 1)
        #expect(at44.ongoingRunCrossed)
        #expect(abs(at44.runSeconds - 0.1) < 1e-12)

        var short44 = ZeroRunTracker()
        feed(&short44, zero: true, frames: 4_409, rate: 44_100, from: 1)
        #expect(!short44.ongoingRunCrossed)

        // The same frame count is shorter at a higher rate.
        var at48 = ZeroRunTracker()
        feed(&at48, zero: true, frames: 4_410, rate: 48_000, from: 1)
        #expect(!at48.ongoingRunCrossed)

        var at16 = ZeroRunTracker()
        feed(&at16, zero: true, frames: 1_600, rate: 16_000, from: 1)
        #expect(at16.ongoingRunCrossed)
    }

    @Test("Ten 10 ms buffers reach 100 ms despite float rounding in a running sum")
    func noAccumulationDrift() {
        var z = ZeroRunTracker()
        feed(&z, zero: true, buffers: 10, frames: 441, rate: 44_100, from: 1)
        #expect(z.ongoingRunCrossed)
    }

    @Test("One large buffer can cross the threshold on its own")
    func singleLargeBuffer() {
        var z = ZeroRunTracker()
        feed(&z, zero: true, frames: 8_192, from: 777)
        #expect(z.ongoingRunCrossed)
        #expect(z.runStartHostTime == 777)
    }

    @Test("A callback with no frames neither starts, extends nor ends a run")
    func emptyCallbackIgnored() {
        var z = ZeroRunTracker()
        var t = feed(&z, zero: true, buffers: 6, from: 10)
        feed(&z, zero: false, frames: 0, from: t)  // a NULL-buffer callback must not end the run
        t = feed(&z, zero: true, frames: 0, from: t)
        feed(&z, zero: true, buffers: 4, from: t)
        #expect(z.ongoingRunCrossed)
        #expect(z.runStartHostTime == 10)
        #expect(z.runFrames == 10 * 480)

        var idle = ZeroRunTracker()
        feed(&idle, zero: true, frames: 0, from: 5)
        #expect(idle == ZeroRunTracker())
    }

    @Test("A non-positive sample rate never crosses the threshold")
    func badRate() {
        var z = ZeroRunTracker()
        feed(&z, zero: true, buffers: 100, rate: 0, from: 1)
        #expect(!z.ongoingRunCrossed)
        #expect(z.runSeconds == 0)
    }

    @Test("Reset on tap start clears the ongoing run and everything latched")
    func resetClears() {
        var z = ZeroRunTracker()
        var t = feed(&z, zero: true, buffers: 20, from: 1)
        t = feed(&z, zero: false, from: t)
        feed(&z, zero: true, buffers: 20, from: t)
        #expect(z.completedRuns == 1 && z.ongoingRunCrossed)
        z.reset()
        #expect(z == ZeroRunTracker())
    }
}

@Suite("ZeroRunLogCursor")
struct ZeroRunLogCursorTests {

    @Test("Nothing to log while the input is live or the run is short")
    func quiet() {
        var cursor = ZeroRunLogCursor()
        var z = ZeroRunTracker()
        #expect(cursor.events(for: z).isEmpty)
        feed(&z, zero: true, buffers: 5, from: 1)
        #expect(cursor.events(for: z).isEmpty)
    }

    @Test("Onset is logged once when the ongoing run crosses 100 ms, not on later ticks")
    func onsetOnce() {
        var cursor = ZeroRunLogCursor()
        var z = ZeroRunTracker()
        var t = feed(&z, zero: true, buffers: 12, from: 400)
        #expect(cursor.events(for: z) == [.onset(startHostTime: 400)])
        t = feed(&z, zero: true, buffers: 50, from: t)
        #expect(cursor.events(for: z).isEmpty)
        _ = t
    }

    @Test("The end of a run logs its length and run number after its onset was logged")
    func endedAfterOnset() {
        var cursor = ZeroRunLogCursor()
        var z = ZeroRunTracker()
        var t = feed(&z, zero: true, buffers: 12, from: 400)
        _ = cursor.events(for: z)
        t = feed(&z, zero: true, buffers: 18, from: t)
        t = feed(&z, zero: false, from: t)
        let events = cursor.events(for: z)
        #expect(events.count == 1)
        guard case let .ended(start, frames, seconds, run)? = events.first else {
            Issue.record("expected an ended event, got \(events)")
            return
        }
        #expect(start == 400)
        #expect(frames == 30 * 480)
        #expect(abs(seconds - 0.3) < 1e-9)
        #expect(run == 1)
        #expect(cursor.events(for: z).isEmpty)
        _ = t
    }

    @Test("A run that began and ended between two ticks logs onset then ended")
    func wholeRunBetweenTicks() {
        var cursor = ZeroRunLogCursor()
        var z = ZeroRunTracker()
        var t = feed(&z, zero: true, buffers: 25, from: 900)
        t = feed(&z, zero: false, from: t)
        let events = cursor.events(for: z)
        #expect(events.count == 2)
        #expect(events.first == .onset(startHostTime: 900))
        #expect(events.last?.startHostTime == 900)
        _ = t
    }

    @Test("A finished run and a new ongoing one in the same tick log in order")
    func endedThenNewOnset() {
        var cursor = ZeroRunLogCursor()
        var z = ZeroRunTracker()
        var t = feed(&z, zero: true, buffers: 15, from: 100)
        t = feed(&z, zero: false, from: t)
        let second = t
        t = feed(&z, zero: true, buffers: 15, from: t)
        let events = cursor.events(for: z)
        #expect(events.map(\.startHostTime) == [100, 100, second])
        #expect(events.first == .onset(startHostTime: 100))
        #expect(events.last == .onset(startHostTime: second))
        _ = t
    }

    @Test("A tracker reset for a rebuilt tap logs nothing and its next run is logged afresh")
    func resetThenNewRun() {
        var cursor = ZeroRunLogCursor()
        var z = ZeroRunTracker()
        var t = feed(&z, zero: true, buffers: 15, from: 100)
        t = feed(&z, zero: false, from: t)
        _ = cursor.events(for: z)
        z.reset()
        #expect(cursor.events(for: z).isEmpty)
        feed(&z, zero: true, buffers: 15, from: t + 5_000)
        #expect(cursor.events(for: z) == [.onset(startHostTime: t + 5_000)])
    }
}

@Suite("ZeroRunClock and forensics text")
struct ZeroRunClockTests {

    @Test("Wall time is now minus the host-time distance, converted with the timebase")
    func wallTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 1 tick = 1 ns here: 250 ms apart.
        let onset = ZeroRunClock.wallTime(ofHostTime: 1_000_000_000, sampledAt: 1_250_000_000, now: now, nanosPerTick: 1)
        #expect(abs(onset.timeIntervalSince(now) + 0.25) < 1e-9)
        // 1 tick = 41.666... ns (a 24 MHz clock): 24,000,000 ticks = 1 s.
        let scaled = ZeroRunClock.wallTime(ofHostTime: 0, sampledAt: 24_000_000, now: now, nanosPerTick: 125.0 / 3.0)
        #expect(abs(scaled.timeIntervalSince(now) + 1.0) < 1e-9)
    }

    @Test("An onset stamped after the sample (a race with the IO thread) clamps to now")
    func wallTimeClamps() {
        let now = Date(timeIntervalSince1970: 50)
        #expect(ZeroRunClock.wallTime(ofHostTime: 200, sampledAt: 100, now: now, nanosPerTick: 1) == now)
    }

    @Test("Clock strings carry milliseconds in the given time zone")
    func clockString() {
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(ZeroRunClock.clockString(Date(timeIntervalSince1970: 3_723.25), timeZone: utc) == "01:02:03.250")
        let plus2 = TimeZone(secondsFromGMT: 7_200)!
        #expect(ZeroRunClock.clockString(Date(timeIntervalSince1970: 3_723.5), timeZone: plus2) == "03:02:03.500")
    }

    @Test("Forensics print the callback deltas, or n/a for the first callback of a tap")
    func forensicsSummary() {
        let f = ZeroRunForensics(
            startHostTime: 5, hostDeltaTicks: 10_666_667, sampleTimeDelta: 512, rateScalar: 1,
            numberBuffers: 1, firstBufferBytes: 4_096, firstBufferChannels: 2
        )
        #expect(f.summary(nanosPerTick: 1) == "prevCb=10.667ms dSample=512.0 rateScalar=1.000000 buffers=1 buf0=4096B/2ch")
        var first = f
        first.hostDeltaTicks = 0
        #expect(first.summary(nanosPerTick: 1) == "prevCb=n/a dSample=n/a rateScalar=1.000000 buffers=1 buf0=4096B/2ch")
    }
}

@Suite("ZeroRunEvent log line")
struct ZeroRunLogLineTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let now = Date(timeIntervalSince1970: 3_723.5)
    private let onsetHost: UInt64 = 1_750_000_000  // 250 ms before the 2_000_000_000 sample (1 tick = 1 ns)

    private func readings(stream: Bool, drift: Bool, forensicsHost: UInt64) -> TapHealthReadings {
        var r = healthy().readings
        r.sampledHostTime = 2_000_000_000
        r.tapIsStream = stream
        r.tapDriftCompensation = drift
        r.zeroRunForensics = ZeroRunForensics(
            startHostTime: forensicsHost, hostDeltaTicks: 10_666_667, sampleTimeDelta: 512, rateScalar: 1,
            numberBuffers: 1, firstBufferBytes: 4_096, firstBufferChannels: 2
        )
        return r
    }

    @Test("Onset line: app, onset wall time from the host clock, config and the run's forensics")
    func onsetLine() {
        let line = ZeroRunEvent.onset(startHostTime: onsetHost).logLine(
            appName: "Google Chrome", pid: 1234, playing: true, devices: ["BuiltInSpeakerDevice"],
            tapSourceDeviceUID: "BuiltInSpeakerDevice",
            readings: readings(stream: true, drift: false, forensicsHost: onsetHost),
            now: now, timeZone: utc, nanosPerTick: 1
        )
        #expect(line == "onset Google Chrome (PID 1234) at 01:02:03.250 src=stream:BuiltInSpeakerDevice drift=off playing=true "
            + "devices=[BuiltInSpeakerDevice] age=119.75s prevCb=10.667ms dSample=512.0 rateScalar=1.000000 buffers=1 buf0=4096B/2ch")
    }

    @Test("Ended line adds the run length and number, and drops forensics that belong to a later run")
    func endedLine() {
        let line = ZeroRunEvent.ended(startHostTime: onsetHost, frames: 202_240, seconds: 4.2133, run: 3).logLine(
            appName: "QuickTime Player", pid: 77, playing: false, devices: ["A", "B"],
            tapSourceDeviceUID: nil,
            readings: readings(stream: false, drift: true, forensicsHost: onsetHost + 5),
            now: now, timeZone: utc, nanosPerTick: 1
        )
        #expect(line == "ended QuickTime Player (PID 77) at 01:02:03.250 length=4.213s frames=202240 run=3 "
            + "src=mixdown drift=on playing=false devices=[A,B] age=119.75s forensics=n/a")
    }
}
