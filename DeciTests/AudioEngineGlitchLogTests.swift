// DeciTests/AudioEngineGlitchLogTests.swift
//
// The engine's persisted glitch evidence: one combined [GLITCH] line per tap, at most once a
// second, and only when a dropout or IO discontinuity counter grew since the line before.
// The line's text itself is asserted in GlitchLogLineTests; here it is when the line appears.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import Deci

@Suite("AudioEngine: [GLITCH] log lines")
@MainActor
struct AudioEngineGlitchLogTests {
    let h = EngineHarness()

    /// A launched, healthy tap (it hears signal, nothing for the watchdog to do) and the lines the engine logs for it.
    private final class Lines {
        var all: [String] = []
    }

    private func launchWithSink(pid: pid_t = 4242, ids: [AudioObjectID] = [10]) -> (RecordingProcessTapController, Lines) {
        let sink = Lines()
        h.engine.onGlitchLine = { sink.all.append($0) }
        let tap = h.launch(h.makeApp(pid: pid, ids: ids))
        tap.readings = readings()
        return (tap, sink)
    }

    private func readings(
        dropouts: UInt32 = 0,
        latestSeconds: Double = 0,
        discontinuities: UInt32 = 0
    ) -> TapHealthReadings {
        TapHealthReadings(
            isSwitching: false,
            secondsSinceTapStart: 120,
            inputSignalSeen: true,
            secondsSinceInputSignal: 0,
            secondsSinceDiscontinuity: .infinity,
            discontinuityCount: discontinuities,
            dropoutCount: dropouts,
            lastDropoutSeconds: latestSeconds,
            secondsSinceHealthyOutput: 0.1
        )
    }

    /// Runs `count` health ticks (the engine's second tick is every fourth).
    private func ticks(_ count: Int) async {
        for _ in 0..<count { await h.engine.runHealthTick() }
    }

    // MARK: - When a line is written

    @Test("A tap with no dropouts and no discontinuities never logs")
    func quietTapLogsNothing() async {
        let (_, sink) = launchWithSink()
        await ticks(12)
        #expect(sink.all.isEmpty)
    }

    @Test("A dropout is logged on the next once-per-second tick, not on the 250 ms tick that saw it")
    func loggedOnSecondTick() async {
        let (tap, sink) = launchWithSink()
        tap.readings = readings(dropouts: 2, latestSeconds: 0.0123)
        await ticks(3)
        #expect(sink.all.isEmpty, "ticks 1 to 3 are not second ticks")
        await ticks(1)
        #expect(sink.all.count == 1)
    }

    @Test("The line carries the app, pid, the growth, the gap, the tap's devices and a load figure")
    func lineContent() async {
        let (tap, sink) = launchWithSink(pid: 777)
        tap.readings = readings(dropouts: 3, latestSeconds: 0.0123, discontinuities: 1)
        await ticks(4)

        guard let line = sink.all.first else {
            Issue.record("expected a [GLITCH] line")
            return
        }
        let devices = tap.currentDeviceUIDs.joined(separator: ",")
        let expectedStart = "[GLITCH] app=\"Chrome\" pid=777 dropouts=+3 latest_ms=12.3 discontinuities=+1 devices=\(devices) load="
        #expect(line.hasPrefix(expectedStart))
        let load = line.dropFirst(expectedStart.count)
        #expect(Double(load) != nil, "the line ends with the load figure")
        #expect(load.split(separator: ".").last?.count == 2, "two decimals")
    }

    @Test("A discontinuity alone is logged, with dropouts=+0")
    func discontinuityAlone() async {
        let (tap, sink) = launchWithSink()
        tap.readings = readings(discontinuities: 2)
        await ticks(4)
        #expect(sink.all.count == 1)
        #expect(sink.all.first?.contains(" dropouts=+0 latest_ms=0.0 discontinuities=+2 ") == true)
    }

    @Test("A dropout alone is logged, with discontinuities=+0")
    func dropoutAlone() async {
        let (tap, sink) = launchWithSink()
        tap.readings = readings(dropouts: 1, latestSeconds: 0.01)
        await ticks(4)
        #expect(sink.all.count == 1)
        #expect(sink.all.first?.contains(" dropouts=+1 latest_ms=10.0 discontinuities=+0 ") == true)
    }

    @Test("At most one line per second: several seconds' worth of growth between two lines is one line")
    func oneLinePerSecond() async {
        let (tap, sink) = launchWithSink()
        tap.readings = readings(dropouts: 1, latestSeconds: 0.01)
        await ticks(2)
        tap.readings = readings(dropouts: 4, latestSeconds: 0.02)
        await ticks(1)
        tap.readings = readings(dropouts: 6, latestSeconds: 0.03)
        await ticks(1)

        #expect(sink.all.count == 1)
        #expect(sink.all.first?.contains(" dropouts=+6 latest_ms=30.0 ") == true, "the whole second's growth, with the latest gap")
    }

    @Test("Counters that stay where they were do not repeat the line")
    func noRepeat() async {
        let (tap, sink) = launchWithSink()
        tap.readings = readings(dropouts: 3, latestSeconds: 0.01, discontinuities: 1)
        await ticks(12)
        #expect(sink.all.count == 1)
    }

    @Test("More growth later logs only the new part")
    func growthSinceTheLastLine() async {
        let (tap, sink) = launchWithSink()
        tap.readings = readings(dropouts: 3, latestSeconds: 0.01, discontinuities: 1)
        await ticks(4)
        tap.readings = readings(dropouts: 5, latestSeconds: 0.02, discontinuities: 1)
        await ticks(4)

        #expect(sink.all.count == 2)
        #expect(sink.all.last?.contains(" dropouts=+2 latest_ms=20.0 discontinuities=+0 ") == true)
    }

    @Test("A tap that starts over (counters back to zero, then growing) logs its new growth")
    func countersStartOver() async {
        let (tap, sink) = launchWithSink()
        tap.readings = readings(dropouts: 9, latestSeconds: 0.01, discontinuities: 4)
        await ticks(4)
        tap.readings = readings()
        await ticks(4)
        #expect(sink.all.count == 1, "back to zero is not a glitch")

        tap.readings = readings(dropouts: 2, latestSeconds: 0.015)
        await ticks(4)
        #expect(sink.all.count == 2)
        #expect(sink.all.last?.contains(" dropouts=+2 latest_ms=15.0 discontinuities=+0 ") == true)
    }

    @Test("Each tap has its own line and its own baseline")
    func perTap() async {
        let sink = Lines()
        h.engine.onGlitchLine = { sink.all.append($0) }
        let a = h.launch(h.makeApp(pid: 100, ids: [10]))
        let b = h.launch(h.makeApp(pid: 200, ids: [20], bundleID: "com.apple.QuickTimePlayerX"))
        a.readings = readings(dropouts: 1, latestSeconds: 0.01)
        b.readings = readings(dropouts: 4, latestSeconds: 0.02)
        await ticks(4)

        #expect(sink.all.count == 2)
        #expect(sink.all.contains { $0.contains(" pid=100 dropouts=+1 ") })
        #expect(sink.all.contains { $0.contains(" pid=200 dropouts=+4 ") })
    }

    @Test("A tap with no readings yet (its callback never ran) logs nothing")
    func noReadings() async {
        let (tap, sink) = launchWithSink()
        tap.readings = nil
        await ticks(8)
        #expect(sink.all.isEmpty)
    }

    @Test("A user-muted app is logged too: it can still glitch on its way to the device")
    func mutedAppStillLogs() async {
        let (tap, sink) = launchWithSink()
        tap.readings = readings(dropouts: 1, latestSeconds: 0.01)
        tap.isMuted = true
        await ticks(4)
        #expect(sink.all.count == 1)
    }

    // MARK: - Per-pid state

    @Test("A tap that went away takes its baseline with it: the same pid starting over is logged in full")
    func pruned() async {
        let sink = Lines()
        h.engine.onGlitchLine = { sink.all.append($0) }
        let appA = h.makeApp(pid: 100, ids: [10])
        let tapA = h.launch(appA)
        let tapB = h.launch(h.makeApp(pid: 200, ids: [20], bundleID: "com.apple.QuickTimePlayerX"))
        tapA.readings = readings(dropouts: 5, latestSeconds: 0.01)
        tapB.readings = readings()
        await ticks(4)
        #expect(sink.all.count == 1)

        // A goes away for good; B keeps the health ticks running through a pruning pass.
        h.probes.alivePIDs.remove(100)
        h.publish([h.makeApp(pid: 200, ids: [20], bundleID: "com.apple.QuickTimePlayerX")])
        let gone = await waitUntil { tapA.wasInvalidated }
        #expect(gone)
        await ticks(4)

        // The same pid comes back with a new tap that has the same count: not hidden by the old baseline.
        h.probes.alivePIDs.insert(100)
        let tapA2 = h.launch(appA)
        tapA2.readings = readings(dropouts: 5, latestSeconds: 0.01)
        tapB.readings = readings()
        await ticks(4)

        #expect(sink.all.count == 2)
        #expect(sink.all.last?.contains(" pid=100 dropouts=+5 ") == true)
    }

    @Test("The only tap going away drops its baseline too, though the pruning pass does not run with no taps")
    func lastTapGone() async {
        let sink = Lines()
        h.engine.onGlitchLine = { sink.all.append($0) }
        let app = h.makeApp(pid: 100, ids: [10])
        let tap = h.launch(app)
        tap.readings = readings(dropouts: 1, latestSeconds: 0.01)
        await ticks(4)
        #expect(sink.all.count == 1)

        h.probes.alivePIDs.remove(100)
        h.publish([])
        let gone = await waitUntil { tap.wasInvalidated }
        #expect(gone)
        await ticks(4)

        // A new tap for the same pid with one dropout of its own: logged, not hidden by the old tap's 1.
        h.probes.alivePIDs.insert(100)
        let tap2 = h.launch(app)
        tap2.readings = readings(dropouts: 1, latestSeconds: 0.02)
        await ticks(4)

        #expect(sink.all.count == 2)
        #expect(sink.all.last?.contains(" pid=100 dropouts=+1 latest_ms=20.0 ") == true)
    }
}
