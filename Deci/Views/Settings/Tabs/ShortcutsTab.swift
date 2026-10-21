// FineTune/Views/Settings/Tabs/ShortcutsTab.swift
import SwiftUI
import KeyboardShortcuts

@MainActor
struct ShortcutsTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                mediaKeysSection
                hotkeysSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onChange(of: settings.appSettings.mediaKeyControlEnabled) { _, _ in
            mediaKeyMonitor.reconcile()
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume Steps") {
            ForEach(Array(VolumeStepChord.allCases.enumerated()), id: \.element) { index, chord in
                if index > 0 { SettingsRowDivider() }
                SettingsRow(chord.label, description: description(for: chord)) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text("\(settings.appSettings.stepPercent(for: chord))%")
                            .font(DesignTokens.Typography.percentage)
                            .monospacedDigit()
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .frame(width: DesignTokens.Dimensions.settingsPercentageWidth, alignment: .trailing)
                        Stepper(chord.label, value: stepBinding(for: chord), in: VolumeStepChord.percentRange, step: 1)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func stepBinding(for chord: VolumeStepChord) -> Binding<Int> {
        switch chord {
        case .plain: $settings.appSettings.volumeStepPercent
        case .command: $settings.appSettings.volumeStepCommandPercent
        case .commandShift: $settings.appSettings.volumeStepCommandShiftPercent
        }
    }

    private func description(for chord: VolumeStepChord) -> String {
        switch chord {
        case .plain: "Per press of the volume keys. Also used by the arrow keys in the popup."
        case .command: "Step while holding Command."
        case .commandShift: "Step while holding Command and Shift."
        }
    }

    // MARK: - Media Keys

    private var mediaKeysSection: some View {
        SettingsSection("Media Keys") {
            SettingsRow(
                "Media Keys Control",
                description: "Use F11/F12 (or volume keys) to control Deci"
            ) {
                Toggle("", isOn: $settings.appSettings.mediaKeyControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if !accessibility.isTrustedCached {
                SettingsRowDivider()
                AccessibilityPromptStrip(accessibility: accessibility)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if mediaKeyStatus.isOffline {
                SettingsRowDivider()
                MediaKeyOfflineCard {
                    mediaKeyMonitor.reconcile()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if settings.appSettings.mediaKeyControlEnabled && accessibility.isTrustedCached {
                SettingsRowDivider()
                SettingsRow(
                    "HUD Style",
                    description: "How the volume indicator appears"
                ) {
                    HUDStyleSegmentedControl(selection: $settings.appSettings.hudStyle)
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeysSection: some View {
        SettingsSection("Hotkeys") {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsRowDivider() }
                SettingsRow(
                    action.displayName,
                    description: description(for: action)
                ) {
                    KeyboardShortcuts.Recorder(
                        for: shortcutsRegistry.name(for: action),
                        onChange: shortcutsRegistry.recordCallback(for: action)
                    )
                }
            }
        }
    }

    private func description(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: "Show or hide the menu bar popup"
        case .saveSongToPlaylist: "Save the playing song to a playlist"
        case .likeSong: "Like the playing song, or remove the like"
        case .dislikeSong: "Dislike the playing song and skip it"
        }
    }
}
