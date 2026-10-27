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
                // The caption fills its width, so without this the column and the spacer split the free width.
                .layoutPriority(1)

                Spacer(minLength: DesignTokens.Spacing.xs)

                // Volume Controls, Mixer, and Multi-Device
                let currentDeviceUID = tab.deviceName.flatMap { name in devices.first(where: { $0.name == name })?.uid }
                let controls = Self.controls(for: tab)
                AppRowControls(
                    volume: Self.displayedVolume(for: tab),
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
                    isVolumeEnabled: controls.volumeAndMute,
                    isEnabled: controls.boostEQAndOutputs,
                    // A tab already in Multi keeps the toggle, so it can be flipped back.
                    showModeToggle: chromeManager.allowsTabMultiDevice || tab.deviceSelectionMode == .multi,
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
        .onChange(of: tab.isCaptured) { _, isCaptured in
            // EQ is unavailable on a tab that is not captured, so don't leave its panel open.
            if !isCaptured { isEQExpanded = false }
        }
        .onChange(of: tab.eqSettings) { _, newEQ in
            // Update local state if the tab model changes (e.g. from background sync)
            localEQSettings = newEQ
        }
    }

    /// One quiet line under the title. Not being captured yet outranks any device problem.
    @ViewBuilder
    private var statusCaption: some View {
        if let note = Self.captureNote(for: tab) {
            Button {
                ChromeExtensionInstaller.live().openExtensionPage()
            } label: {
                caption(note)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .help("Open Deci's extension page in Chrome")
            // The scrolling copy is not in the accessibility tree, so the label is given here.
            .accessibilityLabel(note)
        } else if let note = Self.multiOutputNote(for: tab, supportsMultiDevice: chromeManager.supportsMultiDevice, engineFansOutChrome: chromeManager.engineFansOutChrome) {
            caption(note.text)
        } else if tab.deviceName != nil || !tab.deviceNames.isEmpty {
            // The device guard hides a stale problem right after the user went back to the default.
            switch tab.deviceStatus {
            case .notFound:
                caption("Output not found, using default")
            case .noAccess:
                Button {
                    chromeManager.openDevicePermission()
                } label: {
                    caption("Allow device access in Chrome", color: DesignTokens.Colors.textSecondary, underline: true)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .pointerStyle(.link)
                .help("Open Chrome to allow reading speaker names")
                .accessibilityLabel("Allow device access in Chrome")
            case .defaultOutput, .pending, .routed:
                EmptyView()
            }
        }
    }

    /// A caption that scrolls while the popup is open when it is wider than its room. The render server slides it, so
    /// the app does no work per frame.
    private func caption(_ text: String, color: Color = DesignTokens.Colors.textTertiary, underline: Bool = false) -> some View {
        MusicMarquee(isPlaying: true) {
            Text(text)
                .font(.system(size: 9))
                .underline(underline)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .environment(\.musicPopupIsVisible, isPopupVisible)
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
        /// No chosen output exists: the tab plays on the default.
        case allNotFound
        /// This many chosen outputs exist no more; the others still play.
        case someNotFound(Int)
        /// The engine's Chrome row already plays on several outputs, so this tab's own ticks are not played.
        case chromeRowFansOut

        var text: String {
            switch self {
            case .reloadExtension: "Reload the Deci extension for multiple outputs"
            case .allNotFound: "Outputs not found, using default"
            case .someNotFound(let count): count == 1 ? "1 output not found" : "\(count) outputs not found"
            case .chromeRowFansOut: "Plays on the outputs of the Chrome row"
            }
        }
    }

    /// The multi-output caption for a tab, or nil when the single-output captions apply. Pure. A tab that is not
    /// captured yet is not covered: its own caption wins.
    static func multiOutputNote(for tab: ChromeTab, supportsMultiDevice: Bool, engineFansOutChrome: Bool = false) -> MultiOutputNote? {
        guard tab.isCaptured else { return nil }
        if tab.deviceSelectionMode == .multi, tab.selectedDeviceUIDs.count > 1 {
            // Whoever plays the tab on several outputs, the tab's own ticks are not what is heard.
            if engineFansOutChrome { return .chromeRowFansOut }
            if !supportsMultiDevice { return .reloadExtension }
        }
        guard !tab.deviceNames.isEmpty else { return nil }
        switch tab.deviceStatus {
        case .notFound: return .allNotFound
        case .routed: return tab.missingDeviceNames.isEmpty ? nil : .someNotFound(tab.missingDeviceNames.count)
        // noAccess has its own button, pending and default say nothing yet.
        case .noAccess, .pending, .defaultOutput: return nil
        }
    }

    /// Which controls of a tab's row respond.
    struct Controls: Equatable {
        /// The volume slider, its percentage and the mute button. Plain control: no capture needed.
        var volumeAndMute: Bool
        /// Boost, EQ and the output picker. They need a capture.
        var boostEQAndOutputs: Bool
    }

    /// The controls a tab's row lets the user touch. Pure. A captured tab has all of them; one that is not captured
    /// keeps volume and mute, and boost, EQ and outputs wait for a click on Deci in Chrome.
    static func controls(for tab: ChromeTab) -> Controls {
        Controls(volumeAndMute: true, boostEQAndOutputs: tab.isCaptured)
    }

    /// The caption of a tab that is not captured, saying what a capture adds.
    static let uncapturedCaption = "Click Deci in Chrome for boost, EQ and outputs"

    /// The caption for a tab that is not captured, or nil once it is. Pure. It outranks every device caption: the
    /// stored outputs only matter after a capture.
    static func captureNote(for tab: ChromeTab) -> String? {
        tab.isCaptured ? nil : uncapturedCaption
    }

    /// The volume the row shows for a tab. A tab that is not captured has a plain 0...1 volume, so a stored value above
    /// 1 shows as 1; the stored volume and boost are not rewritten. A captured tab shows its volume as it is. Pure.
    static func displayedVolume(for tab: ChromeTab) -> Float {
        tab.isCaptured ? tab.volume : ChromeTab.plainVolume(tab.volume)
    }

    /// The jitter a playing tab's made-up level is drawn from, before its volume scales it.
    static let jitterRange: ClosedRange<Float> = 0.1...0.7

    /// The level to show for a tab: a made-up one while the tab plays, 0 otherwise.
    static func simulatedLevel(for tab: ChromeTab, jitter: Float = .random(in: jitterRange)) -> Float {
        let isPlaying = (tab.isAudible || tab.isCaptured) && !tab.paused
        guard isPlaying, displayedVolume(for: tab) > 0, !tab.isMuted else { return 0 }
        return jitter * displayedVolume(for: tab)
    }

    private func startSimulatedVUMeter() {
        // The closure holds the manager, the tab's id and the tab as it is now (the fallback if the tab is gone), and
        // not the view: capturing the view would keep a copy of all of its inputs alive.
        levelPoller.start { [manager = chromeManager, id = tab.id, fallback = tab] in
            Self.simulatedLevel(for: manager.chromeTabs.first(where: { $0.id == id }) ?? fallback)
        }
    }
}
