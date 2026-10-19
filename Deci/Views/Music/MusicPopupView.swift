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

/// The popup of the Music menu bar item: the Music shell edge to edge, with a gear strip over its top.
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

    private var totalHeight: CGFloat {
        MusicPopupMetrics.totalHeight(
            maxContentHeight: popupDimensions.maxContentHeight,
            contentPadding: popupDimensions.contentPadding
        )
    }

    /// The player screens fill the popover, and the header's leading button leaves them.
    private var playerNavigation: MusicSearchNavigation? {
        guard let navigation = musicHost.navigation, navigation.screen.isPlayer else { return nil }
        return navigation
    }

    var body: some View {
        // The shell draws edge to edge. The header is a strip laid over its top, and the popup keeps the size it
        // always had (`MusicPopupMetrics.totalHeight`), whatever its content.
        ZStack(alignment: .top) {
            if appSettings.showMusicInMenuBar {
                MusicTabView(host: musicHost)
            } else {
                // Hidden: the player is unmounted, so its panels close, and the popup keeps its size.
                MusicStyle.Palette.base
            }
            header
        }
        .frame(width: popupDimensions.width, height: totalHeight)
        // The Music popup is dark in every appearance setting: the spec's colours are dark only.
        .background(
            WindowAppearanceBridge(appearance: NSAppearance(named: .darkAqua))
                .frame(width: 0, height: 0)
        )
        .background(MusicStyle.Palette.base)
        .preferredColorScheme(.dark)
        .environment(\.appearancePreference, .dark)
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

    // MARK: - Header

    /// The 32 pt strip over the top of the shell: the gear at the trailing edge and, on the player screens, a
    /// chevron at the leading edge that goes back to the browse screen.
    private var header: some View {
        HStack(spacing: 0) {
            if let navigation = playerNavigation {
                MusicHeaderButton(title: "Close player", symbol: "chevron.down", weight: .bold) {
                    navigation.dismissPlayer()
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            MusicHeaderButton(title: "Settings", symbol: "gearshape.fill", weight: .regular) {
                openSettingsWindow()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: MusicPopupMetrics.headerHeight)
        .animation(DesignTokens.Animation.quick, value: playerNavigation != nil)
    }

    // MARK: - Actions

    /// Closes the topmost thing: the account card, the add-to-playlist picker, then a player screen, otherwise the
    /// popup itself.
    private func handleEscape() {
        if musicHost.closeAccountCard() { return }
        if let navigation = musicHost.navigation, navigation.showsPicker {
            navigation.closePicker()
            return
        }
        if let navigation = playerNavigation {
            navigation.dismissPlayer()
            return
        }
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

/// A 24 pt round button of the header strip. The pointer lights it.
private struct MusicHeaderButton: View {
    let title: String
    let symbol: String
    let weight: Font.Weight
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: weight))
                .foregroundStyle(isHovered ? Color.white : MusicStyle.Palette.textTab)
                .frame(width: MusicStyle.Size.headerButton, height: MusicStyle.Size.headerButton)
                .background(Circle().fill(isHovered ? MusicStyle.Palette.fillControl : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .help(title)
    }
}
