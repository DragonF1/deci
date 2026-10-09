// DeciTests/AudioEngineStaleCleanupTests.swift
//
// An app that pauses leaves the process monitor's list (only running processes are
// listed), which used to tear its tap down 30 s later. When the app resumed, its audio
// played unprocessed until a new tap was built. A tap whose process is still alive is
// now kept, and re-checked every poll interval until the process is really gone.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import Deci

@Suite("AudioEngine: stale tap cleanup keeps tapped apps that are only paused", .serialized)
@MainActor
struct AudioEngineStaleCleanupTests {

    // MARK: Alive but silent

    @Test("A silent but alive process keeps its tap across many polls")
    func aliveProcessKeepsTap() async {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)

        h.publish([])  // paused: drops out of the monitor's list

        let polled = await waitUntil { h.probes.aliveQueryCount >= 4 }
        #expect(polled, "the engine should keep re-checking liveness while the tap is retained")
        #expect(tap.wasInvalidated == false)
        #expect(h.engine.audioLevels[app.id] != nil)
    }

    @Test("Routing and follows-default state are kept while the tap is kept")
    func routingSurvivesPause() async {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        h.launch(app)

        h.publish([])
        let polled = await waitUntil { h.probes.aliveQueryCount >= 3 }
        #expect(polled)

        #expect(h.engine.getDeviceUID(for: app) == h.device.uid)
        #expect(h.engine.isFollowingDefault(for: app))
    }

    @Test("Per-app volume survives the pause and later cleanup passes")
    func volumeSurvivesPause() async {
        let h = EngineHarness()
        let app = h.makeApp(pid: 100, ids: [10])
        h.launch(app)
        h.engine.setVolume(for: app, to: 0.4)

        // Another app starting makes the engine run further cleanup passes while A is paused.
        let other = h.makeApp(pid: 200, ids: [20], bundleID: "com.other.App")
        h.probes.alivePIDs.insert(200)
        h.publish([other])
        let polled = await waitUntil { h.probes.aliveQueryCount >= 3 }
        #expect(polled)
        h.publish([other])  // a further app-list change runs another cleanup pass
        try? await Task.sleep(for: .milliseconds(450))  // let the 350 ms cleanup debounce pass

        #expect(abs(h.engine.getVolume(for: app) - 0.4) < 1e-6)
    }

    // MARK: Process gone

    @Test("Once the process is gone the tap is invalidated and removed")
    func deadProcessIsTornDown() async {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)

        h.publish([])
        let polled = await waitUntil { h.probes.aliveQueryCount >= 2 }
        #expect(polled)
        #expect(tap.wasInvalidated == false)

        h.probes.alivePIDs.remove(app.id)  // the process exits

        let gone = await waitUntil { tap.wasInvalidated }
        #expect(gone)
        #expect(h.engine.audioLevels[app.id] == nil)
        #expect(h.engine.getDeviceUID(for: app) == nil)
        #expect(h.engine.isFollowingDefault(for: app) == false)
    }

    @Test("Polling stops after the teardown")
    func pollingStopsAfterTeardown() async throws {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)

        h.publish([])
        let polled = await waitUntil { h.probes.aliveQueryCount >= 2 }
        #expect(polled)
        h.probes.alivePIDs.remove(app.id)
        let gone = await waitUntil { tap.wasInvalidated }
        #expect(gone)

        let settled = h.probes.aliveQueryCount
        try await Task.sleep(for: .milliseconds(250))
        #expect(h.probes.aliveQueryCount == settled)
    }

    @Test("A process that is already dead when the grace ends is torn down right away")
    func alreadyDeadIsTornDownAfterGrace() async {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)
        h.probes.alivePIDs.remove(app.id)

        h.publish([])

        let gone = await waitUntil { tap.wasInvalidated }
        #expect(gone)
        #expect(h.engine.audioLevels[app.id] == nil)
    }

    @Test("Re-initialisation is allowed after a real teardown (appliedPIDs cleared)")
    func relaunchAfterTeardownCreatesFreshTap() async {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let first = h.launch(app)
        h.probes.alivePIDs.remove(app.id)
        h.publish([])
        let gone = await waitUntil { first.wasInvalidated }
        #expect(gone)

        h.launch(app)  // same pid comes back as a new process

        #expect(h.probes.createdTaps.count == 2)
        #expect(h.tap(for: app.id) !== first)
    }

    // MARK: Reappearance

    @Test("A pid that reappears keeps its tap, even if the process later dies")
    func reappearingPidKeepsTap() async throws {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)

        h.publish([])
        let polled = await waitUntil { h.probes.aliveQueryCount >= 2 }
        #expect(polled)

        h.publish([app])  // resumed
        try await Task.sleep(for: .milliseconds(500))  // past the 350 ms cleanup debounce

        // If a pending cleanup survived the reappearance, a dead process would now take the tap with it.
        h.probes.alivePIDs.remove(app.id)
        try await Task.sleep(for: .milliseconds(400))

        #expect(tap.wasInvalidated == false)
        #expect(h.engine.audioLevels[app.id] != nil)
    }

    @Test("Resuming does not rebuild the retained tap")
    func resumeDoesNotRebuildTap() async throws {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)

        h.publish([])
        let polled = await waitUntil { h.probes.aliveQueryCount >= 2 }
        #expect(polled)
        h.publish([app])
        try await Task.sleep(for: .milliseconds(500))

        #expect(h.probes.createdTaps.count == 1)
        #expect(tap.wasInvalidated == false)
        #expect(tap.updateProcessesCalls.isEmpty)
    }

    // MARK: Routing while retained

    @Test("A retained tap of a paused follows-default app still follows a default-device change")
    func retainedTapFollowsDefaultChange() async {
        let other = AudioDevice(id: 100, uid: "uid-other", name: "Other Output", icon: nil, supportsAutoEQ: false)
        let h = EngineHarness(extraDevices: [other])
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)

        h.publish([])
        let polled = await waitUntil { h.probes.aliveQueryCount >= 2 }
        #expect(polled)

        h.engine.setDefaultOutputDevice(other.id)

        let moved = await waitUntil { tap.currentDeviceUIDs == [other.uid] }
        #expect(moved, "a paused app's retained tap must not stay on the old default")
        #expect(h.engine.getDeviceUID(for: app) == other.uid)

        // Resuming afterwards needs no further switch: the tap is already on the right device.
        h.publish([app])
        #expect(tap.currentDeviceUIDs == [other.uid])
        #expect(tap.wasInvalidated == false)
    }
}
