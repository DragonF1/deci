// DeciTests/AudioEngineMultiDeviceTests.swift
// Per-app multi-output routing: entering Multi seeds the selection from the device the app is
// playing on, default-output changes and reconnects leave a multi route alone, a device that was away
// at launch joins the route when it appears, a multi app with none of its devices left follows the
// default, and the engine reports which output devices currently carry a multi-device route.
// When a device in a Multi selection disconnects, the app goes back to Single: to what it was before
// Multi when Multi is recent, else to System Audio, and nothing rejoins on its own.

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

/// Collects notification texts the engine would have posted.
@MainActor
private final class NotificationLog {
    var bodies: [String] = []
}

@MainActor
@Suite("AudioEngine multi-device routing")
struct AudioEngineMultiDeviceTests {

    private let headphones = AudioDevice(id: AudioDeviceID(100), uid: "uid-headphones", name: "Headphones", icon: nil, supportsAutoEQ: false)
    private let speakers = AudioDevice(id: AudioDeviceID(101), uid: "uid-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
    private let hdmi = AudioDevice(id: AudioDeviceID(102), uid: "uid-hdmi", name: "HDMI", icon: nil, supportsAutoEQ: false)

    private func makeHarness() -> EngineHarness {
        EngineHarness(extraDevices: [headphones, speakers])
    }

    /// Persists a multi-device selection for `app` and launches it, so the engine restores it the
    /// way it does after a relaunch (`applyPersistedSettings`). Returns the app's tap.
    @discardableResult
    private func launchMulti(_ harness: EngineHarness, _ app: AudioApp, uids: Set<String>) -> RecordingProcessTapController {
        harness.settings.setDeviceSelectionMode(for: app.persistenceIdentifier, to: .multi, at: harness.clock.now)
        harness.settings.setSelectedDeviceUIDs(for: app.persistenceIdentifier, to: uids)
        return harness.launch(app)
    }

    /// Starts `app` the way a user does: following the default, or pinned to `pin`. Then ticks `uids` and
    /// switches it to Multi through the engine, so the "multi since" time is the harness clock's now.
    /// Pass `tap` when the app was already launched (with `launchAll`); otherwise it is launched here.
    @discardableResult
    private func enterMulti(
        _ harness: EngineHarness, _ app: AudioApp, tap existing: RecordingProcessTapController? = nil,
        pinnedTo pin: AudioDevice? = nil, uids: Set<String>
    ) async -> RecordingProcessTapController {
        let tap = existing ?? harness.launch(app)
        if let pin {
            harness.engine.setDevice(for: app, deviceUID: pin.uid)
            let pinned = await waitUntil { tap.currentDeviceUIDs == [pin.uid] }
            #expect(pinned, "the app should be on its pin before it enters Multi")
        }
        harness.engine.setSelectedDeviceUIDs(for: app, to: uids)
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)
        let routed = await waitUntil { tap.currentDeviceUIDs == uids.sorted() }
        #expect(routed, "the app should be playing on its Multi devices")
        return tap
    }

    /// Makes the test device the highest-priority output, so a device that comes back does not take the
    /// default (and every follow-default app with it) just by reconnecting.
    private func keepTheDefaultOnTheTestDevice(_ harness: EngineHarness) {
        harness.settings.setDevicePriorityOrder([harness.device.uid, headphones.uid, speakers.uid, hdmi.uid])
    }

    /// Lets tasks the engine scheduled run, for "nothing moved" assertions. The main actor runs
    /// them in the order they were scheduled, ahead of this test resuming from the sleep.
    private func drainEngineTasks() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    /// Takes `device` off the monitor and fires the disconnect callback, like an unplug or a
    /// Bluetooth drop.
    private func disconnect(_ device: AudioDevice, in harness: EngineHarness) {
        harness.deviceMonitor.outputDevices.removeAll { $0.uid == device.uid }
        harness.deviceMonitor.onDeviceDisconnected?(device.uid, device.name)
    }

    /// Puts `device` back on the monitor and fires the connect callback.
    private func reconnect(_ device: AudioDevice, in harness: EngineHarness) {
        harness.deviceMonitor.addOutputDevice(device)
        harness.deviceMonitor.onDeviceConnected?(device.uid, device.name)
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

    // MARK: - A device that is away at launch, or drops and returns

    @Test("A device that drops and returns does not put the app back on the multi route")
    func blipDoesNotRestoreTheRoute() async {
        let harness = makeHarness()
        keepTheDefaultOnTheTestDevice(harness)
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid, speakers.uid])

        disconnect(headphones, in: harness)
        let reverted = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(reverted, "the app is back on System Audio, not left on the speakers alone")
        reconnect(headphones, in: harness)
        await drainEngineTasks()

        #expect(tap.currentDeviceUIDs == [harness.device.uid], "nothing rejoins on its own")
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)
        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [headphones.uid, speakers.uid])
    }

    @Test("A disconnect reverts the app to single and leaves its saved multi selection alone")
    func disconnectKeepsTheSavedSelection() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid, speakers.uid])

        disconnect(headphones, in: harness)
        let reverted = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(reverted)

        #expect(harness.settings.getDeviceSelectionMode(for: app.persistenceIdentifier) == .single)
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == [headphones.uid, speakers.uid])
        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [headphones.uid, speakers.uid])
    }

    @Test("The first of two dropping outputs reverts the app, the second finds it already single")
    func bothDevicesBlip() async {
        let harness = makeHarness()
        keepTheDefaultOnTheTestDevice(harness)
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid, speakers.uid])

        disconnect(headphones, in: harness)
        let reverted = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(reverted)
        disconnect(speakers, in: harness)
        await drainEngineTasks()
        #expect(tap.currentDeviceUIDs == [harness.device.uid])

        reconnect(headphones, in: harness)
        reconnect(speakers, in: harness)
        await drainEngineTasks()
        #expect(tap.currentDeviceUIDs == [harness.device.uid], "neither device brings the route back")
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)
    }

    @Test("A device that was away at launch joins the route when it appears")
    func lateDeviceJoinsTheRoute() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid, speakers.uid])
        #expect(tap.currentDeviceUIDs == [speakers.uid])
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == [headphones.uid, speakers.uid])

        reconnect(headphones, in: harness)

        let joined = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid, self.speakers.uid] }
        #expect(joined)
    }

    @Test("Unticking a device in the picker is saved and a later blip of that device does not bring it back")
    func untickPersists() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid, speakers.uid])

        harness.engine.setSelectedDeviceUIDs(for: app, to: [speakers.uid])
        let unticked = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(unticked)
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == [speakers.uid])

        disconnect(headphones, in: harness)
        reconnect(headphones, in: harness)
        await drainEngineTasks()

        #expect(tap.currentDeviceUIDs == [speakers.uid])
        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [speakers.uid])
    }

    @Test("A tick made while a device is away keeps the away device saved, and it rejoins on return")
    func tickWhileAwayKeepsTheAwayDevice() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away at launch
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid, speakers.uid])
        #expect(tap.currentDeviceUIDs == [speakers.uid])

        // The picker hands over what it shows: the connected devices only.
        harness.engine.setSelectedDeviceUIDs(for: app, to: [speakers.uid, harness.device.uid])
        let ticked = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid, harness.device.uid] }
        #expect(ticked)
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == [headphones.uid, speakers.uid, harness.device.uid])
        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [speakers.uid, harness.device.uid])

        reconnect(headphones, in: harness)
        let rejoined = await waitUntil {
            tap.currentDeviceUIDs == [self.headphones.uid, self.speakers.uid, harness.device.uid]
        }
        #expect(rejoined)
    }

    @Test("An untick made while another device is away wins, and only the away device comes back")
    func untickWhileAwayWins() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away at launch
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid, speakers.uid, harness.device.uid])
        #expect(tap.currentDeviceUIDs == [speakers.uid, harness.device.uid])

        harness.engine.setSelectedDeviceUIDs(for: app, to: [harness.device.uid])
        let unticked = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(unticked)
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == [headphones.uid, harness.device.uid])

        reconnect(headphones, in: harness)
        let rejoined = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid, harness.device.uid] }
        #expect(rejoined, "the speakers were unticked by the user and must stay off")
        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [headphones.uid, harness.device.uid])
    }

    @Test("Entering Multi with a saved device away starts on the rest, and the device joins when it appears")
    func savedSelectionWithAnAwayDevice() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away
        let app = harness.makeApp(ids: [1])
        let tap = harness.launch(app)
        harness.settings.setSelectedDeviceUIDs(for: app.persistenceIdentifier, to: [headphones.uid, speakers.uid])

        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        let started = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(started, "a device that is away cannot be part of the route")
        reconnect(headphones, in: harness)
        let joined = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid, self.speakers.uid] }
        #expect(joined)
    }

    // MARK: - A multi app with none of its devices left

    @Test("A multi app whose devices are all away at launch follows the default")
    func launchFallbackFollowsTheDefault() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid])
        #expect(tap.currentDeviceUIDs == [harness.device.uid], "with its device away the app plays on the default")

        harness.engine.setDefaultOutputDevice(speakers.id)

        let followed = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(followed, "an app on the fallback follows the default like a single app")
    }

    @Test("A one-device multi app whose device drops goes back to following the default, and follows the next change")
    func disconnectFallbackFollowsTheDefault() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid])
        disconnect(headphones, in: harness)
        let fellBack = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(fellBack)
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)

        harness.engine.setDefaultOutputDevice(speakers.id)

        let followed = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(followed)
    }

    @Test("A multi app that still has a device left stays on it when the default changes")
    func partialRouteIgnoresDefaultChange() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away at launch
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid, harness.device.uid])
        #expect(tap.currentDeviceUIDs == [harness.device.uid])

        harness.engine.setDefaultOutputDevice(speakers.id)
        await drainEngineTasks()

        #expect(tap.currentDeviceUIDs == [harness.device.uid], "the remaining device is the app's own, not a fallback")
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .multi)
    }

    @Test("An app pinned to a device before Multi falls back when it drops, and returns to it on reconnect")
    func fallbackReturnsToItsDevice() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = await enterMulti(harness, app, pinnedTo: headphones, uids: [headphones.uid, speakers.uid])

        disconnect(headphones, in: harness)
        let fellBack = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(fellBack, "its pin is gone, so it plays on the default meanwhile")
        #expect(harness.settings.getDeviceRouting(for: app.persistenceIdentifier) == headphones.uid, "the pin stays its saved choice")

        reconnect(headphones, in: harness)
        let back = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid] }
        #expect(back, "the device the user picked should win over the fallback")
        harness.engine.setDefaultOutputDevice(speakers.id)
        await drainEngineTasks()

        #expect(tap.currentDeviceUIDs == [headphones.uid], "back on its own device it ignores default changes again")
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)
    }

    @Test("Ticking a device on an app that fell back at launch starts its route there, and the away device stays saved")
    func tickOnAFallbackAppStartsTheRoute() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away at launch
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid])
        #expect(tap.currentDeviceUIDs == [harness.device.uid], "with its only device away the app plays on the default")

        harness.engine.setSelectedDeviceUIDs(for: app, to: [speakers.uid])

        let started = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(started)
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == [headphones.uid, speakers.uid])
        harness.engine.setDefaultOutputDevice(harness.device.id)
        await drainEngineTasks()
        #expect(tap.currentDeviceUIDs == [speakers.uid], "with a device of its own the app no longer follows the default")
    }

    // MARK: - Tap source of a multi app

    // A follow-default app is captured with a stream-specific tap on the default device. That tap
    // goes stale when the default changes, which a multi route of its own never follows, so such an
    // app needs the stereo mixdown tap (no tap source) even though it stays in the follow-default set.

    @Test("An app switched from following the default to Multi with the default ticked gets a mixdown tap")
    func multiSwitchGetsAMixdownTap() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = harness.launch(app)
        #expect(tap.latestTapSource == harness.device.uid, "while it follows the default it is tapped on the default device")

        harness.engine.setSelectedDeviceUIDs(for: app, to: [harness.device.uid, headphones.uid])
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        let routed = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid, harness.device.uid] }
        #expect(routed)
        #expect(tap.latestTapSource == nil, "a multi route must not keep a tap tied to the default device")
    }

    @Test("A multi app created while it was in the follow-default set gets a mixdown tap")
    func multiCreateGetsAMixdownTap() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        // With no default yet the engine marks the app as following it but cannot make a tap.
        harness.deviceVolume.defaultDeviceUID = nil
        harness.probes.alivePIDs.insert(app.id)
        harness.probes.liveObjectIDs.formUnion(app.processObjectIDs)
        harness.publish([app])
        #expect(harness.tap(for: app.id) == nil)
        #expect(harness.engine.isFollowingDefault(for: app))
        harness.deviceVolume.defaultDeviceUID = harness.device.uid

        harness.engine.setSelectedDeviceUIDs(for: app, to: [harness.device.uid, headphones.uid])
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        let created = await waitUntil { harness.tap(for: app.id) != nil }
        #expect(created)
        #expect(harness.tap(for: app.id)?.tapSourceRequests == [nil], "the tap is made as a mixdown from the start")
    }

    @Test("Losing one device of a route that includes the default puts the app on a follow-default tap")
    func disconnectRevertsToAFollowDefaultTap() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = harness.launch(app)
        harness.engine.setSelectedDeviceUIDs(for: app, to: [harness.device.uid, headphones.uid])
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)
        let routed = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid, harness.device.uid] }
        #expect(routed)
        #expect(tap.latestTapSource == nil, "while it is Multi it is a mixdown")

        disconnect(headphones, in: harness)

        let dropped = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(dropped)
        #expect(tap.latestTapSource == harness.device.uid, "back on System Audio the tap follows the default")
    }

    @Test("A fallback multi app gets the default as its tap source, and the next default after a change")
    func fallbackMultiAppKeepsTheDefaultTapSource() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid])
        #expect(tap.currentDeviceUIDs == [harness.device.uid])
        #expect(tap.tapSourceRequests == [harness.device.uid], "on the fallback it is an ordinary follow-default app")

        harness.deviceVolume.defaultDeviceUID = speakers.uid  // the mock's default does not move by itself
        harness.engine.setDefaultOutputDevice(speakers.id)

        let followed = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(followed)
        #expect(tap.latestTapSource == speakers.uid)
    }

    @Test("A fallback multi app that gets the default ticked along with another device becomes a mixdown")
    func tickingTheDefaultOnAFallbackAppGivesAMixdownTap() async {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid])
        #expect(tap.latestTapSource == harness.device.uid)

        harness.engine.setSelectedDeviceUIDs(for: app, to: [speakers.uid, harness.device.uid])

        let routed = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid, harness.device.uid] }
        #expect(routed)
        #expect(tap.latestTapSource == nil, "with a route of its own the app is no longer tied to the default")
    }

    @Test("A multi app that goes back to System Audio when its device drops is tapped on the default")
    func routeBackToTheFallbackTapsTheDefault() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid])
        disconnect(headphones, in: harness)
        let fellBack = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(fellBack)

        #expect(tap.latestTapSource == harness.device.uid, "on System Audio the tap follows the default")
    }

    // MARK: - A device disconnect sends a Multi app back to Single

    // The rule: when an output device in an app's saved Multi selection disconnects, the app switches to
    // Single right away, even if other selected devices are still connected. Within an hour of entering
    // Multi it returns to the pre-Multi single setting (a pinned device, or System Audio). After that, or
    // with no recorded start, it goes to System Audio and forgets the old pin. Nothing rejoins on return.

    @Test("Entering Multi through the engine records the time it happened")
    func enteringMultiRecordsTheTime() {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        harness.launch(app)
        harness.clock.advance(by: 5)

        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        #expect(harness.settings.getMultiOutputSince(for: app.persistenceIdentifier) == harness.clock.now)
    }

    @Test("Leaving Multi through the engine clears the time")
    func leavingMultiClearsTheTime() {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        harness.launch(app)
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        harness.engine.setDeviceSelectionMode(for: app, to: .single)

        #expect(harness.settings.getMultiOutputSince(for: app.persistenceIdentifier) == nil)
    }

    @Test("A short Multi session that began on System Audio returns to System Audio, with the other devices still connected")
    func shortMultiFromSystemAudioReturnsToSystemAudio() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = await enterMulti(harness, app, uids: [headphones.uid, speakers.uid])
        harness.clock.advance(by: 600)

        disconnect(headphones, in: harness)

        let reverted = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(reverted, "the speakers are still connected but the app leaves Multi anyway")
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)
        #expect(harness.engine.isFollowingDefault(for: app))
        #expect(harness.settings.isFollowingDefault(for: app.persistenceIdentifier))
        #expect(harness.settings.getDeviceSelectionMode(for: app.persistenceIdentifier) == .single)
        #expect(harness.settings.getMultiOutputSince(for: app.persistenceIdentifier) == nil)
        #expect(tap.latestTapSource == harness.device.uid, "a System Audio tap follows the default device")
    }

    @Test("A Multi session just under an hour returns to the device the app was pinned to")
    func shortMultiReturnsToThePinnedDevice() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = await enterMulti(harness, app, pinnedTo: speakers, uids: [headphones.uid, harness.device.uid])
        harness.clock.advance(by: MultiOutputRevert.rememberWindow - 1)

        disconnect(headphones, in: harness)

        let reverted = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(reverted, "the app is back on the device it was pinned to before Multi")
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)
        #expect(!harness.engine.isFollowingDefault(for: app))
        #expect(harness.engine.getDeviceUID(for: app) == speakers.uid)
        #expect(harness.settings.getDeviceRouting(for: app.persistenceIdentifier) == speakers.uid)
        #expect(tap.latestTapSource == nil, "a pinned app is a mixdown tap, not tied to the default")
    }

    @Test("A Multi session of an hour or more goes to System Audio and forgets the old pin")
    func longMultiGoesToSystemAudioAndForgetsThePin() async {
        let harness = makeHarness()
        keepTheDefaultOnTheTestDevice(harness)
        let app = harness.makeApp(ids: [1])
        let tap = await enterMulti(harness, app, pinnedTo: speakers, uids: [headphones.uid, harness.device.uid])
        harness.clock.advance(by: MultiOutputRevert.rememberWindow)

        disconnect(headphones, in: harness)

        let reverted = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(reverted)
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)
        #expect(harness.engine.isFollowingDefault(for: app))
        #expect(harness.settings.isFollowingDefault(for: app.persistenceIdentifier))
        #expect(harness.settings.getDeviceRouting(for: app.persistenceIdentifier) == nil, "the old pin must not pull it back later")

        // The speakers going away and coming back changes nothing: they are no longer its pin.
        disconnect(speakers, in: harness)
        reconnect(speakers, in: harness)
        await drainEngineTasks()
        #expect(tap.currentDeviceUIDs == [harness.device.uid])
    }

    @Test("A Multi item with no recorded start goes to System Audio")
    func noRecordedStartGoesToSystemAudio() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        harness.settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: speakers.uid)
        let tap = launchMulti(harness, app, uids: [headphones.uid, speakers.uid])
        harness.settings.setMultiOutputSince(nil, for: app.persistenceIdentifier)  // a settings file from before the start was recorded

        disconnect(headphones, in: harness)

        let reverted = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(reverted)
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)
        #expect(harness.settings.getDeviceRouting(for: app.persistenceIdentifier) == nil)
    }

    @Test("When the pre-Multi pin is the device that dropped, the pin stays saved and the app plays on the default meanwhile")
    func pinThatDroppedStaysTheSavedChoice() async {
        let harness = makeHarness()
        keepTheDefaultOnTheTestDevice(harness)
        let app = harness.makeApp(ids: [1])
        let tap = await enterMulti(harness, app, pinnedTo: headphones, uids: [headphones.uid, speakers.uid])

        disconnect(headphones, in: harness)

        let fellBack = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(fellBack)
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)
        #expect(harness.settings.getDeviceRouting(for: app.persistenceIdentifier) == headphones.uid)
        #expect(!harness.settings.isFollowingDefault(for: app.persistenceIdentifier))

        reconnect(headphones, in: harness)
        let restored = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid] }
        #expect(restored, "the single-mode reconnect puts it back on its pin, and only there")
    }

    @Test("After the revert nothing rejoins when the device returns, and flipping to Multi by hand uses the saved selection")
    func noAutoRejoinAndManualFlipBack() async {
        let harness = makeHarness()
        keepTheDefaultOnTheTestDevice(harness)
        let app = harness.makeApp(ids: [1])
        let tap = await enterMulti(harness, app, uids: [headphones.uid, speakers.uid])
        disconnect(headphones, in: harness)
        let reverted = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(reverted)

        reconnect(headphones, in: harness)
        await drainEngineTasks()
        #expect(tap.currentDeviceUIDs == [harness.device.uid], "no automatic rejoin")
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)

        harness.clock.advance(by: 30)
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)

        let rejoined = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid, self.speakers.uid] }
        #expect(rejoined, "the saved selection is intact, so Multi comes back as it was")
        #expect(harness.settings.getMultiOutputSince(for: app.persistenceIdentifier) == harness.clock.now, "a fresh clock")
    }

    @Test("Multi to Single to Multi starts a fresh clock, so a long first session does not count")
    func freshClockAfterLeavingMulti() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        let tap = await enterMulti(harness, app, pinnedTo: speakers, uids: [headphones.uid, harness.device.uid])
        harness.clock.advance(by: 2 * MultiOutputRevert.rememberWindow)
        harness.engine.setDeviceSelectionMode(for: app, to: .single)
        let single = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(single)
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)
        let multi = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid, harness.device.uid] }
        #expect(multi)
        harness.clock.advance(by: 60)

        disconnect(headphones, in: harness)

        let reverted = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(reverted, "the second session is a minute old, so the pin is remembered")
    }

    @Test("A disconnect of a device that is not in the app's selection changes nothing")
    func unselectedDeviceDisconnectChangesNothing() async {
        let harness = EngineHarness(extraDevices: [headphones, speakers, hdmi])
        let app = harness.makeApp(ids: [1])
        let tap = launchMulti(harness, app, uids: [headphones.uid, speakers.uid])
        #expect(tap.currentDeviceUIDs == [headphones.uid, speakers.uid])

        disconnect(hdmi, in: harness)
        await drainEngineTasks()

        #expect(tap.currentDeviceUIDs == [headphones.uid, speakers.uid])
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .multi)
        #expect(harness.settings.getMultiOutputSince(for: app.persistenceIdentifier) != nil)
    }

    @Test("A single-mode app is not touched by the disconnect of a device left over in its saved selection")
    func singleModeAppIgnoresALeftoverSelection() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        harness.settings.setSelectedDeviceUIDs(for: app.persistenceIdentifier, to: [headphones.uid, speakers.uid])
        let tap = harness.launch(app)

        disconnect(headphones, in: harness)
        await drainEngineTasks()

        #expect(tap.currentDeviceUIDs == [harness.device.uid])
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)
        #expect(harness.settings.isFollowingDefault(for: app.persistenceIdentifier))
        #expect(harness.settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier) == [headphones.uid, speakers.uid])
    }

    @Test("Only the apps whose Multi selection has the device go back to Single")
    func onlyAffectedAppsRevert() async {
        let harness = makeHarness()
        let affected = harness.makeApp(pid: 100, ids: [1], bundleID: "com.deci.tests.Affected")
        let unaffected = harness.makeApp(pid: 200, ids: [2], bundleID: "com.deci.tests.Unaffected")
        let plain = harness.makeApp(pid: 300, ids: [3], bundleID: "com.deci.tests.Plain")
        harness.launchAll([affected, unaffected, plain])
        let affectedTap = await enterMulti(harness, affected, tap: harness.tap(for: affected.id), uids: [headphones.uid, speakers.uid])
        let unaffectedTap = await enterMulti(harness, unaffected, tap: harness.tap(for: unaffected.id), uids: [speakers.uid, harness.device.uid])
        let plainTap = harness.tap(for: plain.id)

        disconnect(headphones, in: harness)

        let reverted = await waitUntil { affectedTap.currentDeviceUIDs == [harness.device.uid] }
        #expect(reverted)
        await drainEngineTasks()
        #expect(harness.engine.getDeviceSelectionMode(for: affected) == .single)
        #expect(harness.engine.getDeviceSelectionMode(for: unaffected) == .multi)
        #expect(unaffectedTap.currentDeviceUIDs == [speakers.uid, harness.device.uid])
        #expect(plainTap?.currentDeviceUIDs == [harness.device.uid])
    }

    @Test("An app with no tap yet is reverted in memory too, so its row does not show Multi")
    func appWithoutATapReverts() {
        let harness = makeHarness()
        harness.engine.permission.status = .denied  // no tap can be created
        let app = harness.makeApp(ids: [1])
        harness.probes.alivePIDs.insert(app.id)
        harness.probes.liveObjectIDs.formUnion(app.processObjectIDs)
        harness.publish([app])
        harness.engine.setSelectedDeviceUIDs(for: app, to: [headphones.uid, speakers.uid])
        harness.engine.setDeviceSelectionMode(for: app, to: .multi)
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .multi)

        disconnect(headphones, in: harness)

        #expect(harness.engine.getDeviceSelectionMode(for: app) == .single)
        #expect(harness.settings.getDeviceSelectionMode(for: app.persistenceIdentifier) == .single)
        #expect(harness.settings.isFollowingDefault(for: app.persistenceIdentifier))
    }

    @Test("The engine reports each output disconnect after it has handled it")
    func disconnectCallbackFiresAfterTheRevert() async {
        let harness = makeHarness()
        let app = harness.makeApp(ids: [1])
        await enterMulti(harness, app, uids: [headphones.uid, speakers.uid])
        var seen: [String] = []
        var modeWhenReported: DeviceSelectionMode?
        harness.engine.onOutputDeviceDisconnected = { uid in
            seen.append(uid)
            modeWhenReported = harness.engine.getDeviceSelectionMode(for: app)
        }

        disconnect(headphones, in: harness)

        #expect(seen == [headphones.uid])
        #expect(modeWhenReported == .single, "listeners see the engine's state after the revert")
    }

    @Test("Processes of one app share its saved settings, so a short session sends every one of them back to the pin")
    func twoProcessesOfOneAppRevertTogether() async {
        let harness = makeHarness()
        let first = harness.makeApp(pid: 100, ids: [1], bundleID: "com.deci.tests.Shared")
        let second = harness.makeApp(pid: 200, ids: [2], bundleID: "com.deci.tests.Shared")
        harness.launchAll([first, second])
        let firstTap = await enterMulti(harness, first, tap: harness.tap(for: first.id), pinnedTo: speakers, uids: [headphones.uid, harness.device.uid])
        let secondTap = await enterMulti(harness, second, tap: harness.tap(for: second.id), pinnedTo: speakers, uids: [headphones.uid, harness.device.uid])
        harness.clock.advance(by: 60)

        disconnect(headphones, in: harness)

        let reverted = await waitUntil {
            firstTap.currentDeviceUIDs == [self.speakers.uid] && secondTap.currentDeviceUIDs == [self.speakers.uid]
        }
        #expect(reverted, "the second process must not read a start the first one already cleared")
        #expect(harness.engine.getDeviceSelectionMode(for: first) == .single)
        #expect(harness.engine.getDeviceSelectionMode(for: second) == .single)
        #expect(harness.settings.getDeviceRouting(for: first.persistenceIdentifier) == speakers.uid, "the pin is still saved")
        #expect(!harness.engine.isFollowingDefault(for: second))
    }

    @Test("A revert to System Audio rebuilds the tap once when the dropped device was the default, with a tapless follow-default app still on it")
    func revertRebuildsTheTapOnce() async {
        let harness = makeHarness()
        harness.settings.setDevicePriorityOrder([harness.device.uid, headphones.uid, speakers.uid])
        // A follow-default app that has no tap yet and is still routed to the default device.
        harness.engine.permission.status = .denied
        let tapless = harness.makeApp(pid: 300, ids: [3], bundleID: "com.deci.tests.Tapless")
        harness.engine.setDevice(for: tapless, deviceUID: nil)
        harness.engine.permission.status = .authorized
        #expect(harness.probes.createdTaps.isEmpty)
        let multi = harness.makeApp(pid: 100, ids: [1], bundleID: "com.deci.tests.Multi")
        let tap = await enterMulti(harness, multi, uids: [harness.device.uid, headphones.uid])
        let requestsBefore = tap.tapSourceRequests.count

        disconnect(harness.device, in: harness)  // the default output

        let reverted = await waitUntil { tap.currentDeviceUIDs == [self.headphones.uid] }
        #expect(reverted)
        await drainEngineTasks()
        #expect(tap.tapSourceRequests.count == requestsBefore + 1, "one rebuild for the revert, not a second from the default re-route")
        #expect(tap.currentDeviceUIDs == [headphones.uid])
        #expect(harness.engine.getDeviceUID(for: tapless) == headphones.uid, "the tapless app still follows the default")
    }

    @Test("A revert to a pin rebuilds the tap once when the dropped device was the default")
    func pinnedRevertRebuildsTheTapOnce() async {
        let harness = makeHarness()
        harness.settings.setDevicePriorityOrder([harness.device.uid, headphones.uid, speakers.uid])
        let app = harness.makeApp(ids: [1])
        let tap = await enterMulti(harness, app, pinnedTo: speakers, uids: [harness.device.uid, headphones.uid])
        let requestsBefore = tap.tapSourceRequests.count

        disconnect(harness.device, in: harness)

        let reverted = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(reverted)
        await drainEngineTasks()
        #expect(tap.tapSourceRequests.count == requestsBefore + 1)
    }

    // MARK: - The disconnect notification names where the apps went

    private func alertsOn(_ harness: EngineHarness) -> @MainActor () -> [String] {
        var settings = harness.settings.appSettings
        settings.showDeviceDisconnectAlerts = true
        harness.settings.updateAppSettings(settings)
        let log = NotificationLog()
        harness.engine.onDisconnectNotification = { log.bodies.append($0) }
        return { log.bodies }
    }

    @Test("The notification names the pin a Multi app went back to")
    func notificationNamesThePin() async {
        let harness = makeHarness()
        let bodies = alertsOn(harness)
        let app = harness.makeApp(ids: [1])
        let tap = await enterMulti(harness, app, pinnedTo: speakers, uids: [headphones.uid, harness.device.uid])
        harness.clock.advance(by: 60)

        disconnect(headphones, in: harness)

        let reverted = await waitUntil { tap.currentDeviceUIDs == [self.speakers.uid] }
        #expect(reverted)
        #expect(bodies().count == 1)
        let body = bodies().first ?? ""
        #expect(body.contains("switched to Speakers"), "it went to the pin, whatever the priority fallback is: \(body)")
        #expect(!body.contains("none"))
    }

    @Test("The notification says System Audio for an app that went back to following the default")
    func notificationNamesSystemAudio() async {
        let harness = makeHarness()
        let bodies = alertsOn(harness)
        let app = harness.makeApp(ids: [1])
        let tap = await enterMulti(harness, app, uids: [headphones.uid, speakers.uid])
        harness.clock.advance(by: 60)

        disconnect(headphones, in: harness)

        let reverted = await waitUntil { tap.currentDeviceUIDs == [harness.device.uid] }
        #expect(reverted)
        let body = bodies().first ?? ""
        #expect(body.contains("switched to System Audio"), "\(body)")
        #expect(!body.contains("none"))
    }

    @Test("The notification lists every place when apps went to different ones")
    func notificationListsEachDestination() async {
        let harness = makeHarness()
        let bodies = alertsOn(harness)
        let pinned = harness.makeApp(pid: 100, ids: [1], bundleID: "com.deci.tests.Pinned")
        let plain = harness.makeApp(pid: 200, ids: [2], bundleID: "com.deci.tests.PlainFollower")
        harness.launchAll([pinned, plain])
        let pinnedTap = await enterMulti(harness, pinned, tap: harness.tap(for: pinned.id), pinnedTo: speakers, uids: [headphones.uid, harness.device.uid])
        let plainTap = await enterMulti(harness, plain, tap: harness.tap(for: plain.id), uids: [headphones.uid, harness.device.uid])
        harness.clock.advance(by: 60)

        disconnect(headphones, in: harness)

        let reverted = await waitUntil {
            pinnedTap.currentDeviceUIDs == [self.speakers.uid] && plainTap.currentDeviceUIDs == [harness.device.uid]
        }
        #expect(reverted)
        let body = bodies().first ?? ""
        #expect(body.contains("2 app(s)"), "\(body)")
        #expect(body.contains("Speakers"))
        #expect(body.contains("System Audio"))
        #expect(!body.contains("none"))
    }

    // MARK: - Inactive and Music items in the settings

    @Test("An inactive Multi app whose device drops returns to its pre-Multi pin in the saved settings")
    func inactiveShortMultiReturnsToItsPin() {
        let harness = makeHarness()
        harness.settings.setDeviceRouting(for: inactiveID, deviceUID: speakers.uid)
        harness.settings.setSelectedDeviceUIDs(for: inactiveID, to: [headphones.uid, speakers.uid])
        harness.engine.setDeviceSelectionModeForInactive(identifier: inactiveID, to: .multi)
        harness.clock.advance(by: 120)

        disconnect(headphones, in: harness)

        #expect(harness.engine.getDeviceSelectionModeForInactive(identifier: inactiveID) == .single)
        #expect(harness.settings.getDeviceRouting(for: inactiveID) == speakers.uid)
        #expect(harness.settings.getSelectedDeviceUIDs(for: inactiveID) == [headphones.uid, speakers.uid])
        #expect(harness.settings.getMultiOutputSince(for: inactiveID) == nil)
    }

    @Test("An inactive Multi app that was in Multi for an hour goes to System Audio and forgets its pin")
    func inactiveLongMultiGoesToSystemAudio() {
        let harness = makeHarness()
        harness.settings.setDeviceRouting(for: inactiveID, deviceUID: speakers.uid)
        harness.settings.setSelectedDeviceUIDs(for: inactiveID, to: [headphones.uid, speakers.uid])
        harness.engine.setDeviceSelectionModeForInactive(identifier: inactiveID, to: .multi)
        harness.clock.advance(by: MultiOutputRevert.rememberWindow)

        disconnect(headphones, in: harness)

        #expect(harness.engine.getDeviceSelectionModeForInactive(identifier: inactiveID) == .single)
        #expect(harness.engine.isFollowingDefaultForInactive(identifier: inactiveID))
        #expect(harness.settings.getDeviceRouting(for: inactiveID) == nil)
    }

    @Test("An inactive Multi app without the device in its selection stays Multi")
    func inactiveUnselectedDeviceChangesNothing() {
        let harness = makeHarness()
        harness.settings.setSelectedDeviceUIDs(for: inactiveID, to: [speakers.uid, harness.device.uid])
        harness.engine.setDeviceSelectionModeForInactive(identifier: inactiveID, to: .multi)

        disconnect(headphones, in: harness)

        #expect(harness.engine.getDeviceSelectionModeForInactive(identifier: inactiveID) == .multi)
        #expect(harness.settings.getMultiOutputSince(for: inactiveID) != nil)
    }

    @Test("The engine leaves the music player's saved Multi alone, since the music mixer reverts itself")
    func engineSkipsTheMusicPlayer() {
        let harness = makeHarness()
        let key = MusicMixerState.settingsKey
        harness.settings.setDeviceSelectionMode(for: key, to: .multi, at: harness.clock.now)
        harness.settings.setSelectedDeviceUIDs(for: key, to: [headphones.uid, speakers.uid])

        disconnect(headphones, in: harness)

        #expect(harness.settings.getDeviceSelectionMode(for: key) == .multi)
        #expect(harness.settings.getMultiOutputSince(for: key) != nil)
    }

    // MARK: - Inactive apps flipped to Multi

    private let inactiveID = "com.deci.tests.Inactive"

    @Test("An inactive app flipped to Multi is seeded with the device it is pinned to")
    func inactiveSeedsFromItsPin() {
        let harness = makeHarness()
        harness.settings.setDeviceRouting(for: inactiveID, deviceUID: headphones.uid)

        harness.engine.setDeviceSelectionModeForInactive(identifier: inactiveID, to: .multi)

        #expect(harness.engine.getDeviceSelectionModeForInactive(identifier: inactiveID) == .multi)
        #expect(harness.engine.getSelectedDeviceUIDsForInactive(identifier: inactiveID) == [headphones.uid])
        #expect(harness.settings.getSelectedDeviceUIDs(for: inactiveID) == [headphones.uid])
    }

    @Test("An inactive app that follows the default is seeded with the default")
    func inactiveSeedsFromTheDefault() {
        let harness = makeHarness()

        harness.engine.setDeviceSelectionModeForInactive(identifier: inactiveID, to: .multi)

        #expect(harness.engine.getSelectedDeviceUIDsForInactive(identifier: inactiveID) == [harness.device.uid])
    }

    @Test("An inactive app pinned to a device that is away is seeded with the default")
    func inactiveSeedSkipsAnAwayPin() {
        let harness = EngineHarness(extraDevices: [speakers])  // the headphones are away
        harness.settings.setDeviceRouting(for: inactiveID, deviceUID: headphones.uid)

        harness.engine.setDeviceSelectionModeForInactive(identifier: inactiveID, to: .multi)

        #expect(harness.engine.getSelectedDeviceUIDsForInactive(identifier: inactiveID) == [harness.device.uid])
    }

    @Test("An inactive app's saved selection is not overwritten when it is flipped to Multi")
    func inactiveKeepsASavedSelection() {
        let harness = makeHarness()
        harness.settings.setSelectedDeviceUIDs(for: inactiveID, to: [headphones.uid, speakers.uid])

        harness.engine.setDeviceSelectionModeForInactive(identifier: inactiveID, to: .multi)

        #expect(harness.engine.getSelectedDeviceUIDsForInactive(identifier: inactiveID) == [headphones.uid, speakers.uid])
    }

    @Test("Flipping an inactive app to Single seeds nothing")
    func inactiveSingleDoesNotSeed() {
        let harness = makeHarness()

        harness.engine.setDeviceSelectionModeForInactive(identifier: inactiveID, to: .single)

        #expect(harness.settings.getSelectedDeviceUIDs(for: inactiveID) == nil)
    }

    @Test("With no pin and no default, an inactive app flipped to Multi stays unseeded")
    func inactiveNoSeedWithoutADevice() {
        let harness = makeHarness()
        harness.deviceVolume.defaultDeviceUID = nil

        harness.engine.setDeviceSelectionModeForInactive(identifier: inactiveID, to: .multi)

        #expect(harness.engine.getDeviceSelectionModeForInactive(identifier: inactiveID) == .multi)
        #expect(harness.engine.getSelectedDeviceUIDsForInactive(identifier: inactiveID).isEmpty)
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

    @Test("The apps on a multi route are reported by bundle id, and the callback fires on each change only")
    func multiRouteBundleIDsFollowTheRoute() async {
        let harness = makeHarness()
        var reported: [Set<String>] = []
        harness.engine.onMultiRouteBundleIDsChange = { reported.append($0) }
        #expect(harness.engine.multiRouteBundleIDs.isEmpty)

        launchMulti(harness, harness.makeApp(pid: 100, ids: [1], bundleID: "com.deci.tests.Fan"), uids: [headphones.uid, harness.device.uid])
        #expect(harness.engine.multiRouteBundleIDs == ["com.deci.tests.Fan"])
        #expect(reported == [["com.deci.tests.Fan"]])

        // Another app that plays on one device changes nothing.
        harness.launch(harness.makeApp(pid: 200, ids: [2], bundleID: "com.deci.tests.Quiet"))
        #expect(harness.engine.multiRouteBundleIDs == ["com.deci.tests.Fan"])
        #expect(reported.count == 1)

        disconnect(headphones, in: harness)
        let cleared = await waitUntil { harness.engine.multiRouteBundleIDs.isEmpty }
        #expect(cleared)
        #expect(reported == [["com.deci.tests.Fan"], []])
    }

    @Test("An app without a bundle id adds nothing to the multi route bundle ids")
    func multiRouteWithoutABundleID() {
        let harness = makeHarness()
        launchMulti(harness, harness.makeApp(ids: [1], bundleID: nil), uids: [headphones.uid, harness.device.uid])

        #expect(!harness.engine.multiRouteDeviceUIDs.isEmpty)
        #expect(harness.engine.multiRouteBundleIDs.isEmpty)
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
