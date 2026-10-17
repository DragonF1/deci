import SwiftUI
import AppKit

/// A row displaying an individual Google Chrome tab with playback and volume controls.
struct ChromeTabRow: View {
    let tab: ChromeTab
    let now: Date
    
    let devices: [AudioDevice]
    let defaultDeviceUID: String?
    
    let userPresets: [UserEQPreset]
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void

    @State private var isEQExpanded = false
    @State private var simulatedLevel: Float = 0
    @State private var levelTimer: Timer?

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
                VUMeter(level: simulatedLevel, isMuted: tab.isMuted || tab.volume == 0)

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
                    selectedDeviceUIDs: [],
                    isFollowingDefault: tab.deviceName == nil,
                    defaultDeviceUID: defaultDeviceUID,
                    deviceSelectionMode: .single,
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
                    onDevicesSelected: { _ in },
                    onDeviceModeChange: { _ in },
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
            startSimulatedVUMeter()
        }
        .onDisappear {
            stopSimulatedVUMeter()
        }
        .onChange(of: tab.isControlled) { _, isControlled in
            // EQ is unavailable on an uncontrolled tab, so don't leave its panel open.
            if !isControlled { isEQExpanded = false }
        }
        .onChange(of: tab.eqSettings) { _, newEQ in
            // Update local state if the tab model changes (e.g. from background sync)
            localEQSettings = newEQ
        }
        .onChange(of: tab.paused) { _, _ in
            // Keep simulation updating naturally
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
        } else if tab.control == .page || tab.control == .armed, tab.deviceName != nil {
            // In-page control cannot pick an output; the stored device waits for a capture.
            Text("Click Deci in Chrome to use this output")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .lineLimit(1)
        } else if tab.deviceName != nil {
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

    private func startSimulatedVUMeter() {
        guard levelTimer == nil else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: DesignTokens.Timing.vuMeterUpdateInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                let currentTab = chromeManager.chromeTabs.first(where: { $0.id == tab.id }) ?? tab
                let isPlaying = (currentTab.isAudible || currentTab.isCaptured) && !currentTab.paused
                if isPlaying && currentTab.volume > 0 && !currentTab.isMuted {
                    // Simulate an active audio level
                    simulatedLevel = Float.random(in: 0.1...0.7) * currentTab.volume
                } else {
                    simulatedLevel = 0
                }
            }
        }
    }

    private func stopSimulatedVUMeter() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}
