// Deci/Views/Rows/MusicMixerRow.swift
import SwiftUI

/// The YouTube Music player's row in the Mixer tab: a real peak meter, volume, mute, boost, output device and the
/// 10-band EQ, all acting on the audio the player makes inside Deci through `MusicMixerState`.
///
/// Built like `ChromeTabRow`, with the device picker in single mode: music has one output, not a set of them.
struct MusicMixerRow: View {
    let mixer: MusicMixerState
    let devices: [AudioDevice]
    var deviceIconOverrides: [String: String] = [:]
    let defaultDeviceUID: String?
    var isPopupVisible = true

    let userPresets: [UserEQPreset]
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void

    @State private var isEQExpanded: Bool
    @State private var displayLevel: Float = 0
    @State private var levelTimer: Timer?

    init(
        mixer: MusicMixerState,
        devices: [AudioDevice],
        deviceIconOverrides: [String: String] = [:],
        defaultDeviceUID: String?,
        isPopupVisible: Bool = true,
        userPresets: [UserEQPreset] = [],
        onSavePreset: @escaping (String, EQSettings) -> Void = { _, _ in },
        onDeleteUserPreset: @escaping (UUID) -> Void = { _ in },
        onRenameUserPreset: @escaping (UUID, String) -> Void = { _, _ in },
        isEQExpanded: Bool = false
    ) {
        self.mixer = mixer
        self.devices = devices
        self.deviceIconOverrides = deviceIconOverrides
        self.defaultDeviceUID = defaultDeviceUID
        self.isPopupVisible = isPopupVisible
        self.userPresets = userPresets
        self.onSavePreset = onSavePreset
        self.onDeleteUserPreset = onDeleteUserPreset
        self.onRenameUserPreset = onRenameUserPreset
        _isEQExpanded = State(initialValue: isEQExpanded)
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

                iconTile

                VStack(alignment: .leading, spacing: 1) {
                    Text("YouTube Music")
                        .font(DesignTokens.Typography.rowName)
                        .lineLimit(1)

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
                    onEQToggle: { isEQExpanded.toggle() }
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

    /// The same 24 pt slot an app icon gets, with a music note on the accent gradient.
    private var iconTile: some View {
        let size = DesignTokens.Dimensions.rowContentHeight - 4
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
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
