// DeciTests/TapWatchdogTests.swift
//
// Pure-value tests for TapWatchdog: when a tap that runs but delivers nothing is rescued
// (probed with a candidate tap) or rebuilt.

import Testing
import Foundation
@testable import Deci

/// A tap that has played for a while, with signal a moment ago and no disturbance.
/// `playing: nil` is "IsRunningOutput was not read" (nothing was silent long enough to ask).
private func healthy(
    tapAge: Double = 120,
    signalSeen: Bool = true,
    silentFor: Double = 0.1,
    discontinuityAge: Double = .infinity,
    outputSilentFor: Double = 0.1,
    switching: Bool = false,
    playing: Bool? = true,
    muted: Bool = false,
    clock: Double = 0
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
        isUserMuted: muted,
        clock: clock
    )
}

@Suite("TapWatchdog: rescue ladder")
struct TapWatchdogLadderTests {

    @Test("Rungs sit at 0.25, 2, 4 and 8 s of silence, then every 20 s")
    func rungThresholds() {
        #expect(TapWatchdog.rescueThreshold(rung: 0) == 0.25)
        #expect(TapWatchdog.rescueThreshold(rung: 1) == 2)
        #expect(TapWatchdog.rescueThreshold(rung: 2) == 4)
        #expect(TapWatchdog.rescueThreshold(rung: 3) == 8)
        #expect(TapWatchdog.rescueThreshold(rung: 4) == 28)
        #expect(TapWatchdog.rescueThreshold(rung: 5) == 48)
        #expect(TapWatchdog.rescueThreshold(rung: 9) == 128)
    }

    @Test("firstRung(after:) is the first rung strictly past the given silence")
    func firstRungAfter() {
        #expect(TapWatchdog.firstRung(after: 0) == 0)
        #expect(TapWatchdog.firstRung(after: 0.24) == 0)
        #expect(TapWatchdog.firstRung(after: 0.25) == 1)
        #expect(TapWatchdog.firstRung(after: 0.3) == 1)
        #expect(TapWatchdog.firstRung(after: 2) == 2)
        #expect(TapWatchdog.firstRung(after: 7.9) == 3)
        #expect(TapWatchdog.firstRung(after: 8.5) == 4)
        #expect(TapWatchdog.firstRung(after: 28) == 5)
        #expect(TapWatchdog.firstRung(after: 30) == 5)
        #expect(TapWatchdog.firstRung(after: 48) == 6)
    }

    @Test("Silence under 0.25 s is left alone")
    func belowFirstRung() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 0.0)) == nil)
        #expect(w.evaluate(healthy(silentFor: 0.24)) == nil)
    }

    @Test("A rescue is asked for once the input has been exact-zero for 0.25 s")
    func firstRescueAtQuarterSecond() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 0.25)) == .rescue(.unexplainedSilence, rung: 0))
    }

    @Test("Without a verdict the same rung is asked again")
    func sameRungUntilVerdict() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 0.3)) == .rescue(.unexplainedSilence, rung: 0))
        #expect(w.evaluate(healthy(silentFor: 0.55)) == .rescue(.unexplainedSilence, rung: 0))
    }

    @Test("An inconclusive rescue steps the ladder: 2 s, 4 s, 8 s, then every 20 s")
    func ladderSteps() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 0.3)) == .rescue(.unexplainedSilence, rung: 0))
        w.rescueInconclusive(atSilence: 0.3, clock: 0.3)

        #expect(w.evaluate(healthy(silentFor: 1.9)) == nil)
        #expect(w.evaluate(healthy(silentFor: 2.0)) == .rescue(.unexplainedSilence, rung: 1))
        w.rescueInconclusive(atSilence: 2.0, clock: 2.0)

        #expect(w.evaluate(healthy(silentFor: 3.9)) == nil)
        #expect(w.evaluate(healthy(silentFor: 4.0)) == .rescue(.unexplainedSilence, rung: 2))
        w.rescueInconclusive(atSilence: 4.0, clock: 4.0)

        #expect(w.evaluate(healthy(silentFor: 7.9)) == nil)
        #expect(w.evaluate(healthy(silentFor: 8.0)) == .rescue(.unexplainedSilence, rung: 3))
        w.rescueInconclusive(atSilence: 8.0, clock: 8.0)

        #expect(w.evaluate(healthy(silentFor: 27.9)) == nil)
        #expect(w.evaluate(healthy(silentFor: 28.0)) == .rescue(.unexplainedSilence, rung: 4))
        w.rescueInconclusive(atSilence: 28.0, clock: 28.0)

        #expect(w.evaluate(healthy(silentFor: 47.9)) == nil)
        #expect(w.evaluate(healthy(silentFor: 48.0)) == .rescue(.unexplainedSilence, rung: 5))
    }

    @Test("A rescue that could only start late skips the rungs already passed")
    func lateRescueSkipsPassedRungs() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 5)) == .rescue(.unexplainedSilence, rung: 0))
        w.rescueInconclusive(atSilence: 5, clock: 5)
        #expect(w.evaluate(healthy(silentFor: 7.9)) == nil)
        #expect(w.evaluate(healthy(silentFor: 8)) == .rescue(.unexplainedSilence, rung: 3))
    }

    @Test("Signal coming back resets the ladder to the first rung once the last probe is 10 s old")
    func signalResetsLadder() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 0.3, clock: 100))
        w.rescueInconclusive(atSilence: 0.3, clock: 100.5)
        _ = w.evaluate(healthy(silentFor: 2.0, clock: 102))
        w.rescueInconclusive(atSilence: 2.0, clock: 102.5)
        #expect(w.nextRung == 2)

        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 120)) == nil)
        #expect(w.nextRung == 0)
        #expect(w.lastInconclusiveClock == nil)
        #expect(w.evaluate(healthy(silentFor: 0.3, clock: 121)) == .rescue(.unexplainedSilence, rung: 0))
    }

    @Test("One probe is a gap between tracks: signal resets to the first rung at once")
    func singleProbeResets() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 0.3, clock: 100)) == .rescue(.unexplainedSilence, rung: 0))
        w.rescueInconclusive(atSilence: 0.3, clock: 100.5)
        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 101.2)) == nil)
        #expect(w.nextRung == 0)

        // The tap dies 3 s into the next track: the first rung still fires at 0.25 s.
        #expect(w.evaluate(healthy(silentFor: 0.3, clock: 104.5)) == .rescue(.unexplainedSilence, rung: 0))
        // That probe chains with the gap's (4 s apart), so the next return keeps rung 1.
        w.rescueInconclusive(atSilence: 0.3, clock: 104.8)
        #expect(w.recentInconclusive == 2)
        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 106)) == nil)
        #expect(w.nextRung == 1)
    }

    @Test("Signal within 10 s of a second chained probe keeps rung 1: a bursty app's next gap needs 2 s")
    func ladderMemoryKeepsRung() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 0.3, clock: 100)) == .rescue(.unexplainedSilence, rung: 0))
        w.rescueInconclusive(atSilence: 0.3, clock: 100.5)
        #expect(w.evaluate(healthy(silentFor: 2.0, clock: 102)) == .rescue(.unexplainedSilence, rung: 1))
        w.rescueInconclusive(atSilence: 2.0, clock: 102.5)

        // A burst of sound, then another gap.
        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 105)) == nil)
        #expect(w.nextRung == 1)
        #expect(w.evaluate(healthy(silentFor: 0.3, clock: 106)) == nil)
        #expect(w.evaluate(healthy(silentFor: 1.9, clock: 107.6)) == nil)
        #expect(w.evaluate(healthy(silentFor: 2.0, clock: 107.7)) == .rescue(.unexplainedSilence, rung: 1))
    }

    @Test("The ladder memory expires exactly 10 s after the last inconclusive probe")
    func ladderMemoryExpires() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 0.3, clock: 100))
        w.rescueInconclusive(atSilence: 0.3, clock: 100)
        w.rescueInconclusive(atSilence: 2.0, clock: 102)

        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 111.9)) == nil)
        #expect(w.nextRung == 1)
        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 112)) == nil)
        #expect(w.nextRung == 0)
        #expect(w.lastInconclusiveClock == nil)
        #expect(w.recentInconclusive == 0)
    }

    @Test("A newer inconclusive probe restarts the 10 s")
    func ladderMemoryRestarts() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 0.3, clock: 100))
        w.rescueInconclusive(atSilence: 0.3, clock: 100)
        _ = w.evaluate(healthy(silentFor: 2.0, clock: 108))
        w.rescueInconclusive(atSilence: 2.0, clock: 108)

        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 112)) == nil)
        #expect(w.nextRung == 1, "only 4 s since the last probe")
        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 117.9)) == nil)
        #expect(w.nextRung == 1)
        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 118)) == nil)
        #expect(w.nextRung == 0)
    }

    @Test("Playback resuming right after a short pause's 8 s probe waits 2 s, not the paused rung's 28 s")
    func ladderMemoryCapsAtRungOne() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 0.3, clock: 100))
        w.rescueInconclusive(atSilence: 0.3, clock: 100)
        for silence in [2.0, 4.0, 8.0] {
            w.rescueInconclusive(atSilence: silence, clock: 100 + silence)
        }
        #expect(w.nextRung == 4)

        // Resumed 2 s after the 8 s probe, then the tap dies.
        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 110)) == nil)
        #expect(w.nextRung == 1)
        #expect(w.evaluate(healthy(silentFor: 1.9, clock: 112)) == nil)
        #expect(w.evaluate(healthy(silentFor: 2.0, clock: 112.1)) == .rescue(.unexplainedSilence, rung: 1))
    }

    @Test("A long pause's 20 s probes break the chain: playback resuming gets the first rung back")
    func longPauseResumesAtFirstRung() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 0.3, clock: 100))
        w.rescueInconclusive(atSilence: 0.3, clock: 100)
        for silence in [2.0, 4.0, 8.0, 28.0, 48.0] {
            w.rescueInconclusive(atSilence: silence, clock: 100 + silence)
        }
        #expect(w.nextRung == 6)
        #expect(w.recentInconclusive == 1)

        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 150)) == nil)
        #expect(w.nextRung == 0)
    }

    @Test("The fallback-rebuild budget follows the same memory as the rung")
    func fallbackBudgetFollowsMemory() {
        var w = TapWatchdog()
        for _ in 0..<TapWatchdog.maxFallbackRebuilds {
            let claimed = w.claimFallbackRebuild()
            #expect(claimed)
        }
        w.rescueInconclusive(atSilence: 0.3, clock: 98)
        w.rescueInconclusive(atSilence: 2.0, clock: 100)

        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 101)) == nil)
        let stillSpent = w.claimFallbackRebuild()
        #expect(!stillSpent)
        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 111)) == nil)
        let renewed = w.claimFallbackRebuild()
        #expect(renewed)
    }

    @Test("A promotion resets the ladder, clears its memory, and a promoted tap's fresh silence clock keeps it there")
    func promotionResetsLadder() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 0.3, clock: 100))
        w.rescueInconclusive(atSilence: 0.3, clock: 100)
        #expect(w.nextRung == 1)

        w.rescuePromoted(clock: 101)
        #expect(w.nextRung == 0)
        #expect(w.lastInconclusiveClock == nil)
        #expect(w.recentInconclusive == 0)
        // The promoted tap has not heard signal yet: silence counts from its start.
        #expect(w.evaluate(healthy(tapAge: 0.1, signalSeen: false, silentFor: 0.1, clock: 101.1)) == nil)
        #expect(w.nextRung == 0)
    }

    // MARK: Play start

    @Test("Silence is counted from when playback was seen starting, not from the last signal minutes ago")
    func playStartOffset() {
        var w = TapWatchdog()
        // Idle for 300 s: IsRunningOutput reads false.
        #expect(w.evaluate(healthy(silentFor: 300, playing: false)) == nil)
        #expect(w.isStopped)

        // IsRunningOutput flips true before the first sample arrives.
        #expect(w.evaluate(healthy(silentFor: 300, playing: true)) == nil)
        #expect(!w.isStopped)
        #expect(w.silenceAtPlayStart == 300)
        #expect(w.evaluate(healthy(silentFor: 300.125)) == nil)
        #expect(w.evaluate(healthy(silentFor: 300.25)) == .rescue(.unexplainedSilence, rung: 0))
    }

    @Test("effectiveSilence subtracts the play-start offset and never goes negative")
    func effectiveSilence() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 300, playing: false))
        _ = w.evaluate(healthy(silentFor: 300, playing: true))
        #expect(w.effectiveSilence(healthy(silentFor: 300.5).readings) == 0.5)
        #expect(w.effectiveSilence(healthy(silentFor: 299).readings) == 0)
    }

    @Test("Signal returning or a new tap drops the reading below the offset and clears it")
    func newTapClearsOffset() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 300, playing: false))
        _ = w.evaluate(healthy(silentFor: 300, playing: true))
        #expect(w.silenceAtPlayStart == 300)

        // A rescue promoted a tap that never heard signal: its silence counts from its start,
        // and the old offset must not blind it.
        #expect(w.evaluate(healthy(tapAge: 0.125, signalSeen: false, silentFor: 0.125)) == nil)
        #expect(w.silenceAtPlayStart == 0)
        #expect(w.evaluate(healthy(tapAge: 0.25, signalSeen: false, silentFor: 0.25)) == .rescue(.silentAfterTapStart, rung: 0))
    }

    @Test("An app that stops playing again clears the offset and is stopped once more")
    func stoppingClearsOffset() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 300, playing: false))
        _ = w.evaluate(healthy(silentFor: 300, playing: true))
        _ = w.evaluate(healthy(silentFor: 310, playing: false))
        #expect(w.isStopped)
        #expect(w.silenceAtPlayStart == 0)
    }

    @Test("A tap that was never seen stopped counts silence from its own start")
    func freshWatchdogHasNoOffset() {
        var w = TapWatchdog()
        #expect(!w.isStopped)
        #expect(w.evaluate(healthy(silentFor: 5)) == .rescue(.unexplainedSilence, rung: 0))
        #expect(w.silenceAtPlayStart == 0)
    }

    // MARK: Promotion storm floor

    @Test("Promotions within 30 s of the previous one are counted; a longer gap starts over")
    func promotionCounting() {
        var w = TapWatchdog()
        w.rescuePromoted(clock: 0)
        #expect(w.recentPromotions == 1)
        w.rescuePromoted(clock: 10)
        #expect(w.recentPromotions == 2)
        w.rescuePromoted(clock: 20)
        #expect(w.recentPromotions == 3)
        w.rescuePromoted(clock: 49)
        #expect(w.recentPromotions == 4)
        w.rescuePromoted(clock: 79.5)
        #expect(w.recentPromotions == 1)
        #expect(w.lastPromotionClock == 79.5)
    }

    @Test("Three promotions in a row move the ladder floor to rung 1: no 0.25 s probe, audio still recovers")
    func stormFloor() {
        var w = TapWatchdog()
        w.rescuePromoted(clock: 0)
        w.rescuePromoted(clock: 5)
        #expect(w.nextRung == 0)
        w.rescuePromoted(clock: 10)
        #expect(w.recentPromotions == 3)
        #expect(w.nextRung == 1)

        // The promoted tap dies again at once: it waits 2 s instead of 0.25 s.
        #expect(w.evaluate(healthy(tapAge: 1, silentFor: 0.3, clock: 10.5)) == nil)
        #expect(w.evaluate(healthy(tapAge: 2, silentFor: 1.9, clock: 12)) == nil)
        #expect(w.evaluate(healthy(tapAge: 2.1, silentFor: 2.0, clock: 12.1)) == .rescue(.silentAfterTapStart, rung: 1))
    }

    @Test("Signal returning inside the storm resets to the floor, and to rung 0 once 30 s have passed")
    func stormFloorOnReset() {
        var w = TapWatchdog()
        w.rescuePromoted(clock: 0)
        w.rescuePromoted(clock: 5)
        w.rescuePromoted(clock: 10)

        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 20)) == nil)
        #expect(w.nextRung == 1)
        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 39.9)) == nil)
        #expect(w.nextRung == 1)
        #expect(w.evaluate(healthy(silentFor: 0.05, clock: 40)) == nil)
        #expect(w.nextRung == 0)
    }

    @Test("Fewer than three promotions, or promotions more than 30 s apart, leave the floor at rung 0")
    func noStormBelowThree() {
        var w = TapWatchdog()
        w.rescuePromoted(clock: 0)
        w.rescuePromoted(clock: 5)
        #expect(w.nextRung == 0)

        var spaced = TapWatchdog()
        spaced.rescuePromoted(clock: 0)
        spaced.rescuePromoted(clock: 31)
        spaced.rescuePromoted(clock: 62)
        #expect(spaced.recentPromotions == 1)
        #expect(spaced.nextRung == 0)
    }

    @Test("An app that stops playing ends a storm")
    func stormEndsWhenAppStops() {
        var w = TapWatchdog()
        w.rescuePromoted(clock: 0)
        w.rescuePromoted(clock: 5)
        w.rescuePromoted(clock: 10)
        _ = w.evaluate(healthy(silentFor: 1, playing: false, clock: 11))
        #expect(w.recentPromotions == 0)
        #expect(w.lastPromotionClock == nil)
        #expect(w.nextRung == 0)
    }

    @Test("The reason names what the silence followed")
    func reasons() {
        var w = TapWatchdog()
        // A discontinuity on the current tap within 15 s outranks a recent tap start.
        #expect(w.evaluate(healthy(tapAge: 5, silentFor: 0.3, discontinuityAge: 0.3)) == .rescue(.silentAfterOverload, rung: 0))
        #expect(w.evaluate(healthy(tapAge: 5, silentFor: 0.3)) == .rescue(.silentAfterTapStart, rung: 0))
        #expect(w.evaluate(healthy(tapAge: 40, silentFor: 0.3)) == .rescue(.unexplainedSilence, rung: 0))
        // Old disturbances are not a cause.
        #expect(w.evaluate(healthy(tapAge: 40, silentFor: 0.3, discontinuityAge: 16)) == .rescue(.unexplainedSilence, rung: 0))
    }

    @Test("An app that stops playing resets everything and is never rescued")
    func notPlaying() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 0.3))
        w.rescueInconclusive(atSilence: 0.3, clock: 0)
        let claimed = w.claimFallbackRebuild()
        #expect(claimed)
        #expect(w.evaluate(healthy(silentFor: 60, discontinuityAge: 1, playing: false)) == nil)
        #expect(w.isStopped)
        #expect(w.nextRung == 0)
        #expect(w.fallbackRebuilds == 0)
        #expect(w.lastInconclusiveClock == nil)
        #expect(w.silenceAtPlayStart == 0)
    }

    @Test("IsRunningOutput not read: no rescue, and the ladder is left as it is")
    func playingStateUnknown() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 0.3))
        w.rescueInconclusive(atSilence: 0.3, clock: 0)
        #expect(w.evaluate(healthy(silentFor: 5, playing: nil)) == nil)
        #expect(w.nextRung == 1)
    }

    @Test("A user-muted or switching tap is left alone")
    func mutedOrSwitching() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 30, discontinuityAge: 2, muted: true)) == nil)
        #expect(w.evaluate(healthy(silentFor: 30, discontinuityAge: 2, switching: true)) == nil)
        #expect(w.nextRung == 0)
    }

    @Test("Fallback rebuilds per episode are capped, and signal starts a new episode")
    func fallbackCap() {
        var w = TapWatchdog()
        for _ in 0..<TapWatchdog.maxFallbackRebuilds {
            let claimed = w.claimFallbackRebuild()
            #expect(claimed)
        }
        let overCap = w.claimFallbackRebuild()
        #expect(!overCap)
        #expect(w.evaluate(healthy(silentFor: 0.05)) == nil)
        let newEpisode = w.claimFallbackRebuild()
        #expect(newEpisode)
    }

    @Test("IsRunningOutput is only worth reading once a rule is close to firing")
    func needsPlayingState() {
        let w = TapWatchdog()
        #expect(!w.needsPlayingState(readings(silent: 0.0)))
        #expect(!w.needsPlayingState(readings(silent: 0.24)))
        #expect(w.needsPlayingState(readings(silent: 0.25)))
        #expect(!w.needsPlayingState(readings(silent: 0.1, output: 1.4)))
        #expect(w.needsPlayingState(readings(silent: 0.1, output: 1.5)))
    }

    @Test("The read waits for the next rung's silence, not the first rung's")
    func needsPlayingStateFollowsRung() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 0.3))
        w.rescueInconclusive(atSilence: 0.3, clock: 0)
        #expect(!w.needsPlayingState(readings(silent: 1.9)))
        #expect(w.needsPlayingState(readings(silent: 2.0)))
    }

    @Test("A stopped app is not asked about again by the watchdog (the engine re-reads once a second)")
    func needsPlayingStateWhenStopped() {
        var w = TapWatchdog()
        _ = w.evaluate(healthy(silentFor: 30, playing: false))
        #expect(!w.needsPlayingState(readings(silent: 30)))
        // The silent-output rule still needs it.
        #expect(w.needsPlayingState(readings(silent: 30, output: 1.5)))

        _ = w.evaluate(healthy(silentFor: 30, playing: true))
        #expect(!w.isStopped)
        #expect(!w.needsPlayingState(readings(silent: 30)), "silence counts from play start now")
        #expect(w.needsPlayingState(readings(silent: 30.25)))
    }

    private func readings(silent: Double, output: Double = 0.1) -> TapHealthReadings {
        healthy(silentFor: silent, outputSilentFor: output).readings
    }
}

@Suite("TapWatchdog: stuck output")
struct TapWatchdogOutputTests {

    @Test("Live input with silent output for 1.5 s rebuilds (upstream #461)")
    func outputSilent() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(outputSilentFor: 1.0)) == nil)
        #expect(w.evaluate(healthy(outputSilentFor: 1.6)) == .rebuild(.outputSilent))
    }

    @Test("Silent-output rebuilds are capped per playing run and reset when the app stops")
    func outputCap() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(outputSilentFor: 2)) == .rebuild(.outputSilent))
        #expect(w.evaluate(healthy(outputSilentFor: 2)) == .rebuild(.outputSilent))
        #expect(w.evaluate(healthy(outputSilentFor: 2)) == nil)
        _ = w.evaluate(healthy(playing: false))
        #expect(w.evaluate(healthy(outputSilentFor: 2)) == .rebuild(.outputSilent))
    }

    @Test("A silent output outranks an input rescue")
    func outputBeforeRescue() {
        var w = TapWatchdog()
        #expect(w.evaluate(healthy(silentFor: 0.5, outputSilentFor: 2)) == .rebuild(.outputSilent))
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
