// FineTune/Views/Settings/Tabs/GeneralTab.swift
import SwiftUI

@MainActor
struct GeneralTab: View {
    @Bindable var settings: SettingsManager
    let downloads: MusicDownloadsSettingsModel
    let onResetAll: () -> Void

    @State private var showResetConfirmation = false
    @State private var showRemoveDownloadsConfirmation = false
    private let chrome = ChromeExtensionManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                generalSection
                menuBarSection
                chromeSection
                downloadsSection
                dataSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { onResetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .onAppear {
            // Settles the connection verdict the Chrome section needs.
            if settings.appSettings.chromeTabsEnabled { chrome.requestTabs() }
        }
        .onChange(of: settings.appSettings.chromeTabsEnabled) { _, enabled in
            if enabled { chrome.requestTabs() }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection("General") {
            SettingsRow(
                "Launch at Login",
                description: "Start Deci when you log in"
            ) {
                Toggle("", isOn: $settings.appSettings.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Theme",
                description: "Match macOS, or lock to Light or Dark"
            ) {
                ThemeTilePicker(selection: $settings.appSettings.appearance)
            }
            SettingsRowDivider()
            SettingsRow(
                "Device Disconnect Alerts",
                description: "Show notification when an audio device disconnects"
            ) {
                Toggle("", isOn: $settings.appSettings.showDeviceDisconnectAlerts)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Menu Bar

    private var menuBarSection: some View {
        SettingsSection("Menu Bar") {
            SettingsRow(
                "Icon Style",
                description: "How Deci appears in your menu bar"
            ) {
                IconStyleSegmentedControl(selection: $settings.appSettings.menuBarIconStyle)
            }
            SettingsRowDivider()
            SettingsRow(
                "Popup Size",
                description: "Smaller fits more on screen; larger leaves more breathing room."
            ) {
                PopupSizeTilePicker(selection: $settings.appSettings.popupSize)
            }
            SettingsRowDivider()
            SettingsRow(
                "Show Music in menu bar",
                description: "A second icon for the music player. Playback keeps going when it is hidden."
            ) {
                Toggle("", isOn: $settings.appSettings.showMusicInMenuBar)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Menu bar style",
                description: "The Music icon, or a small chip with the song's cover and title while one is loaded. Hover the chip for controls."
            ) {
                Picker("", selection: $settings.appSettings.musicMenuBarStyle) {
                    ForEach(MusicMenuBarStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(!settings.appSettings.showMusicInMenuBar)
            }
        }
    }

    // MARK: - Chrome

    private var chromeSection: some View {
        SettingsSection("Chrome") {
            SettingsRow(
                "Chrome tabs",
                description: "Show Chrome tabs in Deci so you can set their volume."
            ) {
                Toggle("", isOn: $settings.appSettings.chromeTabsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if settings.appSettings.chromeTabsEnabled {
                SettingsRowDivider()
                SettingsRow(
                    "Incognito tabs",
                    description: "Also show tabs from incognito windows."
                ) {
                    Toggle("", isOn: $settings.appSettings.chromeIncognitoEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }

                if settings.appSettings.chromeIncognitoEnabled
                    && chrome.connectionState == .connected
                    && !chrome.incognitoAllowed {
                    Text("Turn on Allow in Incognito for Deci in chrome://extensions.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                if chrome.connectionState == .disconnected {
                    SettingsRowDivider()
                    ChromeInstallStrip(chrome: chrome)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }

            SettingsRowDivider()
            SettingsRow(
                "Keep YouTube Music here",
                description: "Click “Switch” when YouTube Music says your account is playing on another device."
            ) {
                Toggle("", isOn: $settings.appSettings.chromeYTMusicAutoSwitch)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Downloads

    private var downloadsSection: some View {
        SettingsSection(MusicDownloadSettingsText.sectionTitle) {
            SettingsRow(
                MusicDownloadSettingsText.storageTitle,
                description: downloads.summary
            ) {
                Text(downloads.sizeText)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 96, alignment: .trailing)
            }
            SettingsRowDivider()
            SettingsRow(
                MusicDownloadSettingsText.removeTitle,
                description: MusicDownloadSettingsText.removeDescription
            ) {
                HStack(spacing: 8) {
                    if let removing = downloads.removingText {
                        ProgressView()
                            .controlSize(.small)
                        Text(removing)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        showRemoveDownloadsConfirmation = true
                    } label: {
                        Text(MusicDownloadSettingsText.removeButton)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(!downloads.canRemoveAll)
                }
            }

            // How the last removal ended, when it fell short: red when items could not be removed.
            if let caption = downloads.wipeCaption {
                Text(caption.text)
                    .font(.system(size: 11))
                    .foregroundStyle(caption.isFailure ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .confirmationDialog(
            MusicDownloadSettingsText.confirmationTitle,
            isPresented: $showRemoveDownloadsConfirmation,
            titleVisibility: .visible
        ) {
            Button(MusicDownloadSettingsText.confirmButton, role: .destructive) {
                Task { await downloads.removeAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(downloads.confirmationMessage)
        }
        // Reads the counts and the size when the tab shows, and again whenever the download set changes.
        .task { await downloads.watch() }
    }

    // MARK: - Data

    private var dataSection: some View {
        SettingsSection("Data") {
            SettingsRow(
                "Reset All Settings",
                description: "Clear all volumes, EQ, and device routings"
            ) {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Text("Reset")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
    }
}
