// FineTune/Views/Settings/Tabs/ShortcutsTab.swift
import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
struct ShortcutsTab: View {
    @Bindable var settings: SettingsManager
    let audioEngine: AudioEngine
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let volumeKeyRecorder: VolumeKeyRecorder
    let shortcutsRegistry: ShortcutsRegistry

    /// The apps open now, for the targets of the volume keybinds: one that is silent can be picked too.
    @State private var runningApps: [VolumeKeyTarget] = []

    private static let targetWidth: CGFloat = 150

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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
        // The monitor listens system-wide, so a recording left open would take a volume key pressed anywhere.
        .onChange(of: canRecordVolumeKey) { _, canRecord in
            if !canRecord { volumeKeyRecorder.cancel() }
        }
        .onDisappear { volumeKeyRecorder.cancel() }
        // Only this window: a popup or the HUD resigning key says nothing about a recording in Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard Self.isSettingsWindow(notification) else { return }
            volumeKeyRecorder.cancel()
        }
        .onExitCommand { volumeKeyRecorder.cancel() }
        .onAppear { refreshRunningApps() }
        .onReceive(Self.workspaceChanges(NSWorkspace.didLaunchApplicationNotification)) { _ in refreshRunningApps() }
        .onReceive(Self.workspaceChanges(NSWorkspace.didTerminateApplicationNotification)) { _ in refreshRunningApps() }
    }

    private static func workspaceChanges(_ name: Notification.Name) -> NotificationCenter.Publisher {
        NSWorkspace.shared.notificationCenter.publisher(for: name)
    }

    private func refreshRunningApps() {
        runningApps = VolumeKeyTargetMenu.runningApps()
    }

    /// Whether a window notification is about the Settings window, found by the title `WindowTitleBridge` pins.
    static func isSettingsWindow(_ notification: Notification) -> Bool {
        (notification.object as? NSWindow)?.title == SettingsRootView.windowTitle
    }

    // MARK: - Media Keys

    private var mediaKeysSection: some View {
        SettingsSection("Media Keys") {
            SettingsRow(
                "Media Keys Control",
                description: "Use the media keys (F7 to F12) to control Deci"
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
            ForEach(settings.appSettings.volumeKeyBindings) { binding in
                SettingsRowDivider()
                volumeKeyRow(binding)
            }
            SettingsRowDivider()
            addVolumeKeybindRow
        }
    }

    // MARK: - Volume keybinds

    /// Recording needs the media key tap to be running, since a hardware volume key only reaches Deci through it.
    private var canRecordVolumeKey: Bool {
        settings.appSettings.mediaKeyControlEnabled && accessibility.isTrustedCached && !mediaKeyStatus.isOffline
    }

    private func volumeKeyRow(_ binding: VolumeKeyBinding) -> some View {
        let isRecording = volumeKeyRecorder.recordingID == binding.id
        let isOnlyRow = settings.appSettings.volumeKeyBindings.count == 1
        return SettingsRow("Volume step") {
            HStack(spacing: DesignTokens.Spacing.sm) {
                VolumeKeyRecorderField(combo: binding.combo, isRecording: isRecording, isEnabled: canRecordVolumeKey) {
                    if isRecording { volumeKeyRecorder.cancel() } else { volumeKeyRecorder.begin(binding.id) }
                }
                targetPicker(binding)
                Text("\(VolumeKeyBinding.clampedPercent(binding.percent))%")
                    .font(DesignTokens.Typography.percentage)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: DesignTokens.Dimensions.settingsPercentageWidth, alignment: .trailing)
                Stepper(binding.combo.label, value: percentBinding(for: binding.id), in: VolumeKeyBinding.percentRange, step: 1)
                    .labelsHidden()
                    .controlSize(.small)
                Button {
                    remove(binding.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(isOnlyRow)
                .help(isOnlyRow ? "At least one volume keybind stays" : "Remove this volume keybind")
            }
        }
    }

    private func targetPicker(_ binding: VolumeKeyBinding) -> some View {
        let apps = VolumeKeyTargetMenu.apps(
            saved: binding.target,
            mixer: audioEngine.displayableApps,
            running: runningApps,
            isIgnored: { audioEngine.isIgnored(identifier: $0) }
        )
        return Picker("Controls", selection: targetBinding(for: binding.id)) {
            Text("Default output").tag(VolumeKeyTarget.defaultOutput)
            Text("App in front").tag(VolumeKeyTarget.frontApp)
            Divider()
            ForEach(apps, id: \.appIdentifier) { target in
                Text(target.menuTitle).tag(target)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: Self.targetWidth, alignment: .trailing)
        .help("What these keys control. Mute with the same modifiers mutes it.")
    }

    private var addVolumeKeybindRow: some View {
        let isFull = settings.appSettings.volumeKeyBindings.count >= VolumeKeyBinding.maxCount
        return SettingsRow(
            "Add volume keybind",
            description: isFull
                ? "Up to \(VolumeKeyBinding.maxCount) volume keybinds."
                : "Hold modifiers with F11 / F12 for their own step, on the default output or one app. The plain step also "
                    + "sets the popup's arrow keys."
        ) {
            Button("Add") {
                // The new row waits for its modifiers right away when a press can reach the recorder.
                volumeKeyRecorder.addBinding(startRecording: canRecordVolumeKey)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isFull)
        }
    }

    /// The percent of one row, looked up by id so a row removed in the meantime is never indexed.
    private func percentBinding(for id: UUID) -> Binding<Int> {
        Binding(
            get: {
                settings.appSettings.volumeKeyBindings.first { $0.id == id }
                    .map { VolumeKeyBinding.clampedPercent($0.percent) } ?? VolumeKeyBinding.percentRange.lowerBound
            },
            set: { newValue in
                var app = settings.appSettings
                guard let index = app.volumeKeyBindings.firstIndex(where: { $0.id == id }) else { return }
                app.volumeKeyBindings[index].percent = VolumeKeyBinding.clampedPercent(newValue)
                settings.appSettings = app
            }
        )
    }

    private func targetBinding(for id: UUID) -> Binding<VolumeKeyTarget> {
        Binding(
            get: { settings.appSettings.volumeKeyBindings.first { $0.id == id }?.target ?? .defaultOutput },
            set: { newValue in
                var app = settings.appSettings
                guard let index = app.volumeKeyBindings.firstIndex(where: { $0.id == id }) else { return }
                app.volumeKeyBindings[index].target = newValue
                settings.appSettings = app
            }
        )
    }

    /// The last row stays: a saved empty list reads back as the defaults, so removing it would only look like it worked.
    private func remove(_ id: UUID) {
        var app = settings.appSettings
        guard app.volumeKeyBindings.count > 1 else { return }
        if volumeKeyRecorder.recordingID == id { volumeKeyRecorder.cancel() }
        app.volumeKeyBindings.removeAll { $0.id == id }
        settings.appSettings = app
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
