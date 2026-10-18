// Deci/Music/MusicMixerState.swift
import Foundation
import Observation

/// What the music mixer needs to know about the rest of the app: the output devices, the system default, the AutoEQ
/// profiles and the engine's global audio switches. A protocol so the model can be tested without a real engine.
@MainActor
protocol MusicMixerEnvironment: AnyObject {
    var outputDevices: [AudioDevice] { get }
    /// UID of the system default output device.
    var defaultOutputDeviceUID: String? { get }
    /// The AutoEQ profile in effect for `uid`, from memory. nil when there is none or it is not cached yet.
    func autoEQProfile(forDeviceUID uid: String) -> AutoEQProfile?
    /// Same, but loads the profile when it is not cached yet.
    func resolveAutoEQProfile(forDeviceUID uid: String) async -> AutoEQProfile?
    /// The hardware or software output volume (0...1) of the device, nil when unknown.
    func deviceVolume(forDeviceUID uid: String) -> Float?
    var loudnessCompensationEnabled: Bool { get }
    var loudnessEqualizationEnabled: Bool { get }
    var autoEQPreampEnabled: Bool { get }
}

/// The real environment: answers from the audio engine.
@MainActor
final class EngineMusicEnvironment: MusicMixerEnvironment {
    private let engine: AudioEngine

    init(engine: AudioEngine) {
        self.engine = engine
    }

    var outputDevices: [AudioDevice] { engine.outputDevices }
    var defaultOutputDeviceUID: String? { engine.deviceVolumeMonitor.defaultDeviceUID }

    func autoEQProfile(forDeviceUID uid: String) -> AutoEQProfile? {
        engine.activeAutoEQProfile(for: uid)
    }

    func resolveAutoEQProfile(forDeviceUID uid: String) async -> AutoEQProfile? {
        await engine.resolveActiveAutoEQProfile(for: uid)
    }

    func deviceVolume(forDeviceUID uid: String) -> Float? {
        guard let device = engine.outputDevices.first(where: { $0.uid == uid }) else { return nil }
        return engine.deviceVolumeMonitor.volumes[device.id]
    }

    var loudnessCompensationEnabled: Bool { engine.settingsManager.appSettings.loudnessCompensationEnabled }
    var loudnessEqualizationEnabled: Bool { engine.settingsManager.appSettings.loudnessEqualizationEnabled }
    var autoEQPreampEnabled: Bool { engine.settingsManager.autoEQPreampEnabled }
}

/// The YouTube Music row's model: volume, mute, boost, EQ and output device, saved under one settings key, pushed into
/// the music `MusicDSPChain` and the playback engine, and kept right when devices come and go.
///
/// It exists before the music service does (the service is created lazily when the Music tab opens): settings load at
/// once, the chain is shaped from the start, and the engine is bound later through `attach(engine:)`.
@Observable
@MainActor
final class MusicMixerState: InProcessAudioSink {
    /// Where the music row's settings live in `SettingsManager`, next to the per-app ones, with no schema change.
    static let settingsKey = "com.abraham.Deci.music"

    /// The DSP the playback engine's tap runs. Built at 48 kHz: a stream at another rate is handled by the chain.
    @ObservationIgnored let chain = MusicDSPChain(sampleRate: 48_000)

    private(set) var volume: Float = 1
    private(set) var isMuted = false
    private(set) var boost: BoostLevel = .x1
    private(set) var eqSettings: EQSettings = .flat
    /// The output device the user picked. Kept even while it is unplugged: it is their intent, and it returns with it.
    /// nil follows the system default output.
    private(set) var selectedDeviceUID: String?
    /// The device the engine is actually told to use: the selected one while it is connected, otherwise nil (default).
    private(set) var outputDeviceUID: String?
    /// True once an engine was attached. Stays true if that engine goes away: the state is only meaningful per app run.
    private(set) var hasEngine = false

    /// The volume and mute the watchtime pings report, as the web player's 0 to 100 slider: the row's slider
    /// position, boost left out.
    var watchtimeLevel: (volume: Int, muted: Bool) {
        (Int((VolumeMapping.gainToSlider(volume) * 100).rounded()), isMuted)
    }

    @ObservationIgnored private let settings: SettingsManager
    @ObservationIgnored private let environment: any MusicMixerEnvironment
    @ObservationIgnored private weak var engine: (any PlaybackEngine)?
    /// What the engine was last told; the outer optional says whether it was told anything yet.
    @ObservationIgnored private var pushedDeviceUID: String??
    @ObservationIgnored private var loudnessCompensationOn: Bool
    /// The default output as the engine last reported it: its own cached value can lag behind the notification.
    @ObservationIgnored private var reportedDefaultUID: String?
    /// Device volumes as the engine last reported them, for the same reason.
    @ObservationIgnored private var reportedDeviceVolumes: [String: Float] = [:]
    @ObservationIgnored private var autoEQTask: Task<Void, Never>?

    init(settings: SettingsManager, environment: any MusicMixerEnvironment) {
        self.settings = settings
        self.environment = environment
        loudnessCompensationOn = environment.loudnessCompensationEnabled

        let key = Self.settingsKey
        let savedVolume = settings.getVolume(for: key) ?? 1
        volume = savedVolume.isFinite ? min(1, max(0, savedVolume)) : 1
        isMuted = settings.getMute(for: key) ?? false
        boost = settings.getBoost(for: key) ?? .x1
        eqSettings = settings.getEQSettings(for: key)
        selectedDeviceUID = settings.getDeviceRouting(for: key)

        // The first gain jumps straight to the stored value, so a stored mute or low volume never leaks a loud start.
        chain.setTargetGain(effectiveGain, snap: true)
        chain.setEQ(eqSettings)
        chain.setAutoEQPreampEnabled(environment.autoEQPreampEnabled)
        chain.setLoudnessEqualization(enabled: environment.loudnessEqualizationEnabled)
        updateLoudness()
        resolveOutputDevice()
        refreshAutoEQ()
    }

    // MARK: - Derived

    var isFollowingDefault: Bool { selectedDeviceUID == nil }

    /// The device the music comes out of: the one it is routed to, otherwise the system default output.
    var effectiveDeviceUID: String? {
        outputDeviceUID ?? reportedDefaultUID ?? environment.defaultOutputDeviceUID
    }

    private var effectiveGain: Float {
        isMuted ? 0 : volume * boost.rawValue
    }

    // MARK: - The row's controls

    func setVolume(_ newVolume: Float) {
        guard newVolume.isFinite else { return }
        volume = min(1, max(0, newVolume))
        settings.setVolume(for: Self.settingsKey, to: volume)
        pushGain()
        updateLoudness()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        settings.setMute(for: Self.settingsKey, to: muted)
        pushGain()
    }

    func setBoost(_ newBoost: BoostLevel) {
        boost = newBoost
        settings.setBoost(for: Self.settingsKey, to: newBoost)
        pushGain()
    }

    func setEQ(_ newSettings: EQSettings) {
        // The EQ panel reports one edit twice (through its binding and its callback): the second is a no-op.
        guard newSettings != eqSettings else { return }
        eqSettings = newSettings
        chain.setEQ(newSettings)
        settings.setEQSettings(newSettings, for: Self.settingsKey)
    }

    /// Routes the music to the output device with this UID. A device that is not connected is refused.
    func selectDevice(uid: String) {
        guard environment.outputDevices.contains(where: { $0.uid == uid }) else { return }
        selectedDeviceUID = uid
        settings.setDeviceRouting(for: Self.settingsKey, deviceUID: uid)
        deviceChoiceChanged()
    }

    /// Back to the system default output.
    func followDefaultDevice() {
        selectedDeviceUID = nil
        settings.setFollowDefault(for: Self.settingsKey)
        deviceChoiceChanged()
    }

    /// The loudest sample played since the last call, linear 0...1 and beyond when boosted: for the row's meter.
    func sampleLevel() -> Float {
        chain.consumePeak()
    }

    // MARK: - Engine

    /// Binds the playback engine and applies the stored output device to it. Called when the service is built.
    func attach(engine: any PlaybackEngine) {
        self.engine = engine
        hasEngine = true
        pushedDeviceUID = nil
        pushOutputDevice()
    }

    private func pushOutputDevice() {
        guard let engine else { return }
        if let pushed = pushedDeviceUID, pushed == outputDeviceUID { return }
        pushedDeviceUID = .some(outputDeviceUID)
        engine.setOutputDevice(uid: outputDeviceUID)
    }

    // MARK: - InProcessAudioSink

    func loudnessCompensationChanged(enabled: Bool) {
        loudnessCompensationOn = enabled
        updateLoudness()
    }

    func loudnessEqualizationChanged(enabled: Bool) {
        chain.setLoudnessEqualization(enabled: enabled)
    }

    func autoEQPreampChanged(enabled: Bool) {
        chain.setAutoEQPreampEnabled(enabled)
    }

    func autoEQSelectionChanged(deviceUID: String) {
        guard deviceUID == effectiveDeviceUID else { return }
        refreshAutoEQ()
    }

    func deviceVolumeChanged(deviceUID: String, volume: Float) {
        guard volume.isFinite else { return }
        reportedDeviceVolumes[deviceUID] = volume
        guard deviceUID == effectiveDeviceUID else { return }
        updateLoudness()
    }

    func defaultDeviceChanged(uid: String) {
        reportedDefaultUID = uid
        // An explicit device keeps its place; only a row that follows the default moves with it.
        guard outputDeviceUID == nil else { return }
        refreshAutoEQ()
        updateLoudness()
    }

    func outputDevicesChanged() {
        resolveOutputDevice()
        pushOutputDevice()
        refreshAutoEQ()
        updateLoudness()
    }

    /// Everything went back to its default. The settings were cleared already, so nothing is written here.
    func settingsDidReset() {
        volume = 1
        isMuted = false
        boost = .x1
        eqSettings = .flat
        selectedDeviceUID = nil
        chain.setTargetGain(effectiveGain)
        chain.setEQ(.flat)
        chain.setAutoEQPreampEnabled(environment.autoEQPreampEnabled)
        chain.setLoudnessEqualization(enabled: environment.loudnessEqualizationEnabled)
        loudnessCompensationOn = environment.loudnessCompensationEnabled
        resolveOutputDevice()
        pushOutputDevice()
        refreshAutoEQ()
        updateLoudness()
    }

    // MARK: - Pushing state to the chain

    private func pushGain() {
        chain.setTargetGain(effectiveGain)
    }

    private func deviceChoiceChanged() {
        resolveOutputDevice()
        pushOutputDevice()
        refreshAutoEQ()
        updateLoudness()
    }

    /// The selected device when it is connected, otherwise nil: an unknown UID would send the audio nowhere.
    private func resolveOutputDevice() {
        if let selected = selectedDeviceUID, environment.outputDevices.contains(where: { $0.uid == selected }) {
            outputDeviceUID = selected
        } else {
            outputDeviceUID = nil
        }
    }

    /// Loudness compensation hears the level the listener has on the device times the row's own volume. Boost is left
    /// out: it is the same as a louder source, which the contours were never meant to follow.
    private func updateLoudness() {
        let deviceVolume = effectiveDeviceUID.flatMap { reportedDeviceVolumes[$0] ?? environment.deviceVolume(forDeviceUID: $0) } ?? 1
        chain.setLoudnessCompensation(enabled: loudnessCompensationOn, volume: deviceVolume * volume)
    }

    /// Applies the AutoEQ profile of the device in use. A profile that is not in memory yet loads in the background and
    /// is applied when it arrives, unless the device in use changed in the meantime.
    private func refreshAutoEQ() {
        autoEQTask?.cancel()
        autoEQTask = nil
        guard let uid = effectiveDeviceUID else {
            chain.setAutoEQProfile(nil)
            return
        }
        if let profile = environment.autoEQProfile(forDeviceUID: uid) {
            chain.setAutoEQProfile(profile)
            return
        }
        chain.setAutoEQProfile(nil)
        autoEQTask = Task { [weak self, environment] in
            let profile = await environment.resolveAutoEQProfile(forDeviceUID: uid)
            guard !Task.isCancelled, let self, self.effectiveDeviceUID == uid else { return }
            self.chain.setAutoEQProfile(profile)
        }
    }
}
