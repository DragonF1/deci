// DeciTests/AudioEngineTapRescueTests.swift
//
// The engine's health tick (`runHealthTick`) with the fake controller: when exact-zero input
// asks for a rescue, how the ladder reacts to each outcome, what falls back to recreateTap,
// and that a recreated tap keeps the helper processes of the tap it replaces.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import Deci

@Suite("AudioEngine: stuck-tap rescue")
@MainActor
struct AudioEngineTapRescueTests {
    let h = EngineHarness()

    /// A launched app whose output is running, with a tap that reads signal.
    private func launchPlaying(ids: [AudioObjectID] = [10]) -> (AudioApp, RecordingProcessTapController) {
        let app = h.makeApp(ids: ids)
        let tap = h.launch(app)
        h.probes.runningOutputPIDs.insert(app.id)
        tap.readings = readings(silentFor: 0.0)
        return (app, tap)
    }

    private func readings(
        silentFor: Double,
        outputSilentFor: Double = 0.1,
        tapAge: Double = 120,
        switching: Bool = false
    ) -> TapHealthReadings {
        TapHealthReadings(
            isSwitching: switching,
            secondsSinceTapStart: tapAge,
            inputSignalSeen: true,
            secondsSinceInputSignal: silentFor,
            secondsSinceDiscontinuity: .infinity,
            discontinuityCount: 0,
            secondsSinceHealthyOutput: outputSilentFor
        )
    }

    private func tick(_ tap: RecordingProcessTapController, silentFor: Double, now: Date = Date()) async {
        tap.readings = readings(silentFor: silentFor)
        await h.engine.runHealthTick(now: now)
    }

    // MARK: - When a rescue is asked for

    @Test("Exact-zero input for 0.25 s while the app runs output triggers a rescue")
    func rescueAtQuarterSecond() async {
        let (_, tap) = launchPlaying()
        await tick(tap, silentFor: 0.3)
        #expect(tap.rescueCalls == 1)
    }

    @Test("Under 0.25 s of silence nothing is rescued and IsRunningOutput is not even read")
    func belowQuarterSecond() async {
        let (_, tap) = launchPlaying()
        await tick(tap, silentFor: 0.2)
        #expect(tap.rescueCalls == 0)
        #expect(h.probes.runningOutputQueryCount == 0)
    }

    @Test("An app that is not running output is not rescued, however long its tap is silent")
    func notRunningOutput() async {
        let (app, tap) = launchPlaying()
        h.probes.runningOutputPIDs.remove(app.id)
        await tick(tap, silentFor: 30)
        #expect(tap.rescueCalls == 0)
        #expect(h.probes.runningOutputQueryCount == 1)
    }

    @Test("A tap that is switching, or whose app is user-muted, is not rescued")
    func switchingOrMuted() async {
        let (_, tap) = launchPlaying()
        tap.readings = readings(silentFor: 5, switching: true)
        await h.engine.runHealthTick()
        #expect(tap.rescueCalls == 0)

        tap.readings = readings(silentFor: 5)
        tap.isMuted = true
        await h.engine.runHealthTick()
        #expect(tap.rescueCalls == 0)
    }

    @Test("A tap that has not rendered yet (no readings) is left to the unresponsive check")
    func noReadings() async {
        let (_, tap) = launchPlaying()
        tap.readings = nil
        await h.engine.runHealthTick()
        #expect(tap.rescueCalls == 0)
        #expect(h.probes.runningOutputQueryCount == 0)
    }

    // MARK: - Ladder

    @Test("candidateSilent steps the ladder: the next rescue waits for 2 s of silence, then 4 s")
    func candidateSilentSteps() async {
        let (_, tap) = launchPlaying()
        tap.rescueResult = .failure(CrossfadeError.candidateSilent)

        await tick(tap, silentFor: 0.3)
        #expect(tap.rescueCalls == 1)
        await tick(tap, silentFor: 0.55)
        await tick(tap, silentFor: 1.9)
        #expect(tap.rescueCalls == 1)
        await tick(tap, silentFor: 2.1)
        #expect(tap.rescueCalls == 2)
        await tick(tap, silentFor: 3.9)
        #expect(tap.rescueCalls == 2)
        await tick(tap, silentFor: 4.1)
        #expect(tap.rescueCalls == 3)
        #expect(h.probes.createdTaps.count == 1, "a silent candidate is not a reason to rebuild")
        #expect(tap.wasInvalidated == false)
    }

    @Test("A primary that recovered during verify steps the ladder the same way")
    func primaryRecoveredSteps() async {
        let (_, tap) = launchPlaying()
        tap.rescueResult = .failure(CrossfadeError.primaryRecovered)

        await tick(tap, silentFor: 0.3)
        await tick(tap, silentFor: 0.6)
        #expect(tap.rescueCalls == 1)
        await tick(tap, silentFor: 2.0)
        #expect(tap.rescueCalls == 2)
        #expect(h.probes.createdTaps.count == 1)
    }

    @Test("Signal returning resets the ladder to 0.25 s once the last probe is 10 s old")
    func signalResetsLadder() async {
        let (_, tap) = launchPlaying()
        let t0 = Date()
        await tick(tap, silentFor: 0.3, now: t0)
        await tick(tap, silentFor: 2.1, now: t0.addingTimeInterval(2))
        #expect(tap.rescueCalls == 2)

        await tick(tap, silentFor: 0.02, now: t0.addingTimeInterval(13))  // the app made sound again
        await tick(tap, silentFor: 0.3, now: t0.addingTimeInterval(14))
        #expect(tap.rescueCalls == 3, "back on the first rung")
    }

    @Test("One gap probe resets on signal; a second within 10 s keeps the ladder, so the next gap needs 2 s")
    func ladderMemory() async {
        let (_, tap) = launchPlaying()
        let t0 = Date()
        await tick(tap, silentFor: 0.3, now: t0)
        #expect(tap.rescueCalls == 1)

        // A gap between tracks: the next silence is probed at 0.25 s again.
        await tick(tap, silentFor: 0.02, now: t0.addingTimeInterval(1.2))
        await tick(tap, silentFor: 0.3, now: t0.addingTimeInterval(4))
        #expect(tap.rescueCalls == 2)

        await tick(tap, silentFor: 0.02, now: t0.addingTimeInterval(5))
        await tick(tap, silentFor: 0.3, now: t0.addingTimeInterval(6))
        await tick(tap, silentFor: 1.9, now: t0.addingTimeInterval(7.6))
        #expect(tap.rescueCalls == 2, "a bursty app is not probed at every gap")
        await tick(tap, silentFor: 2.1, now: t0.addingTimeInterval(7.8))
        #expect(tap.rescueCalls == 3)
    }

    @Test("A promoted rescue leaves the tap in place and does not rebuild it")
    func promotedRescue() async {
        let (_, tap) = launchPlaying()
        tap.rescueResult = .success(TapRescueReport(candidateSignalLatency: 0.04))
        await tick(tap, silentFor: 0.3)
        #expect(tap.rescueCalls == 1)
        #expect(tap.wasInvalidated == false)
        #expect(h.probes.createdTaps.count == 1)
    }

    @Test("Three promotions inside 30 s each raise the ladder floor to rung 1; the tap is still promoted")
    func promotionStormFloor() async {
        let (_, tap) = launchPlaying()
        tap.rescueResult = .success(TapRescueReport(candidateSignalLatency: 0.04))
        let t0 = Date()
        await tick(tap, silentFor: 0.3, now: t0)
        await tick(tap, silentFor: 0.3, now: t0.addingTimeInterval(5))
        #expect(tap.rescueCalls == 2, "two promotions: still the 0.25 s rung")
        await tick(tap, silentFor: 0.3, now: t0.addingTimeInterval(10))
        #expect(tap.rescueCalls == 3, "the third promotion is still done")

        await tick(tap, silentFor: 0.3, now: t0.addingTimeInterval(10.5))
        #expect(tap.rescueCalls == 3, "storm: no more 0.25 s probes")
        await tick(tap, silentFor: 2.1, now: t0.addingTimeInterval(12.5))
        #expect(tap.rescueCalls == 4, "rung 1 still promotes a tap that is really dead")
    }

    @Test("Promotions more than 30 s apart never raise the floor")
    func spacedPromotionsNoStorm() async {
        let (_, tap) = launchPlaying()
        tap.rescueResult = .success(TapRescueReport(candidateSignalLatency: 0.04))
        let t0 = Date()
        for k in 0..<4 {
            await tick(tap, silentFor: 0.3, now: t0.addingTimeInterval(Double(k) * 31))
        }
        #expect(tap.rescueCalls == 4)
    }

    // MARK: - Fallbacks

    @Test("Any other rescue error falls back to recreateTap, then honours the recovery cooldown")
    func otherErrorRecreates() async {
        struct Boom: Error {}
        let (app, tap) = launchPlaying()
        tap.rescueResult = .failure(Boom())
        let t0 = Date()
        await tick(tap, silentFor: 0.3, now: t0)

        #expect(tap.rescueCalls == 1)
        #expect(tap.wasInvalidated)
        #expect(h.probes.createdTaps.count == 2)
        guard let replacement = h.tap(for: app.id), replacement !== tap else {
            Issue.record("expected a replacement tap")
            return
        }

        // The 5 s cooldown keeps the new tap from being judged straight away.
        replacement.readings = readings(silentFor: 5)
        await h.engine.runHealthTick(now: t0.addingTimeInterval(1))
        #expect(replacement.rescueCalls == 0)
        await h.engine.runHealthTick(now: t0.addingTimeInterval(6))
        #expect(replacement.rescueCalls == 1)
    }

    @Test("The recovery cooldown starts when the rescue gave up, not when the tick began")
    func cooldownStartsAfterRescue() async {
        struct Boom: Error {}
        let (app, tap) = launchPlaying()
        tap.rescueResult = .failure(Boom())
        tap.rescueDelay = .milliseconds(200)
        let t0 = Date()
        await tick(tap, silentFor: 0.3, now: t0)
        guard let replacement = h.tap(for: app.id), replacement !== tap else {
            Issue.record("expected a replacement tap")
            return
        }

        replacement.readings = readings(silentFor: 5)
        await h.engine.runHealthTick(now: t0.addingTimeInterval(5.1))
        #expect(replacement.rescueCalls == 0, "5 s of cooldown after the 200 ms the rescue took")
        await h.engine.runHealthTick(now: t0.addingTimeInterval(60))
        #expect(replacement.rescueCalls == 1)
    }

    @Test("A CancellationError (tap torn down or superseded) neither rebuilds nor steps the ladder")
    func cancelledRescue() async {
        let (_, tap) = launchPlaying()
        tap.rescueResult = .failure(CancellationError())
        await tick(tap, silentFor: 0.3)
        await tick(tap, silentFor: 0.55)
        #expect(tap.rescueCalls == 2, "asked again on the next tick, still on the first rung")
        #expect(h.probes.createdTaps.count == 1)
        #expect(tap.wasInvalidated == false)
    }

    @Test("A switch that started between the readings and the rescue is retried next tick, not stepped")
    func switchInFlight() async {
        let (_, tap) = launchPlaying()
        tap.rescueResult = .failure(CrossfadeError.switchInFlight)
        await tick(tap, silentFor: 0.3)
        await tick(tap, silentFor: 0.55)
        #expect(tap.rescueCalls == 2)
        #expect(h.probes.createdTaps.count == 1)
        #expect(tap.wasInvalidated == false)
    }

    @Test("Live input with silent output still rebuilds directly, without a rescue")
    func outputSilentRebuilds() async {
        let (_, tap) = launchPlaying()
        tap.readings = readings(silentFor: 0.1, outputSilentFor: 2)
        await h.engine.runHealthTick()
        #expect(tap.rescueCalls == 0)
        #expect(tap.wasInvalidated)
        #expect(h.probes.createdTaps.count == 2)
    }

    // MARK: - recreateTap keeps paused helpers

    @Test("A recreated tap keeps the old process objects that still exist (a paused helper)")
    func recreateKeepsPausedHelper() async {
        let (app, tap) = launchPlaying(ids: [10, 11])
        // The monitor stops listing the paused helper; its HAL object is still alive.
        h.publish([h.makeApp(pid: app.id, ids: [10])])
        tap.readings = readings(silentFor: 0.1, outputSilentFor: 2)
        await h.engine.runHealthTick()

        #expect(tap.wasInvalidated)
        #expect(h.tap(for: app.id)?.app.processObjectIDs == [10, 11])
    }

    @Test("A recreated tap drops old process objects that are gone and adds the monitor's current ones")
    func recreateDropsExitedHelper() async {
        let (app, tap) = launchPlaying(ids: [10, 11, 12])
        h.probes.liveObjectIDs.remove(11)  // exited
        h.publish([h.makeApp(pid: app.id, ids: [10, 12])])
        tap.readings = readings(silentFor: 0.1, outputSilentFor: 2)
        await h.engine.runHealthTick()

        #expect(h.tap(for: app.id)?.app.processObjectIDs == [10, 12])
    }

    @Test("The HAL process list is read once for all the old objects, not once per object")
    func mergeReadsProcessListOnce() async {
        let (app, tap) = launchPlaying(ids: [10, 11, 12, 13])
        h.publish([h.makeApp(pid: app.id, ids: [10])])
        tap.readings = readings(silentFor: 0.1, outputSilentFor: 2)
        let before = h.probes.processListReadCount
        await h.engine.runHealthTick()

        #expect(h.tap(for: app.id)?.app.processObjectIDs == [10, 11, 12, 13])
        #expect(h.probes.processListReadCount - before == 1)
    }

    @Test("No HAL read when the monitor still lists every old object")
    func mergeSkipsReadWhenNothingMissing() async {
        let (app, tap) = launchPlaying(ids: [10, 11])
        h.publish([h.makeApp(pid: app.id, ids: [10, 11, 12])])
        tap.readings = readings(silentFor: 0.1, outputSilentFor: 2)
        let before = h.probes.processListReadCount
        await h.engine.runHealthTick()

        #expect(h.tap(for: app.id)?.app.processObjectIDs == [10, 11, 12])
        #expect(h.probes.processListReadCount == before)
    }

    @Test("A paused helper is kept when either side has no bundle ID, and when both have none",
          arguments: [(nil, nil), ("com.google.Chrome", nil), (nil, "com.google.Chrome")] as [(String?, String?)])
    func mergeWithMissingBundleID(oldBundleID: String?, currentBundleID: String?) async {
        let app = h.makeApp(ids: [10, 11], bundleID: oldBundleID)
        let tap = h.launch(app)
        h.probes.runningOutputPIDs.insert(app.id)
        h.publish([h.makeApp(pid: app.id, ids: [10], bundleID: currentBundleID)])
        tap.readings = readings(silentFor: 0.1, outputSilentFor: 2)
        await h.engine.runHealthTick()

        #expect(tap.wasInvalidated)
        #expect(h.tap(for: app.id)?.app.processObjectIDs == [10, 11])
    }

    @Test("A pid reused by an app with a different bundle ID keeps none of the old objects")
    func mergeSkipsReusedPID() async {
        let app = h.makeApp(ids: [10, 11], bundleID: "com.google.Chrome")
        let tap = h.launch(app)
        h.probes.runningOutputPIDs.insert(app.id)
        h.publish([h.makeApp(pid: app.id, ids: [20], bundleID: "com.apple.QuickTimePlayerX")])
        tap.readings = readings(silentFor: 0.1, outputSilentFor: 2)
        await h.engine.runHealthTick()

        #expect(h.tap(for: app.id)?.app.processObjectIDs == [20])
    }

    // MARK: - Once-per-second work

    @Test("The unresponsive-tap check still counts one miss per second: 6 misses rebuild, on the 24th 250 ms tick")
    func unresponsiveCheckKeepsItsPace() async {
        let (_, tap) = launchPlaying()
        tap.readings = nil
        tap.healthCheckEligible = true
        tap.hasRecentCallback = false

        for _ in 0..<23 { await h.engine.runHealthTick() }
        #expect(h.probes.createdTaps.count == 1, "5 misses so far")
        await h.engine.runHealthTick()
        #expect(h.probes.createdTaps.count == 2, "the 6th miss rebuilds")
        #expect(tap.wasInvalidated)
    }

    @Test("An idle tap reads IsRunningOutput once per second, not on every 250 ms tick")
    func idleTapReadsOncePerSecond() async {
        let (app, tap) = launchPlaying()
        h.probes.runningOutputPIDs.remove(app.id)

        await tick(tap, silentFor: 30)  // tick 1: not yet known to be stopped
        #expect(h.probes.runningOutputQueryCount == 1)
        await tick(tap, silentFor: 30)
        await tick(tap, silentFor: 30)
        #expect(h.probes.runningOutputQueryCount == 1)
        await tick(tap, silentFor: 30)  // tick 4: the once-per-second read
        #expect(h.probes.runningOutputQueryCount == 2)
        for _ in 5...7 { await tick(tap, silentFor: 30) }
        #expect(h.probes.runningOutputQueryCount == 2)
        await tick(tap, silentFor: 30)  // tick 8
        #expect(h.probes.runningOutputQueryCount == 3)
        #expect(tap.rescueCalls == 0)
    }

    @Test("An app that starts playing after a long idle is not probed until 0.25 s after play start")
    func playStartIsNotProbedAtOnce() async {
        let (app, tap) = launchPlaying()
        h.probes.runningOutputPIDs.remove(app.id)
        for _ in 1...3 { await tick(tap, silentFor: 300) }
        #expect(h.probes.runningOutputQueryCount == 1)

        h.probes.runningOutputPIDs.insert(app.id)
        await tick(tap, silentFor: 300)  // tick 4: sees the app play
        #expect(h.probes.runningOutputQueryCount == 2)
        #expect(tap.rescueCalls == 0, "the 300 s of silence was the app being idle")
        await tick(tap, silentFor: 300.1)
        #expect(h.probes.runningOutputQueryCount == 2, "0.1 s into playback: nothing to ask yet")
        #expect(tap.rescueCalls == 0)

        await tick(tap, silentFor: 300.3)
        #expect(tap.rescueCalls == 1)
    }

    // MARK: - Chrome audible gate

    /// A launched app other than Chrome, whose output is running, with a tap that reads signal.
    private func launchPlayingNonChrome() -> RecordingProcessTapController {
        let app = h.makeApp(ids: [20], bundleID: "com.apple.QuickTimePlayerX")
        let tap = h.launch(app)
        h.probes.runningOutputPIDs.insert(app.id)
        tap.readings = readings(silentFor: 0.0)
        return tap
    }

    @Test("A Chrome tap the extension reports silent is never probed, however long it is silent")
    func chromeReportedSilentIsNotProbed() async {
        let (_, tap) = launchPlaying()
        h.engine.chromeAudibleReport = { .silent }
        for silence in [0.3, 0.55, 2.1, 4.1, 8.1, 28.1, 60] {
            await tick(tap, silentFor: silence)
        }
        #expect(tap.rescueCalls == 0)
        #expect(h.probes.createdTaps.count == 1)
        #expect(tap.wasInvalidated == false)
    }

    @Test("A Chrome tap with an audible tab is first probed at 3.5 s of silence, not at 0.25 s")
    func chromeReportedAudibleWaitsForTheHold() async {
        let (_, tap) = launchPlaying()
        h.engine.chromeAudibleReport = { .audible }
        for silence in [0.3, 1.0, 2.0, 2.6, 3.4] {
            await tick(tap, silentFor: silence)
        }
        #expect(tap.rescueCalls == 0, "a lingering audible flag proves nothing yet")
        await tick(tap, silentFor: 3.6)
        #expect(tap.rescueCalls == 1)
    }

    @Test("A Chrome tap with no report from the extension is probed at 0.25 s, as before")
    func chromeUnknownReportIsProbed() async {
        let (_, tap) = launchPlaying()
        h.engine.chromeAudibleReport = { .unknown }
        await tick(tap, silentFor: 0.3)
        #expect(tap.rescueCalls == 1)
    }

    @Test("An app other than Chrome is probed at 0.25 s whatever the report, and the report is not even read")
    func nonChromeIgnoresTheReport() async {
        let tap = launchPlayingNonChrome()
        var reads = 0
        h.engine.chromeAudibleReport = {
            reads += 1
            return .silent
        }
        await tick(tap, silentFor: 0.3)
        #expect(tap.rescueCalls == 1)
        #expect(reads == 0)
    }

    @Test("The report is read only once a rule is close to firing: never while the tap hears Chrome")
    func reportIsNotReadOnTheHotPath() async {
        let (_, tap) = launchPlaying()
        var reads = 0
        h.engine.chromeAudibleReport = {
            reads += 1
            return .silent
        }
        for _ in 1...8 { await tick(tap, silentFor: 0.1) }
        #expect(reads == 0)
        #expect(h.probes.runningOutputQueryCount == 0)

        await tick(tap, silentFor: 0.3)
        #expect(reads == 1)
        #expect(tap.rescueCalls == 0)
    }

    @Test("A Chrome tap that hears signal while its output is silent is still rebuilt, whatever the report says")
    func chromeOutputSilentStillRebuilds() async {
        let (app, tap) = launchPlaying()
        h.engine.chromeAudibleReport = { .silent }
        tap.readings = readings(silentFor: 0.0, outputSilentFor: 2.0)
        await h.engine.runHealthTick()
        #expect(tap.wasInvalidated, "live input with a silent output is the output rule's, not the report's")
        #expect(h.tap(for: app.id) !== tap)
    }

    @Test("Chrome that was reported silent is probed again once a tab is audible and the tap stays dead")
    func chromeAudibleAfterSilentIsProbedAgain() async {
        let (_, tap) = launchPlaying()
        var report = ChromeAudibleReport.silent
        h.engine.chromeAudibleReport = { report }
        // Ticks 1 to 4 (the 4th is the once-per-second read): the report stops the watchdog.
        for silence in [0.3, 2.1, 4.1, 8.1] { await tick(tap, silentFor: silence) }
        #expect(tap.rescueCalls == 0)

        // A tab turns audible but the tap stays dead. Ticks 5 to 7 do not read (the watchdog is stopped); tick 8 is the
        // next once-per-second read: the audible report is past the hold, so the app plays again and the ladder counts
        // its silence from there (9.75 s).
        report = .audible
        for silence in [9.0, 9.25, 9.5, 9.75] { await tick(tap, silentFor: silence) }
        #expect(tap.rescueCalls == 0, "silence counts from the play start, so rung 0's 0.25 s is still to come")

        await tick(tap, silentFor: 10.0)
        #expect(tap.rescueCalls == 1, "rung 0 fires 0.25 s after the play start")

        // The silent candidate steps the ladder to rung 1: 2 s of silence from the play start (11.75 s).
        for silence in [10.25, 10.5, 10.75, 11.0, 11.25, 11.5] { await tick(tap, silentFor: silence) }
        #expect(tap.rescueCalls == 1)
        await tick(tap, silentFor: 11.75)
        #expect(tap.rescueCalls == 2)
    }

    @Test("A Chrome watchdog stopped by a silent report still rebuilds when signal returns and the output stays silent")
    func chromeStoppedThenOutputSilentRebuilds() async {
        let (app, tap) = launchPlaying()
        h.engine.chromeAudibleReport = { .silent }
        await tick(tap, silentFor: 0.3)  // the report stops the watchdog
        #expect(tap.wasInvalidated == false)

        tap.readings = readings(silentFor: 0.0, outputSilentFor: 2.0)
        await h.engine.runHealthTick()
        #expect(tap.wasInvalidated, "live input with a silent output is the output rule's, whatever happened before")
        #expect(tap.rescueCalls == 0)
        #expect(h.tap(for: app.id) !== tap)
    }

    @Test("The report is read only for a Chrome tap whose app runs output")
    func reportNeedsRunningChrome() async {
        let (app, tap) = launchPlaying()
        var reads = 0
        h.engine.chromeAudibleReport = {
            reads += 1
            return .audible
        }
        h.probes.runningOutputPIDs.remove(app.id)
        await tick(tap, silentFor: 30)
        #expect(h.probes.runningOutputQueryCount == 1, "IsRunningOutput was read")
        #expect(reads == 0, "a Chrome that runs no output needs no report")
        #expect(tap.rescueCalls == 0)

        h.probes.runningOutputPIDs.insert(app.id)
        for _ in 0..<3 { await tick(tap, silentFor: 30) }  // ticks 2 to 4; the 4th is the once-per-second read
        #expect(reads == 1)
    }

    @Test("The tick is 250 ms")
    func tickInterval() {
        #expect(AudioEngine.healthTickInterval == .milliseconds(250))
        #expect(AudioEngine.healthTicksPerSecond == 4)
    }
}
