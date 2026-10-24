// DeciTests/AudioEngineMultiDeviceTests.swift
// Per-app multi-output routing: entering Multi seeds the selection from the device the app is
// playing on, default-output changes and reconnects leave a multi route alone, and the engine
// reports which output devices currently carry a multi-device route.

import Testing
import Foundation
import AppKit
import AudioToolbox
import Observation
import os
@testable import Deci

/// Records that an observation fired, from the nonisolated closure `withObservationTracking` takes.
private nonisolated final class Fired: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

@MainActor
@Suite("AudioEngine multi-device routing")
struct AudioEngineMultiDeviceTests {

    private let headphones = AudioDevice(id: AudioDeviceID(100), uid: "uid-headphones", name: "Headphones", icon: nil, supportsAutoEQ: false)
    private let speakers = AudioDevice(id: AudioDeviceID(101), uid: "uid-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)

    private func makeHarness() -> EngineHarness {
        EngineHarness(extraDevices: [headphones, speakers])
    }

    /// Persists a multi-device selection for `app` and launches it, so the engine restores it the
    /// way it does after a relaunch (`applyPersistedSettings`). Returns the app's tap.
    @discardableResult
    private func launchMulti(_ harness: EngineHarness, _ app: AudioApp, uids: Set<String>) -> RecordingProcessTapController {
        harness.settings.setDeviceSelectionMode(for: app.persistenceIdentifier, to: .multi)
        harness.settings.setSelectedDeviceUIDs(for: app.persistenceIdentifier, to: uids)
        return harness.launch(app)
    }

    /// Lets tasks the engine scheduled run, for "nothing moved" assertions. The main actor runs
    /// them in the order they were scheduled, ahead of this test resuming from the sleep.
    private func drainEngineTasks() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: - Seeding on entering Multi

    @Test("Entering Multi with no saved selection ticks the device the app is playing on")
    func seedsFromDefaultDevice() {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        harness.launch(app)
        #expect(harness.engine.getSelectedDeviceUIDs(for: app).isEmpty)

        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [harness.device.uid])
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == [harness.device.uid])
    }

    @Test("The seed is the tap's device, not the system default, when the app is routed elsewhere")
    func seedsFromTapDevice() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = harness.launch(app)
        harness.engine.setDevice(for: app, deviceUID: headphones.uid)
        let moved = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid] }
        #expect(moved)

        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [headphones.uid])
        #expect(tap.currentDeviceUIDs == [headphones.uid], "seeding must not move the tap")
    }

    @Test("Without a tap, the seed is the device the app is routed to")
    func seedsFromRoutedDeviceWithoutTap() {
        let harness = makeHarness()
        harness.engine.permission.status = .denied  // no tap can be created
        let app = harness.makeApp(ids: [1])
        harness.engine.setDevice(for: app, deviceUID: headphones.uid)
        #expect(harness.probes.createdTaps.isEmpty)

        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [headphones.uid])
    }

    @Test("Without a tap or a routed device, the seed is the system default")
    func seedsFromDefaultWithoutTap() {
        let harness = makeHarness()
        harness.engine.permission.status = .denied
        let app = harness.makeApp(ids: [1])

        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [harness.device.uid])
    }

    @Test("With no tap, no route and no default, the selection stays empty")
    func noSeedWhenNothingIsPlaying() {
        let harness = makeHarness()
        harness.engine.permission.status = .denied
        harness.deviceVolume.defaultDeviceUID = nil
        let app = harness.makeApp(ids: [1])

        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        #expect(harness.engine.getSelectedDeviceUIDs(for: app).isEmpty)
    }

    @Test("A saved selection is not overwritten when the app enters Multi")
    func keepsSavedSelection() {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        harness.launch(app)
        harness.engine.setSelectedDeviceUIDs(for: app, to: [headphones.uid, speakers.uid])

        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [headphones.uid, speakers.uid])
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == [headphones.uid, speakers.uid])
    }

    @Test("A selection saved in an earlier session is loaded, not overwritten")
    func keepsSelectionSavedByAnEarlierSession() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = harness.launch(app)
        // The app launched in single mode, so the engine never read this into memory.
        harness.settings.setSelectedDeviceUIDs(for: app.persistenceIdentifier, to: [headphones.uid, speakers.uid])

        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [headphones.uid, speakers.uid])
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == [headphones.uid, speakers.uid])
        let routed = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid, self.speakers.uid] }
        #expect(routed, "the saved selection should become the route")
    }

    @Test("Leaving Multi does not seed anything")
    func singleModeDoesNotSeed() {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        harness.launch(app)

        harness.engine.setDeviceSelectionMode(for: app, to: .single)

        #expect(harness.engine.getSelectedDeviceUIDs(for: app).isEmpty)
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == nil)
    }

    @Test("After the seed, ticking a second device routes the app to both")
    func secondDeviceMakesTwoOutputs() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = harness.launch(app)
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        var selection = harness.engine.getSelectedDeviceUIDs(for: app)
        selection.insert(headphones.uid)
        harness.engine.setSelectedDeviceUIDs(for: app, to: selection)

        let routed = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid, harness.device.uid] }
        #expect(routed, "the tap should play on both devices")
    }

    // MARK: - Default-output changes

    /// A multi app and a single follow-default app, both on the default (`uid-test`). The multi app
    /// has the lower pid, so a route that wrongly included it would switch it first.
    private func multiAndSingleApps(_ harness: EngineHarness) async throws -> (
        multi: AudioApp, single: AudioApp, multiTap: RecordingProcessTapController, singleTap: RecordingProcessTapController
    ) {
        let multi = harness.makeApp(pid: 100, ids: [1], bundleID: "com.deci.tests.Multi")
        let single = harness.makeApp(pid: 200, ids: [2], bundleID: "com.deci.tests.Single")
        harness.launchAll([multi, single])
        let multiTap = try #require(harness.tap(for: multi.id))
        let singleTap = try #require(harness.tap(for: single.id))

        harness.engine.setSelectedDeviceUIDs(for: multi, to: [harness.device.uid, headphones.uid])
        harness.engine.setDeviceSelectionMode(for: multi, to: .multi)
        let routed = await waitUntil { multiTap.currentDeviceUIDs == [self.headphones.uid, harness.device.uid] }
        #expect(routed)
        return (multi, single, multiTap, singleTap)
    }

    @Test("A default-output change moves a single follow-default app and leaves a multi app alone")
    func defaultChangeSkipsMultiApps() async throws {
        let harness = makeHarness()
        let apps = try await multiAndSingleApps(harness)

        harness.engine.setDefaultOutputDevice(speakers.id)

        let moved = await waitUntil { apps.singleTap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(moved, "the single follow-default app should follow the default")
        #expect(apps.multiTap.currentDeviceUIDs == [headphones.uid, harness.device.uid])
        #expect(harness.engine.getDeviceUID(for: apps.multi) == harness.device.uid, "the multi app's routing must not be rewritten")
    }

    @Test("Switching a multi app back to single restores following the default")
    func backToSingleFollowsDefaultAgain() async throws {
        let harness = makeHarness()
        let apps = try await multiAndSingleApps(harness)
        harness.engine.setDefaultOutputDevice(speakers.id)
        harness.deviceVolume.defaultDeviceUID = speakers.uid  // the mock's default does not move by itself
        let moved = await waitUntil { apps.singleTap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(moved)

        harness.engine.setDeviceSelectionMode(for: apps.multi, to: .single)

        #expect(harness.engine.isFollowingDefault(for: apps.multi))
        let followed = await waitUntil { apps.multiTap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(followed, "the app should be back on the default device")
    }

    @Test("A multi app switched back to single follows the next default change")
    func backToSingleRoutingTracksDefault() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = harness.launch(app)
        harness.engine.setSelectedDeviceUIDs(for: app, to: [harness.device.uid, headphones.uid])
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)
        let routed = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid, harness.device.uid] }
        #expect(routed)
        harness.engine.setDefaultOutputDevice(speakers.id)
        harness.deviceVolume.defaultDeviceUID = speakers.uid
        harness.engine.setDeviceSelectionMode(for: app, to: .single)
        let onSpeakers = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(onSpeakers)

        harness.deviceVolume.defaultDeviceUID = harness.device.uid
        harness.engine.setDefaultOutputDevice(harness.device.id)

        let followed = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(followed, "the app should follow the default back to the original device")
    }

    // MARK: - Device reconnects

    @Test("A reconnecting device does not collapse a multi app to the device it was once pinned to")
    func reconnectSkipsMultiApps() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away
        let app = harness.makeApp(ids: [1])
        // Pinned to the headphones in single mode before it was switched to Multi.
        harness.settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: headphones.uid)
        let tap = launchMulti(harness, app, uids: [speakers.uid, harness.device.uid])
        #expect(tap.currentDeviceUIDs == [speakers.uid, harness.device.uid])

        harness.deviceMonitor.addOutputDevice(headphones)
        harness.deviceMonitor.onDeviceConnected?(headphones.uid, headphones.name)
        await drainEngineTasks()

        #expect(tap.currentDeviceUIDs == [speakers.uid, harness.device.uid])
    }

    @Test("A single-mode app pinned to a reconnecting device still moves back to it")
    func reconnectStillRestoresSingleApps() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away
        let app = harness.makeApp(ids: [1])
        harness.settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: headphones.uid)
        let tap = harness.launch(app)  // the pinned device is away, so the app falls back to the default
        #expect(tap.currentDeviceUIDs == [harness.device.uid])

        harness.deviceMonitor.addOutputDevice(headphones)
        harness.deviceMonitor.onDeviceConnected?(headphones.uid, headphones.name)

        let restored = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid] }
        #expect(restored)
    }

    // MARK: - Devices in use by a multi route

    @Test("No device is in use by a multi route when every tap has one device")
    func noMultiRouteForSingleTaps() {
        let harness = makeHarness()
        harness.launch(harness.makeApp(ids: [1]))

        #expect(harness.engine.multiRouteDeviceUIDs.isEmpty)
    }

    @Test("Both devices of a two-device multi tap are in use")
    func twoDeviceTapIsInUse() {
        let harness = makeHarness()
        launchMulti(harness, harness.makeApp(ids: [1]), uids: [headphones.uid, harness.device.uid])

        #expect(harness.engine.multiRouteDeviceUIDs == [headphones.uid, harness.device.uid])
    }

    @Test("The devices the popup lights up include the devices of an app's multi route")
    func popupSetIncludesAppMultiRoutes() {
        let harness = makeHarness()
        #expect(harness.engine.outputDevicesInUse.isEmpty)

        launchMulti(harness, harness.makeApp(ids: [1]), uids: [headphones.uid, harness.device.uid])

        #expect(harness.engine.outputDevicesInUse == [headphones.uid, harness.device.uid])
    }

    @Test("A multi selection of one device is not a multi route")
    func oneDeviceMultiSelectionIsNotInUse() {
        let harness = makeHarness()
        launchMulti(harness, harness.makeApp(ids: [1]), uids: [headphones.uid])

        #expect(harness.engine.multiRouteDeviceUIDs.isEmpty)
    }

    @Test("The in-use devices of several multi apps are combined")
    func unionAcrossApps() {
        let harness = makeHarness()
        launchMulti(harness, harness.makeApp(pid: 100, ids: [1], bundleID: "com.deci.tests.A"), uids: [headphones.uid, harness.device.uid])
        launchMulti(harness, harness.makeApp(pid: 200, ids: [2], bundleID: "com.deci.tests.B"), uids: [speakers.uid, harness.device.uid])

        #expect(harness.engine.multiRouteDeviceUIDs == [headphones.uid, speakers.uid, harness.device.uid])
    }

    @Test("Ticking a second device and unticking it again updates the in-use devices")
    func followsLiveSelectionChanges() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        harness.launch(app)
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)
        #expect(harness.engine.multiRouteDeviceUIDs.isEmpty, "one seeded device is not a multi route")

        harness.engine.setSelectedDeviceUIDs(for: app, to: [harness.device.uid, headphones.uid])
        let added = await waitUntil { harness.engine.multiRouteDeviceUIDs == [self.headphones.uid, harness.device.uid] }
        #expect(added)

        harness.engine.setSelectedDeviceUIDs(for: app, to: [harness.device.uid])
        let removed = await waitUntil { harness.engine.multiRouteDeviceUIDs.isEmpty }
        #expect(removed)
    }

    @Test("Pinning a multi app to one device ends its multi route")
    func singleRerouteClearsInUse() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        launchMulti(harness, app, uids: [headphones.uid, harness.device.uid])
        #expect(!harness.engine.multiRouteDeviceUIDs.isEmpty)

        harness.engine.setDevice(for: app, deviceUID: speakers.uid)

        let cleared = await waitUntil { harness.engine.multiRouteDeviceUIDs.isEmpty }
        #expect(cleared)
    }

    @Test("Losing one device of a two-device route ends the multi route")
    func disconnectClearsInUse() async {
        let harness = makeHarness()
        let tap = launchMulti(harness, harness.makeApp(ids: [1]), uids: [headphones.uid, harness.device.uid])
        #expect(!harness.engine.multiRouteDeviceUIDs.isEmpty)

        harness.deviceMonitor.outputDevices.removeAll { $0.uid == headphones.uid }
        harness.deviceMonitor.onDeviceDisconnected?(headphones.uid, headphones.name)

        let cleared = await waitUntil { harness.engine.multiRouteDeviceUIDs.isEmpty }
        #expect(cleared)
        #expect(tap.currentDeviceUIDs == [harness.device.uid])
    }

    @Test("Hiding the app drops its devices from the in-use set")
    func ignoringClearsInUse() {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        launchMulti(harness, app, uids: [headphones.uid, harness.device.uid])
        #expect(!harness.engine.multiRouteDeviceUIDs.isEmpty)

        harness.engine.ignoreApp(app)

        #expect(harness.engine.multiRouteDeviceUIDs.isEmpty)
    }

    @Test("A change to the in-use devices redraws whoever read them")
    func inUseDevicesAreObservable() {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        launchMulti(harness, app, uids: [headphones.uid, harness.device.uid])

        let fired = Fired()
        withObservationTracking { _ = harness.engine.outputDevicesInUse } onChange: { fired.set() }
        harness.engine.ignoreApp(app)

        #expect(fired.value)
    }
}
