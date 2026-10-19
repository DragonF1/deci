// Deci/Views/Music/MusicPopupView.swift
import SwiftUI

/// Sizes of the Music popup. It keeps the size it had as a tab of the one popup: a header row as tall
/// as the old "Mixer | Music" pill row, then a body capped so it fits the popup size setting.
nonisolated enum MusicPopupMetrics {
    /// The header row, which holds only the gear. 26 pt pill plus 3 pt of padding on each side, as before.
    static let headerHeight: CGFloat = 32

    /// The tallest the body gets, whatever the popup size setting allows.
    static let maxBodyHeight: CGFloat = 520

    /// The Music body has a fixed height, capped by the popup size setting.
    static func bodyHeight(maxContentHeight: CGFloat) -> CGFloat {
        min(maxContentHeight, maxBodyHeight)
    }
}

/// The popup of the Music menu bar item: a gear row over the Music body.
///
/// The view stays mounted while the popup is hidden, so it learns about opening and closing from the
/// key window notifications of its own window, found by title (the Mixer popup is a window of the same
/// class). It reports to `PopupVisibilityService` so the HUD stays quiet, and to the host so the lyrics
/// panel fetches and animates only while this popup is on screen.
struct MusicPopupView: View {
    /// Owns the music service. The heavy parts are built when this popup is first opened.
    let musicHost: MusicServiceHost

    let settings: SettingsManager

    /// Shared with the Mixer popup, so the HUD is suppressed while either one is open.
    let popupVisibility: PopupVisibilityService

    @Environment(\.openSettings) private var openSettings

    private var appSettings: AppSettings {
        settings.appSettings
    }

    private var popupDimensions: PopupDimensions {
        appSettings.popupSize.dimensions
    }

    private var bodyHeight: CGFloat {
        MusicPopupMetrics.bodyHeight(maxContentHeight: popupDimensions.maxContentHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .center) {
                Spacer()
                settingsButton
            }
            .frame(height: MusicPopupMetrics.headerHeight)

            if appSettings.showMusicInMenuBar {
                MusicTabView(host: musicHost, height: bodyHeight)
            } else {
                // Hidden: the player is unmounted, so its panels close, and the popup keeps its size.
                Color.clear.frame(height: bodyHeight)
            }
        }
        .padding(popupDimensions.contentPadding)
        .frame(width: popupDimensions.width)
        .background(
            WindowAppearanceBridge(appearance: appSettings.appearance.nsAppearance)
                .frame(width: 0, height: 0)
        )
        .darkGlassBackground()
        .preferredColorScheme(appSettings.appearance.swiftUIColorScheme)
        .environment(\.appearancePreference, appSettings.appearance)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard isMusicPopup(notification) else { return }
            popupVisibility.setOpen(.music, true)
            musicHost.isPopupVisible = true
            musicHost.loadIfNeeded()
            // A second chance for the rename if the launch retries ran out before the scene built the item.
            // One attempt, no retry; an item that already has its name is left alone.
            MenuBarStatusItems.nameMusicItem(shown: appSettings.showMusicInMenuBar)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard isMusicPopup(notification) else { return }
            popupVisibility.setOpen(.music, false)
            musicHost.isPopupVisible = false
            // A card left open must not greet the next open of the popup.
            musicHost.isAccountCardOpen = false
        }
        .onChange(of: appSettings.showMusicInMenuBar) { _, shown in
            // The app's settings hook is what moves the icon. This repeats it as insurance, and every step
            // does nothing when it is already done, so the two cannot loop.
            MenuBarStatusItems.applyMusicVisibility(shown, popupVisibility: popupVisibility, musicHost: musicHost)
        }
        .background {
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
    }

    // MARK: - Settings Button

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape.fill") {
            openSettingsWindow()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    /// Closes the account card if it is open, otherwise dismisses the popup.
    private func handleEscape() {
        if musicHost.closeAccountCard() { return }
        NSApp.keyWindow?.resignKey()
    }

    private func openSettingsWindow() {
        NSApp.keyWindow?.resignKey()
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    /// Key window notifications arrive for every window in the process. Only this popup's own window
    /// counts, so the Mixer popup, Settings and alerts do not mark the Music popup as open.
    private func isMusicPopup(_ notification: Notification) -> Bool {
        guard let window = notification.object as? NSWindow else { return false }
        return MenuBarStatusItems.itemID(of: window) == .music
    }
}
