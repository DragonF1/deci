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

    @Test("The tick is 250 ms")
    func tickInterval() {
        #expect(AudioEngine.healthTickInterval == .milliseconds(250))
        #expect(AudioEngine.healthTicksPerSecond == 4)
    }
}
