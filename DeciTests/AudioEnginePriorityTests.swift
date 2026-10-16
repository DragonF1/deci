// DeciTests/AudioEnginePriorityTests.swift
// Priority-based device switching: a connected device that tops the priority list becomes
// the active one (output and, while Input Follows Priority is on, input), and a reordered list
// that puts a different connected device on top switches to it.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import Deci

@MainActor
@Suite("AudioEngine device priority")
struct AudioEnginePriorityTests {

    private let headphones = AudioDevice(id: AudioDeviceID(100), uid: "uid-headphones", name: "Headphones", icon: nil, supportsAutoEQ: false)
    private let builtInMic = AudioDevice(id: AudioDeviceID(201), uid: "uid-mic-builtin", name: "Built-in Mic", icon: nil, supportsAutoEQ: false)
    private let headsetMic = AudioDevice(id: AudioDeviceID(202), uid: "uid-mic-headset", name: "Headset Mic", icon: nil, supportsAutoEQ: false)

    // MARK: - Pure decision

    @Test("The highest-priority device makes sure it is the default, even when macOS already switched")
    func highestPriorityEnsuresDefault() {
        #expect(AudioEngine.connectedOutputDefaultAction(connectedDeviceUID: "a", highestPriorityConnectedUID: "a", currentDefaultUID: "a") == .ensureHighestPriorityDefault)
        #expect(AudioEngine.connectedOutputDefaultAction(connectedDeviceUID: "a", highestPriorityConnectedUID: "a", currentDefaultUID: "b") == .ensureHighestPriorityDefault)
        #expect(AudioEngine.connectedOutputDefaultAction(connectedDeviceUID: "a", highestPriorityConnectedUID: "a", currentDefaultUID: nil) == .ensureHighestPriorityDefault)
    }

    @Test("A lower-priority device macOS switched to is undone; otherwise nothing happens")
    func lowerPriorityRestoresOrIgnores() {
        #expect(AudioEngine.connectedOutputDefaultAction(connectedDeviceUID: "b", highestPriorityConnectedUID: "a", currentDefaultUID: "b") == .restorePrevious)
        #expect(AudioEngine.connectedOutputDefaultAction(connectedDeviceUID: "b", highestPriorityConnectedUID: "a", currentDefaultUID: "a") == .none)
    }

    // MARK: - Output

    @Test("Headphones that top the list and that macOS already made default take the follows-default apps along")
    func connectedTopDeviceMovesFollowsDefaultApps() async {
        let harness = EngineHarness()
        let tap = harness.launch(harness.makeApp(ids: [1]))
        #expect(tap.currentDeviceUID == harness.device.uid)

        harness.deviceMonitor.addOutputDevice(headphones)
        harness.settings.setDevicePriorityOrder([headphones.uid, harness.device.uid])
        harness.deviceVolume.defaultDeviceUID = headphones.uid  // macOS switched first
        harness.deviceMonitor.onDeviceConnected?(headphones.uid, headphones.name)

        let moved = await waitUntil { tap.currentDeviceUID == self.headphones.uid }
        #expect(moved, "the follows-default tap should move to the headphones")
    }

    @Test("Reordering so a different connected device is on top makes it the default")
    func reorderSwitchesOutput() async {
        let harness = EngineHarness(extraDevices: [headphones])
        let tap = harness.launch(harness.makeApp(ids: [1]))
        harness.settings.setDevicePriorityOrder([harness.device.uid, headphones.uid])

        harness.engine.applyOutputPriorityOrder(connectedOrder: [headphones.uid, harness.device.uid])

        #expect(harness.settings.devicePriorityOrder.first == headphones.uid)
        #expect(harness.deviceVolume.setDefaultDeviceCalls.last == headphones.id)
        let moved = await waitUntil { tap.currentDeviceUID == self.headphones.uid }
        #expect(moved)
    }

    @Test("Reordering below the top leaves the default alone")
    func reorderBelowTopDoesNothing() {
        let other = AudioDevice(id: AudioDeviceID(101), uid: "uid-other", name: "Other", icon: nil, supportsAutoEQ: false)
        let harness = EngineHarness(extraDevices: [headphones, other])
        harness.settings.setDevicePriorityOrder([harness.device.uid, headphones.uid, other.uid])

        harness.engine.applyOutputPriorityOrder(connectedOrder: [harness.device.uid, other.uid, headphones.uid])

        #expect(harness.settings.devicePriorityOrder == [harness.device.uid, other.uid, headphones.uid])
        #expect(harness.deviceVolume.setDefaultDeviceCalls.isEmpty)
    }

    // MARK: - Input

    private func inputHarness(priority: [String], locked: String, lockEnabled: Bool = true) -> EngineHarness {
        let harness = EngineHarness()
        harness.deviceMonitor.addInputDevice(builtInMic)
        var appSettings = harness.settings.appSettings
        appSettings.lockInputDevice = lockEnabled
        harness.settings.updateAppSettings(appSettings)
        harness.settings.setInputDevicePriorityOrder(priority)
        harness.settings.setLockedInputDeviceUID(locked)
        harness.deviceVolume.defaultInputDeviceUID = locked
        return harness
    }

    @Test("A mic that connects at the top of the input list becomes the locked input")
    func topMicConnectLocksToIt() {
        let harness = inputHarness(priority: [headsetMic.uid, builtInMic.uid], locked: builtInMic.uid)

        harness.deviceMonitor.addInputDevice(headsetMic)
        harness.deviceMonitor.onInputDeviceConnected?(headsetMic.uid, headsetMic.name)

        #expect(harness.settings.lockedInputDeviceUID == headsetMic.uid)
        #expect(harness.deviceVolume.setDefaultInputDeviceCalls.last == headsetMic.id)
    }

    @Test("A lower-priority mic that connects does not take the input")
    func lowerMicConnectKeepsLock() {
        let harness = inputHarness(priority: [builtInMic.uid, headsetMic.uid], locked: builtInMic.uid)

        harness.deviceMonitor.addInputDevice(headsetMic)
        harness.deviceMonitor.onInputDeviceConnected?(headsetMic.uid, headsetMic.name)

        #expect(harness.settings.lockedInputDeviceUID == builtInMic.uid)
        #expect(!harness.deviceVolume.setDefaultInputDeviceCalls.contains(headsetMic.id))
    }

    @Test("With Input Follows Priority off, macOS keeps control of the input")
    func lockOffIgnoresPriority() {
        let harness = inputHarness(priority: [headsetMic.uid, builtInMic.uid], locked: builtInMic.uid, lockEnabled: false)

        harness.deviceMonitor.addInputDevice(headsetMic)
        harness.deviceMonitor.onInputDeviceConnected?(headsetMic.uid, headsetMic.name)
        harness.engine.applyInputPriorityOrder(connectedOrder: [builtInMic.uid, headsetMic.uid])

        #expect(harness.settings.lockedInputDeviceUID == builtInMic.uid)
        #expect(harness.deviceVolume.setDefaultInputDeviceCalls.isEmpty)
    }

    @Test("Reordering the inputs so another mic is on top switches and locks to it")
    func reorderSwitchesInput() {
        let harness = inputHarness(priority: [builtInMic.uid, headsetMic.uid], locked: builtInMic.uid)
        harness.deviceMonitor.addInputDevice(headsetMic)

        harness.engine.applyInputPriorityOrder(connectedOrder: [headsetMic.uid, builtInMic.uid])

        #expect(harness.settings.inputDevicePriorityOrder.first == headsetMic.uid)
        #expect(harness.settings.lockedInputDeviceUID == headsetMic.uid)
        #expect(harness.deviceVolume.setDefaultInputDeviceCalls == [headsetMic.id])
    }

    @Test("Turning Input Follows Priority on switches to the top connected mic and remembers it")
    func enablingLockAppliesPriority() {
        let harness = inputHarness(priority: [headsetMic.uid, builtInMic.uid], locked: builtInMic.uid, lockEnabled: false)
        harness.deviceMonitor.addInputDevice(headsetMic)

        harness.engine.handleInputLockEnabled()

        #expect(harness.settings.lockedInputDeviceUID == headsetMic.uid)
        #expect(harness.settings.preferredInputDeviceUID == headsetMic.uid)
        #expect(harness.deviceVolume.setDefaultInputDeviceCalls == [headsetMic.id])
    }

    @Test("A priority switch also moves the preferred mic, so an older pick cannot take over later")
    func prioritySwitchUpdatesPreferred() {
        let harness = inputHarness(priority: [builtInMic.uid, headsetMic.uid], locked: builtInMic.uid)
        harness.settings.setPreferredInputDeviceUID(builtInMic.uid)
        harness.deviceMonitor.addInputDevice(headsetMic)

        harness.engine.applyInputPriorityOrder(connectedOrder: [headsetMic.uid, builtInMic.uid])

        #expect(harness.settings.preferredInputDeviceUID == headsetMic.uid)
    }

    @Test("A default input macOS picked before the device list knows it is left to the connect handler")
    func unknownDefaultInputIsDeferred() async {
        let harness = inputHarness(priority: [builtInMic.uid], locked: builtInMic.uid)

        harness.deviceVolume.onDefaultInputDeviceChanged?("uid-not-listed-yet")
        // The handler hops to the main actor; give it a turn before checking nothing happened.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(harness.deviceVolume.setDefaultInputDeviceCalls.isEmpty)
        #expect(harness.settings.lockedInputDeviceUID == builtInMic.uid)
    }
}
