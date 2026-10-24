// DeciTests/ChromeTapLatencyReporterTests.swift
//
// ChromeTapLatencyReporter decides what the engine tells the Chrome extension about its tap: only Chrome's own
// stream tap counts, each tapped output maps to the measured seconds, and a message goes out only when the set of
// outputs changes or a value moves by more than 5 ms from the last one sent. The second suite runs the same decisions
// through AudioEngine with the fake tap controller; no process tap is created and no audio plays.

import Foundation
import Testing
@testable import Deci

@Suite("ChromeTapLatencyReporter")
struct ChromeTapLatencyReporterTests {
    private typealias Observation = ChromeTapLatencyReporter.Observation

    private let chrome = "com.google.Chrome"

    private func readings(through seconds: Double, stream: Bool = true) -> TapHealthReadings {
        var readings = TapHealthReadings(
            isSwitching: false,
            secondsSinceTapStart: 60,
            inputSignalSeen: true,
            secondsSinceInputSignal: 0,
            secondsSinceDiscontinuity: .infinity,
            discontinuityCount: 0,
            secondsSinceHealthyOutput: 0
        )
        readings.tapIsStream = stream
        readings.tapThroughSeconds = seconds
        return readings
    }

    private func chromeTap(
        _ seconds: Double,
        on uids: [String] = ["xm5"],
        stream: Bool = true,
        bundleID: String? = "com.google.Chrome"
    ) -> Observation {
        Observation(bundleID: bundleID, deviceUIDs: uids, readings: readings(through: seconds, stream: stream))
    }

    // MARK: First emit

    @Test("with no taps there is nothing to say, and no clear is sent for something never sent")
    func nothingToSay() {
        var reporter = ChromeTapLatencyReporter()
        #expect(reporter.next(readings: []) == nil)
        #expect(reporter.next(readings: []) == nil)
    }

    @Test("a Chrome stream tap with a measurement is reported on its output")
    func firstEmit() {
        var reporter = ChromeTapLatencyReporter()
        #expect(reporter.next(readings: [chromeTap(0.046)]) == ["xm5": 0.046])
    }

    @Test("every device the tap plays on gets the seconds")
    func allTappedDevices() {
        var reporter = ChromeTapLatencyReporter()
        let emitted = reporter.next(readings: [chromeTap(0.046, on: ["xm5", "buds"])])
        #expect(emitted == ["xm5": 0.046, "buds": 0.046])
    }

    @Test("the same reading again says nothing")
    func repeatIsQuiet() {
        var reporter = ChromeTapLatencyReporter()
        _ = reporter.next(readings: [chromeTap(0.046)])
        #expect(reporter.next(readings: [chromeTap(0.046)]) == nil)
        #expect(reporter.next(readings: [chromeTap(0.046)]) == nil)
    }

    // MARK: Threshold

    @Test("a move of 5 ms or less is not reported, more than 5 ms is")
    func threshold() {
        var reporter = ChromeTapLatencyReporter()
        _ = reporter.next(readings: [chromeTap(0.040)])
        #expect(reporter.next(readings: [chromeTap(0.0449)]) == nil)
        #expect(reporter.next(readings: [chromeTap(0.0351)]) == nil)
        #expect(reporter.next(readings: [chromeTap(0.0451)]) == ["xm5": 0.0451])
    }

    @Test("the threshold is measured against the last value sent, so a slow drift still gets through")
    func driftAccumulates() {
        var reporter = ChromeTapLatencyReporter()
        _ = reporter.next(readings: [chromeTap(0.040)])
        #expect(reporter.next(readings: [chromeTap(0.043)]) == nil)
        #expect(reporter.next(readings: [chromeTap(0.0449)]) == nil)
        // 5.5 ms from the 0.040 that was sent, though only 0.6 ms from the previous reading.
        #expect(reporter.next(readings: [chromeTap(0.0455)]) == ["xm5": 0.0455])
        // And the new baseline is the value just sent.
        #expect(reporter.next(readings: [chromeTap(0.048)]) == nil)
    }

    @Test("with several devices, one of them moving enough sends them all")
    func oneDeviceMoves() {
        var reporter = ChromeTapLatencyReporter()
        _ = reporter.next(readings: [chromeTap(0.040, on: ["xm5", "buds"])])
        let moved = Observation(bundleID: chrome, deviceUIDs: ["xm5"], readings: readings(through: 0.060))
        let steady = Observation(bundleID: chrome, deviceUIDs: ["buds"], readings: readings(through: 0.041))
        #expect(reporter.next(readings: [moved, steady]) == ["xm5": 0.060, "buds": 0.041])
    }

    // MARK: UID set

    @Test("a different set of outputs is reported even when the value is the same")
    func uidSetChange() {
        var reporter = ChromeTapLatencyReporter()
        _ = reporter.next(readings: [chromeTap(0.046, on: ["xm5"])])
        #expect(reporter.next(readings: [chromeTap(0.046, on: ["xm5", "buds"])]) == ["xm5": 0.046, "buds": 0.046])
        #expect(reporter.next(readings: [chromeTap(0.046, on: ["buds"])]) == ["buds": 0.046])
        #expect(reporter.next(readings: [chromeTap(0.046, on: ["speakers"])]) == ["speakers": 0.046])
    }

    @Test("the order of the devices does not count as a change")
    func uidOrderIsNotAChange() {
        var reporter = ChromeTapLatencyReporter()
        _ = reporter.next(readings: [chromeTap(0.046, on: ["xm5", "buds"])])
        #expect(reporter.next(readings: [chromeTap(0.046, on: ["buds", "xm5"])]) == nil)
    }

    // MARK: Clearing

    @Test("a tap that turns into a mixdown clears once")
    func clearOnMixdown() {
        var reporter = ChromeTapLatencyReporter()
        _ = reporter.next(readings: [chromeTap(0.046)])
        #expect(reporter.next(readings: [chromeTap(0.046, stream: false)]) == [:])
        #expect(reporter.next(readings: [chromeTap(0.046, stream: false)]) == nil)
    }

    @Test("a mixdown tap is never reported, whatever it measures")
    func mixdownNeverReported() {
        var reporter = ChromeTapLatencyReporter()
        #expect(reporter.next(readings: [chromeTap(0.080, stream: false)]) == nil)
    }

    @Test("a Chrome tap that goes away clears once")
    func clearWhenGone() {
        var reporter = ChromeTapLatencyReporter()
        _ = reporter.next(readings: [chromeTap(0.046)])
        #expect(reporter.next(readings: []) == [:])
        #expect(reporter.next(readings: []) == nil)
    }

    @Test("a reading of zero clears once, and so do values that are negative or not finite")
    func clearOnZero() {
        for bad in [0.0, -0.01, Double.nan, Double.infinity] {
            var reporter = ChromeTapLatencyReporter()
            _ = reporter.next(readings: [chromeTap(0.046)])
            #expect(reporter.next(readings: [chromeTap(bad)]) == [:], "reading \(bad)")
            #expect(reporter.next(readings: [chromeTap(bad)]) == nil, "reading \(bad)")
        }
    }

    @Test("a tap that has not rendered yet (no readings) counts as no measurement")
    func noReadingsClears() {
        var reporter = ChromeTapLatencyReporter()
        #expect(reporter.next(readings: [Observation(bundleID: chrome, deviceUIDs: ["xm5"], readings: nil)]) == nil)
        _ = reporter.next(readings: [chromeTap(0.046)])
        #expect(reporter.next(readings: [Observation(bundleID: chrome, deviceUIDs: ["xm5"], readings: nil)]) == [:])
    }

    @Test("a measurement after a clear is reported again, even at the old value")
    func reportsAgainAfterClear() {
        var reporter = ChromeTapLatencyReporter()
        _ = reporter.next(readings: [chromeTap(0.046)])
        _ = reporter.next(readings: [])
        #expect(reporter.next(readings: [chromeTap(0.046)]) == ["xm5": 0.046])
    }

    // MARK: Which taps count

    @Test("taps of other apps are ignored, whatever they measure")
    func otherAppsIgnored() {
        var reporter = ChromeTapLatencyReporter()
        let other = chromeTap(0.090, on: ["xm5"], bundleID: "com.apple.Music")
        let noBundle = chromeTap(0.090, on: ["xm5"], bundleID: nil)
        #expect(reporter.next(readings: [other, noBundle]) == nil)
    }

    @Test("only Chrome's devices and seconds are reported when other taps run beside it")
    func chromeAmongOthers() {
        var reporter = ChromeTapLatencyReporter()
        let other = chromeTap(0.090, on: ["speakers"], bundleID: "com.apple.Music")
        #expect(reporter.next(readings: [other, chromeTap(0.046)]) == ["xm5": 0.046])
    }

    @Test("another app's tap changing does not send anything")
    func otherAppChangesAreQuiet() {
        var reporter = ChromeTapLatencyReporter()
        _ = reporter.next(readings: [chromeTap(0.046)])
        let other = chromeTap(0.200, on: ["speakers"], bundleID: "com.apple.Music")
        #expect(reporter.next(readings: [chromeTap(0.046), other]) == nil)
    }

    @Test("when Chrome's tap goes away while another app's stays, Chrome's entry is cleared")
    func chromeGoneOtherStays() {
        var reporter = ChromeTapLatencyReporter()
        let other = chromeTap(0.090, on: ["speakers"], bundleID: "com.apple.Music")
        _ = reporter.next(readings: [other, chromeTap(0.046)])
        #expect(reporter.next(readings: [other]) == [:])
    }

    @Test("two Chrome taps on one device report the larger value")
    func twoChromeTapsOneDevice() {
        var reporter = ChromeTapLatencyReporter()
        let a = chromeTap(0.040, on: ["xm5"])
        let b = chromeTap(0.052, on: ["xm5", "buds"])
        #expect(reporter.next(readings: [a, b]) == ["xm5": 0.052, "buds": 0.052])
    }

    @Test("a Chrome stream tap with no devices has nothing to report")
    func noDevices() {
        var reporter = ChromeTapLatencyReporter()
        #expect(reporter.next(readings: [chromeTap(0.046, on: [])]) == nil)
    }
}

@Suite("AudioEngine: Chrome tap latency")
@MainActor
struct AudioEngineChromeTapLatencyTests {
    let h = EngineHarness()

    private func readings(through seconds: Double, stream: Bool = true) -> TapHealthReadings {
        var readings = TapHealthReadings(
            isSwitching: false,
            secondsSinceTapStart: 60,
            inputSignalSeen: true,
            secondsSinceInputSignal: 0,
            secondsSinceDiscontinuity: .infinity,
            discontinuityCount: 0,
            secondsSinceHealthyOutput: 0
        )
        readings.tapIsStream = stream
        readings.tapThroughSeconds = seconds
        return readings
    }

    /// Collects what the engine reports through `onChromeTapLatencyChange`.
    private final class Emitted {
        var maps: [[String: Double]] = []
    }

    private func listen() -> Emitted {
        let emitted = Emitted()
        h.engine.onChromeTapLatencyChange = { emitted.maps.append($0) }
        return emitted
    }

    @Test("a Chrome stream tap that measured its latency is reported by device UID")
    func reportsTheChromeTap() {
        let emitted = listen()
        let tap = h.launch(h.makeApp(ids: [10]))
        tap.readings = readings(through: 0.046)

        h.engine.pollChromeTapLatency()

        #expect(emitted.maps == [[tap.currentDeviceUIDs[0]: 0.046]])
    }

    @Test("polling again with the same reading reports nothing more")
    func repeatPollIsQuiet() {
        let emitted = listen()
        let tap = h.launch(h.makeApp(ids: [10]))
        tap.readings = readings(through: 0.046)

        h.engine.pollChromeTapLatency()
        h.engine.pollChromeTapLatency()

        #expect(emitted.maps.count == 1)
    }

    @Test("a tap of another app is not reported")
    func otherAppIsIgnored() {
        let emitted = listen()
        let tap = h.launch(h.makeApp(ids: [10], bundleID: "com.apple.Music"))
        tap.readings = readings(through: 0.046)

        h.engine.pollChromeTapLatency()

        #expect(emitted.maps.isEmpty)
    }

    @Test("a Chrome tap that turns into a mixdown is cleared")
    func mixdownClears() {
        let emitted = listen()
        let tap = h.launch(h.makeApp(ids: [10]))
        tap.readings = readings(through: 0.046)
        h.engine.pollChromeTapLatency()

        tap.readings = readings(through: 0.046, stream: false)
        h.engine.pollChromeTapLatency()

        #expect(emitted.maps.count == 2)
        #expect(emitted.maps.last == [:])
    }

    @Test("the poll does not depend on the health tick, so a Chrome tap that is gone is cleared with no taps left")
    func clearsWithNoTapsLeft() async {
        let emitted = listen()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)
        tap.readings = readings(through: 0.046)
        h.engine.pollChromeTapLatency()
        #expect(emitted.maps.count == 1)

        h.probes.alivePIDs.remove(app.id)
        h.publish([])
        let cleaned = await waitUntil { tap.wasInvalidated }
        #expect(cleaned, "the engine should drop the tap of a process that is gone")

        // runHealthTick returns at once with no taps; the poll must still see the Chrome tap leave.
        await h.engine.runHealthTick()
        h.engine.pollChromeTapLatency()

        #expect(emitted.maps.last == [:])
        #expect(emitted.maps.count == 2)
    }

    @Test("stopping the engine clears what it reported")
    func stopClears() {
        let emitted = listen()
        let tap = h.launch(h.makeApp(ids: [10]))
        tap.readings = readings(through: 0.046)
        h.engine.pollChromeTapLatency()

        h.engine.stop()

        #expect(emitted.maps.last == [:])
    }

    @Test("with no callback set the poll is harmless")
    func noCallback() {
        let tap = h.launch(h.makeApp(ids: [10]))
        tap.readings = readings(through: 0.046)
        h.engine.pollChromeTapLatency()
    }
}
