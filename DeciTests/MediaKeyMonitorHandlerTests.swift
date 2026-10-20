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

/// Records what the monitor asks the HUD to show, so a test can compare it with the popup slider.
@MainActor
final class FractionRecordingHUD: MediaKeyHUDPresenting {
    private(set) var shown: [(sliderFraction: Double, mute: Bool, deviceName: String)] = []
    func show(sliderFraction: Double, mute: Bool, deviceName: String) {
        shown.append((sliderFraction, mute, deviceName))
    }
    func swallowObserved() {}
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
    /// the real `handle(_:chord:)` path (default device, tier and volume come from the mock).
    private func makeRig(
        hudController: HUDWindowController? = nil,
        popupVisible: Bool = false,
        presenter: MediaKeyHUDPresenting? = nil
    ) -> (monitor: MediaKeyMonitor, hud: HUDWindowController, popup: PopupVisibilityService, settingsManager: SettingsManager, volume: MockDeviceVolumeProviding) {
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

        let monitor = MediaKeyMonitor(
            decoder: StubMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: MockAccessibilityTrustProviding(isTrusted: true),
            hudController: presenter ?? hud,
            popupVisibility: popup,
            mediaKeyStatus: mediaKeyStatus
        )
        return (monitor, hud, popup, settings, mockVolume)
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

    // MARK: - Modifier chords (F11/F12, Cmd, Cmd+Shift)

    /// Runs one hardware-tier press at `currentVolume` and returns the volume written (nil if none).
    private func press(
        _ monitor: MediaKeyMonitor,
        _ event: MediaKeyEvent,
        from currentVolume: Float,
        chord: VolumeStepChord,
        currentMute: Bool = false,
        setMute: @escaping (Bool) -> Void = { _ in }
    ) -> Float? {
        var written: Float?
        monitor.handleCore(
            event: event, deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: currentVolume, currentMute: currentMute,
            setVolume: { _, v in written = v }, setMute: { _, m in setMute(m) },
            chord: chord
        )
        return written
    }

    @Test("Each chord steps the slider by its own percent", arguments: [
        (chord: VolumeStepChord.plain,        step: 0.10),
        (chord: VolumeStepChord.command,      step: 0.05),
        (chord: VolumeStepChord.commandShift, step: 0.01),
    ])
    func chordStepsUpAndDown(_ c: (chord: VolumeStepChord, step: Double)) {
        let (monitor, _, _, _) = makeMonitor()
        let up = press(monitor, .volumeUp(isRepeat: false), from: 0.5, chord: c.chord)
        let down = press(monitor, .volumeDown(isRepeat: false), from: 0.5, chord: c.chord)
        #expect(abs(Double(up ?? 0) - (0.5 + c.step)) < 1e-6)
        #expect(abs(Double(down ?? 0) - (0.5 - c.step)) < 1e-6)
    }

    @Test("Without a chord argument handleCore uses the plain step")
    func chordDefaultsToPlain() {
        let (monitor, _, _, settings) = makeMonitor()
        var appSettings = settings.appSettings
        appSettings.volumeStepPercent = 20
        appSettings.volumeStepCommandPercent = 3
        settings.updateAppSettings(appSettings)
        var written: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, v in written = v }, setMute: { _, _ in }
        )
        #expect(abs(Double(written ?? 0) - 0.7) < 1e-6)
    }

    @Test("Edited percents are honoured per chord")
    func customPercentsHonoured() {
        let (monitor, _, _, settings) = makeMonitor()
        var appSettings = settings.appSettings
        appSettings.volumeStepPercent = 20
        appSettings.volumeStepCommandPercent = 3
        appSettings.volumeStepCommandShiftPercent = 2
        settings.updateAppSettings(appSettings)

        let plain = press(monitor, .volumeUp(isRepeat: false), from: 0.5, chord: .plain)
        let command = press(monitor, .volumeUp(isRepeat: false), from: 0.5, chord: .command)
        let commandShift = press(monitor, .volumeDown(isRepeat: false), from: 0.5, chord: .commandShift)
        #expect(abs(Double(plain ?? 0) - 0.70) < 1e-6)
        #expect(abs(Double(command ?? 0) - 0.53) < 1e-6)
        #expect(abs(Double(commandShift ?? 0) - 0.48) < 1e-6)
    }

    @Test("A chord steps in slider space on the software tier (x² taper)")
    func chordStepOnSoftwareTier() {
        let (monitor, _, _, _) = makeMonitor()
        var written: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: 1, tier: .software,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, v in written = v }, setMute: { _, _ in },
            chord: .commandShift
        )
        let expected = Float(0.7171 * 0.7171)  // slider 0.7071 + 0.01, snapped to the 1e-4 grid
        #expect(abs((written ?? 0) - expected) < 1e-5)
    }

    @Test("Chord steps clamp at 1.0 and 0.0", arguments: VolumeStepChord.allCases)
    func chordClamps(chord: VolumeStepChord) {
        let (monitor, _, _, _) = makeMonitor()
        #expect(press(monitor, .volumeUp(isRepeat: false), from: 1.0, chord: chord) == 1.0)
        #expect(press(monitor, .volumeDown(isRepeat: false), from: 0.0, chord: chord) == 0.0)
    }

    @Test("A step bigger than the headroom lands on 1.0, a smaller one does not")
    func chordClampBoundary() {
        let (monitor, _, _, _) = makeMonitor()
        #expect(press(monitor, .volumeUp(isRepeat: false), from: 0.96, chord: .plain) == 1.0)
        #expect(press(monitor, .volumeUp(isRepeat: false), from: 0.96, chord: .command) == 1.0)
        let fine = press(monitor, .volumeUp(isRepeat: false), from: 0.96, chord: .commandShift)
        #expect(abs(Double(fine ?? 0) - 0.97) < 1e-6)
    }

    @Test("100 Command+Shift presses walk the slider from 0 to 1 in 1% steps")
    func hundredFinePressesReachOne() {
        let (monitor, _, _, _) = makeMonitor()
        var volume: Float = 0
        for _ in 0..<100 {
            volume = press(monitor, .volumeUp(isRepeat: false), from: volume, chord: .commandShift) ?? volume
        }
        #expect(abs(volume - 1.0) < 1e-4)
    }

    @Test("Mute behaviour is the same under every chord", arguments: VolumeStepChord.allCases)
    func muteSemanticsUnderChord(chord: VolumeStepChord) {
        let (monitor, _, _, _) = makeMonitor()

        // volumeUp while muted unmutes.
        var upMute: Bool?
        _ = press(monitor, .volumeUp(isRepeat: false), from: 0.5, chord: chord, currentMute: true) { upMute = $0 }
        #expect(upMute == false)

        // volumeDown to audible while muted unmutes.
        var downMute: Bool?
        _ = press(monitor, .volumeDown(isRepeat: false), from: 0.5, chord: chord, currentMute: true) { downMute = $0 }
        #expect(downMute == false)

        // volumeDown that reaches silence while unmuted auto-mutes (a step of at least the current volume).
        var silentMute: Bool?
        let nearSilence = Float(VolumeStepChord.percentRange.lowerBound) / 100  // 0.01: every chord's step reaches 0
        _ = press(monitor, .volumeDown(isRepeat: false), from: nearSilence, chord: chord) { silentMute = $0 }
        #expect(silentMute == true)

        // volumeUp while unmuted never touches mute.
        var untouched = 0
        _ = press(monitor, .volumeUp(isRepeat: false), from: 0.5, chord: chord) { _ in untouched += 1 }
        #expect(untouched == 0)
    }

    @Test("muteToggle ignores the chord and leaves the volume alone", arguments: VolumeStepChord.allCases)
    func muteToggleUnderChord(chord: VolumeStepChord) {
        let (monitor, _, _, _) = makeMonitor()
        var writtenMute: Bool?
        var setVolumeCalls = 0
        monitor.handleCore(
            event: .muteToggle, deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, _ in setVolumeCalls += 1 }, setMute: { _, m in writtenMute = m },
            chord: chord
        )
        #expect(writtenMute == true)
        #expect(setVolumeCalls == 0)
    }

    @Test("playFeedback still fires once per chord press", arguments: VolumeStepChord.allCases)
    func feedbackUnderChord(chord: VolumeStepChord) {
        let (monitor, _, _, _) = makeMonitor()
        var feedbackCalls = 0
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, _ in }, setMute: { _, _ in },
            playFeedback: { _ in feedbackCalls += 1 },
            chord: chord
        )
        #expect(feedbackCalls == 1)
    }

    // MARK: - Float residue and the device floor

    @Test("An 11% step walking down from 1.0 ends muted at exactly 0, never 0 while unmuted")
    func elevenPercentWalkDownEndsMutedAtZero() {
        let (monitor, _, _, settings) = makeMonitor()
        var appSettings = settings.appSettings
        appSettings.volumeStepPercent = 11
        settings.updateAppSettings(appSettings)

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

    @Test("handle() applies the Command+Shift step (1%) to the default device", arguments: [
        (chord: VolumeStepChord.plain,        up: 0.60, down: 0.40),
        (chord: VolumeStepChord.command,      up: 0.55, down: 0.45),
        (chord: VolumeStepChord.commandShift, up: 0.51, down: 0.49),
    ])
    func handleAppliesChordStep(_ c: (chord: VolumeStepChord, up: Double, down: Double)) {
        let rig = makeRig()
        rig.volume.defaultDeviceID = 7
        rig.volume.defaultTier = .hardware
        rig.volume.volumes[7] = 0.5

        rig.monitor.handle(.volumeUp(isRepeat: false), chord: c.chord)
        #expect(rig.volume.setVolumeCalls.count == 1)
        #expect(rig.volume.setVolumeCalls.last?.deviceID == 7)
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - c.up) < 1e-6)

        rig.volume.volumes[7] = 0.5
        rig.monitor.handle(.volumeDown(isRepeat: false), chord: c.chord)
        #expect(rig.volume.setVolumeCalls.count == 2)
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - c.down) < 1e-6)
    }

    @Test("handle() without a chord uses the plain step, and edited percents flow through")
    func handleDefaultsToPlainAndHonoursSettings() {
        let rig = makeRig()
        rig.volume.defaultDeviceID = 7
        rig.volume.volumes[7] = 0.5

        rig.monitor.handle(.volumeUp(isRepeat: false))
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - 0.60) < 1e-6)

        var appSettings = rig.settingsManager.appSettings
        appSettings.volumeStepCommandPercent = 3
        rig.settingsManager.updateAppSettings(appSettings)
        rig.volume.volumes[7] = 0.5
        rig.monitor.handle(.volumeUp(isRepeat: false), chord: .command)
        #expect(abs(Double(rig.volume.setVolumeCalls.last?.volume ?? 0) - 0.53) < 1e-6)
    }

    @Test("handle() with no valid default device writes nothing")
    func handleIgnoresInvalidDevice() {
        let rig = makeRig()
        rig.volume.defaultDeviceID = AudioDeviceID.unknown
        rig.monitor.handle(.volumeUp(isRepeat: false), chord: .commandShift)
        #expect(rig.volume.setVolumeCalls.isEmpty)
    }

    @Test("The HUD fraction equals the popup slider for the gain written, under every chord and tier", arguments: [
        VolumeStepChord.plain, .command, .commandShift,
    ])
    func hudFractionMatchesPopupSliderForWrittenGain(chord: VolumeStepChord) {
        for tier in [VolumeControlTier.hardware, .ddc, .software] {
            let hud = FractionRecordingHUD()
            let rig = makeRig(presenter: hud)
            for event in [MediaKeyEvent.volumeUp(isRepeat: false), .volumeDown(isRepeat: false)] {
                var written: Float?
                rig.monitor.handleCore(
                    event: event, deviceID: 1, tier: tier,
                    deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
                    setVolume: { _, v in written = v }, setMute: { _, _ in },
                    chord: chord
                )
                let shown = hud.shown.last?.sliderFraction
                let popup = DeviceRow.volumeToSlider(written ?? -1, backend: tier)
                #expect(abs((shown ?? -1) - popup) < 1e-5, "\(chord) \(tier) \(event): HUD \(shown ?? -1) vs popup \(popup)")
            }
        }
    }
}
