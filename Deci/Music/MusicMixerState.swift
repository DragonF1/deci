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

/// The music player row's model (the row shows as Deci in the Mixer tab): volume, mute, boost, EQ and output device, saved under one settings key, pushed into
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
    /// The device the music is anchored on: the selected one while it is connected, otherwise nil (default). In Multi
    /// mode it is the first, in sorted UID order, of the ticked devices that are connected: the one whose AutoEQ profile
    /// and device volume the music follows, as a multi-device app tap does. Not what the engine is told while two or more
    /// devices play: that is the aggregate.
    private(set) var outputDeviceUID: String?
    /// True once an engine was attached. Stays true if that engine goes away: the state is only meaningful per app run.
    private(set) var hasEngine = false
    /// The name of the AutoEQ profile in effect on the device in use. nil when none.
    private(set) var autoEQProfileName: String?
    /// Whether the music plays on one output (the chosen device, else the default) or on several at once.
    private(set) var deviceSelectionMode: DeviceSelectionMode = .single
    /// The devices ticked for Multi mode. Kept while they are unplugged and while the mode is Single: it is the user's
    /// intent, and it returns with the devices.
    private(set) var selectedDeviceUIDs: Set<String> = []
    /// The devices the music plays on while it uses two or more, through the aggregate. Empty in every other case, so a
    /// view can light the devices in use. Assigned only when it really changes.
    private(set) var multiOutputDeviceUIDs: Set<String> = []

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
    @ObservationIgnored private let aggregates: any MusicOutputAggregating
    /// The aggregate the player is pointed at while two or more devices play, with the stack it was built for.
    @ObservationIgnored private var liveAggregate: (stack: MusicOutputStack, aggregate: MusicOutputAggregate)?
    /// The stack the last build failed for, while it is still the one wanted. Each build waits on the main thread for
    /// the aggregate to come up, so the same stack is not tried again on every device event; it is once it changes.
    @ObservationIgnored private var failedStack: MusicOutputStack?
    /// The ticked devices that are connected, while in Multi mode.
    @ObservationIgnored private var multiAvailableUIDs: Set<String> = []
    /// The last selection that was not empty. Unticking every device keeps the music where it is rather than dropping it
    /// onto the default output, which could be the speakers; the engine's multi-device tap does the same.
    @ObservationIgnored private var heldSelectionUIDs: Set<String> = []
    /// Set on quit: no aggregate is made after it.
    @ObservationIgnored private var isShutDown = false
    /// The time, for how long the music has been in Multi.
    @ObservationIgnored private let now: @MainActor () -> Date
    /// The output devices seen connected at the last device event, so a device that is gone from the list now is a real
    /// disconnect. A device that was never seen (away at launch) is not one.
    @ObservationIgnored private var knownConnectedUIDs: Set<String> = []

    /// `aggregates` makes the output aggregate and `now` is the clock for the Multi session; tests pass fakes.
    init(
        settings: SettingsManager,
        environment: any MusicMixerEnvironment,
        aggregates: any MusicOutputAggregating = CoreAudioMusicOutputAggregates(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.aggregates = aggregates
        self.settings = settings
        self.environment = environment
        self.now = now
        knownConnectedUIDs = Set(environment.outputDevices.map(\.uid))
        loudnessCompensationOn = environment.loudnessCompensationEnabled

        let key = Self.settingsKey
        let savedVolume = settings.getVolume(for: key) ?? 1
        volume = savedVolume.isFinite ? min(1, max(0, savedVolume)) : 1
        isMuted = settings.getMute(for: key) ?? false
        boost = settings.getBoost(for: key) ?? .x1
        eqSettings = settings.getEQSettings(for: key)
        selectedDeviceUID = settings.getDeviceRouting(for: key)
        deviceSelectionMode = settings.getDeviceSelectionMode(for: key) ?? .single
        selectedDeviceUIDs = settings.getSelectedDeviceUIDs(for: key) ?? []
        heldSelectionUIDs = selectedDeviceUIDs

        // The first gain jumps straight to the stored value, so a stored mute or low volume never leaks a loud start.
        chain.setTargetGain(effectiveGain, snap: true)
        chain.setEQ(eqSettings)
        chain.setAutoEQPreampEnabled(environment.autoEQPreampEnabled)
        chain.setLoudnessEqualization(enabled: environment.loudnessEqualizationEnabled)
        updateLoudness()
        resolveOutputDevice()
        refreshAutoEQ()
    }

    /// A mixer that is dropped frees its aggregate, so none is ever left in the system's device list.
    isolated deinit {
        if let live = liveAggregate { aggregates.destroy(live.aggregate) }
    }

    // MARK: - Derived

    var isFollowingDefault: Bool { selectedDeviceUID == nil }

    /// The device the music comes out of: the one it is routed to, otherwise the system default output.
    ///
    /// AutoEQ policy for Multi mode, mirroring what `AudioEngine` and `ProcessTapController` do for a multi-device app
    /// tap: the music is one stream copied to every device, so one device's AutoEQ profile and device volume apply to all
    /// of them. That device is the first of the stack in sorted UID order (`outputDeviceUID`), not the clock device. The
    /// other devices' profiles are not looked at, so a primary without a profile plays flat, and the manual EQ is
    /// untouched.
    var effectiveDeviceUID: String? {
        outputDeviceUID ?? reportedDefaultUID ?? environment.defaultOutputDeviceUID
    }

    private var effectiveGain: Float {
        isMuted ? 0 : volume * boost.rawValue
    }

    /// A device was chosen but is not connected (in Multi mode: none of the ticked ones is): the music plays on the
    /// default output until it comes back.
    var isChosenDeviceMissing: Bool {
        switch deviceSelectionMode {
        case .single: selectedDeviceUID != nil && outputDeviceUID == nil
        case .multi: !selectedDeviceUIDs.isEmpty && outputDeviceUID == nil
        }
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

    /// Switches between one output and several. Entering Multi with nothing ticked ticks the device the music plays on,
    /// so the picker opens with it checked and the music keeps playing there. Going back to Single plays on the device
    /// chosen before (or the default) and keeps the ticked devices for the next time.
    func setDeviceSelectionMode(_ mode: DeviceSelectionMode) {
        guard mode != deviceSelectionMode else { return }
        deviceSelectionMode = mode
        settings.setDeviceSelectionMode(for: Self.settingsKey, to: mode, at: now())
        if mode == .multi { seedMultiSelection() }
        deviceChoiceChanged()
    }

    /// Sets the ticked devices for Multi mode. Saved at once; the music follows when the mode is Multi. A device that is
    /// not connected stays ticked and joins when it returns. Unticking every device keeps the music where it is.
    func setSelectedDeviceUIDs(_ uids: Set<String>) {
        guard uids != selectedDeviceUIDs else { return }
        storeSelection(uids)
        guard deviceSelectionMode == .multi else { return }
        deviceChoiceChanged()
    }

    /// Quit path: puts the player back on the default output and destroys the aggregate. Nothing is built afterwards.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        if let engine, liveAggregate != nil { point(engine, at: nil) }
        retireLiveAggregate()
        publishMultiOutput()
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

    /// The loudest buffer RMS played since the last call, before the volume: for the player column's spectrum. It is
    /// read apart from `sampleLevel()`, so the Mixer row and the spectrum never take each other's samples.
    func sampleSpectrumLevel() -> Float {
        chain.consumeLevel()
    }

    // MARK: - Engine

    /// Binds the playback engine and applies the stored output device and level to it. Called when the service is built.
    func attach(engine: any PlaybackEngine) {
        self.engine = engine
        hasEngine = true
        // The mixer is built before the engine's device monitors have filled in the devices, so what init resolved (no
        // device, no AutoEQ, a device volume of 1) can be stale by now, and no device event is sent for devices that
        // were already there. Resolve again before the engine is told anything.
        knownConnectedUIDs = Set(environment.outputDevices.map(\.uid))
        resolveOutputDevice()
        refreshAutoEQ()
        updateLoudness()
        pushedDeviceUID = nil
        pushOutputDevice()
        pushLevel()
    }

    /// Points the player where the music should come out and keeps the aggregate in step with it. Two or more connected
    /// devices in Multi mode get one stacked aggregate, kept while the set of devices is the same; one device is used
    /// directly; none leaves the default output. A new aggregate is given to the player before the old one is destroyed,
    /// so the player is never left on a device that is gone.
    private func pushOutputDevice() {
        guard let engine, !isShutDown else { return }
        var target = outputDeviceUID
        var retired: MusicOutputAggregate?
        if let stack = wantedStack() {
            if let live = liveAggregate, live.stack == stack {
                target = live.aggregate.uid
            } else if stack == failedStack {
                target = stack.clockDeviceUID
            } else {
                let made = aggregates.makeAggregate(for: stack)
                retired = liveAggregate?.aggregate
                liveAggregate = made.map { (stack: stack, aggregate: $0) }
                failedStack = made == nil ? stack : nil
                // An aggregate that could not be made leaves the music on the clock device alone rather than silent.
                target = made?.uid ?? stack.clockDeviceUID
            }
        } else {
            retired = liveAggregate?.aggregate
            liveAggregate = nil
            failedStack = nil
        }
        point(engine, at: target)
        if let retired { aggregates.destroy(retired) }
        publishMultiOutput()
    }

    /// The stack to play on: the connected ticked devices when there are two or more, in Multi mode.
    private func wantedStack() -> MusicOutputStack? {
        guard deviceSelectionMode == .multi else { return nil }
        return MusicOutputStack.plan(for: multiAvailableUIDs, isBluetooth: { aggregates.isBluetooth(deviceUID: $0) })
    }

    /// Tells the engine where to play, unless it was told already.
    private func point(_ engine: any PlaybackEngine, at target: String?) {
        if let pushed = pushedDeviceUID, pushed == target { return }
        pushedDeviceUID = .some(target)
        engine.setOutputDevice(uid: target)
    }

    private func retireLiveAggregate() {
        guard let live = liveAggregate else { return }
        liveAggregate = nil
        aggregates.destroy(live.aggregate)
    }

    /// The devices the music plays on through the aggregate. Written only when it differs, so views that read it are not
    /// woken by a rebuild that changed nothing.
    private func publishMultiOutput() {
        let inUse = liveAggregate.map { Set($0.stack.subDeviceUIDs) } ?? []
        if inUse != multiOutputDeviceUIDs { multiOutputDeviceUIDs = inUse }
    }

    /// Ticks the device the music plays on when Multi starts with nothing ticked. A selection saved earlier is left alone.
    private func seedMultiSelection() {
        guard selectedDeviceUIDs.isEmpty, let playingOn = effectiveDeviceUID else { return }
        storeSelection([playingOn])
    }

    private func storeSelection(_ uids: Set<String>) {
        selectedDeviceUIDs = uids
        if !uids.isEmpty { heldSelectionUIDs = uids }
        settings.setSelectedDeviceUIDs(for: Self.settingsKey, to: uids)
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
        let connected = Set(environment.outputDevices.map(\.uid))
        let dropped = knownConnectedUIDs.subtracting(connected)
        knownConnectedUIDs = connected
        // A device that was connected and is gone, and that the music plays on in Multi: back to Single at once, even if
        // other ticked devices are still there. The new mode is in place before the player is pointed anywhere.
        let playsOn = selectedDeviceUIDs.isEmpty ? heldSelectionUIDs : selectedDeviceUIDs
        if dropped.contains(where: {
            MultiOutputRevert.disconnectAffects(mode: deviceSelectionMode, selected: playsOn, uid: $0)
        }) {
            revertMultiAfterDisconnect()
        }
        resolveOutputDevice()
        pushOutputDevice()
        refreshAutoEQ()
        updateLoudness()
    }

    /// Leaves Multi after a ticked device disconnected. A short session returns to the single choice it had before (a
    /// device, or the default output if it followed that); a long one, or one with no recorded start, follows the default
    /// output and forgets the device. The ticked devices are kept, and nothing rejoins when the device returns.
    private func revertMultiAfterDisconnect() {
        let target = MultiOutputRevert.target(multiSince: settings.getMultiOutputSince(for: Self.settingsKey), now: now())
        if target == .systemAudio {
            selectedDeviceUID = nil
            settings.setFollowDefault(for: Self.settingsKey)
        }
        // The caller resolves and points the player once.
        deviceSelectionMode = .single
        settings.setDeviceSelectionMode(for: Self.settingsKey, to: .single, at: now())
    }

    /// Everything went back to its default. The settings were cleared already, so nothing is written here.
    func settingsDidReset() {
        volume = 1
        isMuted = false
        boost = .x1
        eqSettings = .flat
        selectedDeviceUID = nil
        deviceSelectionMode = .single
        selectedDeviceUIDs = []
        heldSelectionUIDs = []
        pushGain()
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
        pushLevel()
    }

    /// What the player itself plays at when the tap is not on the item (it could not be built, or the format is one the
    /// DSP cannot process): the volume and mute, so a muted row never turns loud. Boost needs the tap and is left out.
    private func pushLevel() {
        engine?.setFallbackLevel(volume: volume, muted: isMuted)
    }

    private func deviceChoiceChanged() {
        resolveOutputDevice()
        pushOutputDevice()
        refreshAutoEQ()
        updateLoudness()
    }

    /// The selected device when it is connected, otherwise nil: an unknown UID would send the audio nowhere. In Multi mode
    /// the ticked devices that are connected, and the first of them in sorted UID order as the anchor.
    private func resolveOutputDevice() {
        let connected = Set(environment.outputDevices.map(\.uid))
        switch deviceSelectionMode {
        case .single:
            multiAvailableUIDs = []
            if let selected = selectedDeviceUID, connected.contains(selected) {
                outputDeviceUID = selected
            } else {
                outputDeviceUID = nil
            }
        case .multi:
            multiAvailableUIDs = (selectedDeviceUIDs.isEmpty ? heldSelectionUIDs : selectedDeviceUIDs).intersection(connected)
            outputDeviceUID = multiAvailableUIDs.min()
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
            applyAutoEQ(nil)
            return
        }
        if let profile = environment.autoEQProfile(forDeviceUID: uid) {
            applyAutoEQ(profile)
            return
        }
        applyAutoEQ(nil)
        autoEQTask = Task { [weak self, environment] in
            let profile = await environment.resolveAutoEQProfile(forDeviceUID: uid)
            guard !Task.isCancelled, let self, self.effectiveDeviceUID == uid else { return }
            self.applyAutoEQ(profile)
        }
    }

    /// Hands the profile to the chain and keeps its name.
    private func applyAutoEQ(_ profile: AutoEQProfile?) {
        chain.setAutoEQProfile(profile)
        autoEQProfileName = profile?.name
    }
}
