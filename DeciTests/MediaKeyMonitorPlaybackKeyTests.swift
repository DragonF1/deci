// DeciTests/MediaKeyMonitorPlaybackKeyTests.swift
// The monitor and the play/pause, next and previous keys: with media key control on, a press is swallowed from its
// fresh down to its key-up (down, auto-repeat, up) so macOS never launches Apple Music from it, and the handler hears
// those events on the next turn of the main queue. A repeat or up whose down was not swallowed passes through. With the
// setting off every phase passes through untouched. Volume and mute keep their own path and never reach the handler,
// and playback keys never reach the volume HUD. Driven through the decoded-event entry points; no CGEvent is made or
// posted and no tap is installed.

import AudioToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Deci

/// Records what the monitor hands the playback side.
@MainActor
private final class RecordingPlaybackHandler: PlaybackKeyHandling {
    private(set) var events: [(key: PlaybackKey, phase: PlaybackKeyPhase)] = []
    func handle(_ key: PlaybackKey, phase: PlaybackKeyPhase) { events.append((key, phase)) }
}

private nonisolated let playbackPhases: [PlaybackKeyPhase] = [.down, .autoRepeat, .up]

@MainActor
@Suite("MediaKeyMonitor: playback keys")
struct MediaKeyMonitorPlaybackKeyTests {
    private struct Rig {
        let monitor: MediaKeyMonitor
        let hud: FractionRecordingHUD
        let handler: RecordingPlaybackHandler
        let settings: SettingsManager
        let accessibility: MockAccessibilityTrustProviding

        func setEnabled(_ enabled: Bool) {
            var appSettings = settings.appSettings
            appSettings.mediaKeyControlEnabled = enabled
            settings.updateAppSettings(appSettings)
        }
    }

    private func makeRig(enabled: Bool = true, wireHandler: Bool = true) -> Rig {
        let accessibility = MockAccessibilityTrustProviding(isTrusted: true)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        var appSettings = settings.appSettings
        appSettings.mediaKeyControlEnabled = enabled
        settings.updateAppSettings(appSettings)

        let deviceMonitor = MockAudioDeviceMonitor()
        let engine = AudioEngine(
            permission: AudioRecordingPermission(),
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: deviceMonitor,
            deviceVolumeMonitor: MockDeviceVolumeProviding(deviceMonitor: deviceMonitor),
            startMonitorsAutomatically: false
        )
        let hud = FractionRecordingHUD()
        let monitor = MediaKeyMonitor(
            decoder: IOKitMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: accessibility,
            hudController: hud,
            popupVisibility: PopupVisibilityService(),
            mediaKeyStatus: MediaKeyStatus(),
            volumeKeyRecorder: VolumeKeyRecorder(settings: settings)
        )
        let handler = RecordingPlaybackHandler()
        if wireHandler { monitor.playbackKeyHandler = handler }
        return Rig(monitor: monitor, hud: hud, handler: handler, settings: settings, accessibility: accessibility)
    }

    /// What the keyboard's HID layer puts in `data1` for a key and state (0x0A down, 0x0B up).
    private func data1(keyType: Int, state: Int, isRepeat: Bool = false) -> Int {
        (keyType << 16) | (state << 8) | (isRepeat ? 1 : 0)
    }

    /// Waits for what the monitor put on the main queue: this block is behind it, and the queue runs in order.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func raw(_ rig: Rig, _ keyType: Int, _ phase: PlaybackKeyPhase) -> Bool {
        let (state, isRepeat) = switch phase {
        case .down: (0x0A, false)
        case .autoRepeat: (0x0A, true)
        case .up: (0x0B, false)
        }
        return rig.monitor.processSystemDefined(subtype: 8, data1: data1(keyType: keyType, state: state, isRepeat: isRepeat), held: [])
    }

    // MARK: - Decoded events

    @Test("A normal press is swallowed in every phase, and the handler hears all of them in order")
    func normalPressSwallowed() async {
        let rig = makeRig()
        for key in [PlaybackKey.playPause, .next, .previous] {
            #expect(rig.monitor.processMediaKey(.playback(key, .down), held: []))
            #expect(rig.monitor.processMediaKey(.playback(key, .autoRepeat), held: []))
            #expect(rig.monitor.processMediaKey(.playback(key, .autoRepeat), held: []))
            #expect(rig.monitor.processMediaKey(.playback(key, .up), held: []))
        }
        await drainMainQueue()
        #expect(rig.handler.events.map(\.key) == [PlaybackKey.playPause, .next, .previous].flatMap { Array(repeating: $0, count: 4) })
        let oneHold: [PlaybackKeyPhase] = [.down, .autoRepeat, .autoRepeat, .up]
        #expect(rig.handler.events.map(\.phase) == oneHold + oneHold + oneHold)
    }

    @Test("A repeat or a key-up whose down was not swallowed passes through, and the handler never hears it", arguments: [PlaybackKeyPhase.autoRepeat, .up])
    func unpairedPhasePassesThrough(phase: PlaybackKeyPhase) async {
        let rig = makeRig()
        for key in [PlaybackKey.playPause, .next, .previous] {
            #expect(rig.monitor.processMediaKey(.playback(key, phase), held: []) == false)
        }
        await drainMainQueue()
        #expect(rig.handler.events.isEmpty)
    }

    @Test("A key-up ends the press: a stray repeat or key-up after it passes through")
    func upEndsThePress() async {
        let rig = makeRig()
        #expect(rig.monitor.processMediaKey(.playback(.next, .down), held: []))
        #expect(rig.monitor.processMediaKey(.playback(.next, .up), held: []))
        #expect(rig.monitor.processMediaKey(.playback(.next, .autoRepeat), held: []) == false)
        #expect(rig.monitor.processMediaKey(.playback(.next, .up), held: []) == false)
        await drainMainQueue()
        #expect(rig.handler.events.map(\.phase) == [.down, .up])
    }

    @Test("Each key is paired on its own: another key's down does not cover this key's up")
    func pairingIsPerKey() {
        let rig = makeRig()
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .down), held: []))
        #expect(rig.monitor.processMediaKey(.playback(.next, .up), held: []) == false)
        #expect(rig.monitor.processMediaKey(.playback(.next, .autoRepeat), held: []) == false)
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .up), held: []))
    }

    @Test("A second down before any up is a new press: swallowed and handled")
    func secondDownWithoutUp() async {
        let rig = makeRig()
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .down), held: []))
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .down), held: []))
        await drainMainQueue()
        #expect(rig.handler.events.map(\.phase) == [.down, .down])
    }

    @Test("The handler runs on a later turn of the main queue, never inside the call that decides the swallow")
    func handlerRunsLater() async {
        let rig = makeRig()
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .down), held: []))
        #expect(rig.handler.events.isEmpty)
        await drainMainQueue()
        #expect(rig.handler.events.count == 1)
    }

    @Test("Quick presses reach the handler in the order they were made")
    func pressesInOrder() async {
        let rig = makeRig()
        let sequence: [PlaybackKey] = [.next, .next, .previous, .playPause, .next]
        for key in sequence {
            #expect(rig.monitor.processMediaKey(.playback(key, .down), held: []))
            #expect(rig.monitor.processMediaKey(.playback(key, .up), held: []))
        }
        await drainMainQueue()
        #expect(rig.handler.events.filter { $0.phase == .down }.map(\.key) == sequence)
    }

    @Test("Playback keys never touch the volume HUD path")
    func hudUntouched() {
        let rig = makeRig()
        for phase in playbackPhases {
            _ = rig.monitor.processMediaKey(.playback(.playPause, phase), held: [])
        }
        #expect(rig.hud.swallowed == 0)
        #expect(rig.hud.passedThrough == 0)
        #expect(rig.hud.shown.isEmpty)
    }

    @Test("Playback keys are swallowed even when no handler is wired")
    func swallowedWithoutHandler() async {
        let rig = makeRig(wireHandler: false)
        #expect(rig.monitor.processMediaKey(.playback(.next, .down), held: []))
        #expect(rig.monitor.processMediaKey(.playback(.next, .up), held: []))
        await drainMainQueue()
    }

    @Test("Playback keys ignore held modifiers")
    func modifiersIgnored() async {
        let rig = makeRig()
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .down), held: [.command, .shift]))
        await drainMainQueue()
        #expect(rig.handler.events.count == 1)
    }

    @Test("Mute still goes through the volume path and never reaches the playback handler")
    func muteUnchanged() async {
        let rig = makeRig()
        #expect(rig.monitor.processMediaKey(.muteToggle, held: []))
        await drainMainQueue()
        #expect(rig.hud.swallowed == 1)
        #expect(rig.handler.events.isEmpty)
    }

    @Test("A volume key no row fits is still handed back to macOS and never reaches the playback handler")
    func volumeUnchanged() async {
        let rig = makeRig()
        // The only row names Command, so a press with nothing held fits no row and is left to macOS.
        var appSettings = rig.settings.appSettings
        appSettings.volumeKeyBindings = [VolumeKeyBinding(combo: [.command], percent: 5)]
        rig.settings.updateAppSettings(appSettings)
        #expect(rig.monitor.processMediaKey(.volumeUp(isRepeat: false), held: []) == false)
        await drainMainQueue()
        #expect(rig.hud.passedThrough == 1)
        #expect(rig.handler.events.isEmpty)
    }

    // MARK: - From the raw event, with the setting

    @Test("Raw play/pause, next and previous presses reach the handler with their phases while the setting is on")
    func rawEvents() async {
        let rig = makeRig()
        let cases: [(keyType: Int, key: PlaybackKey)] = [(16, .playPause), (17, .next), (18, .previous), (19, .next), (20, .previous)]
        for (keyType, key) in cases {
            #expect(raw(rig, keyType, .down))
            #expect(raw(rig, keyType, .autoRepeat))
            #expect(raw(rig, keyType, .up))
            await drainMainQueue()
            let last = rig.handler.events.suffix(3)
            #expect(last.map(\.key) == [key, key, key])
            #expect(last.map(\.phase) == [.down, .autoRepeat, .up])
        }
    }

    @Test("With the setting off, playback keys pass through and the handler hears nothing")
    func settingOff() async {
        let rig = makeRig(enabled: false)
        for phase in [0x0A, 0x0B] {
            for keyType in 16...20 {
                #expect(rig.monitor.processSystemDefined(subtype: 8, data1: data1(keyType: keyType, state: phase), held: []) == false)
            }
        }
        await drainMainQueue()
        #expect(rig.handler.events.isEmpty)
        #expect(rig.hud.swallowed == 0)
        #expect(rig.hud.passedThrough == 0)
    }

    @Test("Turning the setting on mid-hold: the key-up of a press that began while it was off passes through")
    func settingTurnedOnMidHold() async {
        let rig = makeRig(enabled: false)
        #expect(raw(rig, 16, .down) == false)
        rig.setEnabled(true)
        #expect(raw(rig, 16, .autoRepeat) == false)
        #expect(raw(rig, 16, .up) == false)
        await drainMainQueue()
        #expect(rig.handler.events.isEmpty)

        // The next press is a normal one.
        #expect(raw(rig, 16, .down))
        #expect(raw(rig, 16, .up))
        await drainMainQueue()
        #expect(rig.handler.events.map(\.phase) == [.down, .up])
    }

    @Test("Turning the setting off mid-hold passes the rest of the hold through, and leaves nothing behind for the next one")
    func settingTurnedOffMidHold() async {
        let rig = makeRig()
        #expect(raw(rig, 16, .down))
        rig.setEnabled(false)
        #expect(raw(rig, 16, .autoRepeat) == false)
        #expect(raw(rig, 16, .up) == false)

        // Back on: a key-up with no swallowed down is not covered by the press from before.
        rig.setEnabled(true)
        #expect(raw(rig, 16, .up) == false)
        await drainMainQueue()
        #expect(rig.handler.events.map(\.phase) == [.down])
    }

    @Test("Stopping the monitor forgets the held keys")
    func stopForgetsHeldKeys() {
        let rig = makeRig()
        #expect(rig.monitor.processMediaKey(.playback(.next, .down), held: []))
        rig.monitor.stop()
        #expect(rig.monitor.processMediaKey(.playback(.next, .autoRepeat), held: []) == false)
        #expect(rig.monitor.processMediaKey(.playback(.next, .up), held: []) == false)
    }

    @Test("A tap disabled by the kernel forgets the held keys, as presses may have gone by")
    func tapDisabledForgetsHeldKeys() {
        let rig = makeRig()
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .down), held: []))
        rig.monitor.handleTapDisabled()
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .up), held: []) == false)
    }

    @Test("A second tap disable inside the watchdog window forgets the held keys too")
    func secondTapDisableForgetsHeldKeys() {
        let rig = makeRig()
        rig.monitor.handleTapDisabled()
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .down), held: []))
        rig.monitor.handleTapDisabled()
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .up), held: []) == false)
    }

    @Test("Losing Accessibility trust stops the tap and forgets the held keys")
    func accessibilityLossForgetsHeldKeys() {
        let rig = makeRig()
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .down), held: []))
        rig.accessibility.isTrustedValue = false
        rig.monitor.handleTapDisabled()
        #expect(rig.monitor.processMediaKey(.playback(.playPause, .up), held: []) == false)
    }

    @Test("Events from other subtypes pass through")
    func otherSubtypes() {
        let rig = makeRig()
        #expect(rig.monitor.processSystemDefined(subtype: 7, data1: data1(keyType: 16, state: 0x0A), held: []) == false)
        #expect(rig.monitor.processSystemDefined(subtype: 0, data1: data1(keyType: 16, state: 0x0A), held: []) == false)
        #expect(rig.handler.events.isEmpty)
    }

    @Test("Key types the monitor does not know pass through")
    func unknownKeyTypes() {
        let rig = makeRig()
        for keyType in [2, 3, 15, 21] {
            #expect(rig.monitor.processSystemDefined(subtype: 8, data1: data1(keyType: keyType, state: 0x0A), held: []) == false)
        }
        #expect(rig.handler.events.isEmpty)
    }

    @Test("Raw mute and volume events still take the volume path")
    func rawVolumeAndMute() {
        let rig = makeRig()
        #expect(rig.monitor.processSystemDefined(subtype: 8, data1: data1(keyType: 7, state: 0x0A), held: []))
        #expect(rig.hud.swallowed == 1)
        // Key-up of a volume key is still not decoded: it passes through as before.
        #expect(rig.monitor.processSystemDefined(subtype: 8, data1: data1(keyType: 0, state: 0x0B), held: []) == false)
        #expect(rig.handler.events.isEmpty)
    }
}
