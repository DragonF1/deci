// DeciTests/GlitchLogLineTests.swift
//
// The [GLITCH] log lines are a contract with the glitch report script, which parses them: the
// text is asserted character for character. Also the cursor that decides when a tap's counters
// have grown enough to log, and the defaults the new health readings keep for old call sites.

import Testing
import Foundation
@testable import Deci

@Suite("GlitchLogLine: the exact text")
struct GlitchLogLineTests {

    @Test("a tap line: app, pid, dropout delta, latest gap in ms, discontinuity delta, devices, load")
    func fullLine() {
        let line = GlitchLogLine.make(
            appName: "Google Chrome",
            pid: 1234,
            dropouts: 3,
            latestDropoutSeconds: 0.0123,
            discontinuities: 1,
            devices: ["AirPods-uid:output", "BuiltInSpeakerDevice"],
            load: 2.456
        )
        #expect(line == "[GLITCH] app=\"Google Chrome\" pid=1234 dropouts=+3 latest_ms=12.3 discontinuities=+1 devices=AirPods-uid:output,BuiltInSpeakerDevice load=2.46")
    }

    @Test("a counter that did not move prints +0")
    func zeroDeltas() {
        let dropoutsOnly = GlitchLogLine.make(
            appName: "Chrome", pid: 7, dropouts: 2, latestDropoutSeconds: 0.0105,
            discontinuities: 0, devices: ["uid-a"], load: 1
        )
        #expect(dropoutsOnly == "[GLITCH] app=\"Chrome\" pid=7 dropouts=+2 latest_ms=10.5 discontinuities=+0 devices=uid-a load=1.00")

        let discontinuitiesOnly = GlitchLogLine.make(
            appName: "Chrome", pid: 7, dropouts: 0, latestDropoutSeconds: 0,
            discontinuities: 4, devices: ["uid-a"], load: 0
        )
        #expect(discontinuitiesOnly == "[GLITCH] app=\"Chrome\" pid=7 dropouts=+0 latest_ms=0.0 discontinuities=+4 devices=uid-a load=0.00")
    }

    @Test("latest_ms has one decimal and load two, with a point, whatever the locale")
    func decimals() {
        let line = GlitchLogLine.make(
            appName: "Spotify", pid: 99, dropouts: 1, latestDropoutSeconds: 0.25,
            discontinuities: 0, devices: ["d"], load: 12.346
        )
        #expect(line.contains(" latest_ms=250.0 "))
        #expect(line.hasSuffix(" load=12.35"))
    }

    @Test("several devices are joined with a comma and no space, in order")
    func deviceJoin() {
        let line = GlitchLogLine.make(
            appName: "Chrome", pid: 1, dropouts: 1, latestDropoutSeconds: 0.01,
            discontinuities: 0, devices: ["a", "b", "c"], load: 0.5
        )
        #expect(line.contains(" devices=a,b,c load=0.50"))
    }

    @Test("no devices leaves the field empty so the line keeps its shape")
    func noDevices() {
        let line = GlitchLogLine.make(
            appName: "Chrome", pid: 1, dropouts: 1, latestDropoutSeconds: 0.01,
            discontinuities: 0, devices: [], load: 0.5
        )
        #expect(line.contains(" devices= load=0.50"))
    }

    @Test("a quote or a line break in an app name cannot break the quoted field")
    func appNameIsContained() {
        let line = GlitchLogLine.make(
            appName: "My \"Player\"\nPro", pid: 1, dropouts: 1, latestDropoutSeconds: 0.01,
            discontinuities: 0, devices: ["d"], load: 0.5
        )
        #expect(line.hasPrefix("[GLITCH] app=\"My 'Player' Pro\" pid=1 "))
        #expect(!line.contains("\n"))
    }

    @Test("a line with no new dropout prints latest_ms=0.0 even when an older dropout had a length")
    func latestOnlyWithNewDropouts() {
        let line = GlitchLogLine.make(
            appName: "Chrome", pid: 7, dropouts: 0, latestDropoutSeconds: 0.0123,
            discontinuities: 2, devices: ["d"], load: 1
        )
        #expect(line.contains(" dropouts=+0 latest_ms=0.0 discontinuities=+2 "))
    }

    @Test("a space, comma, quote or line break in a device UID cannot split the devices field")
    func deviceUIDsAreContained() {
        let line = GlitchLogLine.make(
            appName: "Chrome", pid: 7, dropouts: 1, latestDropoutSeconds: 0.01,
            discontinuities: 0, devices: ["My Speaker", "a,b", "q\"x\ny"], load: 1
        )
        #expect(line.hasSuffix(" devices=My_Speaker,a_b,q_x_y load=1.00"))
    }

    @Test("a non-finite gap length or load prints as zero, never nan or inf")
    func nonFiniteNumbers() {
        let line = GlitchLogLine.make(
            appName: "Chrome", pid: 1, dropouts: 1, latestDropoutSeconds: .nan,
            discontinuities: 0, devices: ["d"], load: .infinity
        )
        #expect(line == "[GLITCH] app=\"Chrome\" pid=1 dropouts=+1 latest_ms=0.0 discontinuities=+0 devices=d load=0.00")
    }

    @Test("a large delta prints in full")
    func largeDelta() {
        let line = GlitchLogLine.make(
            appName: "Chrome", pid: 1, dropouts: .max, latestDropoutSeconds: 0.01,
            discontinuities: 0, devices: ["d"], load: 0.5
        )
        #expect(line.contains(" dropouts=+4294967295 "))
    }

    @Test("the music player's stall line")
    func stallLine() {
        #expect(GlitchLogLine.makeStall(appName: "Deci music", load: 3.2) == "[GLITCH] app=\"Deci music\" stalled=1 load=3.20")
        #expect(GlitchLogLine.makeStall(appName: GlitchLogLine.musicAppName, load: 0) == "[GLITCH] app=\"Deci music\" stalled=1 load=0.00")
    }

    @Test("the one-minute load average is a finite, non-negative number")
    func loadAverage() {
        let load = GlitchLogLine.loadAverage()
        #expect(load.isFinite)
        #expect(load >= 0)
    }
}

@Suite("GlitchLogCursor: when a tap's counters have grown")
struct GlitchLogCursorTests {

    @Test("nothing has moved: no line")
    func quiet() {
        var cursor = GlitchLogCursor()
        #expect(cursor.growth(dropouts: 0, discontinuities: 0) == nil)
        #expect(cursor.growth(dropouts: 0, discontinuities: 0) == nil)
    }

    @Test("growth is reported once, as the change since the last line")
    func reportsDelta() {
        var cursor = GlitchLogCursor()
        #expect(cursor.growth(dropouts: 3, discontinuities: 0) == GlitchLogCursor.Growth(dropouts: 3, discontinuities: 0))
        #expect(cursor.growth(dropouts: 3, discontinuities: 0) == nil, "the same counters again are not news")
        #expect(cursor.growth(dropouts: 5, discontinuities: 0) == GlitchLogCursor.Growth(dropouts: 2, discontinuities: 0))
    }

    @Test("either counter alone is enough, and the other prints +0")
    func eitherCounter() {
        var cursor = GlitchLogCursor()
        #expect(cursor.growth(dropouts: 0, discontinuities: 2) == GlitchLogCursor.Growth(dropouts: 0, discontinuities: 2))
        #expect(cursor.growth(dropouts: 1, discontinuities: 2) == GlitchLogCursor.Growth(dropouts: 1, discontinuities: 0))
        #expect(cursor.growth(dropouts: 4, discontinuities: 3) == GlitchLogCursor.Growth(dropouts: 3, discontinuities: 1))
    }

    @Test("counters that went back (a new tap, a reset) count again from zero")
    func counterReset() {
        var cursor = GlitchLogCursor()
        _ = cursor.growth(dropouts: 7, discontinuities: 5)

        #expect(cursor.growth(dropouts: 2, discontinuities: 5) == GlitchLogCursor.Growth(dropouts: 2, discontinuities: 0))
        #expect(cursor.growth(dropouts: 0, discontinuities: 0) == nil, "back to zero is not growth")
        #expect(cursor.growth(dropouts: 1, discontinuities: 0) == GlitchLogCursor.Growth(dropouts: 1, discontinuities: 0), "the baseline moved down with them")
    }

    @Test("a counter that went back while the other grew still reports the growth")
    func resetWithOtherGrowth() {
        var cursor = GlitchLogCursor()
        _ = cursor.growth(dropouts: 7, discontinuities: 1)
        #expect(cursor.growth(dropouts: 0, discontinuities: 3) == GlitchLogCursor.Growth(dropouts: 0, discontinuities: 2))
    }
}

@Suite("TapHealthReadings: dropout fields")
struct TapHealthReadingsDropoutTests {

    @Test("existing initialisers still compile and read no dropouts")
    func defaults() {
        let readings = TapHealthReadings(
            isSwitching: false,
            secondsSinceTapStart: 10,
            inputSignalSeen: true,
            secondsSinceInputSignal: 0,
            secondsSinceDiscontinuity: .infinity,
            discontinuityCount: 0,
            secondsSinceHealthyOutput: 0
        )
        #expect(readings.dropoutCount == 0)
        #expect(readings.lastDropoutSeconds == 0)
    }

    @Test("the dropout fields can be set alongside the others")
    func settable() {
        var readings = TapHealthReadings(
            isSwitching: false,
            secondsSinceTapStart: 10,
            inputSignalSeen: true,
            secondsSinceInputSignal: 0,
            secondsSinceDiscontinuity: .infinity,
            discontinuityCount: 2,
            dropoutCount: 5,
            lastDropoutSeconds: 0.012,
            secondsSinceHealthyOutput: 0
        )
        #expect(readings.dropoutCount == 5)
        #expect(readings.lastDropoutSeconds == 0.012)
        #expect(readings.discontinuityCount == 2)
        readings.dropoutCount = 6
        #expect(readings.dropoutCount == 6)
    }
}
