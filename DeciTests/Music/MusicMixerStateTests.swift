// DeciTests/Music/MusicMixerStateTests.swift
// The YouTube Music mixer row's model: volume, mute, boost, EQ and output device, persisted under one settings key,
// pushed to the DSP chain and the playback engine, and kept right when devices come and go. No audio runs here.

import AudioToolbox
import Foundation
import Testing
@testable import Deci

@MainActor
final class FakeMusicMixerEnvironment: MusicMixerEnvironment {
    var outputDevices: [AudioDevice] = []
    var defaultOutputDeviceUID: String?
    /// Active AutoEQ profile per device UID, as the engine's lookup would answer it.
    var autoEQProfiles: [String: AutoEQProfile] = [:]
    /// Profiles that only arrive through the async path (not cached yet).
    var slowAutoEQProfiles: [String: AutoEQProfile] = [:]
    var deviceVolumes: [String: Float] = [:]
    var loudnessCompensationEnabled = false
    var loudnessEqualizationEnabled = false
    var autoEQPreampEnabled = true
    private(set) var autoEQLookups: [String] = []

    func autoEQProfile(forDeviceUID uid: String) -> AutoEQProfile? {
        autoEQLookups.append(uid)
        return autoEQProfiles[uid]
    }

    func resolveAutoEQProfile(forDeviceUID uid: String) async -> AutoEQProfile? {
        slowAutoEQProfiles[uid] ?? autoEQProfiles[uid]
    }

    func deviceVolume(forDeviceUID uid: String) -> Float? { deviceVolumes[uid] }

    static func device(_ uid: String, id: UInt32 = 1) -> AudioDevice {
        AudioDevice(id: AudioDeviceID(id), uid: uid, name: "Device \(uid)", icon: nil, supportsAutoEQ: true)
    }
}

@MainActor
@Suite("MusicMixerState")
struct MusicMixerStateTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deci-mixer-\(UUID().uuidString)")

    private func makeSettings() -> SettingsManager { SettingsManager(directory: directory) }

    private func makeState(
        settings: SettingsManager? = nil,
        environment: FakeMusicMixerEnvironment = FakeMusicMixerEnvironment()
    ) -> (state: MusicMixerState, settings: SettingsManager, environment: FakeMusicMixerEnvironment) {
        let settings = settings ?? makeSettings()
        return (MusicMixerState(settings: settings, environment: environment), settings, environment)
    }

    private func profile(_ id: String) -> AutoEQProfile {
        AutoEQProfile(
            id: id, name: id, source: .bundled, preampDB: -3,
            filters: [AutoEQFilter(type: .peaking, frequency: 1_000, gainDB: 3, q: 1)]
        )
    }

    // MARK: - Defaults and the chain

    @Test("a fresh state is full volume, unmuted, x1, flat, following the default output")
    func defaults() {
        let (state, _, _) = makeState()
        #expect(state.volume == 1)
        #expect(!state.isMuted)
        #expect(state.boost == .x1)
        #expect(state.eqSettings == .flat)
        #expect(state.selectedDeviceUID == nil)
        #expect(state.isFollowingDefault)
        #expect(state.chain.targetGain == 1)
        #expect(state.chain.eqSettings == .flat)
    }

    @Test("the settings key is the one the plan names")
    func settingsKey() {
        #expect(MusicMixerState.settingsKey == "com.abraham.Deci.music")
    }

    @Test("volume times boost is the chain's gain, and mute takes it to zero without forgetting the volume")
    func gainReachesTheChain() {
        let (state, _, _) = makeState()
        state.setVolume(0.5)
        #expect(state.chain.targetGain == 0.5)
        state.setBoost(.x2)
        #expect(state.chain.targetGain == 1.0)
        state.setBoost(.x4)
        #expect(state.chain.targetGain == 2.0)
        state.setMuted(true)
        #expect(state.chain.targetGain == 0)
        #expect(state.volume == 0.5, "mute keeps the volume")
        state.setMuted(false)
        #expect(state.chain.targetGain == 2.0)
    }

    @Test("volume is clamped to 0...1 and a non-finite volume is ignored")
    func volumeIsContained() {
        let (state, _, _) = makeState()
        state.setVolume(0.3)
        state.setVolume(.nan)
        #expect(state.volume == 0.3)
        state.setVolume(.infinity)
        #expect(state.volume == 0.3)
        state.setVolume(7)
        #expect(state.volume == 1)
        state.setVolume(-2)
        #expect(state.volume == 0)
    }

    @Test("EQ settings reach the chain")
    func eqReachesTheChain() {
        let (state, _, _) = makeState()
        var eq = EQSettings()
        eq.bandGains[3] = 6
        state.setEQ(eq)
        #expect(state.eqSettings == eq)
        #expect(state.chain.eqSettings == eq)
    }

    @Test("the level is the chain's peak since the last reading")
    func levelReadsThePeak() {
        let (state, _, _) = makeState()
        #expect(state.sampleLevel() == 0)
        let lease = MusicRenderLease(chain: state.chain, sampleRate: 48_000, maxFrames: 1_024)
        let buffers = TestBufferList(channels: MusicTestSignal.constant(0.5, frames: 256), layout: .interleaved)
        lease.render(buffers.list, frames: 256)
        #expect(abs(state.sampleLevel() - 0.5) < 1e-3)
        #expect(state.sampleLevel() == 0)
    }

    @Test("the spectrum level is the chain's own, so the row's meter and the player column never starve each other")
    func spectrumLevelIsSeparate() {
        let (state, _, _) = makeState()
        state.setVolume(0.5)
        #expect(state.sampleSpectrumLevel() == 0)
        let lease = MusicRenderLease(chain: state.chain, sampleRate: 48_000, maxFrames: 1_024)
        let buffers = TestBufferList(channels: MusicTestSignal.constant(0.5, frames: 256), layout: .interleaved)
        lease.render(buffers.list, frames: 256)

        #expect(abs(state.sampleSpectrumLevel() - 0.5) < 1e-4, "before the volume, so 0.5 and not 0.25")
        #expect(state.sampleSpectrumLevel() == 0)
        #expect(state.sampleLevel() > 0, "reading the spectrum level did not take the meter's")
    }

    // MARK: - Persistence

    @Test("everything round-trips through SettingsManager under the music key, with no schema change")
    func persistenceRoundTrip() {
        let (state, settings, _) = makeState(environment: {
            let environment = FakeMusicMixerEnvironment()
            environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a")]
            return environment
        }())
        var eq = EQSettings()
        eq.bandGains[7] = -4
        state.setVolume(0.4)
        state.setMuted(true)
        state.setBoost(.x3)
        state.setEQ(eq)
        state.selectDevice(uid: "uid-a")
        settings.flushSync()

        let key = MusicMixerState.settingsKey
        #expect(settings.getVolume(for: key) == 0.4)
        #expect(settings.getMute(for: key) == true)
        #expect(settings.getBoost(for: key) == .x3)
        #expect(settings.getEQSettings(for: key) == eq)
        #expect(settings.getDeviceRouting(for: key) == "uid-a")

        let reopened = MusicMixerState(settings: SettingsManager(directory: directory), environment: FakeMusicMixerEnvironment())
        #expect(reopened.volume == 0.4)
        #expect(reopened.isMuted)
        #expect(reopened.boost == .x3)
        #expect(reopened.eqSettings == eq)
        #expect(reopened.selectedDeviceUID == "uid-a")
        #expect(reopened.chain.targetGain == 0, "a persisted mute is silent from the first sample")
    }

    @Test("a persisted low volume starts at that volume, never at full for a moment")
    func persistedVolumeSnaps() {
        let settings = makeSettings()
        settings.setVolume(for: MusicMixerState.settingsKey, to: 0.2)
        let (state, _, _) = makeState(settings: settings)
        let lease = MusicRenderLease(chain: state.chain, sampleRate: 48_000, maxFrames: 1_024)
        let buffers = TestBufferList(channels: MusicTestSignal.constant(1, frames: 8), layout: .interleaved)
        lease.render(buffers.list, frames: 8)
        #expect(abs(buffers.samples(channel: 0)[0] - 0.2) < 1e-4)
    }

    @Test("following the default output removes the stored device")
    func followDefaultClearsTheRouting() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a")]
        let (state, settings, _) = makeState(environment: environment)
        state.selectDevice(uid: "uid-a")
        #expect(settings.getDeviceRouting(for: MusicMixerState.settingsKey) == "uid-a")
        state.followDefaultDevice()
        #expect(settings.getDeviceRouting(for: MusicMixerState.settingsKey) == nil)
        #expect(state.selectedDeviceUID == nil)
        #expect(state.isFollowingDefault)
    }

    // MARK: - Output device

    @Test("choosing a device tells the engine, and following the default tells it nil")
    func deviceReachesTheEngine() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a"), FakeMusicMixerEnvironment.device("uid-b", id: 2)]
        let (state, _, _) = makeState(environment: environment)
        let engine = FakePlaybackEngine()
        state.attach(engine: engine)

        state.selectDevice(uid: "uid-b")
        #expect(engine.outputDevices.last == .some("uid-b"))
        state.followDefaultDevice()
        #expect(engine.outputDevices.last == .some(nil))
    }

    @Test("attaching an engine applies the stored device at once, and works before the service existed")
    func attachAppliesTheStoredDevice() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a")]
        let (state, _, _) = makeState(environment: environment)
        state.setVolume(0.6)           // no engine yet: must not crash or lose the value
        state.selectDevice(uid: "uid-a")
        #expect(state.volume == 0.6)

        let engine = FakePlaybackEngine()
        state.attach(engine: engine)
        #expect(engine.outputDevices == [.some("uid-a")])
    }

    @Test("devices that appear between the mixer's creation and the attach still reach the engine, with their AutoEQ and loudness")
    func devicesAppearBeforeAttach() {
        // The mixer is built before the engine's device monitors have run: the list is empty, so the saved device does
        // not resolve and AutoEQ and loudness have nothing to go on.
        let settings = makeSettings()
        settings.setDeviceRouting(for: MusicMixerState.settingsKey, deviceUID: "uid-a")
        let environment = FakeMusicMixerEnvironment()
        environment.loudnessCompensationEnabled = true
        let (state, _, _) = makeState(settings: settings, environment: environment)
        #expect(state.outputDeviceUID == nil)
        #expect(state.chain.autoEQProfile == nil)
        #expect(state.chain.loudnessCompensationVolume == 1)

        // The monitors start, and no device event follows for devices that were already there.
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a")]
        environment.autoEQProfiles = ["uid-a": profile("for-a")]
        environment.deviceVolumes = ["uid-a": 0.5]

        let engine = FakePlaybackEngine()
        state.attach(engine: engine)

        #expect(engine.outputDevices == [.some("uid-a")], "the engine must get the saved device, not the stale nil")
        #expect(state.outputDeviceUID == "uid-a")
        #expect(state.chain.autoEQProfile?.id == "for-a")
        #expect(abs(state.chain.loudnessCompensationVolume - 0.5) < 1e-6)
    }

    @Test("devices that appear after the attach are corrected by the engine's device notification")
    func devicesAppearAfterAttach() {
        let settings = makeSettings()
        settings.setDeviceRouting(for: MusicMixerState.settingsKey, deviceUID: "uid-a")
        let environment = FakeMusicMixerEnvironment()
        environment.loudnessCompensationEnabled = true
        let (state, _, _) = makeState(settings: settings, environment: environment)
        let engine = FakePlaybackEngine()
        state.attach(engine: engine)
        #expect(engine.outputDevices == [nil], "nothing is connected yet")

        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a")]
        environment.autoEQProfiles = ["uid-a": profile("for-a")]
        environment.deviceVolumes = ["uid-a": 0.5]
        state.outputDevicesChanged()

        #expect(engine.outputDevices == [nil, .some("uid-a")])
        #expect(state.chain.autoEQProfile?.id == "for-a")
        #expect(abs(state.chain.loudnessCompensationVolume - 0.5) < 1e-6)
    }

    @Test("a stored device that is not connected is not handed to the engine, and returns when it reappears")
    func missingDeviceFallsBackToDefault() {
        let settings = makeSettings()
        settings.setDeviceRouting(for: MusicMixerState.settingsKey, deviceUID: "uid-gone")
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a")]
        environment.defaultOutputDeviceUID = "uid-a"
        let (state, _, _) = makeState(settings: settings, environment: environment)
        let engine = FakePlaybackEngine()
        state.attach(engine: engine)

        #expect(state.selectedDeviceUID == "uid-gone", "the choice is the user's intent and stays")
        #expect(state.outputDeviceUID == nil)
        #expect(engine.outputDevices == [nil], "an unknown UID would play to nothing")
        #expect(state.effectiveDeviceUID == "uid-a")

        environment.outputDevices.append(FakeMusicMixerEnvironment.device("uid-gone", id: 3))
        state.outputDevicesChanged()
        #expect(state.outputDeviceUID == "uid-gone")
        #expect(engine.outputDevices.last == .some("uid-gone"))

        environment.outputDevices.removeAll { $0.uid == "uid-gone" }
        state.outputDevicesChanged()
        #expect(engine.outputDevices.last == .some(nil), "unplugging falls back to the default output")
    }

    @Test("selecting a device that is not in the list is refused")
    func selectingAnUnknownDeviceIsRefused() {
        let (state, settings, _) = makeState()
        state.selectDevice(uid: "uid-nowhere")
        #expect(state.selectedDeviceUID == nil)
        #expect(settings.getDeviceRouting(for: MusicMixerState.settingsKey) == nil)
    }

    @Test("an unchanged device is not pushed to the engine again")
    func deviceIsNotRepushed() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a")]
        let (state, _, _) = makeState(environment: environment)
        let engine = FakePlaybackEngine()
        state.attach(engine: engine)
        state.outputDevicesChanged()
        state.outputDevicesChanged()
        state.setVolume(0.5)
        #expect(engine.outputDevices.count == 1)
    }

    // MARK: - Level without the tap

    @Test("attaching an engine hands it the stored volume and mute, for when the tap is not on the item")
    func attachHandsOverTheLevel() {
        let settings = makeSettings()
        settings.setVolume(for: MusicMixerState.settingsKey, to: 0.4)
        settings.setMute(for: MusicMixerState.settingsKey, to: true)
        let (state, _, _) = makeState(settings: settings)
        let engine = FakePlaybackEngine()
        state.attach(engine: engine)
        #expect(engine.fallbackLevels.last == .init(volume: 0.4, muted: true))
    }

    @Test("volume and mute reach the engine as the player's own level, and boost is left out")
    func levelReachesTheEngine() {
        let (state, _, _) = makeState()
        let engine = FakePlaybackEngine()
        state.attach(engine: engine)

        state.setVolume(0.5)
        #expect(engine.fallbackLevels.last == .init(volume: 0.5, muted: false))
        state.setBoost(.x4)
        #expect(engine.fallbackLevels.last == .init(volume: 0.5, muted: false), "the player cannot boost: it plays the volume")
        state.setMuted(true)
        #expect(engine.fallbackLevels.last == .init(volume: 0.5, muted: true), "mute keeps the volume")
        state.setMuted(false)
        #expect(engine.fallbackLevels.last == .init(volume: 0.5, muted: false))
    }

    @Test("a settings reset puts the player's level back to full and unmuted")
    func resetReachesTheEnginesLevel() {
        let (state, settings, _) = makeState()
        let engine = FakePlaybackEngine()
        state.attach(engine: engine)
        state.setVolume(0.3)
        state.setMuted(true)

        settings.resetAllSettings()
        state.settingsDidReset()
        #expect(engine.fallbackLevels.last == .init(volume: 1, muted: false))
    }

    // MARK: - AutoEQ

    @Test("AutoEQ follows the explicit device, not the default")
    func autoEQUsesTheExplicitDevice() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a"), FakeMusicMixerEnvironment.device("uid-b", id: 2)]
        environment.defaultOutputDeviceUID = "uid-a"
        environment.autoEQProfiles = ["uid-a": profile("for-a"), "uid-b": profile("for-b")]
        let (state, _, _) = makeState(environment: environment)

        state.selectDevice(uid: "uid-b")
        #expect(state.chain.autoEQProfile?.id == "for-b")
        state.defaultDeviceChanged(uid: "uid-a")
        #expect(state.chain.autoEQProfile?.id == "for-b", "a default change does not matter to an explicit device")
    }

    @Test("AutoEQ follows the default device while the row follows the default, including when it changes")
    func autoEQFollowsTheDefault() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a"), FakeMusicMixerEnvironment.device("uid-b", id: 2)]
        environment.defaultOutputDeviceUID = "uid-a"
        environment.autoEQProfiles = ["uid-a": profile("for-a")]
        let (state, _, _) = makeState(environment: environment)
        #expect(state.chain.autoEQProfile?.id == "for-a")

        // The engine hands over the UID in the notification: its own cached default may lag behind it.
        state.defaultDeviceChanged(uid: "uid-b")
        #expect(state.effectiveDeviceUID == "uid-b")
        #expect(state.chain.autoEQProfile == nil, "uid-b has no profile")

        environment.autoEQProfiles["uid-b"] = profile("for-b")
        state.defaultDeviceChanged(uid: "uid-b")
        #expect(state.chain.autoEQProfile?.id == "for-b")
    }

    @Test("an AutoEQ change for the device in use refreshes the chain, and one for another device does nothing")
    func autoEQSelectionChange() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a"), FakeMusicMixerEnvironment.device("uid-b", id: 2)]
        environment.defaultOutputDeviceUID = "uid-a"
        let (state, _, _) = makeState(environment: environment)
        #expect(state.chain.autoEQProfile == nil)

        environment.autoEQProfiles["uid-a"] = profile("for-a")
        state.autoEQSelectionChanged(deviceUID: "uid-b")
        #expect(state.chain.autoEQProfile == nil, "uid-b is not the device in use")
        state.autoEQSelectionChanged(deviceUID: "uid-a")
        #expect(state.chain.autoEQProfile?.id == "for-a")

        environment.autoEQProfiles["uid-a"] = nil
        state.autoEQSelectionChanged(deviceUID: "uid-a")
        #expect(state.chain.autoEQProfile == nil)
    }

    @Test("a profile that is not cached yet is applied when it resolves, unless the device moved on meanwhile")
    func autoEQResolvesLate() async {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a"), FakeMusicMixerEnvironment.device("uid-b", id: 2)]
        environment.defaultOutputDeviceUID = "uid-a"
        environment.slowAutoEQProfiles = ["uid-a": profile("late-a")]
        let (state, _, _) = makeState(environment: environment)

        let arrived = await waitUntil(timeout: .seconds(5)) { state.chain.autoEQProfile?.id == "late-a" }
        #expect(arrived)

        environment.slowAutoEQProfiles = ["uid-b": profile("late-b")]
        state.defaultDeviceChanged(uid: "uid-b")
        state.defaultDeviceChanged(uid: "uid-a")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(state.chain.autoEQProfile?.id != "late-b", "a late answer for a device no longer in use is dropped")
    }

    @Test("the AutoEQ preamp toggle reaches the chain")
    func preampToggle() {
        let (state, _, environment) = makeState()
        #expect(state.chain.autoEQPreampEnabled)
        state.autoEQPreampChanged(enabled: false)
        #expect(!state.chain.autoEQPreampEnabled)
        state.autoEQPreampChanged(enabled: true)
        #expect(state.chain.autoEQPreampEnabled)

        environment.autoEQPreampEnabled = false
        let other = MusicMixerState(settings: makeSettings(), environment: environment)
        #expect(!other.chain.autoEQPreampEnabled, "the engine's current setting is read at creation")
    }

    // MARK: - Loudness

    @Test("loudness compensation hears device volume times the row's volume, without boost")
    func loudnessCompensationInput() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a"), FakeMusicMixerEnvironment.device("uid-b", id: 2)]
        environment.defaultOutputDeviceUID = "uid-a"
        environment.deviceVolumes = ["uid-a": 0.5, "uid-b": 1.0]
        let (state, _, _) = makeState(environment: environment)

        state.loudnessCompensationChanged(enabled: true)
        #expect(state.chain.loudnessCompensationEnabled)
        #expect(abs(state.chain.loudnessCompensationVolume - 0.5) < 1e-6)

        state.setVolume(0.4)
        state.setBoost(.x4)
        #expect(abs(state.chain.loudnessCompensationVolume - 0.2) < 1e-6)

        state.deviceVolumeChanged(deviceUID: "uid-a", volume: 0.8)
        #expect(abs(state.chain.loudnessCompensationVolume - 0.32) < 1e-6)

        environment.deviceVolumes["uid-a"] = 0.8
        state.deviceVolumeChanged(deviceUID: "uid-b", volume: 0.1)
        #expect(abs(state.chain.loudnessCompensationVolume - 0.32) < 1e-6, "another device's volume is not ours")

        state.loudnessCompensationChanged(enabled: false)
        #expect(!state.chain.loudnessCompensationEnabled)
    }

    @Test("loudness equalization reaches the chain, and both toggles are read from the engine at creation")
    func loudnessEqualization() {
        let environment = FakeMusicMixerEnvironment()
        environment.loudnessEqualizationEnabled = true
        environment.loudnessCompensationEnabled = true
        let (state, _, _) = makeState(environment: environment)
        #expect(state.chain.loudnessEqualizationEnabled)
        #expect(state.chain.loudnessCompensationEnabled)

        state.loudnessEqualizationChanged(enabled: false)
        #expect(!state.chain.loudnessEqualizationEnabled)
    }

    @Test("a default-device change updates the loudness input when following the default")
    func defaultChangeUpdatesLoudness() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a"), FakeMusicMixerEnvironment.device("uid-b", id: 2)]
        environment.defaultOutputDeviceUID = "uid-a"
        environment.deviceVolumes = ["uid-a": 0.5, "uid-b": 0.25]
        let (state, _, _) = makeState(environment: environment)
        state.loudnessCompensationChanged(enabled: true)
        #expect(abs(state.chain.loudnessCompensationVolume - 0.5) < 1e-6)
        state.defaultDeviceChanged(uid: "uid-b")
        #expect(abs(state.chain.loudnessCompensationVolume - 0.25) < 1e-6)
    }

    // MARK: - Reset

    @Test("a settings reset returns everything to defaults in memory without writing the defaults back")
    func settingsReset() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a")]
        let (state, settings, _) = makeState(environment: environment)
        let engine = FakePlaybackEngine()
        state.attach(engine: engine)
        var eq = EQSettings()
        eq.bandGains[1] = 5
        state.setVolume(0.3)
        state.setMuted(true)
        state.setBoost(.x2)
        state.setEQ(eq)
        state.selectDevice(uid: "uid-a")
        state.autoEQPreampChanged(enabled: false)

        settings.resetAllSettings()
        state.settingsDidReset()

        #expect(state.volume == 1)
        #expect(!state.isMuted)
        #expect(state.boost == .x1)
        #expect(state.eqSettings == .flat)
        #expect(state.selectedDeviceUID == nil)
        #expect(state.chain.targetGain == 1)
        #expect(state.chain.eqSettings == .flat)
        #expect(engine.outputDevices.last == .some(nil))
        #expect(state.chain.autoEQPreampEnabled, "the engine's reset preamp setting is read back")

        let key = MusicMixerState.settingsKey
        #expect(settings.getVolume(for: key) == nil, "the reset must not recreate the key")
        #expect(settings.getMute(for: key) == nil)
        #expect(settings.getBoost(for: key) == nil)
        #expect(settings.getDeviceRouting(for: key) == nil)
    }

    // MARK: - The player's output device

    @Test("a chosen device that disappears is flagged missing and the music falls back to the default")
    func chosenDeviceDisappears() {
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("uid-a", id: 1), FakeMusicMixerEnvironment.device("uid-b", id: 2)]
        environment.defaultOutputDeviceUID = "uid-a"
        let (state, _, _) = makeState(environment: environment)
        state.selectDevice(uid: "uid-b")
        #expect(state.outputDeviceUID == "uid-b")
        #expect(!state.isChosenDeviceMissing)
        #expect(state.effectiveDeviceUID == "uid-b")

        environment.outputDevices.removeAll { $0.uid == "uid-b" }
        state.outputDevicesChanged()
        #expect(state.selectedDeviceUID == "uid-b", "the choice stays the user's intent")
        #expect(state.outputDeviceUID == nil, "so the menu checks the default, not the missing device")
        #expect(state.isChosenDeviceMissing)
        #expect(state.effectiveDeviceUID == "uid-a")

        environment.outputDevices.append(FakeMusicMixerEnvironment.device("uid-b", id: 2))
        state.outputDevicesChanged()
        #expect(state.outputDeviceUID == "uid-b")
        #expect(!state.isChosenDeviceMissing)

        state.followDefaultDevice()
        #expect(!state.isChosenDeviceMissing, "following the default is never a missing device")
    }
}
