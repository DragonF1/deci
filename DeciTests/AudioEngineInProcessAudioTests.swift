// DeciTests/AudioEngineInProcessAudioTests.swift
// The engine's fan-out to audio that plays inside Deci's own process (the YouTube Music player), which the Core Audio
// process taps never see. The engine names only a narrow protocol; the end-to-end cases wire a real MusicMixerState.

import Testing
import AudioToolbox
import Foundation
@testable import Deci

@MainActor
final class RecordingInProcessSink: InProcessAudioSink {
    enum Call: Equatable {
        case loudnessCompensation(Bool)
        case loudnessEqualization(Bool)
        case autoEQPreamp(Bool)
        case autoEQSelection(String)
        case deviceVolume(String, Float)
        case defaultDevice(String)
        case devicesChanged
        case reset
    }

    private(set) var calls: [Call] = []

    func loudnessCompensationChanged(enabled: Bool) { calls.append(.loudnessCompensation(enabled)) }
    func loudnessEqualizationChanged(enabled: Bool) { calls.append(.loudnessEqualization(enabled)) }
    func autoEQPreampChanged(enabled: Bool) { calls.append(.autoEQPreamp(enabled)) }
    func autoEQSelectionChanged(deviceUID: String) { calls.append(.autoEQSelection(deviceUID)) }
    func deviceVolumeChanged(deviceUID: String, volume: Float) { calls.append(.deviceVolume(deviceUID, volume)) }
    func defaultDeviceChanged(uid: String) { calls.append(.defaultDevice(uid)) }
    func outputDevicesChanged() { calls.append(.devicesChanged) }
    func settingsDidReset() { calls.append(.reset) }
}

@MainActor
@Suite("AudioEngine in-process audio fan-out")
struct AudioEngineInProcessAudioTests {

    @Test("with no sink registered every hook is a no-op")
    func noSinkIsHarmless() {
        let harness = EngineHarness()
        harness.engine.setLoudnessCompensationEnabled(true)
        harness.engine.setLoudnessEqualizationEnabled(true)
        harness.engine.setAutoEQPreampEnabled(false)
        harness.deviceVolume.onVolumeChanged?(harness.device.id, 0.3)
        harness.deviceVolume.onDefaultDeviceChanged?("uid-test")
        harness.engine.handleSettingsReset()
        #expect(harness.engine.inProcessAudio == nil)
    }

    @Test("the global toggles reach the sink")
    func globalToggles() {
        let harness = EngineHarness()
        let sink = RecordingInProcessSink()
        harness.engine.inProcessAudio = sink

        harness.engine.setLoudnessCompensationEnabled(true)
        harness.engine.setLoudnessEqualizationEnabled(true)
        harness.engine.setAutoEQPreampEnabled(false)
        harness.engine.setLoudnessCompensationEnabled(false)

        #expect(sink.calls == [
            .loudnessCompensation(true), .loudnessEqualization(true), .autoEQPreamp(false), .loudnessCompensation(false),
        ])
    }

    @Test("an AutoEQ selection or enable change for a device reaches the sink with that device")
    func autoEQSelection() {
        let harness = EngineHarness()
        let sink = RecordingInProcessSink()
        harness.engine.inProcessAudio = sink

        harness.engine.setAutoEQProfile(for: "uid-test", profileID: "some-profile")
        harness.engine.setAutoEQEnabled(for: "uid-test", enabled: false)
        harness.engine.setAutoEQProfile(for: "uid-test", profileID: nil)

        #expect(sink.calls == [.autoEQSelection("uid-test"), .autoEQSelection("uid-test"), .autoEQSelection("uid-test")])
    }

    @Test("a device volume change reaches the sink with the device's UID")
    func deviceVolume() {
        let harness = EngineHarness()
        let sink = RecordingInProcessSink()
        harness.engine.inProcessAudio = sink

        harness.deviceVolume.onVolumeChanged?(harness.device.id, 0.3)
        #expect(sink.calls == [.deviceVolume("uid-test", 0.3)])
    }

    @Test("a volume change for a device the engine does not know is not forwarded")
    func unknownDeviceVolume() {
        let harness = EngineHarness()
        let sink = RecordingInProcessSink()
        harness.engine.inProcessAudio = sink
        harness.deviceVolume.onVolumeChanged?(AudioDeviceID(4_242), 0.3)
        #expect(sink.calls.isEmpty)
    }

    @Test("a system default output change reaches the sink with the new UID")
    func defaultDeviceChange() {
        let harness = EngineHarness()
        let sink = RecordingInProcessSink()
        harness.engine.inProcessAudio = sink

        harness.deviceVolume.onDefaultDeviceChanged?("uid-other")
        #expect(sink.calls.contains(.defaultDevice("uid-other")))
    }

    @Test("a device connecting or disconnecting tells the sink the list changed")
    func deviceListChanges() {
        let harness = EngineHarness()
        let sink = RecordingInProcessSink()
        harness.engine.inProcessAudio = sink

        harness.deviceMonitor.onDeviceConnected?("uid-new", "New Device")
        harness.deviceMonitor.onDeviceDisconnected?("uid-new", "New Device")
        #expect(sink.calls.filter { $0 == .devicesChanged }.count == 2)
    }

    @Test("a settings reset reaches the sink after the settings were cleared")
    func settingsReset() {
        let harness = EngineHarness()
        let key = "com.abraham.Deci.music"
        harness.settings.setVolume(for: key, to: 0.3)
        let sink = RecordingInProcessSink()
        harness.engine.inProcessAudio = sink

        harness.engine.handleSettingsReset()
        #expect(sink.calls == [.reset])
        #expect(harness.settings.getVolume(for: key) == nil, "the music key is cleared with everything else")
    }

    @Test("the engine does not keep the sink alive")
    func sinkIsWeak() {
        let harness = EngineHarness()
        weak var weakSink: RecordingInProcessSink?
        do {
            let sink = RecordingInProcessSink()
            weakSink = sink
            harness.engine.inProcessAudio = sink
        }
        #expect(weakSink == nil)
        #expect(harness.engine.inProcessAudio == nil)
    }

    // MARK: - End to end with the real mixer state

    private func makeMixer(_ harness: EngineHarness) -> MusicMixerState {
        let mixer = MusicMixerState(settings: harness.settings, environment: EngineMusicEnvironment(engine: harness.engine))
        harness.engine.inProcessAudio = mixer
        return mixer
    }

    @Test("toggling loudness compensation in the engine reaches the music chain")
    func loudnessReachesTheChain() {
        let harness = EngineHarness()
        let mixer = makeMixer(harness)
        #expect(!mixer.chain.loudnessCompensationEnabled)

        harness.engine.setLoudnessCompensationEnabled(true)
        #expect(mixer.chain.loudnessCompensationEnabled)
        harness.engine.setLoudnessCompensationEnabled(false)
        #expect(!mixer.chain.loudnessCompensationEnabled)

        harness.engine.setLoudnessEqualizationEnabled(true)
        #expect(mixer.chain.loudnessEqualizationEnabled)
    }

    @Test("toggling the AutoEQ preamp in the engine reaches the music chain")
    func preampReachesTheChain() {
        let harness = EngineHarness()
        let mixer = makeMixer(harness)
        #expect(mixer.chain.autoEQPreampEnabled)
        harness.engine.setAutoEQPreampEnabled(false)
        #expect(!mixer.chain.autoEQPreampEnabled)
    }

    @Test("a hardware device volume change reaches the chain's loudness input through the engine")
    func deviceVolumeReachesTheChain() {
        let harness = EngineHarness()
        let mixer = makeMixer(harness)
        harness.deviceVolume.defaultDeviceUID = "uid-test"
        harness.engine.setLoudnessCompensationEnabled(true)

        harness.deviceVolume.volumes[harness.device.id] = 0.5
        harness.deviceVolume.onVolumeChanged?(harness.device.id, 0.5)
        mixer.setVolume(0.5)
        #expect(abs(mixer.chain.loudnessCompensationVolume - 0.25) < 1e-6)
    }

    @Test("the environment adapter answers from the engine: devices, default, toggles and device volume")
    func environmentAdapter() {
        let harness = EngineHarness(deviceVolumeLevel: 0.6)
        harness.deviceVolume.defaultDeviceUID = "uid-test"
        let environment = EngineMusicEnvironment(engine: harness.engine)
        #expect(environment.outputDevices.map(\.uid) == ["uid-test"])
        #expect(environment.defaultOutputDeviceUID == "uid-test")
        #expect(environment.deviceVolume(forDeviceUID: "uid-test") == 0.6)
        #expect(environment.deviceVolume(forDeviceUID: "uid-unknown") == nil)
        #expect(environment.autoEQPreampEnabled)
        #expect(!environment.loudnessCompensationEnabled)
        #expect(environment.autoEQProfile(forDeviceUID: "uid-test") == nil)
    }

    @Test("a settings reset in the engine resets the music mixer and clears its key")
    func resetReachesTheMixer() {
        let harness = EngineHarness()
        let mixer = makeMixer(harness)
        mixer.setVolume(0.3)
        mixer.setMuted(true)
        mixer.setBoost(.x2)
        let key = MusicMixerState.settingsKey
        #expect(harness.settings.getVolume(for: key) == 0.3)

        harness.engine.handleSettingsReset()
        #expect(mixer.volume == 1)
        #expect(!mixer.isMuted)
        #expect(mixer.boost == .x1)
        #expect(mixer.chain.targetGain == 1)
        #expect(harness.settings.getVolume(for: key) == nil)
        #expect(harness.settings.getMute(for: key) == nil)
        #expect(harness.settings.getBoost(for: key) == nil)
    }
}
