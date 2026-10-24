// DeciTests/AudioEngineTestHarness.swift
//
// Shared AudioEngine harness for the Phase 3 suites (process sync, BT rate path,
// stale-tap cleanup). Wires the engine to the existing fakes and exposes the
// injected closures as mutable probes so a test can flip them mid-run.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import Deci

// MARK: - Probes

/// Mutable state behind the engine's injected closures.
@MainActor
final class EngineProbes {
    /// HAL process objects that still exist (backs `processObjectList`).
    var liveObjectIDs: Set<AudioObjectID> = []
    /// How many times the engine read the HAL process list.
    private(set) var processListReadCount = 0
    /// Processes that are still running (backs `isProcessAlive`).
    var alivePIDs: Set<pid_t> = []
    /// Processes whose HAL IsRunningOutput reads true (backs `isProcessRunningOutput`).
    var runningOutputPIDs: Set<pid_t> = []
    /// How many times the engine read IsRunningOutput.
    private(set) var runningOutputQueryCount = 0
    /// How many times the engine asked whether a pid is alive.
    private(set) var aliveQueryCount = 0
    /// Every tap the factory handed out, in creation order.
    private(set) var createdTaps: [RecordingProcessTapController] = []

    func recordAliveQuery(_ pid: pid_t) -> Bool {
        aliveQueryCount += 1
        return alivePIDs.contains(pid)
    }

    func readProcessList() -> Set<AudioObjectID> {
        processListReadCount += 1
        return liveObjectIDs
    }

    func recordRunningOutputQuery(_ pid: pid_t) -> Bool {
        runningOutputQueryCount += 1
        return runningOutputPIDs.contains(pid)
    }

    func record(_ tap: RecordingProcessTapController) {
        createdTaps.append(tap)
    }
}

// MARK: - Harness

@MainActor
struct EngineHarness {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let processMonitor: StubProcessMonitor
    let device: AudioDevice
    let probes: EngineProbes
    /// Debounce used for process-list rebuilds, exposed so tests can wait a multiple of it.
    let debounce: Duration

    init(
        debounce: Duration = .milliseconds(40),
        staleGrace: Duration = .milliseconds(30),
        stalePoll: Duration = .milliseconds(30),
        extraDevices: [AudioDevice] = [],
        deviceVolumeLevel: Float = 0.75
    ) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        // The default-changed notification path would talk to UNUserNotificationCenter.
        var appSettings = settings.appSettings
        appSettings.showDeviceDisconnectAlerts = false
        settings.updateAppSettings(appSettings)

        let deviceMonitor = MockAudioDeviceMonitor()
        let device = AudioDevice(
            id: AudioDeviceID(99),
            uid: "uid-test",
            name: "Test Output",
            icon: nil,
            supportsAutoEQ: false
        )
        deviceMonitor.addOutputDevice(device)
        for extra in extraDevices { deviceMonitor.addOutputDevice(extra) }

        let deviceVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        deviceVolume.volumes[device.id] = deviceVolumeLevel
        deviceVolume.defaultDeviceUID = device.uid

        let processMonitor = StubProcessMonitor()
        let probes = EngineProbes()

        // ensureTapExists guards on permission.status == .authorized; the TCC preflight
        // is unknown under xctest, so force it (same trick as the initial-state suite).
        let permission = AudioRecordingPermission()
        permission.status = .authorized

        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: deviceMonitor,
            processMonitor: processMonitor,
            deviceVolumeMonitor: deviceVolume,
            tapFactory: { app, uids, source in
                let tap = RecordingProcessTapController(app: app, deviceUIDs: uids, preferredTapSource: source)
                probes.record(tap)
                return tap
            },
            isAlive: { _ in true },
            isProcessAlive: { probes.recordAliveQuery($0) },
            processObjectList: { probes.readProcessList() },
            isProcessRunningOutput: { probes.recordRunningOutputQuery($0.id) },
            staleTapGrace: staleGrace,
            staleTapPollInterval: stalePoll,
            processRebuildDebounce: debounce,
            startMonitorsAutomatically: false
        )

        self.engine = engine
        self.settings = settings
        self.deviceMonitor = deviceMonitor
        self.deviceVolume = deviceVolume
        self.processMonitor = processMonitor
        self.device = device
        self.probes = probes
        self.debounce = debounce
    }

    /// Makes `app` active and lets the engine create its tap the production way
    /// (`applyPersistedSettings` from the monitor callback). Marks the process alive.
    @discardableResult
    func launch(_ app: AudioApp) -> RecordingProcessTapController {
        probes.alivePIDs.insert(app.id)
        probes.liveObjectIDs.formUnion(app.processObjectIDs)
        publish([app])
        guard let tap = probes.createdTaps.last else {
            Issue.record("Engine did not create a tap for \(app.name)")
            return RecordingProcessTapController(app: app, deviceUIDs: [])
        }
        return tap
    }

    /// Makes every app active at once (one monitor refresh), marking each process alive.
    func launchAll(_ apps: [AudioApp]) {
        for app in apps {
            probes.alivePIDs.insert(app.id)
            probes.liveObjectIDs.formUnion(app.processObjectIDs)
        }
        publish(apps)
    }

    /// Barrier for "nothing was rebuilt" assertions. A fixed sleep proves nothing when the
    /// main actor is busy (every engine construction blocks it for a while), so instead run a
    /// sentinel app through a rebuild: timers of equal length fire in the order they were set,
    /// so any rebuild scheduled before this call has already reached its tap when this returns.
    func settleProcessRebuilds() async {
        let existing = processMonitor.activeApps
        let sentinel = makeApp(pid: 31_337, ids: [9_001], bundleID: "com.deci.tests.Sentinel")
        probes.alivePIDs.insert(sentinel.id)
        probes.liveObjectIDs.formUnion(sentinel.processObjectIDs)
        publish(existing + [sentinel])
        guard let sentinelTap = tap(for: sentinel.id) else {
            Issue.record("Engine did not create the sentinel tap")
            return
        }
        publish(existing + [makeApp(pid: sentinel.id, ids: [9_001, 9_002], bundleID: "com.deci.tests.Sentinel")])
        let ran = await waitUntil { sentinelTap.updateProcessesCalls.count == 1 }
        #expect(ran, "the sentinel rebuild should run")
    }

    /// Latest tap the factory created for `pid`.
    func tap(for pid: pid_t) -> RecordingProcessTapController? {
        probes.createdTaps.last { $0.app.id == pid }
    }

    /// Replaces the monitor's app list and fires `onAppsChanged`, like a real refresh.
    func publish(_ apps: [AudioApp]) {
        processMonitor.activeApps = apps
        processMonitor.onAppsChanged?(apps)
    }

    func makeApp(
        pid: pid_t = 4242,
        ids: [AudioObjectID],
        bundleID: String? = "com.google.Chrome"
    ) -> AudioApp {
        AudioApp(
            id: pid,
            processObjectIDs: ids,
            name: "Chrome",
            icon: NSImage(),
            bundleID: bundleID,
            isHelperBacked: true
        )
    }
}

extension RecordingProcessTapController {
    /// True once the engine has torn this controller down.
    var wasInvalidated: Bool { events.contains(.invalidate) }
}

// MARK: - Waiting

/// Polls `condition` on the main actor until it holds or `timeout` elapses. The default is
/// generous on purpose: in a full run the main actor is shared with the whole suite and a
/// wait that needs 50 ms alone can take seconds. It returns as soon as the condition holds.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(30),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
