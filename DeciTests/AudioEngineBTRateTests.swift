// DeciTests/AudioEngineBTRateTests.swift
//
// A Bluetooth output flipping sample rate (A2DP <-> SCO) makes the engine rebuild every
// tap on that device. The rebuilt aggregate must not leave the tap at default output
// state, and a cancelled rebuild must not be "recovered" by tearing the tap down.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import Deci

private struct RecreateFailure: Error {}

@Suite("AudioEngine: BT device sample-rate change")
@MainActor
struct AudioEngineBTRateTests {

    // MARK: Output state after a successful recreate

    @Test("After a successful recreate the tap's volume and mute equal the engine's effective values")
    func successfulRecreateReappliesOutputState() async {
        let h = EngineHarness(deviceVolumeLevel: 0.75)
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)
        h.engine.setVolume(for: app, to: 0.5)
        h.engine.setMute(for: app, to: true)
        tap.recreateResetsOutputState = true

        await h.engine.handleBTDeviceSampleRateChanged(uid: h.device.uid, newRate: 16_000)

        #expect(tap.recreateForOutputRateChangeCallCount == 1)
        #expect(tap.volume == 0.5)
        #expect(tap.isMuted == true)
    }

    @Test("Device volume and mute state are re-applied too")
    func successfulRecreateReappliesDeviceState() async {
        let h = EngineHarness(deviceVolumeLevel: 0.75)
        h.deviceVolume.muteStates[h.device.id] = true
        let tap = h.launch(h.makeApp(ids: [10]))
        tap.recreateResetsOutputState = true

        await h.engine.handleBTDeviceSampleRateChanged(uid: h.device.uid, newRate: 48_000)

        #expect(tap.currentDeviceVolume == 0.75)
        #expect(tap.isDeviceMuted == true)
    }

    @Test("An unmuted app comes back unmuted at its slider volume")
    func unmutedAppKeepsSliderVolume() async {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)
        h.engine.setVolume(for: app, to: 0.3)
        tap.recreateResetsOutputState = true

        await h.engine.handleBTDeviceSampleRateChanged(uid: h.device.uid, newRate: 8_000)

        #expect(abs(tap.volume - 0.3) < 1e-6)
        #expect(tap.isMuted == false)
    }

    // MARK: Cancellation

    @Test("A CancellationError does not trigger the recreateTap fallback")
    func cancellationSkipsFullRecreate() async {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)
        tap.recreateForOutputRateChangeError = CancellationError()

        await h.engine.handleBTDeviceSampleRateChanged(uid: h.device.uid, newRate: 16_000)

        #expect(tap.recreateForOutputRateChangeCallCount == 1)
        #expect(tap.wasInvalidated == false, "the cancelled tap must not be torn down")
        #expect(h.probes.createdTaps.count == 1, "no replacement tap may be created")
        #expect(h.engine.audioLevels[app.id] != nil)
    }

    // MARK: Failure fallback (unchanged behaviour)

    @Test("Any other error still falls back to a full tap recreate")
    func otherErrorFallsBackToFullRecreate() async {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)
        tap.recreateForOutputRateChangeError = RecreateFailure()

        await h.engine.handleBTDeviceSampleRateChanged(uid: h.device.uid, newRate: 16_000)

        #expect(tap.wasInvalidated == true)
        #expect(h.probes.createdTaps.count == 2)
        #expect(h.tap(for: app.id) !== tap)
    }

    @Test("One tap failing does not stop the others from being recreated")
    func failureDoesNotStopOtherTaps() async throws {
        let h = EngineHarness()
        let a = h.makeApp(pid: 100, ids: [1])
        let b = h.makeApp(pid: 200, ids: [2])
        h.launchAll([a, b])
        let tapA = try #require(h.tap(for: 100))
        let tapB = try #require(h.tap(for: 200))
        tapA.recreateForOutputRateChangeError = RecreateFailure()
        tapB.recreateResetsOutputState = true

        await h.engine.handleBTDeviceSampleRateChanged(uid: h.device.uid, newRate: 16_000)

        #expect(tapA.wasInvalidated == true)
        #expect(tapB.recreateForOutputRateChangeCallCount == 1)
        #expect(tapB.wasInvalidated == false)
    }

    // MARK: Scope

    @Test("Only taps on the changed device are recreated")
    func onlyAffectedTapsAreRecreated() async throws {
        let other = AudioDevice(id: 100, uid: "uid-other", name: "Other Output", icon: nil, supportsAutoEQ: false)
        let h = EngineHarness(extraDevices: [other])
        let onDefault = h.makeApp(pid: 100, ids: [1])
        let onOther = h.makeApp(pid: 200, ids: [2])
        h.launch(onDefault)
        h.engine.setDevice(for: onOther, deviceUID: other.uid)
        let tapDefault = try #require(h.tap(for: 100))
        let tapOther = try #require(h.tap(for: 200))
        #expect(tapOther.currentDeviceUIDs == [other.uid])

        await h.engine.handleBTDeviceSampleRateChanged(uid: h.device.uid, newRate: 16_000)

        #expect(tapDefault.recreateForOutputRateChangeCallCount == 1)
        #expect(tapOther.recreateForOutputRateChangeCallCount == 0)
    }

    @Test("A rate change on a device nothing is tapping is a no-op")
    func unrelatedDeviceIsNoOp() async {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10]))

        await h.engine.handleBTDeviceSampleRateChanged(uid: "uid-not-in-use", newRate: 16_000)

        #expect(tap.recreateForOutputRateChangeCallCount == 0)
        #expect(tap.wasInvalidated == false)
    }
}
