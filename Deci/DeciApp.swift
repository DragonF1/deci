// Deci/DeciApp.swift
import SwiftUI
import UserNotifications
import FluidMenuBarExtra
import AppKit
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var audioEngine: AudioEngine?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let audioEngine = audioEngine else {
            return
        }
        let urlHandler = URLHandler(audioEngine: audioEngine)

        for url in urls {
            urlHandler.handleURL(url)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// LSUIElement agent — closing the Settings window must not terminate the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Picks the app to run. Under `xcodebuild test` this process is only the unit tests' host:
/// the tests build their own engines with fakes, and the real app would tap the owner's
/// apps, answer the Chrome extension and grab the media keys while the tests run.
@main
enum DeciMain {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil {
            TestHostApp.main()
        } else {
            DeciApp.main()
        }
    }
}

/// Inert stand-in for DeciApp while hosting unit tests.
struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct DeciApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var audioEngine: AudioEngine
    @State private var accessibility: AccessibilityPermissionService
    @State private var mediaKeyStatus: MediaKeyStatus
    @State private var popupVisibility: PopupVisibilityService
    @State private var hudController: HUDWindowController
    @State private var mediaKeyMonitor: MediaKeyMonitor
    @State private var feedbackPlayer: VolumeFeedbackPlayer
    @State private var iconCoordinator: MenuBarIconCoordinator
    @State private var menuBarPopupController: MenuBarPopupController
    @State private var shortcutsRegistry: ShortcutsRegistry
    @State private var musicHost: MusicServiceHost
    @State private var musicChip: MusicMenuBarChipController
    @StateObject private var updateManager = UpdateManager()
    @State private var showMenuBarExtra = true

    /// Snapshot icon computed at launch from the user's chosen style and the current
    /// default-device volume/mute. The coordinator keeps it in sync afterwards.
    private let launchIconImage: NSImage

    /// The Music icon. It never changes, so there is no coordinator behind it.
    private let launchMusicIconImage: NSImage

    var body: some Scene {
        // Declared before FluidMenuBarExtra so this Settings scene wins over
        // FluidMenuBarExtra's `Settings {}` placeholder. Both ⌘, and the
        // gear button route here via openSettings().
        Settings {
            SettingsRootView(
                settings: audioEngine.settingsManager,
                audioEngine: audioEngine,
                deviceVolumeMonitor: audioEngine.deviceVolumeMonitor as! DeviceVolumeMonitor,
                accessibility: accessibility,
                mediaKeyStatus: mediaKeyStatus,
                mediaKeyMonitor: mediaKeyMonitor,
                shortcutsRegistry: shortcutsRegistry,
                updateManager: updateManager,
                onSettingsReset: { musicHost.settingsDidReset() }
            )
        }
        // Scene order is creation order: the Mixer stays first, so it keeps the status item
        // autosave name "Item-0" and the icon stays where the owner put it.
        FluidMenuBarExtra(MenuBarItemID.mixer.title, image: launchIconImage) {
            menuBarContent
        }
        FluidMenuBarExtra(MenuBarItemID.music.title, image: launchMusicIconImage, isInserted: musicItemInserted) {
            musicMenuBarContent
        }
    }

    /// Whether the Music icon is in the menu bar, backed by the setting. FluidMenuBarExtra writes
    /// to this when the icon is removed with cmd-drag, which turns the setting off.
    private var musicItemInserted: Binding<Bool> {
        let settings = audioEngine.settingsManager
        return Binding(
            get: { settings.appSettings.showMusicInMenuBar },
            set: { shown in
                // Not while the item is being renamed: a visibility change AppKit makes then is not the owner's.
                guard !MenuBarStatusItems.isConfiguringMusicItem,
                      settings.appSettings.showMusicInMenuBar != shown else { return }
                settings.appSettings.showMusicInMenuBar = shown
            }
        )
    }

    @ViewBuilder
    private var menuBarContent: some View {
        // `deviceVolumeMonitor` is declared as `any DeviceVolumeProviding` on
        // AudioEngine so tests can inject mocks; in production it's always the
        // concrete `DeviceVolumeMonitor` that this view consumes directly.
        MenuBarPopupView(
            audioEngine: audioEngine,
            deviceVolumeMonitor: audioEngine.deviceVolumeMonitor as! DeviceVolumeMonitor,
            updateManager: updateManager,
            permission: audioEngine.permission,
            accessibility: accessibility,
            mediaKeyStatus: mediaKeyStatus,
            popupVisibility: popupVisibility,
            hudController: hudController,
            mediaKeyMonitor: mediaKeyMonitor,
            musicHost: musicHost
        )
        .task {
            // Idempotent: subsequent task runs (popup re-open) are no-ops inside start().
            shortcutsRegistry.start()
        }
    }

    @ViewBuilder
    private var musicMenuBarContent: some View {
        MusicPopupView(
            musicHost: musicHost,
            settings: audioEngine.settingsManager,
            popupVisibility: popupVisibility
        )
    }

    /// Tells the Chrome bridge which tabs to track. While tabs are on, also makes sure Chrome
    /// can find DeciHost (a no-op when the manifest is already right, and skipped unless
    /// Deci runs from an Applications folder with Chrome installed).
    private static func applyChromeTracking(tabs: Bool, incognito: Bool) {
        ChromeExtensionManager.shared.setTracking(tabs: tabs, incognito: incognito)
        if tabs { ChromeExtensionInstaller.live().ensureHostManifestLoggingErrors() }
    }

    init() {
        // Install crash handler to clean up aggregate devices on abnormal exit
        CrashGuard.install()
        // Destroy any orphaned aggregate devices from previous crashes
        OrphanedTapCleanup.destroyOrphanedDevices()

        // Ensure macOS ControlCenter never marks the status item as hidden/removed
        UserDefaults.standard.set(1, forKey: "NSStatusItem VisibleCC Item-0")
        UserDefaults.standard.set(1, forKey: "NSStatusItem Visible Item-0")

        #if DEBUG
        DebugFaults.install()
        // Debug runs can keep their settings out of the owner's real settings.json.
        let settings = SettingsManager(directory: ProcessInfo.processInfo.environment["DECI_DEBUG_SETTINGS_DIR"].map { URL(fileURLWithPath: $0) })
        #else
        let settings = SettingsManager()
        #endif
        // The App Volume Up, App Volume Down and App Mute hotkeys are gone: clear what they left in settings.json and
        // in KeyboardShortcuts' own defaults, before the registry reads either.
        ShortcutMigration.dropRemovedShortcuts(from: settings)
        let profileManager = AutoEQProfileManager()
        let permission = AudioRecordingPermission()
        let engine = AudioEngine(permission: permission, settingsManager: settings, autoEQProfileManager: profileManager)
        _audioEngine = State(initialValue: engine)

        // Initialize Chrome extension manager for tab audio control, with the saved tracking
        // switches. Every later change (Settings toggles, Reset All) arrives through the hooks.
        ChromeExtensionManager.shared.setYTMusicAutoSwitch(settings.appSettings.chromeYTMusicAutoSwitch)
        Self.applyChromeTracking(
            tabs: settings.appSettings.chromeTabsEnabled,
            incognito: settings.appSettings.chromeIncognitoEnabled
        )
        settings.onChromeTrackingChange = { tabs, incognito in
            Self.applyChromeTracking(tabs: tabs, incognito: incognito)
        }
        settings.onChromeYTMusicAutoSwitchChange = { enabled in
            ChromeExtensionManager.shared.setYTMusicAutoSwitch(enabled)
        }

        // Media keys / HUD services — instantiated at app scope so the tap
        // and HUD panel outlive popup open/close cycles.
        let accessibilityService = AccessibilityPermissionService()
        let statusService = MediaKeyStatus()
        let popupService = PopupVisibilityService()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: statusService, popupVisibility: popupService)
        let feedbackPlayer = VolumeFeedbackPlayer()

        // Wire the interactive Tahoe slider back to the device volume monitor.
        // Mirrors the mute semantics applied for media-key drags (auto-unmute
        // when ramping above 0 from muted; auto-mute when dragging down to 0)
        // so the HUD slider and F11/F12 behave identically.
        hud.volumeWriter = { [weak engine] sliderFraction in
            guard let engine else { return }
            let volumeMonitor = engine.deviceVolumeMonitor
            let deviceID = volumeMonitor.defaultDeviceID
            guard deviceID.isValid else { return }
            let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
            let currentMute = volumeMonitor.muteStates[deviceID] ?? false
            let willBeSilent = sliderFraction <= 0.001
            if currentMute && !willBeSilent {
                volumeMonitor.setMute(for: deviceID, to: false)
            } else if !currentMute && willBeSilent {
                volumeMonitor.setMute(for: deviceID, to: true)
            }
            let gain = VolumeMapping.systemGain(forSliderFraction: sliderFraction, tier: tier)
            volumeMonitor.setVolume(for: deviceID, to: gain)
            feedbackPlayer.requestFeedback(
                gain: VolumeFeedback.gain(tier: tier, sliderFraction: sliderFraction)
            )
        }

        let monitor = MediaKeyMonitor(
            decoder: IOKitMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: accessibilityService,
            hudController: hud,
            popupVisibility: popupService,
            mediaKeyStatus: statusService
        )
        monitor.feedbackPlayer = feedbackPlayer
        _accessibility = State(initialValue: accessibilityService)
        _mediaKeyStatus = State(initialValue: statusService)
        _popupVisibility = State(initialValue: popupService)
        _hudController = State(initialValue: hud)
        _mediaKeyMonitor = State(initialValue: monitor)
        _feedbackPlayer = State(initialValue: feedbackPlayer)

        let coordinator = MenuBarIconCoordinator(
            deviceVolumeMonitor: engine.deviceVolumeMonitor as! DeviceVolumeMonitor,
            deviceProvider: engine.deviceMonitor,
            settings: settings
        )
        monitor.iconCoordinator = coordinator
        // Defer start() so NSApplication.shared is fully bootstrapped before we walk NSApp.windows.
        DispatchQueue.main.async { [coordinator] in coordinator.start() }
        // The Music scene builds its status item at the same time, so it is named the same way.
        DispatchQueue.main.async { [settings] in
            MenuBarStatusItems.configureMusicItem { settings.appSettings.showMusicInMenuBar }
        }
        _iconCoordinator = State(initialValue: coordinator)


        // Render the scene's first frame with the user's chosen style instead of a generic
        // placeholder, so non-speaker styles don't briefly flash a speaker icon at launch.
        let launchVolumeMonitor = engine.deviceVolumeMonitor
        let launchID = launchVolumeMonitor.defaultDeviceID
        let launchState = MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: launchVolumeMonitor.volumes[launchID] ?? 1.0,
            muted: launchVolumeMonitor.muteStates[launchID] ?? false,
            deviceSymbol: MenuBarDeviceIconResolver.resolveSymbol(
                priorityOrder: settings.devicePriorityOrder,
                outputDevices: engine.deviceMonitor.outputDevices,
                defaultDeviceID: launchID,
                overrideForUID: { settings.getDeviceIconOverride(for: $0) }
            )
        )
        // The fallback must go through the shared canvas too, or the status
        // item launches at natural symbol width and jumps on the first apply().
        let mixerIcon = launchState.image.nsImage()
            ?? MenuBarIconImage.systemSymbol("speaker.wave.2").nsImage()!
        launchIconImage = mixerIcon
        // Same canvas as the Mixer icon, so the two items are the same width.
        launchMusicIconImage = MenuBarIconImage.systemSymbol("music.note")
            .nsImage(accessibilityDescription: MenuBarItemID.music.title) ?? mixerIcon

        // Start Accessibility polling immediately so `isTrustedCached` is live
        // before the user first opens Settings. The trust-flip callback wires
        // the monitor to reconcile its tap state whenever trust changes — this
        // is the single source of truth for retroactive start/stop (a `.onChange`
        // inside MenuBarPopupView would miss flips when the popup is closed).
        accessibilityService.onTrustChanged = { [weak monitor] _ in
            monitor?.reconcile()
        }
        accessibilityService.start()
        monitor.reconcile()

        // Global hotkeys (KeyboardShortcuts SPM, Carbon-backed; no Accessibility
        // permission required for the hotkey itself). Registry start() is deferred
        // to a SwiftUI `.task` on the popup content so the FluidMenuBarExtra
        // status item has been materialized before any hotkey can fire.
        let popupController = MenuBarPopupController()
        // The music player row (shown as Deci) plays inside Deci, where the process taps never reach: the engine tells this model about
        // the global audio switches and device events instead, and the model shapes the player's own audio.
        let mixer = MusicMixerState(settings: settings, environment: EngineMusicEnvironment(engine: engine))
        engine.inProcessAudio = mixer
        let music = MusicServiceHost(mixer: mixer, settings: settings)
        // Only this boolean reaches Chrome: while Deci plays, the extension stops auto-clicking "Switch".
        music.onNativePlayingChange = { ChromeExtensionManager.shared.setNativeMusicPlaying($0) }
        _musicHost = State(initialValue: music)
        // One opener for the Music popup: the Save hotkey and the hover card's buttons open it the same way.
        let musicPopupOpener = MusicPopupOpener()
        // The hotkeys and the song menus report a Like or Dislike the same way: the popup's notice line, else the HUD.
        let outcomes = MusicOutcomeReporter(musicHost: music, popupOpener: musicPopupOpener, hud: hud)
        music.outcomes = outcomes
        let registry = ShortcutsRegistry(
            settings: settings,
            popupController: popupController,
            music: MusicShortcutActions(musicHost: music, popupOpener: musicPopupOpener),
            outcomes: outcomes
        )
        _menuBarPopupController = State(initialValue: popupController)
        _shortcutsRegistry = State(initialValue: registry)
        // The icon follows the setting from here, not from the views: the scenes' own change handlers only
        // run while their views are live.
        settings.onShowMusicInMenuBarChange = { [popupService, music] shown in
            MenuBarStatusItems.applyMusicVisibility(shown, popupVisibility: popupService, musicHost: music)
        }
        // The Now playing chip style puts the song on the Music item's button and a hover card under it. Started once
        // the scene has built the item, like the icon coordinator.
        let chip = MusicMenuBarChipController(
            settings: settings,
            musicHost: music,
            iconImage: launchMusicIconImage,
            hud: hud,
            popupOpener: musicPopupOpener
        )
        _musicChip = State(initialValue: chip)
        DispatchQueue.main.async { [chip] in chip.start() }

        // Pass engine to AppDelegate
        _appDelegate.wrappedValue.audioEngine = engine

        if permission.status == .unknown {
            permission.request()
        }

        // DeviceVolumeMonitor is now created and started inside AudioEngine
        // This ensures proper initialization order: deviceMonitor.start() -> deviceVolumeMonitor.start()

        // Set delegate before requesting authorization so willPresent is called
        UNUserNotificationCenter.current().delegate = _appDelegate.wrappedValue

        // Request notification authorization (for device disconnect alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            // If not granted, notifications will silently not appear - acceptable behavior
        }

        // Flush debounced settings + tear down the CGEventTap before dealloc.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [settings, monitor, accessibilityService, hud, coordinator, music, chip] _ in
            MainActor.assumeIsolated {
                chip.stop()
                coordinator.stop()
                monitor.stop()
                accessibilityService.stop()
                hud.shutdown()
                music.shutdown()
                // Stopping music queues one last options message; the app exits before the batch timer fires.
                ChromeExtensionManager.shared.flushMessages()
                settings.flushSync()
            }
        }
    }
}
