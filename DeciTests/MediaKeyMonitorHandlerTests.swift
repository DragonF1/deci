// FineTuneTests/MediaKeyMonitorHandlerTests.swift
// Tests for MediaKeyMonitor.handleCore() — the volume/mute logic decoupled from
// real CGEventTap, AudioEngine, and DeviceVolumeMonitor.
//
// Strategy: call handleCore directly, injecting closure stubs. No real CoreAudio is touched.

import Testing
import Foundation
import AudioToolbox
import CoreGraphics
@testable import Deci

// MARK: - Stub decoder and HUD controller helpers

/// Stub decoder that always returns a pre-configured event.
final class StubMediaKeyDecoder: MediaKeyEventDecoding, @unchecked Sendable {
    var nextEvent: MediaKeyEvent?
    func decode(data1: Int) -> MediaKeyEvent? { nextEvent }
}

/// Records what the monitor asks the HUD to show, so a test can compare it with the popup slider,
/// and how many keypresses it swallowed and left to macOS.
@MainActor
final class FractionRecordingHUD: MediaKeyHUDPresenting {
    private(set) var shown: [(sliderFraction: Double, mute: Bool, deviceName: String)] = []
    private(set) var swallowed = 0
    private(set) var passedThrough = 0
    func show(sliderFraction: Double, mute: Bool, deviceName: String) {
        shown.append((sliderFraction, mute, deviceName))
    }
    func swallowObserved() { swallowed += 1 }
    func passThroughObserved() { passedThrough += 1 }
}

/// Stands in for `NSSound.beep` so a test can count the rejections without making a sound.
@MainActor
final class BeepCounter {
    private(set) var count = 0
    func beep() { count += 1 }
}

// MARK: - Test suite

@Suite("MediaKeyMonitor — handleCore() volume/mute logic")
@MainActor
struct MediaKeyMonitorHandlerTests {

    // MARK: Helpers

    private func makeMonitor(
        hudController: HUDWindowController? = nil,
        popupVisible: Bool = false
    ) -> (monitor: MediaKeyMonitor, hud: HUDWindowController, popup: PopupVisibilityService, settingsManager: SettingsManager) {
        let rig = makeRig(hudController: hudController, popupVisible: popupVisible)
        return (rig.monitor, rig.hud, rig.popup, rig.settingsManager)
    }

    /// Same wiring as `makeMonitor`, but also hands back the mock volume provider so a test can drive
    /// the real `handle(_:held:)` path (default device, tier and volume come from the mock), plus the
    /// keybind recorder the monitor consults and the beeps it made.
    private func makeRig(
        hudController: HUDWindowController? = nil,
        popupVisible: Bool = false,
        presenter: MediaKeyHUDPresenting? = nil
    ) -> (
        monitor: MediaKeyMonitor, hud: HUDWindowController, popup: PopupVisibilityService,
        settingsManager: SettingsManager, volume: MockDeviceVolumeProviding,
        recorder: VolumeKeyRecorder, beeps: BeepCounter
    ) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        var appSettings = settings.appSettings
        appSettings.mediaKeyControlEnabled = true
        settings.updateAppSettings(appSettings)

        let deviceMonitor = MockAudioDeviceMonitor()
        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        let engine = AudioEngine(
            permission: AudioRecordingPermission(),
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: deviceMonitor,
            deviceVolumeMonitor: mockVolume,
            startMonitorsAutomatically: false
        )

        let mediaKeyStatus = MediaKeyStatus()
        let popup = PopupVisibilityService()
        popup.isVisible = popupVisible
        let hud = hudController ?? HUDWindowController(settingsManager: settings, mediaKeyStatus: mediaKeyStatus, popupVisibility: popup)
        // Replace frameProvider to avoid NSScreen access in unit tests.
        hud.frameProvider = { NSRect(x: 0, y: 0, width: 1440, height: 900) }

        let beeps = BeepCounter()
        let recorder = VolumeKeyRecorder(settings: settings, beep: { beeps.beep() })
        let monitor = MediaKeyMonitor(
            decoder: StubMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: MockAccessibilityTrustProviding(isTrusted: true),
            hudController: presenter ?? hud,
            popupVisibility: popup,
            mediaKeyStatus: mediaKeyStatus,
            volumeKeyRecorder: recorder
        )
        return (monitor, hud, popup, settings, mockVolume, recorder, beeps)
    }

    // MARK: - Volume step arithmetic

    @Test("volumeUp on software tier steps in slider domain (x² taper)")
    func volumeUpStep() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        let nextSlider = 0.8071  // 0.7071 + 0.10, snapped to the 1e-4 slider grid
        let expected = Float(nextSlider * nextSlider)
        #expect(abs((writtenVolume ?? 0) - expected) < 1e-5)
    }

    @Test("volumeDown on software tier steps in slider domain (x² taper)")
    func volumeDownStep() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeDown(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        let nextSlider = 0.6071  // 0.7071 - 0.10, snapped to the 1e-4 slider grid
        let expected = Float(nextSlider * nextSlider)
        #expect(abs((writtenVolume ?? 0) - expected) < 1e-5)
    }

    @Test("volumeUp clamps at 1.0 when current is already 1.0")
    func volumeUpClamp() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 1.0,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        #expect(writtenVolume == 1.0)
    }

    @Test("volumeDown clamps at 0.0 when current is already 0")
    func volumeDownClamp() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeDown(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.0,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        #expect(writtenVolume == 0.0)
    }

    // MARK: - Repeat handling (AC #6, #7, #8, #10)

    @Test("volumeUp(isRepeat: true) from 0.5 steps volume to 0.6 (AC #7 companion)")
    func volumeUpRepeatStepsVolume() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: true),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        #expect(abs((writtenVolume ?? 0) - 0.6) < 1e-6)
    }

    @Test("volumeDown(isRepeat: true) from 0.5 writes 0.4 (AC #6)")
    func volumeDownRepeatStepsVolume() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeDown(isRepeat: true),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        #expect(abs((writtenVolume ?? 0) - 0.4) < 1e-6)
    }

    @Test("4 volumeUp repeats from 0.5 land at 0.5 + 4·0.1 = 0.9")
    func fourRepeatsCumulative() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var currentVolume: Float = 0.5
        for _ in 0..<4 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: true),
                deviceID: deviceID,
                tier: .hardware,
                deviceName: "Test Device",
                currentVolume: currentVolume,
                currentMute: false,
                setVolume: { _, v in currentVolume = v },
                setMute: { _, _ in }
            )
        }
        #expect(abs(currentVolume - 0.9) < 1e-5)
    }

    @Test("3 volumeUp repeats from 0.85 clamp at 1.0")
    func repeatsClampAtOne() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var currentVolume: Float = 0.85
        for _ in 0..<3 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: true),
                deviceID: deviceID,
                tier: .hardware,
                deviceName: "Test Device",
                currentVolume: currentVolume,
                currentMute: false,
                setVolume: { _, v in currentVolume = v },
                setMute: { _, _ in }
            )
        }
        #expect(currentVolume == 1.0)
    }

    // MARK: - DDC repeat coalescing (AC #10)

    @Test("4 DDC repeats within 150 ms fire ≤ 3 setVolume calls (AC #10)")
    func ddcRepeatsCoalesced() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var setVolumeCount = 0
        // Four rapid repeats with no sleep — the 80 ms floor will drop at least one.
        for _ in 0..<4 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: true),
                deviceID: deviceID,
                tier: .ddc,
                deviceName: "Test Display",
                currentVolume: 0.5,
                currentMute: false,
                setVolume: { _, _ in setVolumeCount += 1 },
                setMute: { _, _ in }
            )
        }
        #expect(setVolumeCount <= 3)
    }

    @Test("Non-repeat DDC press always writes — floor applies only to repeats")
    func ddcNonRepeatAlwaysWrites() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var setVolumeCount = 0
        for _ in 0..<3 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: false),
                deviceID: deviceID,
                tier: .ddc,
                deviceName: "Test Display",
                currentVolume: 0.5,
                currentMute: false,
                setVolume: { _, _ in setVolumeCount += 1 },
                setMute: { _, _ in }
            )
        }
        #expect(setVolumeCount == 3)
    }

    @Test("Hardware-tier repeats are NOT coalesced (no 80 ms floor)")
    func hardwareRepeatsNotCoalesced() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var setVolumeCount = 0
        for _ in 0..<4 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: true),
                deviceID: deviceID,
                tier: .hardware,
                deviceName: "Test Device",
                currentVolume: 0.5,
                currentMute: false,
                setVolume: { _, _ in setVolumeCount += 1 },
                setMute: { _, _ in }
            )
        }
        #expect(setVolumeCount == 4)
    }

    // MARK: - Mute semantics on volume keys (volumeHUD / macOS parity)

    @Test("volumeUp while muted auto-unmutes (bug: F12 after F10 used to stay muted)")
    func volumeUpWhileMutedUnmutes() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenMute: Bool?
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: true,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, m in writtenMute = m }
        )
        #expect(writtenMute == false)
        #expect(abs((writtenVolume ?? 0) - 0.6) < 1e-6)
    }

    @Test("volumeUp while unmuted does not touch mute state")
    func volumeUpWhileUnmutedDoesNotCallSetMute() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var setMuteCalls = 0
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, _ in },
            setMute: { _, _ in setMuteCalls += 1 }
        )
        #expect(setMuteCalls == 0)
    }

    @Test("volumeDown to audible while muted auto-unmutes")
    func volumeDownToAudibleWhileMutedUnmutes() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenMute: Bool?
        monitor.handleCore(
            event: .volumeDown(isRepeat: false),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: true,
            setVolume: { _, _ in },
            setMute: { _, m in writtenMute = m }
        )
        #expect(writtenMute == false)
    }

    @Test("volumeDown to 0 while unmuted auto-mutes (macOS native parity)")
    func volumeDownToZeroAutoMutes() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenMute: Bool?
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeDown(isRepeat: false),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.1,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, m in writtenMute = m }
        )
        #expect(writtenVolume == 0)  // Float(0.1) minus 0.1 leaves ~1e-9 before the grid snap
        #expect(writtenMute == true)
    }

    @Test("volumeDown already at 0 while muted is a no-op for mute")
    func volumeDownAtZeroWhileMutedNoOp() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var setMuteCalls = 0
        monitor.handleCore(
            event: .volumeDown(isRepeat: false),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.0,
            currentMute: true,
            setVolume: { _, _ in },
            setMute: { _, _ in setMuteCalls += 1 }
        )
        #expect(setMuteCalls == 0)
    }

    // MARK: - Mute toggle

    @Test("muteToggle from unmuted sets mute to true")
    func muteToggleOn() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenMute: Bool?
        monitor.handleCore(
            event: .muteToggle,
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, _ in },
            setMute: { _, m in writtenMute = m }
        )
        #expect(writtenMute == true)
    }

    @Test("muteToggle from muted sets mute to false")
    func muteToggleOff() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenMute: Bool?
        monitor.handleCore(
            event: .muteToggle,
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: true,
            setVolume: { _, _ in },
            setMute: { _, m in writtenMute = m }
        )
        #expect(writtenMute == false)
    }

    // MARK: - HUD show count

    @Test("handleCore calls HUD show once when popup is not visible")
    func hudShowCalledWhenPopupHidden() {
        let (monitor, hud, _, _) = makeMonitor(popupVisible: false)
        let deviceID: AudioDeviceID = 1
        #expect(hud.showCallCount == 0)
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, _ in },
            setMute: { _, _ in }
        )
        #expect(hud.showCallCount == 1)
    }

    @Test("handleCore does not call HUD show when popup is visible")
    func hudNotShownWhenPopupVisible() {
        let (monitor, hud, _, _) = makeMonitor(popupVisible: true)
        let deviceID: AudioDeviceID = 1
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, _ in },
            setMute: { _, _ in }
        )
        #expect(hud.showCallCount == 0)
    }

    @Test("handleCore calls HUD show for repeat volumeUp when popup hidden (AC #7 per-call)")
    func hudShownForRepeat() {
        let (monitor, hud, _, _) = makeMonitor(popupVisible: false)
        let deviceID: AudioDeviceID = 1
        monitor.handleCore(
            event: .volumeUp(isRepeat: true),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, _ in },
            setMute: { _, _ in }
        )
        #expect(hud.showCallCount == 1)
    }

    @Test("Software tier post-step gain differs from hardware tier by exactly the x² taper")
    func softwareVsHardwareStepDivergence() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1

        var softwareVolume: Float = 0.5
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: deviceID, tier: .software,
            deviceName: "Software Device", currentVolume: softwareVolume, currentMute: false,
            setVolume: { _, v in softwareVolume = v }, setMute: { _, _ in }
        )

        var hardwareVolume: Float = 0.5
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: deviceID, tier: .hardware,
            deviceName: "Hardware Device", currentVolume: hardwareVolume, currentMute: false,
            setVolume: { _, v in hardwareVolume = v }, setMute: { _, _ in }
        )

        #expect(abs(hardwareVolume - 0.6) < 1e-5)
        let expectedSoftware = Float(0.8071 * 0.8071)  // slider 0.7071 + 0.10, snapped to the 1e-4 grid
        #expect(abs(softwareVolume - expectedSoftware) < 1e-5)
        #expect(softwareVolume != hardwareVolume)
    }

    // MARK: - Volume-feedback hook

    @Test("volumeUp on hardware tier invokes playFeedback with gain 1.0")
    func feedbackOnVolumeUpHardware() {
        let (monitor, _, _, _) = makeMonitor()
        var feedbackGain: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, _ in }, setMute: { _, _ in },
            playFeedback: { feedbackGain = $0 }
        )
        #expect(feedbackGain == 1.0)
    }

    @Test("volumeUp on software tier passes exactly the gain written to the device")
    func feedbackGainTracksSoftwareTier() {
        let (monitor, _, _, _) = makeMonitor()
        var written: Float?
        var feedbackGain: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: 1, tier: .software,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, v in written = v }, setMute: { _, _ in },
            playFeedback: { feedbackGain = $0 }
        )
        #expect(feedbackGain != nil)
        #expect(feedbackGain == written)  // the pop self-scales exactly like the tap gain
    }

    @Test("volumeDown invokes playFeedback")
    func feedbackOnVolumeDown() {
        let (monitor, _, _, _) = makeMonitor()
        var feedbackCalls = 0
        monitor.handleCore(
            event: .volumeDown(isRepeat: false), deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, _ in }, setMute: { _, _ in },
            playFeedback: { _ in feedbackCalls += 1 }
        )
        #expect(feedbackCalls == 1)
    }

    @Test("muteToggle never invokes playFeedback (native parity)")
    func noFeedbackOnMuteToggle() {
        let (monitor, _, _, _) = makeMonitor()
        var feedbackCalls = 0
        monitor.handleCore(
            event: .muteToggle, deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, _ in }, setMute: { _, _ in },
            playFeedback: { _ in feedbackCalls += 1 }
        )
        #expect(feedbackCalls == 0)
    }

    @Test("DDC-coalesced repeats skip playFeedback along with setVolume")
    func feedbackCoalescedWithDDC() {
        let (monitor, _, _, _) = makeMonitor()
        var setVolumeCalls = 0
        var feedbackCalls = 0
        for _ in 0..<4 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: true), deviceID: 1, tier: .ddc,
                deviceName: "Test Display", currentVolume: 0.5, currentMute: false,
                setVolume: { _, _ in setVolumeCalls += 1 }, setMute: { _, _ in },
                playFeedback: { _ in feedbackCalls += 1 }
            )
        }
        #expect(setVolumeCalls == 1)  // 4 synchronous repeats coalesce to one write
        #expect(feedbackCalls == setVolumeCalls)  // pop count mirrors actual volume writes
    }

    @Test("volumeDown reaching 0 auto-mutes AND still pops (spec behavior-table row)")
    func feedbackOnVolumeDownToZero() {
        let (monitor, _, _, _) = makeMonitor()
        var writtenMute: Bool?
        var feedbackCalls = 0
        monitor.handleCore(
            event: .volumeDown(isRepeat: false), deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.1, currentMute: false,
            setVolume: { _, _ in }, setMute: { _, m in writtenMute = m },
            playFeedback: { _ in feedbackCalls += 1 }
        )
        #expect(writtenMute == true)
        #expect(feedbackCalls == 1)
    }

    // MARK: - Held modifiers (F11/F12, Cmd, Cmd+Shift and any added row)

    /// Writes the rows the next press will be matched against.
    private func setBindings(_ settings: SettingsManager, _ bindings: [VolumeKeyBinding]) {
        var appSettings = settings.appSettings
        appSettings.volumeKeyBindings = bindings
        settings.updateAppSettings(appSettings)
    }

    /// Sets the percent of the default row at `index` (0 plain, 1 Command, 2 Command+Shift).
    private func setDefaultRowPercent(_ settings: SettingsManager, _ index: Int, to percent: Int) {
        var appSettings = settings.appSettings
        appSettings.volumeKeyBindings[index].percent = percent
        settings.updateAppSettings(appSettings)
    }

    /// Runs one hardware-tier press at `currentVolume` and returns the volume written (nil if none).
    private func press(
        _ monitor: MediaKeyMonitor,
        _ event: MediaKeyEvent,
        from currentVolume: Float,
        held: VolumeKeyCombo = [],
        currentMute: Bool = false,
        setMute: @escaping (Bool) -> Void = { _ in }
    ) -> Float? {
        var written: Float?
        monitor.handleCore(
            event: event, deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: currentVolume, currentMute: currentMute,
            setVolume: { _, v in written = v }, setMute: { _, m in setMute(m) },
            held: held
        )
        return written
    }

    @Test("Each default row steps the slider by its own percent", arguments: [
        (held: VolumeKeyCombo([]),                    step: 0.10),
        (held: VolumeKeyCombo([.command]),            step: 0.05),
        (held: VolumeKeyCombo([.command, .shift]),    step: 0.01),
    ])
    func rowStepsUpAndDown(_ c: (held: VolumeKeyCombo, step: Double)) {
        let (monitor, _, _, _) = makeMonitor()
        let up = press(monitor, .volumeUp(isRepeat: false), from: 0.5, held: c.held)
        let down = press(monitor, .volumeDown(isRepeat: false), from: 0.5, held: c.held)
        #expect(abs(Double(up ?? 0) - (0.5 + c.step)) < 1e-6)
        #expect(abs(Double(down ?? 0) - (0.5 - c.step)) < 1e-6)
    }

    @Test("Without a held combo handleCore uses the empty-combo row's step")
    func heldDefaultsToEmpty() {
        let (monitor, _, _, settings) = makeMonitor()
        setDefaultRowPercent(settings, 0, to: 20)
        setDefaultRowPercent(settings, 1, to: 3)
        var written: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, v in written = v }, setMute: { _, _ in }
        )
        #expect(abs(Double(written ?? 0) - 0.7) < 1e-6)
    }

    @Test("Edited percents are honoured per row")
    func customPercentsHonoured() {
        let (monitor, _, _, settings) = makeMonitor()
        setDefaultRowPercent(settings, 0, to: 20)
        setDefaultRowPercent(settings, 1, to: 3)
        setDefaultRowPercent(settings, 2, to: 2)

        let plain = press(monitor, .volumeUp(isRepeat: false), from: 0.5)
        let command = press(monitor, .volumeUp(isRepeat: false), from: 0.5, held: [.command])
        let commandShift = press(monitor, .volumeDown(isRepeat: false), from: 0.5, held: [.command, .shift])
        #expect(abs(Double(plain ?? 0) - 0.70) < 1e-6)
        #expect(abs(Double(command ?? 0) - 0.53) < 1e-6)
        #expect(abs(Double(commandShift ?? 0) - 0.48) < 1e-6)
    }

    @Test("A row added in Settings steps by its own percent, also with extra modifiers held")
    func addedRowSteps() {
        let (monitor, _, _, settings) = makeMonitor()
        setBindings(settings, VolumeKeyBinding.defaults + [VolumeKeyBinding(combo: [.option], percent: 25)])

        let option = press(monitor, .volumeUp(isRepeat: false), from: 0.5, held: [.option])
        let optionShift = press(monitor, .volumeDown(isRepeat: false), from: 0.5, held: [.option, .shift])
        let plain = press(monitor, .volumeUp(isRepeat: false), from: 0.5, held: [.shift])
        #expect(abs(Double(option ?? 0) - 0.75) < 1e-6)
        #expect(abs(Double(optionShift ?? 0) - 0.25) < 1e-6)
        #expect(abs(Double(plain ?? 0) - 0.60) < 1e-6)  // Shift alone still falls to plain
    }

    @Test("With no row for the held modifiers handleCore writes nothing and shows nothing")
    func unmatchedHeldDoesNothing() {
        let hud = FractionRecordingHUD()
        let rig = makeRig(presenter: hud)
        setBindings(rig.settingsManager, [VolumeKeyBinding(combo: [.command], percent: 5)])

        var written = 0
        var feedback = 0
        for event in [MediaKeyEvent.volumeUp(isRepeat: false), .volumeDown(isRepeat: false)] {
            rig.monitor.handleCore(
                event: event, deviceID: 1, tier: .hardware,
                deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
                setVolume: { _, _ in written += 1 }, setMute: { _, _ in written += 1 },
                playFeedback: { _ in feedback += 1 },
                held: [.shift]
            )
        }
        #expect(written == 0)
        #expect(feedback == 0)
        #expect(hud.shown.isEmpty)
    }

    @Test("A row steps in slider space on the software tier (x² taper)")
    func rowStepOnSoftwareTier() {
        let (monitor, _, _, _) = makeMonitor()
        var written: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: 1, tier: .software,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, v in written = v }, setMute: { _, _ in },
            held: [.command, .shift]
        )
        let expected = Float(0.7171 * 0.7171)  // slider 0.7071 + 0.01, snapped to the 1e-4 grid
        #expect(abs((written ?? 0) - expected) < 1e-5)
    }

    @Test("Row steps clamp at 1.0 and 0.0", arguments: VolumeKeyBinding.defaults.map(\.combo))
    func rowClamps(held: VolumeKeyCombo) {
        let (monitor, _, _, _) = makeMonitor()
        #expect(press(monitor, .volumeUp(isRepeat: false), from: 1.0, held: held) == 1.0)
        #expect(press(monitor, .volumeDown(isRepeat: false), from: 0.0, held: held) == 0.0)
    }

    @Test("A step bigger than the headroom lands on 1.0, a smaller one does not")
    func rowClampBoundary() {
        let (monitor, _, _, _) = makeMonitor()
        #expect(press(monitor, .volumeUp(isRepeat: false), from: 0.96) == 1.0)
        #expect(press(monitor, .volumeUp(isRepeat: false), from: 0.96, held: [.command]) == 1.0)
        let fine = press(monitor, .volumeUp(isRepeat: false), from: 0.96, held: [.command, .shift])
        #expect(abs(Double(fine ?? 0) - 0.97) < 1e-6)
    }

    @Test("100 Command+Shift presses walk the slider from 0 to 1 in 1% steps")
    func hundredFinePressesReachOne() {
        let (monitor, _, _, _) = makeMonitor()
        var volume: Float = 0
        for _ in 0..<100 {
            volume = press(monitor, .volumeUp(isRepeat: false), from: volume, held: [.command, .shift]) ?? volume
        }
        #expect(abs(volume - 1.0) < 1e-4)
    }

    @Test("Mute behaviour is the same under every row", arguments: VolumeKeyBinding.defaults.map(\.combo))
    func muteSemanticsUnderRow(held: VolumeKeyCombo) {
        let (monitor, _, _, _) = makeMonitor()

        // volumeUp while muted unmutes.
        var upMute: Bool?
        _ = press(monitor, .volumeUp(isRepeat: false), from: 0.5, held: held, currentMute: true) { upMute = $0 }
        #expect(upMute == false)

        // volumeDown to audible while muted unmutes.
        var downMute: Bool?
        _ = press(monitor, .volumeDown(isRepeat: false), from: 0.5, held: held, currentMute: true) { downMute = $0 }
        #expect(downMute == false)

        // volumeDown that reaches silence while unmuted auto-mutes (a step of at least the current volume).
        var silentMute: Bool?
        let nearSilence = Float(VolumeKeyBinding.percentRange.lowerBound) / 100  // 0.01: every row's step reaches 0
        _ = press(monitor, .volumeDown(isRepeat: false), from: nearSilence, held: held) { silentMute = $0 }
        #expect(silentMute == true)

        // volumeUp while unmuted never touches mute.
        var untouched = 0
        _ = press(monitor, .volumeUp(isRepeat: false), from: 0.5, held: held) { _ in untouched += 1 }
        #expect(untouched == 0)
    }

    @Test("muteToggle ignores the held modifiers and leaves the volume alone", arguments: [
        VolumeKeyCombo([]), VolumeKeyCombo([.command]), VolumeKeyCombo([.option, .control]),
    ])
    func muteToggleUnderModifiers(held: VolumeKeyCombo) {
        let (monitor, _, _, _) = makeMonitor()
        var writtenMute: Bool?
        var setVolumeCalls = 0
        monitor.handleCore(
            event: .muteToggle, deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, _ in setVolumeCalls += 1 }, setMute: { _, m in writtenMute = m },
            held: held
        )
        #expect(writtenMute == true)
        #expect(setVolumeCalls == 0)
    }

    @Test("playFeedback still fires once per press under every row", arguments: VolumeKeyBinding.defaults.map(\.combo))
    func feedbackUnderRow(held: VolumeKeyCombo) {
        let (monitor, _, _, _) = makeMonitor()
        var feedbackCalls = 0
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, _ in }, setMute: { _, _ in },
            playFeedback: { _ in feedbackCalls += 1 },
            held: held
        )
        #expect(feedbackCalls == 1)
    }

    // MARK: - Float residue and the device floor

    @Test("An 11% step walking down from 1.0 ends muted at exactly 0, never 0 while unmuted")
    func elevenPercentWalkDownEndsMutedAtZero() {
        let (monitor, _, _, settings) = makeMonitor()
        setDefaultRowPercent(settings, 0, to: 11)

        // Model the device: hardware/DDC floor sub-1% scalars to 0 exactly as DeviceVolumeMonitor does.
        var volume: Float = 1.0
        var muted = false
        var presses = 0
        while presses < 12 && !muted {
            monitor.handleCore(
                event: .volumeDown(isRepeat: false), deviceID: 1, tier: .hardware,
                deviceName: "Test Device", currentVolume: volume, currentMute: muted,
                setVolume: { _, v in volume = DeviceVolumeMonitor.storedVolume(v, tier: .hardware) },
                setMute: { _, m in muted = m }
            )
            presses += 1
            #expect(!(volume == 0 && !muted), "press \(presses) left the device at 0 and unmuted")
        }
        // 1.0 - 9 * 0.11 = 0.01 on press 9, then 0 on press 10.
        #expect(presses == 10)
        #expect(muted)
        #expect(volume == 0)
    }

    // MARK: - Real handle() path (default device, tier and volume read from the volume provider)

    @Test("handle() applies each default row's step to the default device", arguments: [
        (held: VolumeKeyCombo([]),                 up: 0.60, down: 0.40),
        (held: VolumeKeyCombo([.command]),         up: 0.55, down: 0.45),
        (held: VolumeKeyCombo([.command, .shift]), up: 0.51, down: 0.49),
    ])
    func handleAppliesRowStep(_ c: (held: VolumeKeyCombo, up: Double, down: Double)) {
        let rig = makeRig()
        rig.volume.defaultDeviceID = 7
        rig.volume.defaultTier = .hardware
        rig.volume.volumes[7] = 0.5

        rig.monitor.handle(.volumeUp(isRepeat: false), held: c.held)
        #expect(rig.volume.setVolumeCalls.count == 1)
        #expect(rig.volume.setVolumeCalls.last?.deviceID == 7)
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - c.up) < 1e-6)

        rig.volume.volumes[7] = 0.5
        rig.monitor.handle(.volumeDown(isRepeat: false), held: c.held)
        #expect(rig.volume.setVolumeCalls.count == 2)
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - c.down) < 1e-6)
    }

    @Test("handle() without a held combo uses the plain step, and edited percents flow through")
    func handleDefaultsToPlainAndHonoursSettings() {
        let rig = makeRig()
        rig.volume.defaultDeviceID = 7
        rig.volume.volumes[7] = 0.5

        rig.monitor.handle(.volumeUp(isRepeat: false))
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - 0.60) < 1e-6)

        setDefaultRowPercent(rig.settingsManager, 1, to: 3)
        rig.volume.volumes[7] = 0.5
        rig.monitor.handle(.volumeUp(isRepeat: false), held: [.command])
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - 0.53) < 1e-6)
    }

    @Test("handle() with no valid default device writes nothing")
    func handleIgnoresInvalidDevice() {
        let rig = makeRig()
        rig.volume.defaultDeviceID = AudioDeviceID.unknown
        rig.monitor.handle(.volumeUp(isRepeat: false), held: [.command, .shift])
        #expect(rig.volume.setVolumeCalls.isEmpty)
    }

    @Test("The HUD fraction equals the popup slider for the gain written, under every row and tier",
          arguments: VolumeKeyBinding.defaults.map(\.combo))
    func hudFractionMatchesPopupSliderForWrittenGain(held: VolumeKeyCombo) {
        for tier in [VolumeControlTier.hardware, .ddc, .software] {
            let hud = FractionRecordingHUD()
            let rig = makeRig(presenter: hud)
            for event in [MediaKeyEvent.volumeUp(isRepeat: false), .volumeDown(isRepeat: false)] {
                var written: Float?
                rig.monitor.handleCore(
                    event: event, deviceID: 1, tier: tier,
                    deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
                    setVolume: { _, v in written = v }, setMute: { _, _ in },
                    held: held
                )
                let shown = hud.shown.last?.sliderFraction
                let popup = DeviceRow.volumeToSlider(written ?? -1, backend: tier)
                #expect(abs((shown ?? -1) - popup) < 1e-5, "\(held.label) \(tier) \(event): HUD \(shown ?? -1) vs popup \(popup)")
            }
        }
    }

    // MARK: - Routing a decoded key: swallow, pass through, or record

    /// A rig whose default device is a hardware-tier device at 50%, with a recording HUD.
    private func makeRoutingRig() -> (
        monitor: MediaKeyMonitor, hud: FractionRecordingHUD, settings: SettingsManager,
        volume: MockDeviceVolumeProviding, recorder: VolumeKeyRecorder, beeps: BeepCounter
    ) {
        let hud = FractionRecordingHUD()
        let rig = makeRig(presenter: hud)
        rig.volume.defaultDeviceID = 7
        rig.volume.defaultTier = .hardware
        rig.volume.volumes[7] = 0.5
        return (rig.monitor, hud, rig.settingsManager, rig.volume, rig.recorder, rig.beeps)
    }

    private func rowID(_ settings: SettingsManager, _ index: Int) -> UUID {
        settings.appSettings.volumeKeyBindings[index].id
    }

    @Test("A volume key with a matching row is swallowed and steps by that row", arguments: [
        (held: VolumeKeyCombo([]),                          up: 0.60),
        (held: VolumeKeyCombo([.shift]),                    up: 0.60),
        (held: VolumeKeyCombo([.option]),                   up: 0.60),
        (held: VolumeKeyCombo([.control]),                  up: 0.60),
        (held: VolumeKeyCombo([.command]),                  up: 0.55),
        (held: VolumeKeyCombo([.command, .option]),         up: 0.55),
        (held: VolumeKeyCombo([.command, .shift]),          up: 0.51),
        (held: VolumeKeyCombo([.command, .shift, .option]), up: 0.51),
    ])
    func matchedVolumeKeyIsSwallowed(_ c: (held: VolumeKeyCombo, up: Double)) {
        let rig = makeRoutingRig()
        let swallowed = rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: c.held)
        #expect(swallowed)
        #expect(rig.volume.setVolumeCalls.count == 1)
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - c.up) < 1e-6)
        #expect(rig.hud.swallowed == 1)
        #expect(rig.hud.passedThrough == 0)
    }

    @Test("A volume key with no matching row is not swallowed and changes nothing", arguments: [
        VolumeKeyCombo([]), VolumeKeyCombo([.shift]), VolumeKeyCombo([.control, .shift]),
    ])
    func unmatchedVolumeKeyPassesThrough(held: VolumeKeyCombo) {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [
            VolumeKeyBinding(combo: [.command], percent: 5),
            VolumeKeyBinding(combo: [.option], percent: 2),
        ])
        for event in [MediaKeyEvent.volumeUp(isRepeat: false), .volumeDown(isRepeat: false), .volumeUp(isRepeat: true)] {
            #expect(rig.monitor.processMediaKey(event, held: held) == false)
        }
        #expect(rig.volume.setVolumeCalls.isEmpty)
        #expect(rig.volume.setMuteCalls.isEmpty)
        #expect(rig.hud.shown.isEmpty)
        #expect(rig.hud.swallowed == 0)
        #expect(rig.hud.passedThrough == 3)  // each one tells the HUD that macOS will act on its own
    }

    @Test("A key left to macOS clears the swallow stamp, so macOS's own volume change is not read as a leak")
    func passThroughClearsSuppressionStamp() {
        let status = MediaKeyStatus()
        let popup = PopupVisibilityService()
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: status, popupVisibility: popup)
        hud.fullscreenOverride = true  // show() returns early, so no panel is ordered front
        let rig = makeRig(hudController: hud)
        rig.volume.defaultDeviceID = 7
        rig.volume.volumes[7] = 0.5
        setBindings(rig.settingsManager, [
            VolumeKeyBinding(combo: [.command], percent: 5),
        ])

        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: [.command]))  // swallowed
        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: []) == false)  // left to macOS

        hud.handleSettingsChangedNotification()  // macOS reports the volume change it made itself
        #expect(status.suppressionDegraded == false)
    }

    @Test("A swallowed key whose native HUD still fires does mark suppression degraded")
    func swallowStillMarksSuppressionDegraded() {
        let status = MediaKeyStatus()
        let popup = PopupVisibilityService()
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: status, popupVisibility: popup)
        hud.fullscreenOverride = true  // show() returns early, so no panel is ordered front
        let rig = makeRig(hudController: hud)
        rig.volume.defaultDeviceID = 7
        rig.volume.volumes[7] = 0.5

        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: []))

        hud.handleSettingsChangedNotification()
        #expect(status.suppressionDegraded)
    }

    @Test("Once the plain row is rebound a bare press passes through, and the new combo steps")
    func reboundPlainRowPassesBareKeyThrough() {
        let rig = makeRoutingRig()
        var bindings = VolumeKeyBinding.defaults
        bindings[0].combo = [.option]
        setBindings(rig.settings, bindings)

        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: []) == false)
        #expect(rig.volume.setVolumeCalls.isEmpty)
        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: [.option]))
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - 0.60) < 1e-6)
    }

    @Test("Mute is swallowed and applied whatever rows exist")
    func muteIsAlwaysHandled() {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [VolumeKeyBinding(combo: [.command], percent: 5)])
        #expect(rig.monitor.processMediaKey(.muteToggle, held: []))
        #expect(rig.volume.setMuteCalls.count == 1)
        #expect(rig.volume.setMuteCalls.last?.muted == true)
        #expect(rig.volume.setVolumeCalls.isEmpty)
    }

    // MARK: Recording a keybind

    @Test("A volume key pressed while recording captures the held modifiers and changes no volume", arguments: [
        MediaKeyEvent.volumeUp(isRepeat: false), MediaKeyEvent.volumeDown(isRepeat: false),
    ])
    func recordingCapturesHeldModifiers(event: MediaKeyEvent) {
        let rig = makeRoutingRig()
        rig.recorder.begin(rowID(rig.settings, 1))

        let swallowed = rig.monitor.processMediaKey(event, held: [.option, .shift])

        #expect(swallowed)
        #expect(rig.volume.setVolumeCalls.isEmpty)
        #expect(rig.volume.setMuteCalls.isEmpty)
        #expect(rig.hud.shown.isEmpty)
        #expect(rig.hud.swallowed == 1)
        #expect(rig.recorder.recordingID == nil)
        #expect(rig.settings.appSettings.volumeKeyBindings.rows == [
            VolumeKeyRow([], 10), VolumeKeyRow([.option, .shift], 5), VolumeKeyRow([.command, .shift], 1),
        ])
        #expect(rig.beeps.count == 0)
    }

    @Test("The recorded combo steps by that row from the next press on")
    func recordedComboWorksAtOnce() {
        let rig = makeRoutingRig()
        rig.recorder.begin(rowID(rig.settings, 1))
        _ = rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: [.control])

        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: [.control]))
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - 0.55) < 1e-6)  // the row's 5%
        #expect(rig.volume.setVolumeCalls.count == 1)
    }

    @Test("A combo another row already uses is rejected with a beep, and the row keeps its combo")
    func recordingDuplicateIsRejected() {
        let rig = makeRoutingRig()
        rig.recorder.begin(rowID(rig.settings, 1))

        let swallowed = rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: [])  // the plain row's combo

        #expect(swallowed)
        #expect(rig.volume.setVolumeCalls.isEmpty)
        #expect(rig.beeps.count == 1)
        #expect(rig.recorder.recordingID == nil)
        #expect(rig.settings.appSettings.volumeKeyBindings.rows == defaultVolumeKeyRows)
    }

    @Test("Re-recording a row's own combo succeeds quietly and changes nothing")
    func recordingOwnComboIsNoOp() {
        let rig = makeRoutingRig()
        rig.recorder.begin(rowID(rig.settings, 1))

        let swallowed = rig.monitor.processMediaKey(.volumeDown(isRepeat: false), held: [.command])

        #expect(swallowed)
        #expect(rig.volume.setVolumeCalls.isEmpty)
        #expect(rig.beeps.count == 0)
        #expect(rig.recorder.recordingID == nil)
        #expect(rig.settings.appSettings.volumeKeyBindings.rows == defaultVolumeKeyRows)
    }

    @Test("Mute is not a capture: it works as usual and recording stays on")
    func muteDuringRecordingIsNotCaptured() {
        let rig = makeRoutingRig()
        let id = rowID(rig.settings, 1)
        rig.recorder.begin(id)

        #expect(rig.monitor.processMediaKey(.muteToggle, held: [.option]))

        #expect(rig.volume.setMuteCalls.count == 1)
        #expect(rig.recorder.recordingID == id)
        #expect(rig.settings.appSettings.volumeKeyBindings.rows == defaultVolumeKeyRows)
    }

    @Test("Repeats of the press that ended recording are swallowed; the next fresh press steps normally")
    func repeatsOfCapturingPressDoNotStepVolume() {
        let rig = makeRoutingRig()
        rig.recorder.begin(rowID(rig.settings, 1))
        _ = rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: [.option])

        // The key is still down: macOS keeps sending repeats, and the row now matches them.
        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: true), held: [.option]))
        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: true), held: [.option]))
        #expect(rig.volume.setVolumeCalls.isEmpty)

        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: [.option]))
        #expect(rig.volume.setVolumeCalls.count == 1)
        // A repeat of that new press is a real step again.
        rig.volume.volumes[7] = 0.5
        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: true), held: [.option]))
        #expect(rig.volume.setVolumeCalls.count == 2)
    }

    // MARK: Key repeat follows its press

    private let freshUp = MediaKeyEvent.volumeUp(isRepeat: false)
    private let freshDown = MediaKeyEvent.volumeDown(isRepeat: false)
    private let repeatUp = MediaKeyEvent.volumeUp(isRepeat: true)
    private let repeatDown = MediaKeyEvent.volumeDown(isRepeat: true)

    private func lastVolume(_ volume: MockDeviceVolumeProviding) -> Double {
        Double(volume.setVolumeCalls.last?.volume ?? -1)
    }

    @Test("With no plain row, releasing the modifier mid-hold keeps the repeats on the pressed row")
    func repeatsOutliveTheReleasedModifier() {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [
            VolumeKeyBinding(combo: [.command], percent: 5),
            VolumeKeyBinding(combo: [.option], percent: 2),
        ])

        #expect(rig.monitor.processMediaKey(freshDown, held: [.command]))
        #expect(abs(lastVolume(rig.volume) - 0.45) < 1e-6)

        // Command is up, the key is still down: nothing fits [] now, but the press was Deci's.
        #expect(rig.monitor.processMediaKey(repeatDown, held: []))
        #expect(abs(lastVolume(rig.volume) - 0.40) < 1e-6)
        #expect(rig.monitor.processMediaKey(repeatDown, held: []))
        #expect(abs(lastVolume(rig.volume) - 0.35) < 1e-6)

        #expect(rig.volume.setVolumeCalls.count == 3)
        #expect(rig.hud.swallowed == 3)
        #expect(rig.hud.passedThrough == 0)
    }

    @Test("A repeat of a handled press re-matches the modifiers held now")
    func repeatRematchesCurrentModifiers() {
        let rig = makeRoutingRig()

        #expect(rig.monitor.processMediaKey(freshUp, held: [.command]))
        #expect(abs(lastVolume(rig.volume) - 0.55) < 1e-6)

        #expect(rig.monitor.processMediaKey(repeatUp, held: [.command, .shift]))  // Shift added: the 1% row
        #expect(abs(lastVolume(rig.volume) - 0.56) < 1e-6)

        #expect(rig.monitor.processMediaKey(repeatUp, held: []))  // everything released: the plain row
        #expect(abs(lastVolume(rig.volume) - 0.66) < 1e-6)

        #expect(rig.monitor.processMediaKey(repeatUp, held: [.command]))
        #expect(abs(lastVolume(rig.volume) - 0.71) < 1e-6)
    }

    @Test("A repeat of a press left to macOS stays with macOS, whatever is held by then")
    func repeatOfPassedThroughPressPassesThrough() {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [VolumeKeyBinding(combo: [.command], percent: 5)])

        #expect(rig.monitor.processMediaKey(freshUp, held: [.shift]) == false)
        #expect(rig.monitor.processMediaKey(repeatUp, held: [.shift]) == false)
        // Command goes down mid-hold: a row fits now, but macOS already owns this hold.
        #expect(rig.monitor.processMediaKey(repeatUp, held: [.command]) == false)

        #expect(rig.volume.setVolumeCalls.isEmpty)
        #expect(rig.hud.swallowed == 0)
        #expect(rig.hud.passedThrough == 3)
    }

    @Test("The route is kept per key: up and down do not share it")
    func routesArePerKey() {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [VolumeKeyBinding(combo: [.command], percent: 5)])

        #expect(rig.monitor.processMediaKey(freshUp, held: [.command]))
        #expect(rig.monitor.processMediaKey(freshDown, held: []) == false)

        #expect(rig.monitor.processMediaKey(repeatUp, held: []))  // up was handled
        #expect(abs(lastVolume(rig.volume) - 0.60) < 1e-6)  // 0.55 from the press, 0.60 from the repeat
        #expect(rig.monitor.processMediaKey(repeatDown, held: [.command]) == false)  // down was not
        #expect(rig.volume.setVolumeCalls.count == 2)
    }

    @Test("A fresh press replaces the route of the one before it")
    func freshPressReplacesRoute() {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [VolumeKeyBinding(combo: [.command], percent: 5)])

        #expect(rig.monitor.processMediaKey(freshUp, held: []) == false)
        #expect(rig.monitor.processMediaKey(freshUp, held: [.command]))
        #expect(rig.monitor.processMediaKey(repeatUp, held: []))  // follows the handled press now
        #expect(rig.volume.setVolumeCalls.count == 2)

        #expect(rig.monitor.processMediaKey(freshUp, held: []) == false)
        #expect(rig.monitor.processMediaKey(repeatUp, held: [.command]) == false)  // and the passed-through one
        #expect(rig.volume.setVolumeCalls.count == 2)
    }

    @Test("A repeat whose press was never seen is matched on the modifiers held, as before")
    func repeatWithoutSeenPressMatchesHeld() {
        let rig = makeRoutingRig()
        #expect(rig.monitor.processMediaKey(repeatUp, held: []))
        #expect(abs(lastVolume(rig.volume) - 0.60) < 1e-6)

        let other = makeRoutingRig()
        setBindings(other.settings, [VolumeKeyBinding(combo: [.command], percent: 5)])
        #expect(other.monitor.processMediaKey(repeatDown, held: []) == false)
        #expect(other.monitor.processMediaKey(repeatDown, held: [.command]))
        #expect(abs(lastVolume(other.volume) - 0.45) < 1e-6)
    }

    @Test("If the pressed row is gone and nothing fits, the repeat is left to macOS")
    func repeatPassesThroughWhenItsRowWasRemoved() {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [
            VolumeKeyBinding(combo: [.command], percent: 5),
            VolumeKeyBinding(combo: [.option], percent: 2),
        ])
        #expect(rig.monitor.processMediaKey(freshUp, held: [.command]))

        setBindings(rig.settings, [VolumeKeyBinding(combo: [.option], percent: 2)])  // the Command row is removed

        #expect(rig.monitor.processMediaKey(repeatUp, held: []) == false)
        #expect(rig.monitor.processMediaKey(repeatUp, held: [.option]))  // a row that fits the held modifiers still works
        #expect(abs(lastVolume(rig.volume) - 0.57) < 1e-6)
    }

    @Test("Mute in between does not disturb the route of a held volume key")
    func muteLeavesRoutesAlone() {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [VolumeKeyBinding(combo: [.command], percent: 5)])
        #expect(rig.monitor.processMediaKey(freshUp, held: [.command]))

        #expect(rig.monitor.processMediaKey(.muteToggle, held: []))

        #expect(rig.monitor.processMediaKey(repeatUp, held: []))
        #expect(rig.volume.setVolumeCalls.count == 2)
    }

    @Test("Stopping the tap forgets the routes: a repeat after a restart is matched on its own modifiers")
    func stopForgetsRoutes() {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [VolumeKeyBinding(combo: [.command], percent: 5)])
        #expect(rig.monitor.processMediaKey(freshUp, held: [.command]))

        rig.monitor.stop()

        #expect(rig.monitor.processMediaKey(repeatUp, held: []) == false)
        #expect(rig.monitor.processMediaKey(repeatUp, held: [.command]))
    }

    @Test("Re-enabling the tap forgets the routes, since presses may have been missed while it was off")
    func tapReEnableForgetsRoutes() {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [VolumeKeyBinding(combo: [.command], percent: 5)])
        #expect(rig.monitor.processMediaKey(freshUp, held: [.command]))

        rig.monitor.handleTapDisabled()

        #expect(rig.monitor.processMediaKey(repeatUp, held: []) == false)
    }

    @Test("Repeats of the press that ended recording stay swallowed after its modifier is released")
    func recorderAbsorptionSurvivesReleasedModifier() {
        let rig = makeRoutingRig()
        setBindings(rig.settings, [
            VolumeKeyBinding(combo: [.command], percent: 5),
            VolumeKeyBinding(combo: [.shift], percent: 3),
        ])
        rig.recorder.begin(rowID(rig.settings, 1))
        #expect(rig.monitor.processMediaKey(freshUp, held: [.option]))  // captured: the row is Option now

        #expect(rig.monitor.processMediaKey(repeatUp, held: []))
        #expect(rig.monitor.processMediaKey(repeatUp, held: [.option]))
        #expect(rig.volume.setVolumeCalls.isEmpty)

        // The next fresh press is a real step, and its repeats follow it past the released modifier.
        #expect(rig.monitor.processMediaKey(freshUp, held: [.option]))
        #expect(rig.monitor.processMediaKey(repeatUp, held: []))
        #expect(rig.volume.setVolumeCalls.count == 2)
        #expect(abs(lastVolume(rig.volume) - 0.56) < 1e-6)  // two steps of the row's 3%
    }

    @Test("Not recording, a press is handled as before and nothing is captured")
    func idleRecorderCapturesNothing() {
        let rig = makeRoutingRig()
        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: [.option]))
        #expect(rig.volume.setVolumeCalls.count == 1)
        #expect(rig.settings.appSettings.volumeKeyBindings.rows == defaultVolumeKeyRows)
        #expect(rig.beeps.count == 0)
    }
}
