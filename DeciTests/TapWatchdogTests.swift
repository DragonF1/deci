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
