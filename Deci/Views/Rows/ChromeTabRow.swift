import SwiftUI
import AppKit

/// A row displaying an individual Google Chrome tab with playback and volume controls.
struct ChromeTabRow: View {
    let tab: ChromeTab
    /// False while the popup is closed: the meter stops its timer and rests.
    let isPopupVisible: Bool

    let devices: [AudioDevice]
    let defaultDeviceUID: String?
    
    let userPresets: [UserEQPreset]
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void

    @State private var isEQExpanded = false
    @State private var levelPoller = LevelPoller()

    private var chromeManager: ChromeExtensionManager {
        ChromeExtensionManager.shared
    }

    private var chromeIcon: some View {
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        }
        return Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
    }

    @State private var localEQSettings = EQSettings()

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                // VU Meter
                PolledVUMeter(poller: levelPoller, isMuted: tab.isMuted || tab.volume == 0)

                // Tab Favicon
                Group {
                    // Incognito favicons are never fetched: AsyncImage would put them in Deci's URL cache.
                    if !tab.isIncognito, let urlString = tab.favIconUrl, !urlString.isEmpty, let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                chromeIcon
                            }
                        }
                        .frame(width: 18, height: 18)
                    } else {
                        chromeIcon.frame(width: 18, height: 18)
                    }
                }
                .frame(width: 24, height: 24)

                // Title + Playback Info
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text(tab.title.isEmpty ? "Chrome Tab" : tab.title)
                            .font(DesignTokens.Typography.rowName)
                            .lineLimit(1)
                            .help(tab.title)

                        if tab.isIncognito {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 10))
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                                .help("Incognito tab")
                                .accessibilityLabel("Incognito tab")
                        }
                    }

                    statusCaption
                }

                Spacer(minLength: DesignTokens.Spacing.xs)

                // Volume Controls, Mixer, and Multi-Device
                let currentDeviceUID = tab.deviceName.flatMap { name in devices.first(where: { $0.name == name })?.uid }
                AppRowControls(
                    volume: tab.volume,
                    isMuted: tab.isMuted,
                    devices: devices,
                    deviceIconOverrides: [:],
                    selectedDeviceUID: currentDeviceUID ?? defaultDeviceUID ?? "",
                    selectedDeviceUIDs: tab.selectedDeviceUIDs,
                    isFollowingDefault: tab.deviceName == nil,
                    defaultDeviceUID: defaultDeviceUID,
                    deviceSelectionMode: tab.deviceSelectionMode,
                    boost: tab.boost,
                    isEQExpanded: isEQExpanded,
                    isEnabled: tab.isControlled,
                    onVolumeChange: { newVolume in
                        chromeManager.setTabVolume(tabId: tab.id, volume: newVolume)
                    },
                    onMuteChange: { mute in
                        chromeManager.setTabMuted(tabId: tab.id, muted: mute)
                    },
                    onBoostChange: { newBoost in
                        chromeManager.setTabBoost(tabId: tab.id, boost: newBoost)
                    },
                    onDeviceSelected: { deviceUID in
                        let deviceName = devices.first(where: { $0.uid == deviceUID })?.name
                        chromeManager.setTabDevice(tabId: tab.id, deviceName: deviceName)
                    },
                    onDevicesSelected: { deviceUIDs in
                        chromeManager.setTabDevices(tabId: tab.id, deviceUIDs: deviceUIDs)
                    },
                    onDeviceModeChange: { mode in
                        chromeManager.setTabDeviceSelectionMode(tabId: tab.id, to: mode)
                    },
                    onSelectFollowDefault: { 
                        chromeManager.setTabDevice(tabId: tab.id, deviceName: nil)
                    },
                    onEQToggle: { isEQExpanded.toggle() }
                )
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            EQPanelView(
                settings: Binding(
                    get: { localEQSettings },
                    set: { newSettings in 
                        localEQSettings = newSettings
                        chromeManager.setTabEQ(tabId: tab.id, eqSettings: newSettings)
                    }
                ),
                userPresets: userPresets,
                onPresetSelected: { preset in
                    localEQSettings = preset.settings
                    chromeManager.setTabEQ(tabId: tab.id, eqSettings: preset.settings)
                },
                onUserPresetSelected: { userPreset in
                    localEQSettings = userPreset.settings
                    chromeManager.setTabEQ(tabId: tab.id, eqSettings: userPreset.settings)
                },
                onSettingsChanged: { newSettings in
                    chromeManager.setTabEQ(tabId: tab.id, eqSettings: newSettings)
                },
                onSavePreset: onSavePreset,
                onDeleteUserPreset: onDeleteUserPreset,
                onRenameUserPreset: onRenameUserPreset
            )
        }
        .onAppear {
            localEQSettings = tab.eqSettings
            syncOutputDevices()
            if isPopupVisible { startSimulatedVUMeter() }
        }
        .onChange(of: devices) { _, _ in syncOutputDevices() }
        .onChange(of: defaultDeviceUID) { _, _ in syncOutputDevices() }
        .onDisappear {
            levelPoller.stop()
        }
        .onChange(of: isPopupVisible) { _, visible in
            if visible {
                startSimulatedVUMeter()
            } else {
                levelPoller.stop()
            }
        }
        .onChange(of: tab.isControlled) { _, isControlled in
            // EQ is unavailable on an uncontrolled tab, so don't leave its panel open.
            if !isControlled { isEQExpanded = false }
        }
        .onChange(of: tab.eqSettings) { _, newEQ in
            // Update local state if the tab model changes (e.g. from background sync)
            localEQSettings = newEQ
        }
    }

    /// One quiet line under the title. Not being controllable yet outranks any device problem.
    @ViewBuilder
    private var statusCaption: some View {
        if !tab.isControlled {
            Text("Click Deci in Chrome to control")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .lineLimit(1)
        } else if let note = Self.multiOutputNote(for: tab, supportsMultiDevice: chromeManager.supportsMultiDevice) {
            Text(note.text)
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .lineLimit(1)
        } else if tab.control == .page || tab.control == .armed, tab.deviceName != nil {
            // In-page control cannot pick an output; the stored device waits for a capture.
            Text("Click Deci in Chrome to use this output")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .lineLimit(1)
        } else if tab.deviceName != nil || !tab.deviceNames.isEmpty {
            // The device guard hides a stale problem right after the user went back to the default.
            switch tab.deviceStatus {
            case .notFound:
                Text("Output not found, using default")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .lineLimit(1)
            case .noAccess:
                Button {
                    chromeManager.openDevicePermission()
                } label: {
                    Text("Allow device access in Chrome")
                        .font(.system(size: 9))
                        .underline()
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open Chrome to allow reading speaker names")
            case .defaultOutput, .pending, .routed:
                EmptyView()
            }
        }
    }

    /// Hands the manager the output devices the picker shows, so it can turn UIDs into the names the extension
    /// matches on. Cheap to repeat: the manager ignores a list it already has.
    private func syncOutputDevices() {
        chromeManager.updateOutputDevices(devices, defaultDeviceUID: defaultDeviceUID)
    }

    /// The caption a multi-output tab can need instead of the single-output ones.
    enum MultiOutputNote: Equatable {
        /// Multi is picked with several devices, but the extension predates SET_TAB_DEVICES and plays on one.
        case reloadExtension
        /// The outputs are stored, but the page is not captured, so nothing routes yet.
        case clickToUse
        /// No chosen output exists: the tab plays on the default.
        case allNotFound
        /// This many chosen outputs exist no more; the others still play.
        case someNotFound(Int)

        var text: String {
            switch self {
            case .reloadExtension: "Reload the Deci extension for multiple outputs"
            case .clickToUse: "Click Deci in Chrome to use these outputs"
            case .allNotFound: "Outputs not found, using default"
            case .someNotFound(let count): count == 1 ? "1 output not found" : "\(count) outputs not found"
            }
        }
    }

    /// The multi-output caption for a tab, or nil when the single-output captions apply. Pure. A tab that cannot
    /// be controlled yet is not covered: its own caption wins.
    static func multiOutputNote(for tab: ChromeTab, supportsMultiDevice: Bool) -> MultiOutputNote? {
        guard tab.isControlled else { return nil }
        if tab.deviceSelectionMode == .multi, !supportsMultiDevice, tab.selectedDeviceUIDs.count > 1 {
            return .reloadExtension
        }
        guard !tab.deviceNames.isEmpty else { return nil }
        guard tab.control == .capture else { return .clickToUse }
        switch tab.deviceStatus {
        case .notFound: return .allNotFound
        case .routed: return tab.missingDeviceNames.isEmpty ? nil : .someNotFound(tab.missingDeviceNames.count)
        // noAccess has its own button, pending and default say nothing yet.
        case .noAccess, .pending, .defaultOutput: return nil
        }
    }

    /// The jitter a playing tab's made-up level is drawn from, before its volume scales it.
    static let jitterRange: ClosedRange<Float> = 0.1...0.7

    /// The level to show for a tab: a made-up one while the tab plays, 0 otherwise.
    static func simulatedLevel(for tab: ChromeTab, jitter: Float = .random(in: jitterRange)) -> Float {
        let isPlaying = (tab.isAudible || tab.isCaptured) && !tab.paused
        guard isPlaying, tab.volume > 0, !tab.isMuted else { return 0 }
        return jitter * tab.volume
    }

    private func startSimulatedVUMeter() {
        // The closure holds the manager, the tab's id and the tab as it is now (the fallback if the tab is gone), and
        // not the view: capturing the view would keep a copy of all of its inputs alive.
        levelPoller.start { [manager = chromeManager, id = tab.id, fallback = tab] in
            Self.simulatedLevel(for: manager.chromeTabs.first(where: { $0.id == id }) ?? fallback)
        }
    }
}
