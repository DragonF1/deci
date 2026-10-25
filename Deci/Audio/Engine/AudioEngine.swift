// FineTune/Audio/Engine/AudioEngine.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

@Observable
@MainActor
final class AudioEngine {
    let processMonitor: any AudioProcessMonitoring
    let deviceMonitor: any AudioDeviceProviding
    let bluetoothDeviceMonitor: BluetoothDeviceMonitor
    let deviceVolumeMonitor: any DeviceVolumeProviding
    let volumeState: VolumeState
    let settingsManager: SettingsManager
    let autoEQProfileManager: AutoEQProfileManager
    let permission: AudioRecordingPermission
    let appListCoordinator: AppListCoordinator

    #if !APP_STORE
    let ddcController: DDCController
    #endif

    private var taps: [pid_t: any ProcessTapControlling] = [:]

    /// Output device UIDs that carry a multi-device route: the union of the devices of every live
    /// tap that plays on more than one. Stored (not computed from `taps`) because a tap's device
    /// list is not observable, so views reading this redraw only when the engine refreshes it.
    private(set) var multiRouteDeviceUIDs: Set<String> = []

    /// Bundle ids of the apps whose tap plays on more than one device. Stored for the same reason as
    /// `multiRouteDeviceUIDs`. Chrome's tab outputs read it: when the Chrome app is fanned out here, a tab must not
    /// be fanned out again by the extension.
    private(set) var multiRouteBundleIDs: Set<String> = []

    /// Called with the new `multiRouteBundleIDs` whenever the set changes.
    var onMultiRouteBundleIDsChange: (@MainActor (Set<String>) -> Void)?

    /// Called with the UID of an output device that disconnected, after the engine has handled it (Multi apps that had the
    /// device selected are back on Single by then). Chrome's tabs are not the engine's apps, so the app wires the
    /// extension manager's own revert to this.
    var onOutputDeviceDisconnected: (@MainActor (String) -> Void)?

    /// Receives the text of the "device disconnected" notification instead of the system notification center. For tests.
    var onDisconnectNotification: (@MainActor (String) -> Void)?

    /// Called when what Deci's tap of Chrome adds to its outputs changes: each tapped output device UID mapped to the
    /// tap's measured through-latency in seconds, or an empty map once the figure stops applying (no Chrome tap, a
    /// mixdown tap, or nothing measured). Chrome cannot see this delay, so the extension adds it when it lines
    /// Chrome's outputs up. Polled at 4 Hz and reported only on a real change (see `ChromeTapLatencyReporter`).
    var onChromeTapLatencyChange: (@MainActor ([String: Double]) -> Void)?

    /// Output device UIDs the engine's own taps play on through a multi-device route. The popup
    /// unions this with the music row's and Chrome tabs' multi-output devices (see
    /// `MenuBarPopupView.outputDevicesInUse`) to light the device list.
    var outputDevicesInUse: Set<String> {
        multiRouteDeviceUIDs
    }

    /// Factory for creating tap controllers. Overridable for testing.
    private let tapFactory: @MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling

    /// Closure to check if a device is alive. Overridable for testing.
    private let isAliveCheck: (AudioDeviceID) -> Bool

    /// Closure to check if a process is still running (signal 0). Overridable for testing.
    private let isProcessAliveCheck: @MainActor (pid_t) -> Bool

    /// Closure to read the HAL process objects that exist now, once per lookup. Overridable for testing.
    private let readProcessObjectIDs: @MainActor () -> Set<AudioObjectID>

    /// Closure to read whether an app has output IO running (HAL IsRunningOutput on any of its
    /// process objects). Overridable for testing.
    private let isProcessRunningOutput: @MainActor (AudioApp) -> Bool

    /// How long an app may be absent from the process list before its tap is considered for cleanup.
    private let staleTapGrace: Duration

    /// How often a retained tap (process still alive but silent) is re-checked after the grace.
    private let staleTapPollInterval: Duration

    /// Quiet period before a changed process list rebuilds a tap (coalesces bursts of helper spawns).
    private let processRebuildDebounce: Duration

    /// The time, for how long an app has been in Multi. Overridable for testing.
    private let currentTime: @MainActor () -> Date

    /// One-shot HAL listeners for devices that were present but not alive during priority resolution.
    /// Keyed by AudioDeviceID. Each entry holds the device UID, listener block, and a timeout task.
    private var aliveWatchers: [AudioDeviceID: (uid: String, block: AudioObjectPropertyListenerBlock, timeout: Task<Void, Never>)] = [:]

    /// Number of pending alive watchers (exposed for testing).
    var pendingAliveWatcherCount: Int { aliveWatchers.count }

    private var appliedPIDs: Set<pid_t> = []
    private var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    private var followsDefault: Set<pid_t> = []  // Apps that follow system default
    /// The last output default confirmed by FineTune (user change or programmatic switch).
    /// Used to restore after macOS auto-switches to a lower-priority device.
    private var lastConfirmedDefaultUID: String?
    /// Timestamp of the last auto-switch override. Used to distinguish rapid BT auto-switches
    /// (< 1s apart) from deliberate user changes (> 1s after last override).
    private var lastAutoSwitchOverrideTime: Date?
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private var staleCleanupTask: Task<Void, Never>?  // Debounced cleanup scheduling
    private var processRebuilds: [pid_t: ProcessRebuildState] = [:]  // Per-pid helper-process rebuilds
    private var failedProcessLists: [pid_t: Set<AudioObjectID>] = [:]  // Last list whose rebuild failed, not retried
    private var healthMonitorTask: Task<Void, Never>?  // Periodic tap health monitor
    private var chromeTapLatencyTask: Task<Void, Never>?  // 4 Hz poll of the Chrome tap's through-latency
    private var chromeTapLatencyReporter = ChromeTapLatencyReporter()
    private var healthTickCount = 0  // Ticks run, for the once-per-second work
    private var consecutiveMisses: [pid_t: Int] = [:]  // Unresponsive-tap misses, one per second
    private var tapRecoveryCooldownUntil: [pid_t: Date] = [:]  // Prevents tap recreation thrashing
    private var tapWatchdogs: [pid_t: TapWatchdog] = [:]  // Stuck-tap detection, kept across rebuilds
    private var loggedDiscontinuities: [pid_t: UInt32] = [:]  // Last IO discontinuity count logged per tap
    #if DEBUG
    private var zeroRunCursors: [pid_t: ZeroRunLogCursor] = [:]  // Zero runs already logged per tap
    #endif
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioEngine")

    // MARK: - Priority State Machine

    /// Tracks whether we're waiting for macOS to potentially auto-switch after a device connect.
    private enum PriorityState {
        case stable
        case pendingAutoSwitch(connectedDeviceUID: String, timeoutTask: Task<Void, Never>)
    }

    private var outputPriorityState: PriorityState = .stable
    private var inputPriorityState: PriorityState = .stable

    /// Grace period for auto-switch detection (wired devices)
    private let autoSwitchGracePeriod: TimeInterval = 2.0

    /// Extended grace period for Bluetooth devices (firmware handshake takes longer)
    private let btAutoSwitchGracePeriod: TimeInterval = 5.0

    // MARK: - Echo Suppression

    private let outputEchoTracker = EchoTracker(label: "Output")
    private let inputEchoTracker = EchoTracker(label: "Input")

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    /// Audio that plays inside Deci's own process (the YouTube Music player), which the process taps never see.
    /// Told about the global switches and device events below. Weak: the engine does not own it.
    @ObservationIgnored weak var inProcessAudio: (any InProcessAudioSink)?

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
        deviceVolumeMonitor.outputVolumeBackend(for: deviceID)
    }

    var inputDevices: [AudioDevice] {
        deviceMonitor.inputDevices
    }

    /// Output devices sorted by user-defined priority order.
    /// Devices in the priority list appear in that order; new/unknown devices are appended alphabetically.
    var prioritySortedOutputDevices: [AudioDevice] {
        let devices = outputDevices
        let priorityOrder = settingsManager.devicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        // Collect devices in priority order (skip stale UIDs)
        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        // Append new devices alphabetically
        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Input devices sorted by user-defined priority order.
    var prioritySortedInputDevices: [AudioDevice] {
        let devices = inputDevices
        let priorityOrder = settingsManager.inputDevicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Saves a reordered output priority list. When the order puts a different connected
    /// device on top, that device becomes the default.
    func applyOutputPriorityOrder(connectedOrder: [String]) {
        let previousTop = highestPriorityOutputUID()
        settingsManager.mergeDevicePriorityOrder(
            oldPriority: settingsManager.devicePriorityOrder,
            connectedOrder: connectedOrder
        )
        guard highestPriorityOutputUID() != previousTop else { return }
        reEvaluateOutputDefault()
    }

    /// Input counterpart of `applyOutputPriorityOrder`. Switches only while the input follows
    /// priority (Input Follows Priority on); otherwise macOS keeps control of the input.
    func applyInputPriorityOrder(connectedOrder: [String]) {
        let previousTop = highestPriorityInputUID()
        settingsManager.mergeInputDevicePriorityOrder(
            oldPriority: settingsManager.inputDevicePriorityOrder,
            connectedOrder: connectedOrder
        )
        guard settingsManager.appSettings.lockInputDevice,
              highestPriorityInputUID() != previousTop,
              let target = reEvaluateInputDefault() else { return }
        settingsManager.setLockedInputDeviceUID(target)
        settingsManager.setPreferredInputDeviceUID(target)
    }

    private func highestPriorityOutputUID() -> String? {
        Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            isAlive: isAliveCheck
        )?.uid
    }

    private func highestPriorityInputUID() -> String? {
        Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            isAlive: isAliveCheck
        )?.uid
    }

    /// Registers any output devices not yet in the priority list.
    /// Call this when devices change (not from computed properties).
    func registerNewDevicesInPriority() {
        for device in outputDevices {
            settingsManager.ensureDeviceInPriority(device.uid)
        }
        for device in inputDevices {
            settingsManager.ensureInputDeviceInPriority(device.uid)
        }
    }

    /// What an output device's connection does to the system default and follows-default routing.
    enum ConnectedOutputDefaultAction: Equatable {
        /// The connected device is the highest-priority connected device: make sure it is the
        /// default and point follows-default taps at it. Also covers macOS having switched to it
        /// already, where the taps would otherwise stay on the previous device.
        case ensureHighestPriorityDefault
        /// macOS switched to a lower-priority device: restore the device the user was on.
        case restorePrevious
        /// A lower-priority device that is not the default: leave routing alone.
        case none
    }

    static func connectedOutputDefaultAction(
        connectedDeviceUID: String,
        highestPriorityConnectedUID: String?,
        currentDefaultUID: String?
    ) -> ConnectedOutputDefaultAction {
        if connectedDeviceUID == highestPriorityConnectedUID { return .ensureHighestPriorityDefault }
        if connectedDeviceUID == currentDefaultUID { return .restorePrevious }
        return .none
    }

    /// Returns the highest-priority device that is both connected and alive.
    /// `isDeviceAlive()` is checked internally — callers never need to check separately.
    static func resolveHighestPriority(
        priorityOrder: [String],
        connectedDevices: [AudioDevice],
        excluding: String? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil
    ) -> AudioDevice? {
        let aliveCheck = isAlive ?? { $0.isDeviceAlive() }
        let connected = Dictionary(
            connectedDevices.map { ($0.uid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for uid in priorityOrder {
            guard uid != excluding,
                  let device = connected[uid],
                  aliveCheck(device.id) else { continue }
            return device
        }
        // Fallback: any alive connected device not excluded
        return connectedDevices.first {
            $0.uid != excluding && aliveCheck($0.id)
        }
    }


    init(
        permission: AudioRecordingPermission,
        settingsManager: SettingsManager,
        autoEQProfileManager: AutoEQProfileManager,
        deviceProvider: (any AudioDeviceProviding)? = nil,
        processMonitor: (any AudioProcessMonitoring)? = nil,
        deviceVolumeMonitor: (any DeviceVolumeProviding)? = nil,
        tapFactory: (@MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling)? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil,
        isProcessAlive: (@MainActor (pid_t) -> Bool)? = nil,
        processObjectList: (@MainActor () -> Set<AudioObjectID>)? = nil,
        isProcessRunningOutput: (@MainActor (AudioApp) -> Bool)? = nil,
        staleTapGrace: Duration = .seconds(30),
        staleTapPollInterval: Duration = .seconds(30),
        processRebuildDebounce: Duration = .milliseconds(100),
        startMonitorsAutomatically: Bool = true,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.permission = permission
        let manager = settingsManager
        self.settingsManager = manager
        self.appListCoordinator = AppListCoordinator(settingsManager: manager)
        self.autoEQProfileManager = autoEQProfileManager
        self.volumeState = VolumeState(settingsManager: manager)
        self.isAliveCheck = isAlive ?? { $0.isDeviceAlive() }
        self.isProcessAliveCheck = isProcessAlive ?? { pid in
            // EPERM means the process exists but belongs to another user.
            kill(pid, 0) == 0 || errno == EPERM
        }
        self.readProcessObjectIDs = processObjectList ?? {
            Set((try? AudioObjectID.readProcessList()) ?? [])
        }
        self.isProcessRunningOutput = isProcessRunningOutput ?? { app in
            app.processObjectIDs.contains { $0.readProcessIsRunningOutput() }
        }
        self.staleTapGrace = staleTapGrace
        self.staleTapPollInterval = staleTapPollInterval
        self.processRebuildDebounce = processRebuildDebounce
        self.currentTime = now

        // If a custom deviceProvider is given, use it directly.
        // Otherwise create a real AudioDeviceMonitor (needed by DeviceVolumeMonitor and default tap factory).
        let realDeviceMonitor: AudioDeviceMonitor?
        if let provider = deviceProvider {
            realDeviceMonitor = provider as? AudioDeviceMonitor
            self.deviceMonitor = provider
        } else {
            let monitor = AudioDeviceMonitor()
            realDeviceMonitor = monitor
            self.deviceMonitor = monitor
        }
        self.processMonitor = processMonitor ?? AudioProcessMonitor()
        self.bluetoothDeviceMonitor = BluetoothDeviceMonitor()

        #if !APP_STORE
        let ddc = DDCController(settingsManager: manager)
        self.ddcController = ddc
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager, ddcController: ddc)
        }
        #else
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager)
        }
        #endif

        // Tap factory: use provided factory or default to ProcessTapController
        if let factory = tapFactory {
            self.tapFactory = factory
        } else {
            self.tapFactory = { app, deviceUIDs, preferredSource in
                if deviceUIDs.count == 1 {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUID: deviceUIDs[0],
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                } else {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUIDs: deviceUIDs,
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                }
            }
        }

        outputEchoTracker.onTimeout = { [weak self] _ in
            self?.restoreConfirmedDefault()
        }
        inputEchoTracker.onTimeout = { [weak self] _ in
            guard let self, self.settingsManager.appSettings.lockInputDevice else { return }
            self.restoreLockedInputDevice()
        }

        // Wire callbacks — needed for both test and production mode
        wireCallbacks()

        if startMonitorsAutomatically {
            #if DEBUG
            logger.notice("[SOAK] \(DebugSoakConfig.current.summary, privacy: .public)")
            #endif
            Task { @MainActor in
                if self.permission.status == .authorized {
                    self.processMonitor.start()
                    // Without this the health monitor (unresponsive and stuck taps) only ever
                    // started on a fresh permission grant, never on a normal launch.
                    self.startHealthMonitor()
                }
                self.deviceMonitor.start()
                self.bluetoothDeviceMonitor.start()

                #if !APP_STORE
                ddc.onProbeCompleted = { [weak self] in
                    self?.deviceVolumeMonitor.refreshAfterDDCProbe()
                    self?.refreshAllTapOutputStates()
                }
                ddc.start()
                #endif

                // Start device volume monitor AFTER deviceMonitor.start() populates devices
                self.deviceVolumeMonitor.start()

                self.finishMonitorStartup()
            }
        }

        // Start process monitor when permission is granted
        if startMonitorsAutomatically && permission.status != .authorized {
            observePermissionGranted()
        }
    }

    /// The last step of the monitor startup, once the device monitors have filled in the devices.
    func finishMonitorStartup() {
        applyPersistedSettings()
        registerNewDevicesInPriority()
        // Seed the confirmed default from whatever macOS has at startup
        lastConfirmedDefaultUID = deviceVolumeMonitor.defaultDeviceUID
        if settingsManager.appSettings.lockInputDevice {
            restoreLockedInputDevice()
        }
        // The music mixer is built before the devices are known and no connect event fires for devices that were
        // already there: tell it the list is real now.
        inProcessAudio?.outputDevicesChanged()
    }

    private func observePermissionGranted() {
        withObservationTracking {
            _ = self.permission.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.permission.status == .authorized {
                    self.processMonitor.start()
                    self.applyPersistedSettings()
                    self.startHealthMonitor()
                    self.logger.info("Audio capture authorized — process monitor started")
                } else {
                    self.observePermissionGranted()
                }
            }
        }
    }

    /// Wire all event callbacks from monitors to AudioEngine handlers.
    private func wireCallbacks() {
        // Sync device volume changes to taps for VU meter accuracy
        deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            self.inProcessAudio?.deviceVolumeChanged(deviceUID: deviceUID, volume: newVolume)
            let loudnessEnabled = self.settingsManager.appSettings.loudnessCompensationEnabled
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.currentDeviceVolume = newVolume
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                    tap.updateLoudnessCompensation(
                        volume: self.effectiveLoudnessVolume(for: tap),
                        enabled: loudnessEnabled
                    )
                }
            }
        }

        deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, isMuted in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.isDeviceMuted = isMuted
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                }
            }
        }

        processMonitor.onAppsChanged = { [weak self] apps in
            self?.applyPersistedSettings()
            self?.syncTapProcesses(apps)
            self?.scheduleStaleCleanup()
        }

        // Priority order closures — only for concrete AudioDeviceMonitor
        if let realMonitor = deviceMonitor as? AudioDeviceMonitor {
            realMonitor.outputPriorityOrder = { [weak self] in
                self?.settingsManager.devicePriorityOrder ?? []
            }
            realMonitor.inputPriorityOrder = { [weak self] in
                self?.settingsManager.inputDevicePriorityOrder ?? []
            }
            realMonitor.onBTDeviceSampleRateChanged = { [weak self] uid, newRate in
                Task { @MainActor [weak self] in
                    await self?.handleBTDeviceSampleRateChanged(uid: uid, newRate: newRate)
                }
            }
        }

        deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            self?.onOutputDeviceDisconnected?(deviceUID)
            self?.inProcessAudio?.outputDevicesChanged()
            self?.bluetoothDeviceMonitor.refresh()
        }

        deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceConnected(deviceUID, name: deviceName)
            self?.inProcessAudio?.outputDevicesChanged()
            self?.bluetoothDeviceMonitor.notifyDeviceAppearedInCoreAudio()
        }

        deviceMonitor.onInputDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device disconnected: \(deviceName) (\(deviceUID))")
            self?.handleInputDeviceDisconnected(deviceUID)
        }

        deviceMonitor.onInputDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device connected: \(deviceName) (\(deviceUID))")
            self?.settingsManager.ensureInputDeviceInPriority(deviceUID)
            self?.handleInputDeviceConnected(deviceUID, name: deviceName)
        }

        deviceVolumeMonitor.onDefaultDeviceChanged = { [weak self] newDefaultUID in
            // Told first and always: the player follows what macOS actually outputs to, whatever the priority logic decides.
            self?.inProcessAudio?.defaultDeviceChanged(uid: newDefaultUID)
            self?.handleDefaultDeviceChanged(newDefaultUID)
        }

        deviceVolumeMonitor.onDefaultInputDeviceChanged = { [weak self] newDefaultInputUID in
            Task { @MainActor [weak self] in
                self?.handleDefaultInputDeviceChanged(newDefaultInputUID)
            }
        }
    }

    var apps: [AudioApp] {
        processMonitor.activeApps
    }

    // MARK: - Displayable Apps (Active + Pinned Inactive)

    /// Combined list of active apps and pinned inactive apps for UI display.
    /// Pinned apps appear first (sorted alphabetically), then unpinned active apps (sorted alphabetically).
    var displayableApps: [DisplayableApp] {
        let activeApps = apps
            .filter { !appListCoordinator.isIgnored(identifier: $0.persistenceIdentifier) }
        let activeIdentifiers = Set(activeApps.map { $0.persistenceIdentifier })

        // Get pinned apps that are not currently active
        let pinnedInactiveInfos = appListCoordinator.pinnedAppInfo()
            .filter { !activeIdentifiers.contains($0.persistenceIdentifier) }

        // Pinned active apps (sorted alphabetically)
        let pinnedActive = activeApps
            .filter { appListCoordinator.isPinned(identifier: $0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        // Pinned inactive apps (sorted alphabetically)
        let pinnedInactive = pinnedInactiveInfos
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { DisplayableApp.pinnedInactive($0) }

        // Unpinned active apps (sorted alphabetically)
        let unpinnedActive = activeApps
            .filter { !appListCoordinator.isPinned(identifier: $0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        return pinnedActive + pinnedInactive + unpinnedActive
    }

    // MARK: - Pinning

    /// Pin an active app so it remains visible when inactive.
    func pinApp(_ app: AudioApp) {
        appListCoordinator.pinApp(app)
    }

    /// Unpin an app by its persistence identifier.
    func unpinApp(_ identifier: String) {
        appListCoordinator.unpinApp(identifier)
    }

    /// Check if an app is pinned.
    func isPinned(_ app: AudioApp) -> Bool {
        appListCoordinator.isPinned(app)
    }

    /// Check if an identifier is pinned (for inactive apps).
    func isPinned(identifier: String) -> Bool {
        appListCoordinator.isPinned(identifier: identifier)
    }

    // MARK: - Ignored Apps

    /// Hide an active app so FineTune ignores it entirely. Persists the ignore,
    /// then tears down the live tap so audio returns to natural volume.
    func ignoreApp(_ app: AudioApp) {
        appListCoordinator.recordIgnore(app)

        cancelProcessRebuild(for: app.id)
        if let tap = taps.removeValue(forKey: app.id) {
            tap.invalidate()
        }
        refreshMultiRouteDeviceUIDs()
        appDeviceRouting.removeValue(forKey: app.id)
        followsDefault.remove(app.id)
        appliedPIDs.remove(app.id)
    }

    /// Unhide an app by its persistence identifier.
    /// Immediately creates a tap if the app is currently running.
    func unignoreApp(_ identifier: String) {
        appListCoordinator.clearIgnore(identifier)
        applyPersistedSettings()
    }

    /// Check if an identifier is hidden.
    func isIgnored(identifier: String) -> Bool {
        appListCoordinator.isIgnored(identifier: identifier)
    }

    // MARK: - Inactive App Settings (by persistence identifier)

    func getVolumeForInactive(identifier: String) -> Float {
        appListCoordinator.getVolumeForInactive(identifier: identifier)
    }

    func setVolumeForInactive(identifier: String, to volume: Float) {
        appListCoordinator.setVolumeForInactive(identifier: identifier, to: volume)
    }

    func getBoostForInactive(identifier: String) -> BoostLevel {
        appListCoordinator.getBoostForInactive(identifier: identifier)
    }

    func setBoostForInactive(identifier: String, to boost: BoostLevel) {
        appListCoordinator.setBoostForInactive(identifier: identifier, to: boost)
    }

    func getMuteForInactive(identifier: String) -> Bool {
        appListCoordinator.getMuteForInactive(identifier: identifier)
    }

    func setMuteForInactive(identifier: String, to muted: Bool) {
        appListCoordinator.setMuteForInactive(identifier: identifier, to: muted)
    }

    func getEQSettingsForInactive(identifier: String) -> EQSettings {
        appListCoordinator.getEQSettingsForInactive(identifier: identifier)
    }

    func setEQSettingsForInactive(_ settings: EQSettings, identifier: String) {
        appListCoordinator.setEQSettingsForInactive(settings, identifier: identifier)
    }

    func getDeviceRoutingForInactive(identifier: String) -> String? {
        appListCoordinator.getDeviceRoutingForInactive(identifier: identifier)
    }

    func setDeviceRoutingForInactive(identifier: String, deviceUID: String?) {
        appListCoordinator.setDeviceRoutingForInactive(identifier: identifier, deviceUID: deviceUID)
    }

    func isFollowingDefaultForInactive(identifier: String) -> Bool {
        appListCoordinator.isFollowingDefaultForInactive(identifier: identifier)
    }

    func getDeviceSelectionModeForInactive(identifier: String) -> DeviceSelectionMode {
        appListCoordinator.getDeviceSelectionModeForInactive(identifier: identifier)
    }

    func setDeviceSelectionModeForInactive(identifier: String, to mode: DeviceSelectionMode) {
        appListCoordinator.setDeviceSelectionModeForInactive(identifier: identifier, to: mode, at: currentTime())
        if mode == .multi {
            seedInactiveMultiSelection(identifier: identifier)
        }
    }

    func getSelectedDeviceUIDsForInactive(identifier: String) -> Set<String> {
        appListCoordinator.getSelectedDeviceUIDsForInactive(identifier: identifier)
    }

    func setSelectedDeviceUIDsForInactive(identifier: String, to uids: Set<String>) {
        appListCoordinator.setSelectedDeviceUIDsForInactive(identifier: identifier, to: uids)
    }

    /// Audio levels for all active apps (for VU meter visualization)
    /// Returns a dictionary mapping PID to peak audio level (0-1)
    var audioLevels: [pid_t: Float] {
        var levels: [pid_t: Float] = [:]
        for (pid, tap) in taps {
            levels[pid] = tap.audioLevel
        }
        return levels
    }

    /// Get audio level for a specific app
    func getAudioLevel(for app: AudioApp) -> Float {
        taps[app.id]?.audioLevel ?? 0.0
    }

    func start() {
        // Monitors have internal guards against double-starting
        if permission.status == .authorized {
            processMonitor.start()
        }
        deviceMonitor.start()
        applyPersistedSettings()
        if permission.status == .authorized {
            startHealthMonitor()
        }

        // Restore locked input device if feature is enabled
        if settingsManager.appSettings.lockInputDevice {
            restoreLockedInputDevice()
        }

        logger.info("AudioEngine started")
    }

    func stop() {
        stopHealthMonitor()
        processMonitor.stop()
        deviceMonitor.stop()
        cancelAllProcessRebuilds()
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        refreshMultiRouteDeviceUIDs()
        // The Chrome tap is gone with the rest. The poll has stopped, so say so here.
        pollChromeTapLatency()
        logger.info("AudioEngine stopped")
    }

    /// Explicit shutdown for app termination. Ensures all listeners are cleaned up.
    /// Call from applicationWillTerminate or equivalent lifecycle hook.
    /// Note: For menu bar apps, process exit cleans up resources anyway, so this is optional.
    func shutdown() {
        stop()
        deviceVolumeMonitor.stop()
        logger.info("AudioEngine shutdown complete")
    }

    // MARK: - Settings Reset

    /// Resets all persisted settings and synchronizes in-memory engine state.
    /// Active taps are kept alive but reverted to defaults (unity volume, unmuted, flat EQ).
    func handleSettingsReset() {
        // 1. Clear persisted state
        settingsManager.resetAllSettings()

        // 2. Clear in-memory routing and tracking state
        appliedPIDs.removeAll()
        appDeviceRouting.removeAll()
        followsDefault.removeAll()

        // 3. Clear cached per-app audio state
        volumeState.resetAll()

        // 4. Refresh output state caches so software-backed devices reset to defaults.
        deviceVolumeMonitor.refreshOutputDeviceStates()

        // 5. Push defaults to all active taps
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
            tap.updateEQSettings(.flat)
            tap.updateAutoEQProfile(nil)
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: false)
        }

        // 6. Re-apply from clean settings (re-establishes routing to system default)
        applyPersistedSettings()

        // 7. The in-process player reads the cleared settings back (its own key was cleared in step 1)
        inProcessAudio?.settingsDidReset()

        logger.info("Settings reset: engine state synchronized")
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
        if let deviceUID = appDeviceRouting[app.id] {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
            if settingsManager.appSettings.loudnessCompensationEnabled {
                tap.updateLoudnessCompensation(
                    volume: effectiveLoudnessVolume(for: tap),
                    enabled: true
                )
            }
        }
    }

    func getVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    // MARK: - Boost

    func setBoost(for app: AudioApp, to boost: BoostLevel) {
        volumeState.setBoost(for: app.id, to: boost, identifier: app.persistenceIdentifier)
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }

    func getBoost(for app: AudioApp) -> BoostLevel {
        volumeState.getBoost(for: app.id)
    }

    /// Effective gain for ProcessTapController: app volume × boost, plus optional
    /// single-device software output gain for software-backed devices.
    /// Single-device-routed apps on `.software`-backed devices always receive the
    /// device's software gain; multi-destination routing keeps `appGain` alone
    /// because per-device software gain has no unambiguous meaning across fan-out.
    private func effectiveVolume(for pid: pid_t, deviceUIDs: [String]? = nil) -> Float {
        let appGain = volumeState.getVolume(for: pid) * volumeState.getBoost(for: pid).rawValue

        guard let resolvedUIDs = deviceUIDs, resolvedUIDs.count == 1,
              let primaryUID = resolvedUIDs.first,
              let device = deviceMonitor.device(for: primaryUID),
              outputVolumeBackend(for: device.id) == .software else {
            return appGain
        }

        return appGain * deviceVolumeMonitor.outputProcessingGain(for: device.id)
    }

    /// Estimated listening level for loudness compensation: device volume × per-app slider.
    /// Does not include boost (intentional amplification beyond reference).
    /// The compensator's phon estimation clamps to [0,1] so values > 1 are treated as reference.
    private func effectiveLoudnessVolume(for tap: any ProcessTapControlling) -> Float {
        tap.currentDeviceVolume * volumeState.getVolume(for: tap.app.id)
    }

    private func applyTapOutputState(to tap: any ProcessTapControlling, for pid: pid_t, deviceUIDs: [String]? = nil) {
        let resolvedUIDs = deviceUIDs ?? tap.currentDeviceUIDs
        tap.volume = effectiveVolume(for: pid, deviceUIDs: resolvedUIDs)
        tap.isMuted = volumeState.getMute(for: pid)

        if let primaryUID = resolvedUIDs.first,
           let device = deviceMonitor.device(for: primaryUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
        } else {
            tap.currentDeviceVolume = 1.0
            tap.isDeviceMuted = false
        }

        // Every tap device change ends here, so this is where the in-use set follows it.
        refreshMultiRouteDeviceUIDs()
    }

    /// Recomputes `multiRouteDeviceUIDs` and `multiRouteBundleIDs` from the live taps. Call after any change to
    /// `taps` or to a tap's devices. Assigns only on a real change so views reading the sets do not redraw for nothing.
    private func refreshMultiRouteDeviceUIDs() {
        var uids: Set<String> = []
        var bundleIDs: Set<String> = []
        for tap in taps.values where tap.currentDeviceUIDs.count > 1 {
            uids.formUnion(tap.currentDeviceUIDs)
            if let bundleID = tap.app.bundleID { bundleIDs.insert(bundleID) }
        }
        if uids != multiRouteDeviceUIDs {
            multiRouteDeviceUIDs = uids
        }
        if bundleIDs != multiRouteBundleIDs {
            multiRouteBundleIDs = bundleIDs
            onMultiRouteBundleIDsChange?(bundleIDs)
        }
    }

    private func refreshAllTapOutputStates() {
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }

    func toggleMute(for app: AudioApp) {
        let current = volumeState.getMute(for: app.id)
        setMute(for: app, to: !current)
    }

    func currentVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    func isMuted(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        volumeState.setMute(for: app.id, to: muted, identifier: app.persistenceIdentifier)
        taps[app.id]?.isMuted = muted
    }

    func getMute(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    /// Update EQ settings for an app
    func setEQSettings(_ settings: EQSettings, for app: AudioApp) {
        guard let tap = taps[app.id] else { return }
        tap.updateEQSettings(settings)
        settingsManager.setEQSettings(settings, for: app.persistenceIdentifier)
    }

    /// Get EQ settings for an app
    func getEQSettings(for app: AudioApp) -> EQSettings {
        return settingsManager.getEQSettings(for: app.persistenceIdentifier)
    }

    // MARK: - Per-Device AutoEQ

    func getAutoEQProfile(for deviceUID: String) -> AutoEQProfile? {
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    func setAutoEQProfile(for deviceUID: String, profileID: String?) {
        if let profileID {
            settingsManager.setAutoEQSelection(for: deviceUID, to: AutoEQSelection(profileID: profileID, isEnabled: true))
        } else {
            settingsManager.setAutoEQSelection(for: deviceUID, to: nil)
        }
        applyAutoEQToTaps(for: deviceUID)
    }

    func setAutoEQEnabled(for deviceUID: String, enabled: Bool) {
        guard var selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return }
        selection.isEnabled = enabled
        settingsManager.setAutoEQSelection(for: deviceUID, to: selection)
        applyAutoEQToTaps(for: deviceUID)
    }

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        settingsManager.getAutoEQSelection(for: deviceUID)
    }

    var autoEQPreampEnabled: Bool {
        settingsManager.autoEQPreampEnabled
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        settingsManager.autoEQPreampEnabled = enabled
        for tap in taps.values {
            tap.setAutoEQPreampEnabled(enabled)
        }
        inProcessAudio?.autoEQPreampChanged(enabled: enabled)
    }

    func setLoudnessCompensationEnabled(_ enabled: Bool) {
        for tap in taps.values {
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: enabled)
        }
        inProcessAudio?.loudnessCompensationChanged(enabled: enabled)
    }

    func setLoudnessEqualizationEnabled(_ enabled: Bool) {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = enabled
        for tap in taps.values {
            tap.updateLoudnessEqualization(settings)
        }
        inProcessAudio?.loudnessEqualizationChanged(enabled: enabled)
    }

    /// Apply AutoEQ profile to all taps currently routed to the given device.
    private func applyAutoEQToTaps(for deviceUID: String) {
        inProcessAudio?.autoEQSelectionChanged(deviceUID: deviceUID)
        for tap in taps.values {
            guard tap.currentDeviceUID == deviceUID else { continue }
            applyAutoEQToTap(tap)
        }
    }

    /// The AutoEQ profile in effect for audio played on `deviceUID`, from memory. nil when the device does not support
    /// AutoEQ, has no selection, the selection is off, or the profile is not cached yet (see `resolveActiveAutoEQProfile`).
    func activeAutoEQProfile(for deviceUID: String) -> AutoEQProfile? {
        autoEQProfileForActivation(deviceUID: deviceUID)
    }

    /// Same rules as `activeAutoEQProfile`, but fetches or loads the profile when it is not cached yet.
    func resolveActiveAutoEQProfile(for deviceUID: String) async -> AutoEQProfile? {
        guard let device = deviceMonitor.device(for: deviceUID), device.supportsAutoEQ else { return nil }
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID), selection.isEnabled else { return nil }
        return await autoEQProfileManager.resolveProfile(for: selection.profileID)
    }

    /// Synchronous in-memory AutoEQ profile lookup. nil = not yet cached.
    private func autoEQProfileForActivation(deviceUID: String) -> AutoEQProfile? {
        guard let device = deviceMonitor.device(for: deviceUID), device.supportsAutoEQ else { return nil }
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID), selection.isEnabled else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    private func tapInitialState(forApp app: AudioApp, primaryDeviceUID: String, deviceVolume: Float) -> TapInitialState {
        var loudnessEqSettings = LoudnessEqualizerSettings()
        loudnessEqSettings.enabled = settingsManager.appSettings.loudnessEqualizationEnabled
        return TapInitialState(
            eqSettings: settingsManager.getEQSettings(for: app.persistenceIdentifier),
            autoEQProfile: autoEQProfileForActivation(deviceUID: primaryDeviceUID),
            autoEQPreampEnabled: settingsManager.autoEQPreampEnabled,
            loudnessVolume: deviceVolume * volumeState.getVolume(for: app.id),
            loudnessCompensationEnabled: settingsManager.appSettings.loudnessCompensationEnabled,
            loudnessEqualizerSettings: loudnessEqSettings
        )
    }

    /// Skips AutoEQ entirely for devices that don't support it (speakers, HDMI, etc.).
    /// If the profile isn't loaded yet, triggers an async fetch and applies when ready.
    private func applyAutoEQToTap(_ tap: any ProcessTapControlling) {
        guard let deviceUID = tap.currentDeviceUID else { return }

        // Skip AutoEQ for non-headphone devices (or if device not found in monitor)
        guard let device = deviceMonitor.device(for: deviceUID) else {
            logger.debug("AutoEQ skip for \(tap.app.name): device \(deviceUID) not found in monitor")
            return
        }
        guard device.supportsAutoEQ else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): \(device.name) doesn't support AutoEQ")
            return
        }

        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID),
              selection.isEnabled else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): no selection or disabled for \(device.name)")
            return
        }

        // Try in-memory first (instant)
        if let profile = autoEQProfileManager.profile(for: selection.profileID) {
            tap.updateAutoEQProfile(profile)
            return
        }

        // Profile not loaded yet — fetch asynchronously
        tap.updateAutoEQProfile(nil)
        Task { @MainActor in
            guard let profile = await autoEQProfileManager.resolveProfile(for: selection.profileID) else { return }
            // Verify tap still exists and is still routed to the same device
            guard tap.currentDeviceUID == deviceUID else { return }
            guard let latestSelection = settingsManager.getAutoEQSelection(for: deviceUID),
                  latestSelection.profileID == selection.profileID,
                  latestSelection.isEnabled else { return }
            tap.updateAutoEQProfile(profile)
        }
    }

    /// Sets the system default output device, routes followsDefault apps, and registers
    /// an echo so the resulting CoreAudio callback is consumed rather than treated as
    /// an external change.
    /// UI code should call this instead of `deviceVolumeMonitor.setDefaultDevice` directly.
    @discardableResult
    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceVolumeMonitor.setDefaultDevice(deviceID) else { return false }
        if let uid = deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid {
            outputEchoTracker.increment(uid)
            lastConfirmedDefaultUID = uid
            routeFollowsDefaultApps(to: uid)
        }
        return true
    }

    /// Sets the output device for an app.
    /// - Parameters:
    ///   - app: The app to route
    ///   - deviceUID: The device UID to route to, or nil to follow system default
    func setDevice(for app: AudioApp, deviceUID: String?) {
        if let deviceUID = deviceUID {
            // Explicit device selection - stop following default
            followsDefault.remove(app.id)
            // Defensive: re-persist routing even if in-memory state matches,
            // to guard against settings file corruption or incomplete prior writes
            settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)

            // If transitioning from follows-default to explicit and tap has a stream-specific
            // source, refresh to mixdown so it won't go stale when the default changes later.
            if let tap = taps[app.id], tap.tapSourceDeviceUID != nil {
                Task {
                    do {
                        try await tap.refreshTapSource(nil)
                        self.applyTapOutputState(to: tap, for: app.id)
                    } catch {
                        self.logger.error("Failed to refresh tap source for \(app.name): \(error)")
                    }
                }
            }

            guard appDeviceRouting[app.id] != deviceUID else { return }
            appDeviceRouting[app.id] = deviceUID
        } else {
            // "System Audio" selected - follow default
            followsDefault.insert(app.id)
            settingsManager.setFollowDefault(for: app.persistenceIdentifier)

            // Route to current default (if available)
            guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                // No default available yet - routing will happen when default becomes available
                // via handleDefaultDeviceChanged callback
                logger.warning("No default device available for \(app.name), will route when available")
                return
            }
            guard appDeviceRouting[app.id] != defaultUID else { return }
            appDeviceRouting[app.id] = defaultUID
        }

        // Switch tap if needed
        guard let targetUID = appDeviceRouting[app.id] else { return }
        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: tapSourceFollowsDefault(app.id))
        if let tap = taps[app.id] {
            Task {
                do {
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    self.applyTapOutputState(to: tap, for: app.id, deviceUIDs: [targetUID])
                    self.applyAutoEQToTap(tap)
                    self.logger.debug("Switched \(app.name) to device: \(targetUID)")
                } catch {
                    self.logger.error("Failed to switch device for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            ensureTapExists(for: app, deviceUID: targetUID)
        }
    }

    func getDeviceUID(for app: AudioApp) -> String? {
        appDeviceRouting[app.id]
    }

    /// Returns true if the app follows system default device
    func isFollowingDefault(for app: AudioApp) -> Bool {
        followsDefault.contains(app.id)
    }

    // MARK: - Multi-Device Selection

    /// Gets the device selection mode for an app
    func getDeviceSelectionMode(for app: AudioApp) -> DeviceSelectionMode {
        volumeState.getDeviceSelectionMode(for: app.id)
    }

    /// Sets the device selection mode for an app.
    /// Triggers tap reconfiguration when mode changes.
    func setDeviceSelectionMode(for app: AudioApp, to mode: DeviceSelectionMode) {
        let previousMode = volumeState.getDeviceSelectionMode(for: app.id)
        volumeState.setDeviceSelectionMode(for: app.id, to: mode, identifier: app.persistenceIdentifier, at: currentTime())

        guard previousMode != mode else { return }

        if mode == .multi {
            seedMultiSelection(for: app)
        }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Ticks the device(s) the app is playing on when it enters multi mode with no selection, so the
    /// dropdown opens with the current output checked and the tap keeps playing there. A selection
    /// already in memory or saved by an earlier session is left alone. Writes synchronously, so
    /// the picker sees the seed in the same update that shows the mode change.
    private func seedMultiSelection(for app: AudioApp) {
        guard getSelectedDeviceUIDs(for: app).isEmpty else { return }
        if let saved = volumeState.loadSavedSelectedDeviceUIDs(for: app.id, identifier: app.persistenceIdentifier),
           !saved.isEmpty {
            return
        }

        let playingOn: [String]
        if let tap = taps[app.id], !tap.currentDeviceUIDs.isEmpty {
            playingOn = tap.currentDeviceUIDs
        } else if let deviceUID = singleModeDeviceUID(for: app) {
            playingOn = [deviceUID]
        } else {
            return
        }
        volumeState.setSelectedDeviceUIDs(for: app.id, to: Set(playingOn), identifier: app.persistenceIdentifier)
    }

    /// The device a single-mode app plays on: the system default while it follows the default,
    /// else its routed device, else the default.
    private func singleModeDeviceUID(for app: AudioApp) -> String? {
        if isFollowingDefault(for: app), let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
            return defaultUID
        }
        return appDeviceRouting[app.id] ?? deviceVolumeMonitor.defaultDeviceUID
    }

    /// The inactive-app twin of `seedMultiSelection`: an inactive app flipped to multi with nothing
    /// saved gets its pinned device ticked, or the system default while it follows the default or
    /// its pin is away (it would launch on the default then). The flip is a settings write only,
    /// so without this the selection stays empty until the user ticks something.
    private func seedInactiveMultiSelection(identifier: String) {
        guard (settingsManager.getSelectedDeviceUIDs(for: identifier) ?? []).isEmpty else { return }
        let pinnedUID = settingsManager.getDeviceRouting(for: identifier).flatMap { isOutputConnected($0) ? $0 : nil }
        guard let deviceUID = pinnedUID ?? deviceVolumeMonitor.defaultDeviceUID else { return }
        appListCoordinator.setSelectedDeviceUIDsForInactive(identifier: identifier, to: [deviceUID])
    }

    /// Whether an output device is connected right now. Reads the list the disconnect fallback is
    /// picked from, so it agrees with the monitor's connect and disconnect callbacks.
    private func isOutputConnected(_ uid: String) -> Bool {
        outputDevices.contains { $0.uid == uid }
    }

    /// Whether a multi app plays on a route of its own: it is in multi mode and at least one device
    /// it selected is connected. A multi app with none left (or none picked) plays on the fallback,
    /// the system default, and counts as an ordinary follow-default app until a device returns.
    private func isOnOwnMultiRoute(_ pid: pid_t) -> Bool {
        guard volumeState.getDeviceSelectionMode(for: pid) == .multi else { return false }
        return volumeState.getSelectedDeviceUIDs(for: pid).contains(where: isOutputConnected)
    }

    /// Whether the app's tap is the stream-specific one on the default device. A multi app on a route of its own stays in
    /// `followsDefault` but never follows a default change, so a tap tied to the default device would go stale; it gets
    /// the stereo mixdown instead.
    private func tapSourceFollowsDefault(_ pid: pid_t) -> Bool {
        followsDefault.contains(pid) && !isOnOwnMultiRoute(pid)
    }

    /// Gets the selected device UIDs for multi-mode
    func getSelectedDeviceUIDs(for app: AudioApp) -> Set<String> {
        volumeState.getSelectedDeviceUIDs(for: app.id)
    }

    /// Sets the selected device UIDs for multi-mode.
    /// Triggers tap reconfiguration when in multi mode.
    ///
    /// This is the user's edit, and it wins: every connected device is ticked or not as the edit
    /// says, and that is what plays and what is saved. The picker lists connected devices only, so
    /// a device that is away can be neither ticked nor unticked there. The edit does not mention it,
    /// so the saved selection keeps it and it rejoins when it returns.
    func setSelectedDeviceUIDs(for app: AudioApp, to uids: Set<String>) {
        let previousUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
        let awayUIDs = (settingsManager.getSelectedDeviceUIDs(for: app.persistenceIdentifier) ?? [])
            .filter { !isOutputConnected($0) }
        volumeState.setSelectedDeviceUIDs(for: app.id, to: uids, identifier: app.persistenceIdentifier, persist: false)
        settingsManager.setSelectedDeviceUIDs(for: app.persistenceIdentifier, to: uids.union(awayUIDs))

        guard previousUIDs != uids,
              getDeviceSelectionMode(for: app) == .multi else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Updates tap configuration based on current mode and selected devices
    private func updateTapForCurrentMode(for app: AudioApp) async {
        let mode = getDeviceSelectionMode(for: app)

        let deviceUIDs: [String]
        switch mode {
        case .single:
            guard let deviceUID = singleModeDeviceUID(for: app) else {
                logger.warning("No device available for \(app.name) in single mode")
                return
            }
            // Default changes skipped this app while it was multi, so catch its routing up.
            if isFollowingDefault(for: app) {
                appDeviceRouting[app.id] = deviceUID
            }
            deviceUIDs = [deviceUID]

        case .multi:
            // A selected device that is away cannot carry audio; handleDeviceConnected adds it back.
            let selectedUIDs = getSelectedDeviceUIDs(for: app).filter(isOutputConnected).sorted()
            if selectedUIDs.isEmpty {
                return
            }
            deviceUIDs = selectedUIDs
        }

        // Update or create tap with the device set
        if let tap = taps[app.id] {
            // Tap exists - update devices
            if tap.currentDeviceUIDs != deviceUIDs {
                do {
                    let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: tapSourceFollowsDefault(app.id))
                    try await tap.updateDevices(to: deviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)
                    logger.debug("Updated \(app.name) to \(deviceUIDs.count) device(s)")
                } catch {
                    logger.error("Failed to update devices for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            // No tap exists - create one
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
        }
    }

    /// Creates a tap with the specified device UIDs
    private func ensureTapWithDevices(for app: AudioApp, deviceUIDs: [String]) {
        guard !deviceUIDs.isEmpty else { return }
        guard taps[app.id] == nil else { return }
        guard permission.status == .authorized else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: tapSourceFollowsDefault(app.id))
        do {
            let tap = try tapFactory(app, deviceUIDs, preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)

            let initial = tapInitialState(
                forApp: app,
                primaryDeviceUID: deviceUIDs[0],
                deviceVolume: tap.currentDeviceVolume
            )
            try tap.activate(initial: initial)
            taps[app.id] = tap
            refreshMultiRouteDeviceUIDs()

            // Catalog AutoEQ may not have been cached yet — kick off async resolve.
            if initial.autoEQProfile == nil {
                applyAutoEQToTap(tap)
            }

            logger.debug("Created tap for \(app.name) on \(deviceUIDs.count) device(s)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    func applyPersistedSettings() {
        guard permission.status == .authorized else { return }

        // Warm the AutoEQ cache for every (app, device) selection so that subsequent
        // tap activations can apply correction synchronously inside activate(initial:)
        // instead of falling back to the async resolve path. Imported profiles are
        // already loaded by AutoEQProfileManager.init.
        let selectedProfileIDs: Set<String> = Set(apps.compactMap { app -> String? in
            let deviceUID = appDeviceRouting[app.id] ?? deviceVolumeMonitor.defaultDeviceUID
            guard let deviceUID, let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
            return selection.isEnabled ? selection.profileID : nil
        })
        let manager = autoEQProfileManager
        Task { @MainActor in
            for id in selectedProfileIDs where manager.profile(for: id) == nil {
                _ = await manager.resolveProfile(for: id)
            }
        }

        for app in apps {
            guard !appliedPIDs.contains(app.id) else { continue }
            guard !settingsManager.isIgnored(app.persistenceIdentifier) else { continue }

            // Load saved device selection mode (single vs multi)
            let savedMode = volumeState.loadSavedDeviceSelectionMode(for: app.id, identifier: app.persistenceIdentifier)
            let mode = savedMode ?? .single

            // Load saved volume, mute, and boost state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)
            _ = volumeState.loadSavedBoost(for: app.id, identifier: app.persistenceIdentifier)

            // Handle multi-device mode
            if mode == .multi {
                if let savedUIDs = volumeState.loadSavedSelectedDeviceUIDs(for: app.id, identifier: app.persistenceIdentifier),
                   !savedUIDs.isEmpty {
                    // Filter to currently available devices, maintaining deterministic order
                    let availableUIDs = savedUIDs.filter { deviceMonitor.device(for: $0) != nil }
                        .sorted()  // Deterministic ordering
                    // The live selection is what is connected; the saved one keeps the rest for when
                    // they appear (handleDeviceConnected).
                    volumeState.setSelectedDeviceUIDs(for: app.id, to: Set(availableUIDs), identifier: app.persistenceIdentifier, persist: false)
                    if !availableUIDs.isEmpty {
                        logger.debug("Restoring multi-device mode for \(app.name) with \(availableUIDs.count) device(s)")
                        ensureTapWithDevices(for: app, deviceUIDs: availableUIDs)

                        // Mark as applied if tap created successfully
                        guard taps[app.id] != nil else { continue }
                        // Set primary device routing so the UI row renders
                        appDeviceRouting[app.id] = availableUIDs[0]
                        appliedPIDs.insert(app.id)

                        // Apply volume (with boost) and mute
                        if savedVolume != nil {
                            if let tap = taps[app.id] {
                                applyTapOutputState(to: tap, for: app.id, deviceUIDs: availableUIDs)
                            }
                        }
                        if let muted = savedMute, muted {
                            taps[app.id]?.isMuted = true
                        }
                        continue  // Skip single-device path
                    }
                    // All saved devices unavailable - fall through to single-device mode
                    logger.debug("All multi-mode devices unavailable for \(app.name), falling back to single mode")
                }
            }

            // Single-device mode (or multi-mode fallback)
            let deviceUID: String
            if settingsManager.isFollowingDefault(for: app.persistenceIdentifier) {
                // App follows system default (new app or explicitly set to follow)
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device available for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) follows system default: \(deviceUID)")
            } else if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
                      deviceMonitor.device(for: savedDeviceUID) != nil {
                // Explicit device routing exists and device is available
                deviceUID = savedDeviceUID
                logger.debug("Applying saved device routing to \(app.name): \(deviceUID)")
            } else {
                // Saved device temporarily unavailable: fall back to system default for now
                // Don't persist - keep original device preference for when it reconnects
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) device temporarily unavailable, using default: \(deviceUID)")
            }
            appDeviceRouting[app.id] = deviceUID

            // If a tap already exists but is on the wrong device (e.g., app reappeared
            // after the default changed while it was absent), switch it.
            if let existingTap = taps[app.id], existingTap.currentDeviceUIDs != [deviceUID] {
                let preferredSource = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: tapSourceFollowsDefault(app.id))
                Task {
                    do {
                        try await existingTap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredSource)
                        self.applyTapOutputState(to: existingTap, for: app.id, deviceUIDs: [deviceUID])
                        self.applyAutoEQToTap(existingTap)
                    } catch {
                        self.logger.error("Failed to re-route \(app.name) to \(deviceUID): \(error.localizedDescription)")
                    }
                }
                appliedPIDs.insert(app.id)
                continue
            }

            // Always create tap for audio apps (always-on strategy)
            ensureTapExists(for: app, deviceUID: deviceUID)

            // Only mark as applied if tap was successfully created
            // This allows retry on next applyPersistedSettings() call if tap failed
            guard taps[app.id] != nil else { continue }
            appliedPIDs.insert(app.id)

            if savedVolume != nil {
                let effective = effectiveVolume(for: app.id, deviceUIDs: [deviceUID])
                let displayPercent = Int(effective * 100)
                logger.debug("Applying saved volume \(displayPercent)% (with boost) to \(app.name)")
                taps[app.id]?.volume = effective
            }

            if let muted = savedMute, muted {
                logger.debug("Applying saved mute state to \(app.name)")
                taps[app.id]?.isMuted = true
            }
        }
    }

    private func ensureTapExists(for app: AudioApp, deviceUID: String) {
        guard taps[app.id] == nil else { return }
        guard permission.status == .authorized else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: tapSourceFollowsDefault(app.id))
        do {
            let tap = try tapFactory(app, [deviceUID], preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: [deviceUID])

            let initial = tapInitialState(
                forApp: app,
                primaryDeviceUID: deviceUID,
                deviceVolume: tap.currentDeviceVolume
            )
            try tap.activate(initial: initial)
            taps[app.id] = tap
            refreshMultiRouteDeviceUIDs()

            // Catalog AutoEQ may not have been cached yet — kick off async resolve.
            // Imported profiles always hit the synchronous path above.
            if initial.autoEQProfile == nil {
                applyAutoEQToTap(tap)
            }

            logger.debug("Created tap for \(app.name)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Restores the default to `lastConfirmedDefaultUID` (what the user/FineTune intended).
    /// Falls back to highest-priority device if the confirmed device is gone.
    private func restoreConfirmedDefault() {
        if let restoreUID = lastConfirmedDefaultUID,
           let device = deviceMonitor.device(for: restoreUID),
           isAliveCheck(device.id) {
            if deviceVolumeMonitor.defaultDeviceUID != restoreUID {
                if deviceVolumeMonitor.setDefaultDevice(device.id) {
                    outputEchoTracker.increment(restoreUID)
                    logger.info("Restored default → \(device.name)")
                }
            }
            routeFollowsDefaultApps(to: restoreUID)
        } else {
            reEvaluateOutputDefault()
        }
    }

    /// Ensures system default matches highest-priority alive connected device.
    /// Routes followsDefault apps and switches their taps if default changes.
    /// Returns the resolved target UID.
    @discardableResult
    private func reEvaluateOutputDefault(excluding: String? = nil, skipping skippedPIDs: Set<pid_t> = []) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        if target.uid != currentDefault {
            if deviceVolumeMonitor.setDefaultDevice(target.id) {
                outputEchoTracker.increment(target.uid)
                logger.info("System default → \(target.name)")
            }
        }

        lastConfirmedDefaultUID = target.uid
        routeFollowsDefaultApps(to: target.uid, skipping: skippedPIDs)
        return target.uid
    }

    /// Ensures system default input matches highest-priority alive connected input device.
    /// Returns the resolved target UID.
    @discardableResult
    private func reEvaluateInputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        if target.uid != deviceVolumeMonitor.defaultInputDeviceUID {
            if deviceVolumeMonitor.setDefaultInputDevice(target.id) {
                inputEchoTracker.increment(target.uid)
                logger.info("Default input → \(target.name)")
            }
        }
        return target.uid
    }

    /// Routes all followsDefault apps to the given device UID and switches their taps.
    /// Apps on a multi route of their own keep their device set: they stay in followsDefault (so
    /// switching back to single mode follows the default again) but are never moved here. A multi
    /// app with none of its devices connected is on the fallback and moves like a single app.
    /// Early-exits if all apps are already routed to the target (avoids unnecessary tap switches).
    /// `skippedPIDs` are apps whose tap another switch is already moving (a Multi app that just went back to Single):
    /// their routing is set like the rest, but their tap is not switched a second time.
    private func routeFollowsDefaultApps(to targetUID: String, skipping skippedPIDs: Set<pid_t> = []) {
        let movable = followsDefault.filter { !isOnOwnMultiRoute($0) }
        guard !movable.allSatisfy({ appDeviceRouting[$0] == targetUID }) else { return }

        for pid in movable {
            appDeviceRouting[pid] = targetUID
        }

        // Walk the taps, not the monitor's list: a paused app drops out of the list but keeps
        // its tap while the process lives, and that tap must follow the default too or the
        // app would resume on the old device (appliedPIDs blocks any later re-route).
        var tapsToSwitch: [(app: AudioApp, tap: any ProcessTapControlling)] = []
        for pid in taps.keys.sorted() {
            guard movable.contains(pid), !skippedPIDs.contains(pid), let tap = taps[pid] else { continue }
            tapsToSwitch.append((tap.app, tap))
        }
        guard !tapsToSwitch.isEmpty else { return }

        Task {
            for (app, tap) in tapsToSwitch {
                do {
                    let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: true)
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    self.applyTapOutputState(to: tap, for: app.id, deviceUIDs: [targetUID])
                    self.applyAutoEQToTap(tap)
                } catch {
                    self.logger.error("Failed to switch \(app.name) to \(targetUID): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Takes a disconnected device out of a multi app's live selection. In memory only: the saved
    /// selection keeps the device, so a Bluetooth drop does not remove it from the route for good and
    /// `handleDeviceConnected` can put it back.
    private func dropFromLiveSelection(_ deviceUID: String, for app: AudioApp) {
        var selection = volumeState.getSelectedDeviceUIDs(for: app.id)
        guard selection.remove(deviceUID) != nil else { return }
        volumeState.setSelectedDeviceUIDs(for: app.id, to: selection, identifier: nil, persist: false)
    }

    /// An app that went back to Single because a device of its Multi selection disconnected.
    private struct MultiRevert {
        let app: AudioApp
        /// Where the app plays now, nil when no output device is available.
        let targetUID: String?
        /// Whether it is on System Audio, so its tap is the stream-specific one on the default device.
        let followsDefault: Bool
    }

    /// Sends every active app in Multi mode with `deviceUID` in its selection back to Single, right away, even when
    /// other selected devices are still connected. Within `MultiOutputRevert.rememberWindow` of entering Multi it
    /// returns to its pre-Multi single setting: its saved device, or System Audio if it followed the default. Longer, or
    /// with no recorded start, it goes to System Audio and the saved device is cleared. A saved device that is itself
    /// away is kept, and the app plays on the default meanwhile, as in Single mode today. Both the live and the saved
    /// selection are left as they are, and nothing rejoins when the device returns. Updates the mode, the saved
    /// settings and the in-memory routing; the caller switches the taps.
    private func revertMultiApps(afterDisconnectOf deviceUID: String, fallbackDevice: AudioDevice?) -> [MultiRevert] {
        var candidates: [pid_t: AudioApp] = [:]
        for tap in taps.values { candidates[tap.app.id] = tap.app }
        for app in apps where candidates[app.id] == nil { candidates[app.id] = app }

        // System Audio: the current default, unless that is the device that just went away.
        let systemAudioUID: String? = {
            if let current = deviceVolumeMonitor.defaultDeviceUID, current != deviceUID, isOutputConnected(current) {
                return current
            }
            return fallbackDevice?.uid
        }()

        // Processes of one app share its saved settings: the first one decides, because leaving Multi clears the start.
        var decided: [String: (target: MultiOutputRevert.Target, savedDeviceUID: String?)] = [:]
        var reverts: [MultiRevert] = []
        for pid in candidates.keys.sorted() {
            guard let app = candidates[pid] else { continue }
            let identifier = app.persistenceIdentifier
            let mode = volumeState.getDeviceSelectionMode(for: pid) == .multi
                ? DeviceSelectionMode.multi
                : settingsManager.getDeviceSelectionMode(for: identifier)
            let selected = volumeState.getSelectedDeviceUIDs(for: pid)
                .union(settingsManager.getSelectedDeviceUIDs(for: identifier) ?? [])
            guard MultiOutputRevert.disconnectAffects(mode: mode, selected: selected, uid: deviceUID) else { continue }

            // Read both before the mode changes: leaving Multi clears the start.
            let decision = decided[identifier] ?? (
                target: MultiOutputRevert.target(multiSince: settingsManager.getMultiOutputSince(for: identifier), now: currentTime()),
                savedDeviceUID: settingsManager.getDeviceRouting(for: identifier)
            )
            decided[identifier] = decision
            let target = decision.target
            let savedDeviceUID = decision.savedDeviceUID
            volumeState.setDeviceSelectionMode(for: pid, to: .single, identifier: identifier, at: currentTime())

            let placed = applyRevertTarget(
                target, to: pid, identifier: identifier, savedDeviceUID: savedDeviceUID,
                droppedUID: deviceUID, systemAudioUID: systemAudioUID
            )
            if placed.uid == nil {
                logger.error("No device available for \(app.name) after it left Multi")
            }
            reverts.append(MultiRevert(app: app, targetUID: placed.uid, followsDefault: placed.onSystemAudio))
        }
        return reverts
    }

    /// Where a reverted app plays, and the bookkeeping that goes with it, in memory and in the saved settings. System
    /// Audio follows the default and clears the saved device. The pre-Multi single setting keeps a saved device that is
    /// connected; a saved device that is away (or is the one that just dropped) stays the saved choice, and meanwhile the
    /// app plays on System Audio in memory, as in Single mode today. Returns the device it plays on now (nil when none is
    /// available) and whether that is System Audio.
    private func applyRevertTarget(
        _ target: MultiOutputRevert.Target, to pid: pid_t, identifier: String,
        savedDeviceUID: String?, droppedUID: String, systemAudioUID: String?
    ) -> (uid: String?, onSystemAudio: Bool) {
        var destination = systemAudioUID
        var onSystemAudio = true
        switch target {
        case .systemAudio:
            settingsManager.setFollowDefault(for: identifier)
            followsDefault.insert(pid)
        case .previousSingle:
            if let savedDeviceUID, savedDeviceUID != droppedUID, isOutputConnected(savedDeviceUID) {
                followsDefault.remove(pid)
                destination = savedDeviceUID
                onSystemAudio = false
            } else {
                // It followed the default, or its device is away: the saved choice is untouched, and in memory the app
                // plays on the default until the device is back (handleDeviceConnected restores a saved pin).
                followsDefault.insert(pid)
            }
        }
        if let destination {
            appDeviceRouting[pid] = destination
        }
        return (destination, onSystemAudio)
    }

    /// The saved-settings half of `revertMultiApps`, for items with no live app: inactive pinned apps. The music
    /// player is left out, since its mixer reverts itself.
    private func revertMultiSettings(afterDisconnectOf deviceUID: String) {
        for identifier in settingsManager.multiOutputIdentifiers(containing: deviceUID).sorted()
        where identifier != MusicMixerState.settingsKey {
            let target = MultiOutputRevert.target(multiSince: settingsManager.getMultiOutputSince(for: identifier), now: currentTime())
            settingsManager.setDeviceSelectionMode(for: identifier, to: .single, at: currentTime())
            if target == .systemAudio { settingsManager.setFollowDefault(for: identifier) }
        }
    }

    /// Called when device disappears - updates routing and switches taps immediately
    private func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
        // Clean up alive watcher — use UID lookup since device is already removed from monitor
        removeAliveWatcher(forUID: deviceUID)

        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = outputPriorityState, uid == deviceUID {
            task.cancel()
            outputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultOutput = deviceUID == deviceVolumeMonitor.defaultDeviceUID

        // Use priority-based fallback (resolve checks isDeviceAlive internally)
        let fallbackDevice = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        var affectedApps: [AudioApp] = []
        // Where the affected apps went, for the notification, each place once.
        var destinationNames: [String] = []
        func noteDestination(_ name: String) {
            if !destinationNames.contains(name) { destinationNames.append(name) }
        }
        var singleModeTapsToSwitch: [(tap: any ProcessTapControlling, targetUID: String, followsDefault: Bool, sourceDead: Bool)] = []
        var multiModeTapsToUpdate: [(tap: any ProcessTapControlling, remainingUIDs: [String])] = []

        // Multi apps that had this device selected go back to Single first, so the loop below sees them as single
        // apps already handled. The other devices of their selection do not keep them in Multi.
        let reverts = revertMultiApps(afterDisconnectOf: deviceUID, fallbackDevice: fallbackDevice)
        var revertedPIDs: Set<pid_t> = []
        for revert in reverts {
            revertedPIDs.insert(revert.app.id)
            guard let tap = taps[revert.app.id], let targetUID = revert.targetUID else { continue }
            let wasOnDevice = tap.currentDeviceUIDs.contains(deviceUID)
            if wasOnDevice {
                affectedApps.append(revert.app)
                noteDestination(revert.followsDefault ? "System Audio" : (outputDevices.first { $0.uid == targetUID }?.name ?? targetUID))
            }
            if tap.currentDeviceUIDs != [targetUID] {
                singleModeTapsToSwitch.append((tap: tap, targetUID: targetUID, followsDefault: revert.followsDefault, sourceDead: wasOnDevice))
            }
        }
        revertMultiSettings(afterDisconnectOf: deviceUID)

        // Iterate over taps instead of apps - apps list may be empty if disconnected device
        // was the system default (CoreAudio removes app from process list when output disappears)
        for tap in taps.values {
            let app = tap.app
            let mode = getDeviceSelectionMode(for: app)

            // Already back on Single above
            guard !revertedPIDs.contains(app.id) else { continue }

            // Check if this tap uses the disconnected device
            guard tap.currentDeviceUIDs.contains(deviceUID) else { continue }

            affectedApps.append(app)
            noteDestination(fallbackDevice?.name ?? "none")

            if mode == .multi && tap.currentDeviceUIDs.count > 1 {
                // Multi-device mode: remove disconnected device, keep others
                let remainingUIDs = tap.currentDeviceUIDs.filter { $0 != deviceUID }.sorted()
                if !remainingUIDs.isEmpty {
                    multiModeTapsToUpdate.append((tap: tap, remainingUIDs: remainingUIDs))
                    dropFromLiveSelection(deviceUID, for: app)
                    continue
                }
                // All devices gone in multi-mode, fall through to single-device fallback
            }

            // Single-device mode (or multi-mode with no remaining devices): switch to fallback
            if mode == .multi {
                dropFromLiveSelection(deviceUID, for: app)
            }
            if let fallback = fallbackDevice {
                appDeviceRouting[app.id] = fallback.uid
                // Set to follow default in-memory (UI shows "System Audio")
                // Don't persist - original device preference stays in settings for reconnection
                followsDefault.insert(app.id)
                singleModeTapsToSwitch.append((tap: tap, targetUID: fallback.uid, followsDefault: true, sourceDead: true))
            } else {
                logger.error("No fallback device available for \(app.name)")
            }
        }

        // Execute device switches
        if !singleModeTapsToSwitch.isEmpty || !multiModeTapsToUpdate.isEmpty {
            Task {
                // Handle single-mode switches (and Multi apps back on Single). When the tap was on the dead
                // device its source is dead, skip crossfade.
                for (tap, targetUID, onSystemAudio, sourceDead) in singleModeTapsToSwitch {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: onSystemAudio)
                        try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID, sourceDeviceDead: sourceDead)
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: [targetUID])
                        self.applyAutoEQToTap(tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) to fallback: \(error.localizedDescription)")
                    }
                }

                // Handle multi-mode updates (remove disconnected device from aggregate)
                // Source device is dead, skip crossfade
                for (tap, remainingUIDs) in multiModeTapsToUpdate {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: remainingUIDs, isFollowsDefault: self.tapSourceFollowsDefault(tap.app.id))
                        try await tap.updateDevices(to: remainingUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID, sourceDeviceDead: true)
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: remainingUIDs)
                        self.logger.debug("Removed \(deviceName) from \(tap.app.name) multi-device output")
                    } catch {
                        self.logger.error("Failed to update \(tap.app.name) devices: \(error.localizedDescription)")
                    }
                }
            }
        }

        if !reverts.isEmpty {
            logger.info("\(deviceName) disconnected, \(reverts.count) Multi app(s) went back to Single")
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) disconnected, \(affectedApps.count) app(s) affected")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showDisconnectNotification(deviceName: deviceName, destinations: destinationNames, affectedApps: affectedApps)
            }
        }

        // If the disconnected device was the system default, override to priority fallback. The taps of the apps that
        // just went back to Single are already being moved; they are not switched a second time.
        if wasDefaultOutput {
            reEvaluateOutputDefault(excluding: deviceUID, skipping: revertedPIDs)
        }
    }

    /// Called when a device appears - switches pinned apps back to their preferred device
    private func handleDeviceConnected(_ deviceUID: String, name deviceName: String) {
        // Register newly connected device in priority list
        settingsManager.ensureDeviceInPriority(deviceUID)

        var affectedApps: [AudioApp] = []
        var tapsToSwitch: [any ProcessTapControlling] = []

        // Iterate over taps for consistency with handleDeviceDisconnected
        for tap in taps.values {
            let app = tap.app

            // A multi app plays on its own device set; the single-device routing left in settings
            // from before it was switched to multi must not collapse it onto the reconnected device.
            guard volumeState.getDeviceSelectionMode(for: app.id) != .multi else { continue }

            // Skip apps that are PERSISTED as following default - they don't have explicit device preferences
            // Note: in-memory followsDefault may include temporarily displaced apps, so check persisted state
            guard !settingsManager.isFollowingDefault(for: app.persistenceIdentifier) else { continue }

            // Check if this app was pinned to the reconnected device (from persisted settings)
            let persistedUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier)
            guard persistedUID == deviceUID else { continue }

            // App was pinned to this device - switch it back
            guard appDeviceRouting[app.id] != deviceUID else { continue }

            affectedApps.append(app)
            appDeviceRouting[app.id] = deviceUID
            // Remove from followsDefault since we're restoring explicit routing
            followsDefault.remove(app.id)
            tapsToSwitch.append(tap)
        }

        if !tapsToSwitch.isEmpty {
            Task {
                for tap in tapsToSwitch {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: false)
                        try await tap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: [deviceUID])
                        self.applyAutoEQToTap(tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) back to \(deviceName): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Second pass: restore multi-device apps that had this device in their selection. This also
        // takes an app back from the fallback when its only device returns.
        var multiModeTapsToUpdate: [any ProcessTapControlling] = []
        for tap in taps.values {
            let app = tap.app
            guard settingsManager.getDeviceSelectionMode(for: app.persistenceIdentifier) == .multi else { continue }
            guard let persistedUIDs = settingsManager.getSelectedDeviceUIDs(for: app.persistenceIdentifier),
                  persistedUIDs.contains(deviceUID) else { continue }
            let currentUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
            guard !currentUIDs.contains(deviceUID) || !tap.currentDeviceUIDs.contains(deviceUID) else { continue }

            // Add the reconnected device back to the live selection. The saved one never lost it,
            // and writing the live one over it would drop any device that is still away.
            var updatedUIDs = currentUIDs
            updatedUIDs.insert(deviceUID)
            volumeState.setSelectedDeviceUIDs(for: app.id, to: updatedUIDs, identifier: app.persistenceIdentifier, persist: false)
            multiModeTapsToUpdate.append(tap)
        }

        if !multiModeTapsToUpdate.isEmpty {
            Task {
                for tap in multiModeTapsToUpdate {
                    await self.updateTapForCurrentMode(for: tap.app)
                }
            }
            logger.info("\(deviceName) reconnected, restored to \(multiModeTapsToUpdate.count) multi-device app(s)")
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) reconnected, switched \(affectedApps.count) app(s) back")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showReconnectNotification(deviceName: deviceName, affectedApps: affectedApps)
            }
        }

        // Only override the default if the newly connected device IS the highest-priority
        // device (i.e., a higher-priority device just came back). If a lower-priority device
        // connects while the user is on a higher-priority device, respect the current default —
        // the user chose it. We still enter PENDING_AUTOSWITCH to guard against macOS
        // auto-switching to the new device.
        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        let highestPriorityUID = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            isAlive: isAliveCheck
        )?.uid

        // If this device is present but not alive, watch for it to become alive
        if let device = deviceMonitor.device(for: deviceUID),
           !isAliveCheck(device.id) {
            installAliveWatcher(deviceID: device.id, uid: deviceUID, name: deviceName)
        }

        switch Self.connectedOutputDefaultAction(
            connectedDeviceUID: deviceUID,
            highestPriorityConnectedUID: highestPriorityUID,
            currentDefaultUID: currentDefault
        ) {
        case .ensureHighestPriorityDefault:
            // The highest-priority device (re)connected. reEvaluateOutputDefault sets the default
            // only when it differs and always re-points follows-default taps, so a default macOS
            // already moved here no longer leaves app audio stranded on the previous device.
            reEvaluateOutputDefault()
        case .restorePrevious:
            // macOS already auto-switched to the lower-priority device — restore
            // what the user was on (not highest priority — they may have chosen a mid-priority device)
            restoreConfirmedDefault()
        case .none:
            break
        }

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one.
        if case .pendingAutoSwitch(_, let oldTask) = outputPriorityState {
            oldTask.cancel()
            outputPriorityState = .stable
        }

        // Always enter PENDING_AUTOSWITCH for the newly connected device.
        // macOS may auto-switch to it multiple times during BT firmware handshake.
        // Without this grace period, auto-switches would be treated as "genuine user change".
        let transport = deviceMonitor.device(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.outputPriorityState = .stable
            self.logger.debug("Auto-switch grace period expired, no macOS switch detected")
        }

        lastAutoSwitchOverrideTime = nil
        outputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
        logger.debug("Entered PENDING_AUTOSWITCH for \(deviceName) (\(timeout)s grace)")
    }

    // MARK: - Alive Watchers

    /// Installs a one-shot HAL listener for kAudioDevicePropertyDeviceIsAlive on a device
    /// that is present but not yet alive. When the device becomes alive, re-runs
    /// handleDeviceConnected so priority is re-evaluated. Self-removes after firing or timeout.
    private func installAliveWatcher(deviceID: AudioDeviceID, uid: String, name: String) {
        guard aliveWatchers[deviceID] == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAliveCheck(deviceID) else { return }
                self.logger.info("Device became alive: \(name) (\(uid)), re-evaluating priority")
                self.removeAliveWatcher(deviceID)
                // One device ID can carry both directions (a USB headset), and whichever
                // connect handler ran first owns the watcher, so re-run both as they apply.
                if self.deviceMonitor.device(for: uid) != nil {
                    self.handleDeviceConnected(uid, name: name)
                }
                if self.deviceMonitor.inputDevice(for: uid) != nil {
                    self.handleInputDeviceConnected(uid, name: name)
                }
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        guard status == noErr else {
            logger.warning("Failed to install alive watcher for \(name) (\(deviceID)): \(status)")
            return
        }

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            self.logger.debug("Alive watcher timed out for \(name) (\(uid))")
            self.removeAliveWatcher(deviceID)
        }

        aliveWatchers[deviceID] = (uid: uid, block: block, timeout: timeoutTask)
        logger.debug("Installed alive watcher for \(name) (\(uid))")
    }

    /// Removes a one-shot alive watcher by device ID, cleaning up the HAL listener and timeout.
    private func removeAliveWatcher(_ deviceID: AudioDeviceID) {
        guard let watcher = aliveWatchers.removeValue(forKey: deviceID) else { return }
        watcher.timeout.cancel()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, watcher.block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove alive watcher for device \(deviceID): \(status)")
        }
    }

    /// Removes a one-shot alive watcher by device UID. Used during disconnect when the
    /// device is already removed from the monitor's list and device(for:) returns nil.
    private func removeAliveWatcher(forUID uid: String) {
        guard let (deviceID, _) = aliveWatchers.first(where: { $0.value.uid == uid }) else { return }
        removeAliveWatcher(deviceID)
    }

    private func showReconnectNotification(deviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Reconnected"
        content.body = "\"\(deviceName)\" is back. \(affectedApps.count) app(s) switched back."
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-reconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// The text of the notification: where the apps went, each place once, so an app that returned to its saved device or
    /// to System Audio is not reported as moved to the priority fallback.
    static func disconnectNotificationBody(deviceName: String, appCount: Int, destinations: [String]) -> String {
        let places = destinations.isEmpty ? "none" : destinations.joined(separator: ", ")
        return "\"\(deviceName)\" disconnected. \(appCount) app(s) switched to \(places)"
    }

    private func showDisconnectNotification(deviceName: String, destinations: [String], affectedApps: [AudioApp]) {
        let body = Self.disconnectNotificationBody(deviceName: deviceName, appCount: affectedApps.count, destinations: destinations)
        if let onDisconnectNotification {
            onDisconnectNotification(body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Disconnected"
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-disconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// Called when system default output device changes - switches apps that follow default
    private func handleDefaultDeviceChanged(_ newDefaultUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after a device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = outputPriorityState {
            // Check echoes FIRST — FineTune's own changes (UI, restoreConfirmedDefault)
            // create echoes. Consuming before Case 1 ensures FineTune UI changes aren't
            // mistaken for macOS auto-switches.
            if outputEchoTracker.consume(newDefaultUID) {
                return
            }

            if newDefaultUID == pendingUID {
                // Settling heuristic: if >1s since last override, BT auto-switches have
                // settled. This is likely the user changing via System Settings — accept it.
                // BT auto-switches happen within ms; user actions take >1s.
                if let lastOverride = lastAutoSwitchOverrideTime,
                   Date().timeIntervalSince(lastOverride) > 1.0 {
                    timeoutTask.cancel()
                    outputPriorityState = .stable
                    lastConfirmedDefaultUID = newDefaultUID
                    lastAutoSwitchOverrideTime = nil
                    routeFollowsDefaultApps(to: newDefaultUID)
                    let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? newDefaultUID
                    logger.info("Accepted user change to \(deviceName) (settled >1s)")
                    return
                }

                // Case 1: macOS auto-switched to the newly connected device — restore what
                // the user was on. Re-enter PENDING_AUTOSWITCH for further auto-switches.
                timeoutTask.cancel()
                restoreConfirmedDefault()
                lastAutoSwitchOverrideTime = Date()
                let transport = deviceMonitor.device(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.outputPriorityState = .stable
                    self.lastAutoSwitchOverrideTime = nil
                    self.logger.debug("Auto-switch grace period expired after override")
                }
                outputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }

            // Case 3: Genuine user intent (different device, not our echo) — respect it.
            timeoutTask.cancel()
            outputPriorityState = .stable
            lastAutoSwitchOverrideTime = nil
        }

        // Suppress echo from our own priority-based override (when not in pendingAutoSwitch)
        if outputEchoTracker.consume(newDefaultUID) {
            return
        }

        // If any echo counter is pending, another override is in flight — skip interim routing
        if outputEchoTracker.hasPending {
            logger.debug("Skipping followsDefault routing — echo pending")
            return
        }

        // Check if the new default device is known and alive.
        guard let newDevice = deviceMonitor.device(for: newDefaultUID) else {
            // Device not yet in monitor's list (e.g., BT device default-changed before device-list
            // notification). Defer — the upcoming handleDeviceConnected will enforce priority.
            logger.debug("Default changed to unknown device \(newDefaultUID), deferring to device list refresh")
            return
        }

        let newDeviceIsAlive = isAliveCheck(newDevice.id)

        if !newDeviceIsAlive {
            // Dead device became default (race with disconnect) — override to priority fallback
            reEvaluateOutputDefault()
        } else {
            // Genuine change to a live device — route followsDefault apps
            lastConfirmedDefaultUID = newDefaultUID
            routeFollowsDefaultApps(to: newDefaultUID)

            let affectedApps = apps.filter { followsDefault.contains($0.id) }
            if !affectedApps.isEmpty {
                let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? "Default Output"
                logger.info("Default changed to \(deviceName), \(affectedApps.count) app(s) following")
                if settingsManager.appSettings.showDeviceDisconnectAlerts {
                    showDefaultChangedNotification(newDeviceName: deviceName, affectedApps: affectedApps)
                }
            }
        }
    }

    private func showDefaultChangedNotification(newDeviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Default Audio Device Changed"
        content.body = "\(affectedApps.count) app(s) switched to \"\(newDeviceName)\""
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "default-device-changed",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// Returns the preferred tap source device UID for stream-specific capture.
    /// Only follows-default apps use stream-specific taps (multichannel preserved, tap always
    /// valid because the app switches device when default changes). Explicitly-routed apps
    /// always use stereo mixdown (nil) — their tap never goes stale when the default changes.
    private func preferredTapSourceDeviceUID(forOutputUIDs outputUIDs: [String], isFollowsDefault: Bool) -> String? {
        guard isFollowsDefault else { return nil }
        guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else { return nil }
        return outputUIDs.contains(defaultUID) ? defaultUID : nil
    }

    private func cleanupStaleTaps() {
        let activePIDs = Set(apps.map { $0.id })
        let stalePIDs = Set(taps.keys).subtracting(activePIDs)

        // Cancel cleanup for PIDs that reappeared — but only if bundleID matches.
        // PID reuse by a different app should not rescue the old tap.

        for pid in activePIDs {
            guard let task = pendingCleanup[pid] else { continue }

            let reappearedApp = apps.first { $0.id == pid }
            let existingTap = taps[pid]

            if let reappearedApp, let existingTap,
               reappearedApp.bundleID != existingTap.app.bundleID {
                // PID was reused by a different app — let the old tap be destroyed
                logger.debug("PID \(pid) reused by different app (\(reappearedApp.bundleID ?? "nil") vs \(existingTap.app.bundleID ?? "nil")), not cancelling cleanup")
                continue
            }

            pendingCleanup.removeValue(forKey: pid)
            task.cancel()
            // Don't remove from appliedPIDs — the tap is still alive and the aggregate
            // device is still running. The process just transiently stopped audio I/O
            // during a device change (kAudioProcessPropertyIsRunning flicker).
            // Device routing is already handled by routeFollowsDefaultApps (follows-default)
            // or stays put (explicit routing). Re-processing would cause an unnecessary
            // crossfade that interrupts audio.
            logger.debug("Cancelled pending cleanup for PID \(pid) - app reappeared")
        }

        // Schedule cleanup for newly stale PIDs (with grace period)
        for pid in stalePIDs {
            guard pendingCleanup[pid] == nil else { continue }  // Already pending

            let grace = staleTapGrace
            let poll = staleTapPollInterval
            pendingCleanup[pid] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: grace)
                // After the grace, a process that is still running keeps its tap (a paused app
                // drops out of the monitor's list but resumes later) and is re-checked every
                // poll interval. `self?` keeps the engine unretained while the task sleeps.
                while !Task.isCancelled {
                    guard self?.staleCleanupShouldKeepPolling(pid) == true else { return }
                    try? await Task.sleep(for: poll)
                }
            }
        }

        // Include pending PIDs in cleanup exclusion to avoid premature state cleanup
        let pidsToKeep = activePIDs.union(Set(pendingCleanup.keys))
        appliedPIDs = appliedPIDs.intersection(pidsToKeep)
        followsDefault = followsDefault.intersection(pidsToKeep)
        volumeState.cleanup(keeping: pidsToKeep)
    }

    /// Debounced stale tap cleanup — coalesces rapid app-list changes into a single cleanup pass.
    private func scheduleStaleCleanup() {
        staleCleanupTask?.cancel()
        staleCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.cleanupStaleTaps()
        }
    }

    /// One step of a stale-cleanup task, after the grace. Returns true while the tap should be
    /// kept and re-checked later; false once the task is finished (reappeared or torn down).
    private func staleCleanupShouldKeepPolling(_ pid: pid_t) -> Bool {
        // The app is back in the monitor's list: nothing to clean up.
        if apps.contains(where: { $0.id == pid }) {
            pendingCleanup.removeValue(forKey: pid)
            return false
        }

        // Absent from the list but the process still runs (paused): keep the tap, routing
        // and volume state, so resuming plays through the tap instead of unprocessed.
        if taps[pid] != nil, isProcessAliveCheck(pid) {
            logger.debug("PID \(pid) absent but still running, keeping tap")
            return true
        }

        // The process is gone: safe to cleanup
        cancelProcessRebuild(for: pid)
        if let tap = taps.removeValue(forKey: pid) {
            tap.invalidate()
            logger.debug("Cleaned up stale tap for PID \(pid)")
        }
        refreshMultiRouteDeviceUIDs()
        appDeviceRouting.removeValue(forKey: pid)
        followsDefault.remove(pid)
        appliedPIDs.remove(pid)  // Allow re-initialization if app resumes
        pendingCleanup.removeValue(forKey: pid)
        return false
    }

    // MARK: - Helper Process Sync

    /// Per-pid state of a process-list rebuild: the debounce, the in-flight rebuild, and
    /// whether a further change arrived while it ran (one coalesced rerun).
    private final class ProcessRebuildState {
        var debounce: Task<Void, Never>?
        var rebuild: Task<Void, Never>?
        var rerunNeeded = false
    }

    /// A tap is built around the app's process objects at creation. When the app later adds a
    /// process object (a new Chrome tab helper), the tap must be rebuilt around the grown list
    /// or that helper's audio plays unprocessed. A shrink alone never rebuilds: a dropped
    /// object is just a helper that went quiet, and its tap input is harmless.
    private func syncTapProcesses(_ apps: [AudioApp]) {
        for app in apps {
            guard let tap = taps[app.id], processListGrew(from: tap.app, to: app) else { continue }
            scheduleProcessRebuild(for: app.id)
        }
    }

    private func processListGrew(from tapApp: AudioApp, to current: AudioApp) -> Bool {
        !Set(current.processObjectIDs).isSubset(of: Set(tapApp.processObjectIDs))
    }

    private func scheduleProcessRebuild(for pid: pid_t) {
        let state = processRebuilds[pid] ?? ProcessRebuildState()
        processRebuilds[pid] = state

        // A rebuild is running: remember to look at the latest state once when it ends.
        if state.rebuild != nil {
            state.rerunNeeded = true
            return
        }

        let delay = processRebuildDebounce
        state.debounce?.cancel()
        state.debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.runProcessRebuild(for: pid)
        }
    }

    /// The process objects to tap when rebuilding around `current`: the old objects that still
    /// exist (a paused helper is absent from the monitor's list but may resume), minus the ones
    /// that exited, plus everything the monitor lists now.
    private func mergedProcessObjectIDs(keeping old: [AudioObjectID], current: [AudioObjectID]) -> [AudioObjectID] {
        let currentIDs = Set(current)
        // One HAL read for every old object the monitor no longer lists, none when it lists them all.
        let unlisted = old.contains { !currentIDs.contains($0) }
        let alive = unlisted ? readProcessObjectIDs() : []
        var ids = old.filter { currentIDs.contains($0) || alive.contains($0) }
        for id in current where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    /// Debounce fired: decide from the monitor's latest state, not from what scheduled it.
    private func runProcessRebuild(for pid: pid_t) {
        guard let state = processRebuilds[pid] else { return }
        state.debounce = nil
        state.rerunNeeded = false

        guard let tap = taps[pid],
              let current = apps.first(where: { $0.id == pid }),
              current.bundleID == tap.app.bundleID,  // pid reuse by another app is not a helper
              processListGrew(from: tap.app, to: current) else {
            processRebuilds.removeValue(forKey: pid)
            return
        }

        let newApp = rebuiltApp(replacing: tap.app, current: current)
        let ids = newApp.processObjectIDs
        // The same list already failed to rebuild: retrying it on every audio change anywhere
        // would dip this app's audio over and over. A different list is tried again.
        let attemptedIDs = Set(ids)
        guard failedProcessLists[pid] != attemptedIDs else {
            processRebuilds.removeValue(forKey: pid)
            return
        }

        logger.info("[PROC] \(current.name, privacy: .public) (PID \(pid)) process list \(tap.app.processObjectIDs.count) → \(ids.count), rebuilding tap")
        state.rebuild = Task { @MainActor [weak self] in
            do {
                try await tap.updateProcesses(newApp)
                self?.failedProcessLists.removeValue(forKey: pid)
            } catch is CancellationError {
                // Torn down or superseded while rebuilding; nothing to recover.
            } catch {
                self?.logger.error("[PROC] Rebuild failed for PID \(pid): \(error.localizedDescription)")
                self?.failedProcessLists[pid] = attemptedIDs
            }
            self?.finishProcessRebuild(for: pid, state: state)
        }
    }

    private func finishProcessRebuild(for pid: pid_t, state: ProcessRebuildState) {
        // Cancelled (tap torn down) while running: the state was already discarded.
        guard processRebuilds[pid] === state else { return }
        state.rebuild = nil
        if state.rerunNeeded {
            scheduleProcessRebuild(for: pid)
        } else {
            processRebuilds.removeValue(forKey: pid)
        }
    }

    /// Cancels a pending or running rebuild for `pid`. Call wherever its tap is torn down.
    private func cancelProcessRebuild(for pid: pid_t) {
        failedProcessLists.removeValue(forKey: pid)
        guard let state = processRebuilds.removeValue(forKey: pid) else { return }
        state.rerunNeeded = false
        state.debounce?.cancel()
        state.rebuild?.cancel()
    }

    private func cancelAllProcessRebuilds() {
        failedProcessLists.removeAll()
        for pid in Array(processRebuilds.keys) {
            cancelProcessRebuild(for: pid)
        }
    }

    // MARK: - Tap Health Monitor

    /// How often the health monitor ticks. A stuck tap is probed from 0.25 s of exact-zero input,
    /// so the tick has to be that fine; the once-per-second work counts ticks.
    nonisolated static let healthTickInterval: Duration = .milliseconds(250)
    nonisolated static let healthTicksPerSecond = 4

    /// Starts a periodic health check that probes stuck taps and recreates unresponsive ones.
    /// Ticks every 250 ms; once per second, after 6 consecutive misses (~6s) a tap with no
    /// callbacks is presumed dead. `TapWatchdog` decides when a tap whose callback runs but
    /// delivers nothing is probed with a candidate tap (`rescueStuckTap`).
    private func startHealthMonitor() {
        startChromeTapLatencyPoll()
        guard healthMonitorTask == nil else { return }
        healthMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AudioEngine.healthTickInterval)
                guard !Task.isCancelled, let self else { return }
                await self.runHealthTick()
            }
        }
    }

    /// One health tick: the stuck-tap watchdog for every tap, and once per second the
    /// unresponsive-tap check and the pruning of per-pid state.
    func runHealthTick(now: Date = Date()) async {
        // Skip entirely when no taps exist: avoids unnecessary work at idle (#176)
        guard !taps.isEmpty else { return }

        healthTickCount &+= 1
        let isSecondTick = healthTickCount % Self.healthTicksPerSecond == 0

        for (pid, tap) in taps {
            // An earlier rebuild in this pass may have replaced or removed this tap.
            guard taps[pid] === tap else { continue }

            // Skip PIDs in recovery cooldown to prevent recreation thrashing
            if let cooldownEnd = tapRecoveryCooldownUntil[pid], now < cooldownEnd {
                continue
            }

            if await checkTapWatchdog(pid: pid, tap: tap, now: now, isSecondTick: isSecondTick) { continue }

            guard isSecondTick else { continue }

            // Skip muted apps: no callbacks while muted isn't a health signal
            guard !tap.isMuted else { continue }

            guard tap.isHealthCheckEligible(minActiveSeconds: 5.0) else { continue }

            // Only health-check apps that are actively streaming (isRunning=true).
            // Paused apps have no callbacks, which is normal, not a health signal.
            let isActivelyStreaming = processMonitor.activeApps.contains { $0.id == pid }
            guard isActivelyStreaming else {
                consecutiveMisses[pid] = 0
                continue
            }

            if tap.hasRecentAudioCallback(within: 3.0) {
                consecutiveMisses[pid] = 0
            } else {
                let misses = (consecutiveMisses[pid] ?? 0) + 1
                consecutiveMisses[pid] = misses

                if misses >= 6 {
                    logger.warning("Tap for PID \(pid) unresponsive (\(misses) misses), recreating")
                    consecutiveMisses[pid] = 0
                    await recreateTap(for: pid, now: now)
                }
            }
        }

        guard isSecondTick else { return }

        // Prune entries for PIDs no longer tracked
        consecutiveMisses = consecutiveMisses.filter { taps[$0.key] != nil }
        tapRecoveryCooldownUntil = tapRecoveryCooldownUntil.filter { taps[$0.key] != nil }
        tapWatchdogs = tapWatchdogs.filter { taps[$0.key] != nil }
        loggedDiscontinuities = loggedDiscontinuities.filter { taps[$0.key] != nil }
        #if DEBUG
        zeroRunCursors = zeroRunCursors.filter { taps[$0.key] != nil }
        #endif
    }

    /// Runs the stuck-tap watchdog for one tap. Returns true when it rebuilt the tap.
    private func checkTapWatchdog(pid: pid_t, tap: any ProcessTapControlling, now: Date, isSecondTick: Bool) async -> Bool {
        guard let readings = tap.healthReadings() else { return false }

        #if DEBUG
        if DebugSoakConfig.current.zeroLog { logZeroRuns(pid: pid, tap: tap, readings: readings) }
        #endif

        // Persisted evidence: every IO discontinuity (skipped cycle) on a tap.
        if readings.discontinuityCount != (loggedDiscontinuities[pid] ?? 0) {
            loggedDiscontinuities[pid] = readings.discontinuityCount
            if readings.discontinuityCount > 0 {
                logger.notice("[WATCHDOG] \(tap.app.name, privacy: .public) (PID \(pid)) IO discontinuity #\(readings.discontinuityCount) on \(tap.currentDeviceUIDs, privacy: .public)")
            }
        }

        // IsRunningOutput is a HAL read, so it waits until a rule could fire on it. A tap the
        // watchdog knows is stopped is re-read once a second, to notice the app starting to play.
        var watchdog = tapWatchdogs[pid] ?? TapWatchdog()
        let needsRead = watchdog.needsPlayingState(readings)
            || (isSecondTick && readings.secondsSinceInputSignal >= TapWatchdog.rescueThreshold(rung: 0))
        let sample = TapHealthSample(
            readings: readings,
            appIsPlaying: needsRead ? isProcessRunningOutput(tap.app) : nil,
            isUserMuted: tap.isMuted,
            clock: now.timeIntervalSinceReferenceDate
        )
        let action = watchdog.evaluate(sample)
        tapWatchdogs[pid] = watchdog

        switch action {
        case nil:
            return false
        case .rebuild(let reason):
            logger.error("[WATCHDOG] \(tap.app.name, privacy: .public) (PID \(pid)) stuck: \(reason.rawValue, privacy: .public) on \(tap.currentDeviceUIDs, privacy: .public); input silent \(readings.secondsSinceInputSignal, format: .fixed(precision: 1))s (signal seen: \(readings.inputSignalSeen)), last discontinuity \(readings.secondsSinceDiscontinuity, format: .fixed(precision: 1))s ago, tap age \(readings.secondsSinceTapStart, format: .fixed(precision: 1))s, output silent \(readings.secondsSinceHealthyOutput, format: .fixed(precision: 1))s; rebuilding tap")
            await recreateTap(for: pid, cooldown: 5, now: now)
            logger.notice("[WATCHDOG] \(tap.app.name, privacy: .public) (PID \(pid)) tap rebuilt: \(self.taps[pid] != nil ? "ok" : "no tap", privacy: .public)")
            return true
        case .rescue(let reason, let rung):
            logger.info("[WATCHDOG] \(tap.app.name, privacy: .public) (PID \(pid)) input silent \(readings.secondsSinceInputSignal, format: .fixed(precision: 2))s while running output (\(reason.rawValue, privacy: .public), rung \(rung)); probing with a candidate tap")
            return await rescueTap(pid: pid, tap: tap, readings: readings, rung: rung, now: now)
        }
    }

    /// Asks the tap for a make-before-break rescue and acts on the outcome. A silent candidate
    /// (the app is paused, not dead) or a primary that recovered steps the watchdog's ladder; a
    /// rescue that could not run at all falls back to `recreateTap`, a few times per episode.
    /// Returns true when it rebuilt the tap.
    private func rescueTap(pid: pid_t, tap: any ProcessTapControlling, readings: TapHealthReadings, rung: Int, now: Date) async -> Bool {
        // Rescues run inline in the tick, by design: the tick waits out the verify window and no
        // other tap is judged meanwhile. `settled` is `now` advanced by what the rescue took, so
        // the ladder memory and the cooldown count from when it ended and stay deterministic when
        // a test injects `now`.
        let started = Date()
        func settled() -> Date { now.addingTimeInterval(Date().timeIntervalSince(started)) }
        func entry(_ outcome: TapRescueLogEntry.Outcome) -> TapRescueLogEntry {
            TapRescueLogEntry(
                appName: tap.app.name,
                pid: pid,
                outcome: outcome,
                rung: rung,
                readings: readings,
                tapSourceDeviceUID: tap.tapSourceDeviceUID,
                devices: tap.currentDeviceUIDs
            )
        }

        do {
            let report = try await tap.rescueStuckTap()
            logRescue(entry(.promoted(candidateLatency: report.candidateSignalLatency)))
            if var watchdog = tapWatchdogs[pid] {
                watchdog.rescuePromoted(clock: settled().timeIntervalSinceReferenceDate)
                tapWatchdogs[pid] = watchdog
                if watchdog.recentPromotions == TapWatchdog.promotionStormCount {
                    logger.notice("[RESCUE] promotion storm \(tap.app.name, privacy: .public) (PID \(pid)) \(watchdog.recentPromotions) promotions in \(Int(TapWatchdog.promotionStormWindow))s")
                }
            }
            return false
        } catch CrossfadeError.candidateSilent {
            logRescue(entry(.candidateSilent))
            tapWatchdogs[pid]?.rescueInconclusive(atSilence: readings.secondsSinceInputSignal, clock: settled().timeIntervalSinceReferenceDate)
            return false
        } catch CrossfadeError.primaryRecovered {
            logRescue(entry(.primaryRecovered))
            tapWatchdogs[pid]?.rescueInconclusive(atSilence: readings.secondsSinceInputSignal, clock: settled().timeIntervalSinceReferenceDate)
            return false
        } catch is CancellationError {
            // Torn down or superseded mid-probe: the owner of that change decides what is next.
            logger.debug("[RESCUE] \(tap.app.name, privacy: .public) (PID \(pid)) cancelled")
            return false
        } catch CrossfadeError.switchInFlight {
            // A switch began between the readings and the call: asked again on the next tick.
            logger.debug("[RESCUE] \(tap.app.name, privacy: .public) (PID \(pid)) skipped, a switch is running")
            return false
        } catch {
            logRescue(entry(.failed(error.localizedDescription)))
            // Only replace the tap that failed, never a newer replacement.
            guard taps[pid] === tap else { return false }
            guard tapWatchdogs[pid]?.claimFallbackRebuild() == true else {
                tapWatchdogs[pid]?.rescueInconclusive(atSilence: readings.secondsSinceInputSignal, clock: settled().timeIntervalSinceReferenceDate)
                return false
            }
            logger.error("[WATCHDOG] \(tap.app.name, privacy: .public) (PID \(pid)) rescue failed: \(error.localizedDescription, privacy: .public); rebuilding tap")
            await recreateTap(for: pid, cooldown: 5, now: settled())
            logger.notice("[WATCHDOG] \(tap.app.name, privacy: .public) (PID \(pid)) tap rebuilt: \(self.taps[pid] != nil ? "ok" : "no tap", privacy: .public)")
            return true
        }
    }

    /// One `[RESCUE]` line, persisted at the entry's level.
    private func logRescue(_ entry: TapRescueLogEntry) {
        let line = entry.line
        switch entry.level {
        case .notice: logger.notice("[RESCUE] \(line, privacy: .public)")
        case .info: logger.info("[RESCUE] \(line, privacy: .public)")
        case .error: logger.error("[RESCUE] \(line, privacy: .public)")
        }
    }

    #if DEBUG
    /// DECI_DEBUG_ZERO_LOG: one persisted line per exact-zero input run of 100 ms or more, at its
    /// onset and at its end. Times come from the IO thread's host clock, not from the health tick.
    private func logZeroRuns(pid: pid_t, tap: any ProcessTapControlling, readings: TapHealthReadings) {
        var cursor = zeroRunCursors[pid] ?? ZeroRunLogCursor()
        let events = cursor.events(for: readings.zeroRun)
        zeroRunCursors[pid] = cursor
        guard !events.isEmpty else { return }

        let now = Date()
        let playing = isProcessRunningOutput(tap.app)
        for event in events {
            let line = event.logLine(
                appName: tap.app.name,
                pid: pid,
                playing: playing,
                devices: tap.currentDeviceUIDs,
                tapSourceDeviceUID: tap.tapSourceDeviceUID,
                readings: readings,
                now: now
            )
            logger.notice("[ZERORUN] \(line, privacy: .public)")
        }
    }
    #endif

    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        chromeTapLatencyTask?.cancel()
        chromeTapLatencyTask = nil
    }

    // MARK: - Chrome Tap Latency

    /// Starts the 4 Hz poll of the Chrome tap's through-latency. Its own loop, not a step of `runHealthTick`: that
    /// returns at once when no taps exist, and the poll still has to say so when the Chrome tap was the last one.
    private func startChromeTapLatencyPoll() {
        guard chromeTapLatencyTask == nil else { return }
        chromeTapLatencyTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AudioEngine.healthTickInterval)
                guard !Task.isCancelled, let self else { return }
                self.pollChromeTapLatency()
            }
        }
    }

    /// One poll: reads the Chrome tap's measured through-latency and reports it through `onChromeTapLatencyChange`
    /// when `ChromeTapLatencyReporter` says it changed. Only Chrome's taps are read.
    func pollChromeTapLatency() {
        guard let report = onChromeTapLatencyChange else { return }
        let observations = taps.values
            .filter { ChromeTapLatencyReporter.isChrome($0.app.bundleID) }
            .map { tap in
                ChromeTapLatencyReporter.Observation(
                    bundleID: tap.app.bundleID,
                    deviceUIDs: tap.currentDeviceUIDs,
                    readings: tap.healthReadings()
                )
            }
        if let map = chromeTapLatencyReporter.next(readings: observations) {
            report(map)
        }
    }

    /// Tears down and recreates a tap for a given PID, preserving routing and settings.
    /// Async: awaits full CoreAudio resource teardown before creating the replacement tap
    /// to prevent orphaned IO procs from accumulating (issue #176).
    private func recreateTap(for pid: pid_t, cooldown: TimeInterval = 20, now: Date = Date()) async {
        guard let oldTap = taps.removeValue(forKey: pid) else { return }
        refreshMultiRouteDeviceUIDs()
        cancelProcessRebuild(for: pid)
        let deviceUIDs = oldTap.currentDeviceUIDs
        await oldTap.invalidateAsync()

        // Set cooldown to prevent thrashing
        tapRecoveryCooldownUntil[pid] = now.addingTimeInterval(cooldown)

        // Find the current AudioApp entry for this PID
        guard let current = apps.first(where: { $0.id == pid }) else {
            logger.debug("No active app for PID \(pid), skipping tap recreation")
            appliedPIDs.remove(pid)
            return
        }
        let app = rebuiltApp(replacing: oldTap.app, current: current)

        // Allow re-initialization
        appliedPIDs.remove(pid)

        // Re-route to the same device(s), preserving multi-device routing
        if deviceUIDs.count > 1 {
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
            if taps[app.id] != nil {
                appDeviceRouting[app.id] = deviceUIDs[0]
            }
        } else if let deviceUID = deviceUIDs.first {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }

        // Mark as applied to avoid redundant re-processing in applyPersistedSettings
        if taps[pid] != nil {
            appliedPIDs.insert(pid)
        }

        // Restore mute state
        if let muted = volumeState.loadSavedMute(for: pid, identifier: app.persistenceIdentifier), muted {
            taps[pid]?.isMuted = true
        }
    }

    /// The app to build a replacement tap for. A paused helper process drops out of the monitor's
    /// list but may resume, so the old tap's objects that still exist are kept (see
    /// `mergedProcessObjectIDs`). A pid reused by another app is not a helper: use it as listed.
    /// An app with no bundle ID cannot be told apart from its old self, so the pid decides.
    private func rebuiltApp(replacing old: AudioApp, current: AudioApp) -> AudioApp {
        let sameApp = current.id == old.id
            && (current.bundleID == old.bundleID || current.bundleID == nil || old.bundleID == nil)
        guard sameApp else { return current }
        return AudioApp(
            id: current.id,
            processObjectIDs: mergedProcessObjectIDs(keeping: old.processObjectIDs, current: current.processObjectIDs),
            name: current.name,
            icon: current.icon,
            bundleID: current.bundleID,
            isHelperBacked: current.isHelperBacked
        )
    }

    /// Recreates the aggregate at the device's new rate for every tap on a BT output that changed
    /// sample rate (A2DP↔SCO), so each tap's IOProc re-rates to match. Falls back to a full tap
    /// recreate if the in-controller recreation throws.
    func handleBTDeviceSampleRateChanged(uid: String, newRate: Double) async {
        logger.info("[RATE] BT output \(uid, privacy: .public) → \(newRate, format: .fixed(precision: 0)) Hz — recreating affected taps (clean dip)")
        let affected = taps.filter { $0.value.currentDeviceUIDs.contains(uid) }
        for (pid, tap) in affected {
            do {
                logger.info("[RATE] Recreating tap for PID \(pid)")
                try await tap.recreateForOutputRateChange()
                // The tap may have been torn down or replaced while this awaited.
                guard taps[pid] === tap else { continue }
                // The rebuilt aggregate starts at default output state; put volume, mute and
                // device state back or the app plays at full volume until the next change.
                applyTapOutputState(to: tap, for: pid, deviceUIDs: tap.currentDeviceUIDs)
            } catch is CancellationError {
                // Superseded or torn down mid-rebuild; a full recreate would fight the newer owner.
                logger.info("[RATE] Recreate cancelled for PID \(pid), skipping full recreate")
            } catch {
                logger.error("[RATE] Recreate failed for PID \(pid): \(error.localizedDescription), falling back to full recreate")
                // Only replace the tap that failed, never a newer replacement.
                guard taps[pid] === tap else { continue }
                await recreateTap(for: pid)
            }
        }
    }

    // MARK: - Input Device Lock

    /// Handles changes to the default input device.
    /// Uses state machine to distinguish auto-switch (from device connection) vs user action.
    private func handleDefaultInputDeviceChanged(_ newDefaultInputUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after input device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = inputPriorityState {
            // Our own change first (as on the output side): switching to a connected top mic
            // sets the default to the pending device, which is not a macOS auto-switch.
            if inputEchoTracker.consume(newDefaultInputUID) {
                return
            }
            if newDefaultInputUID == pendingUID, settingsManager.appSettings.lockInputDevice {
                // Case 1: macOS auto-switched to the newly connected device — restore locked device.
                // Re-enter PENDING_AUTOSWITCH because macOS may auto-switch multiple times.
                timeoutTask.cancel()
                restoreLockedInputDevice()
                let transport = deviceMonitor.inputDevice(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.inputPriorityState = .stable
                    self.logger.debug("Input auto-switch grace period expired after override")
                }
                inputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }
            // Case 2: Genuine user intent — respect it.
            timeoutTask.cancel()
            inputPriorityState = .stable
        }

        // Suppress echo from our own input device override (when not in pendingAutoSwitch)
        if inputEchoTracker.consume(newDefaultInputUID) {
            return
        }

        // If any input echo counter is pending, skip routing
        if inputEchoTracker.hasPending {
            logger.debug("Skipping input routing — echo pending")
            return
        }

        // If lock is disabled, let system control input freely
        guard settingsManager.appSettings.lockInputDevice else { return }

        // A mic macOS switched to before the device list caught up: its connect handler
        // decides (it may be the new top mic), so don't bounce the default back meanwhile.
        guard deviceMonitor.inputDevice(for: newDefaultInputUID) != nil else {
            logger.debug("Default input changed to unknown device \(newDefaultInputUID), deferring to device list refresh")
            return
        }

        // Restore the locked device — any change outside FineTune's UI is either
        // macOS auto-switch or System Settings, and the lock should hold either way.
        // Users change the lock via FineTune's UI (setLockedInputDevice).
        guard let lockedUID = settingsManager.lockedInputDeviceUID else { return }
        if newDefaultInputUID != lockedUID {
            restoreLockedInputDevice()
        }
    }

    /// Restores the locked input device, or falls back to built-in mic if unavailable.
    private func restoreLockedInputDevice() {
        guard let lockedUID = settingsManager.lockedInputDeviceUID,
              let lockedDevice = deviceMonitor.inputDevice(for: lockedUID) else {
            // No locked device or it's unavailable - fall back to built-in
            lockToBuiltInMicrophone()
            return
        }

        // Don't restore if already on the locked device
        guard deviceVolumeMonitor.defaultInputDeviceUID != lockedUID else { return }

        logger.info("Restoring locked input device: \(lockedDevice.name)")
        if deviceVolumeMonitor.setDefaultInputDevice(lockedDevice.id) {
            inputEchoTracker.increment(lockedDevice.uid)
        }
    }

    /// Locks the input device to the built-in microphone.
    /// This is a fallback — does NOT update preferredInputDeviceUID.
    private func lockToBuiltInMicrophone() {
        guard let builtInMic = deviceMonitor.inputDevices.first(where: {
            $0.id.readTransportType() == .builtIn
        }) else {
            logger.warning("No built-in microphone found")
            return
        }

        applyInputDeviceLock(builtInMic)
    }

    /// Applies input device lock without changing the user's preferred device.
    /// Used for fallback scenarios (disconnect, built-in mic recovery).
    private func applyInputDeviceLock(_ device: AudioDevice) {
        logger.info("Locking input device to: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when the user toggles lockInputDevice ON in settings.
    /// Switches to the highest-priority connected mic and makes it the locked and preferred device.
    func handleInputLockEnabled() {
        guard let target = reEvaluateInputDefault() else { return }
        logger.info("Input follows priority, locking to: \(target)")
        settingsManager.setLockedInputDeviceUID(target)
        settingsManager.setPreferredInputDeviceUID(target)
    }

    /// Called when user explicitly selects an input device (via FineTune UI).
    /// Persists the choice and applies the change.
    func setLockedInputDevice(_ device: AudioDevice) {
        logger.info("User locked input device to: \(device.name)")

        // Persist the choice — both current lock and preferred (user intent)
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)

        // Apply the change
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when an input device connects — moves the lock to it when it tops the input
    /// priority list, otherwise restores the locked/preferred device, and guards against auto-switch.
    private func handleInputDeviceConnected(_ deviceUID: String, name deviceName: String) {
        guard settingsManager.appSettings.lockInputDevice else { return }

        // A Bluetooth mic can show up before it is alive; decide again once it is.
        if let device = deviceMonitor.inputDevice(for: deviceUID), !isAliveCheck(device.id) {
            installAliveWatcher(deviceID: device.id, uid: deviceUID, name: deviceName)
        }

        let highestPriority = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            isAlive: isAliveCheck
        )
        if let highestPriority, highestPriority.uid == deviceUID {
            // The highest-priority mic (re)connected: it becomes the locked device
            logger.info("Highest-priority input connected: \(deviceName), locking to it")
            settingsManager.setLockedInputDeviceUID(highestPriority.uid)
            settingsManager.setPreferredInputDeviceUID(highestPriority.uid)
        } else if let preferredUID = settingsManager.preferredInputDeviceUID,
           deviceUID == preferredUID,
           settingsManager.lockedInputDeviceUID != preferredUID,
           let device = deviceMonitor.inputDevice(for: deviceUID) {
            logger.info("Preferred input device reconnected: \(deviceName), restoring lock")
            settingsManager.setLockedInputDeviceUID(device.uid)
        }

        // Restore the user's locked device (not priority-based — lock overrides priority)
        restoreLockedInputDevice()

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one
        if case .pendingAutoSwitch(_, let oldTask) = inputPriorityState {
            oldTask.cancel()
        }

        // Always enter PENDING_AUTOSWITCH — macOS may auto-switch to the newly connected
        // device multiple times during BT handshake, even if we just restored the lock.
        let transport = deviceMonitor.inputDevice(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.inputPriorityState = .stable
            self.logger.debug("Input auto-switch grace period expired, no macOS switch detected")
        }

        inputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
    }

    /// Handles input device disconnect — uses priority fallback, then built-in mic.
    private func handleInputDeviceDisconnected(_ deviceUID: String) {
        removeAliveWatcher(forUID: deviceUID)
        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = inputPriorityState, uid == deviceUID {
            task.cancel()
            inputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultInput = deviceUID == deviceVolumeMonitor.defaultInputDeviceUID

        let priorityFallback = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        // If the disconnected device was the default input, override to priority fallback
        if wasDefaultInput {
            reEvaluateInputDefault(excluding: deviceUID)
        }

        // If the locked device disconnected, update the lock to the fallback (or built-in mic)
        guard settingsManager.appSettings.lockInputDevice,
              settingsManager.lockedInputDeviceUID == deviceUID else { return }

        if let fallbackDevice = priorityFallback {
            logger.info("Locked input device disconnected, falling back to priority: \(fallbackDevice.name)")
            if wasDefaultInput {
                // Default already switched above, just update the lock setting
                settingsManager.setLockedInputDeviceUID(fallbackDevice.uid)
            } else {
                applyInputDeviceLock(fallbackDevice)
            }
        } else {
            logger.info("Locked input device disconnected, falling back to built-in mic")
            lockToBuiltInMicrophone()
        }
    }
}

// MARK: - URLHandlerEngine Conformance

extension AudioEngine: URLHandlerEngine {}
