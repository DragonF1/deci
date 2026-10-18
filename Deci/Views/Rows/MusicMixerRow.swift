// Deci/Views/Rows/MusicMixerRow.swift
import SwiftUI

/// The music player's row in the Mixer tab: a real peak meter, volume, mute, boost, output device and the
/// 10-band EQ, all acting on the audio the player makes inside Deci through `MusicMixerState`.
///
/// It reads as one more app in the apps list: Deci's own name and icon (`MusicPlayerIdentity`), laid out exactly like
/// `AppRow`. Built like `ChromeTabRow` underneath, with the device picker in single mode: music has one output, not a
/// set of them.
struct MusicMixerRow: View {
    let mixer: MusicMixerState
    /// What the row calls itself, in the name, the tooltip and the accessibility labels.
    let name: String
    /// The icon in the row's 24 pt slot: Deci's own application icon.
    let icon: NSImage
    let devices: [AudioDevice]
    var deviceIconOverrides: [String: String] = [:]
    let defaultDeviceUID: String?
    var isPopupVisible = true

    let userPresets: [UserEQPreset]
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void

    /// Whether the EQ panel is open. Owned by the popup's accordion, like every app row's, so only one panel is open at
    /// a time and Escape closes it.
    let isEQExpanded: Bool
    let onEQToggle: () -> Void

    @State private var displayLevel: Float = 0
    @State private var levelTimer: Timer?

    init(
        mixer: MusicMixerState,
        name: String = MusicPlayerIdentity.name,
        icon: NSImage? = nil,
        devices: [AudioDevice],
        deviceIconOverrides: [String: String] = [:],
        defaultDeviceUID: String?,
        isPopupVisible: Bool = true,
        userPresets: [UserEQPreset] = [],
        onSavePreset: @escaping (String, EQSettings) -> Void = { _, _ in },
        onDeleteUserPreset: @escaping (UUID) -> Void = { _ in },
        onRenameUserPreset: @escaping (UUID, String) -> Void = { _, _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {}
    ) {
        self.mixer = mixer
        self.name = name
        self.icon = icon ?? MusicPlayerIdentity.icon
        self.devices = devices
        self.deviceIconOverrides = deviceIconOverrides
        self.defaultDeviceUID = defaultDeviceUID
        self.isPopupVisible = isPopupVisible
        self.userPresets = userPresets
        self.onSavePreset = onSavePreset
        self.onDeleteUserPreset = onDeleteUserPreset
        self.onRenameUserPreset = onRenameUserPreset
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
    }

    /// The device the music really comes out of: the chosen one while connected, otherwise the default output.
    private var routedDeviceUID: String? { mixer.outputDeviceUID }

    private var eqBinding: Binding<EQSettings> {
        Binding(get: { mixer.eqSettings }, set: { mixer.setEQ($0) })
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                VUMeter(level: displayLevel, isMuted: mixer.isMuted || mixer.volume == 0)

                iconImage

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(DesignTokens.Typography.rowName)
                        .lineLimit(1)
                        .help(name)

                    if mixer.selectedDeviceUID != nil && mixer.outputDeviceUID == nil {
                        Text("Output not found, using default")
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                // Same as AppRow: the name column takes what the controls leave, with no spacer eating into it.
                .frame(maxWidth: .infinity, alignment: .leading)

                AppRowControls(
                    volume: mixer.volume,
                    isMuted: mixer.isMuted,
                    devices: devices,
                    deviceIconOverrides: deviceIconOverrides,
                    selectedDeviceUID: routedDeviceUID ?? defaultDeviceUID ?? "",
                    selectedDeviceUIDs: [],
                    isFollowingDefault: routedDeviceUID == nil,
                    defaultDeviceUID: defaultDeviceUID,
                    deviceSelectionMode: .single,
                    boost: mixer.boost,
                    isEQExpanded: isEQExpanded,
                    onVolumeChange: { mixer.setVolume($0) },
                    onMuteChange: { mixer.setMuted($0) },
                    onBoostChange: { mixer.setBoost($0) },
                    onDeviceSelected: { mixer.selectDevice(uid: $0) },
                    onDevicesSelected: { _ in },
                    onDeviceModeChange: { _ in },
                    onSelectFollowDefault: { mixer.followDefaultDevice() },
                    onEQToggle: onEQToggle
                )
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            EQPanelView(
                settings: eqBinding,
                userPresets: userPresets,
                onPresetSelected: { mixer.setEQ($0.settings) },
                onUserPresetSelected: { mixer.setEQ($0.settings) },
                onSettingsChanged: { mixer.setEQ($0) },
                onSavePreset: onSavePreset,
                onDeleteUserPreset: onDeleteUserPreset,
                onRenameUserPreset: onRenameUserPreset
            )
            .padding(.top, DesignTokens.Spacing.sm)
        }
        .onAppear {
            if isPopupVisible { startLevelPolling() }
        }
        .onDisappear {
            stopLevelPolling()
        }
        .onChange(of: isPopupVisible) { _, visible in
            if visible {
                startLevelPolling()
            } else {
                stopLevelPolling()
                displayLevel = 0
            }
        }
    }

    /// The same 24 pt slot an app icon gets in `AppRow`. Not a button (there is nothing to open, the popover is Deci), and
    /// hidden from VoiceOver: the name beside it already says "Deci".
    private var iconImage: some View {
        Image(nsImage: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(
                width: DesignTokens.Dimensions.rowContentHeight - 4,
                height: DesignTokens.Dimensions.rowContentHeight - 4
            )
            .accessibilityHidden(true)
    }

    // MARK: - Level polling

    private func startLevelPolling() {
        guard levelTimer == nil else { return }
        levelTimer = Timer.scheduledTimer(
            withTimeInterval: DesignTokens.Timing.vuMeterUpdateInterval,
            repeats: true
        ) { _ in
            MainActor.assumeIsolated {
                // The peak is post gain, so a boosted signal can pass 1: the meter's scale ends there.
                displayLevel = min(1, mixer.sampleLevel())
            }
        }
    }

    private func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}
