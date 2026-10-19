// Deci/Views/Music/MusicPopupView.swift
import SwiftUI

/// Sizes of the Music popup. It keeps the size it had as a tab of the one popup: a header row as tall
/// as the Mixer's tab pill row, then a body capped so it fits the popup size setting.
nonisolated enum MusicPopupMetrics {
    /// The header row: the tab pill (26 pt buttons plus 3 pt of padding on each side), the avatar and the gear.
    static let headerHeight: CGFloat = 32

    /// The tallest the body gets, whatever the popup size setting allows.
    static let maxBodyHeight: CGFloat = 520

    /// The Music body has a fixed height, capped by the popup size setting.
    static func bodyHeight(maxContentHeight: CGFloat) -> CGFloat {
        min(maxContentHeight, maxBodyHeight)
    }
}

/// The popup of the Music menu bar item: the Music shell edge to edge on the Mixer's glass, with the header row (the
/// tabs, the avatar and the gear) laid over its top.
///
/// The view stays mounted while the popup is hidden, so it learns about opening and closing from the
/// key window notifications of its own window, found by title (the Mixer popup is a window of the same
/// class). It reports to `PopupVisibilityService` so the HUD stays quiet, and to the host so the lyrics
/// panel fetches and animates only while this popup is on screen.
struct MusicPopupView: View {
    /// Owns the music service. The heavy parts are built when this popup is first opened.
    @Bindable var musicHost: MusicServiceHost

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

    /// The service while the user is signed in: the tabs and the avatar are there only then.
    private var signedInService: MusicService? {
        guard let service = musicHost.service, service.authState == .signedIn else { return nil }
        return service
    }

    var body: some View {
        let padding = popupDimensions.contentPadding
        // The shell draws edge to edge. The header is a row laid over its top, and the popup keeps the size it
        // always had (`MusicPopupMetrics.totalHeight`), whatever its content.
        ZStack(alignment: .top) {
            if appSettings.showMusicInMenuBar {
                MusicTabView(host: musicHost)
                    .environment(\.musicContentTop, MusicPopupMetrics.contentTop(contentPadding: padding))
            } else {
                // Hidden: the player is unmounted, so its panels close, and the popup keeps its size.
                Color.clear
            }
            header(padding: padding)
            if musicHost.isAccountCardOpen, let service = signedInService {
                // Over a player screen the card reads dark, like the header's avatar.
                MusicAccountCardLayer(service: service, isOpen: $musicHost.isAccountCardOpen, contentPadding: padding)
                    .musicDarkScope(playerNavigation != nil)
            }
        }
        .animation(DesignTokens.Animation.quick, value: musicHost.isAccountCardOpen)
        .frame(width: popupDimensions.width, height: totalHeight)
        // The same glass and the same appearance setting as the Mixer popup, light or dark.
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
        .onChange(of: signedInService == nil) { _, isSignedOut in
            // A session that ends under an open card must not bring the card back at the next sign in.
            if isSignedOut { musicHost.isAccountCardOpen = false }
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

    /// The Mixer's header row over the top of the shell: on the browse screens the Home, Library and Search tabs, on
    /// the player screens a chevron that goes back; at the trailing edge the avatar (signed in) and the gear. Over the
    /// player screens' dark backdrop it reads in the dark scheme.
    private func header(padding: CGFloat) -> some View {
        HStack(spacing: 0) {
            if let navigation = playerNavigation {
                MusicHeaderButton(title: "Close player", symbol: "chevron.down", weight: .bold) {
                    navigation.dismissPlayer()
                }
                .transition(.opacity)
            } else if let service = signedInService, let navigation = musicHost.navigation {
                MusicTabPill(selection: service.browse.tab) { navigation.select($0) }
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            HStack(spacing: MusicPopupMetrics.headerButtonGap) {
                if let service = signedInService {
                    MusicAccountButton(account: service.account, isOpen: musicHost.isAccountCardOpen) {
                        musicHost.isAccountCardOpen.toggle()
                    }
                }
                MusicHeaderButton(title: "Settings", symbol: "gearshape.fill", weight: .regular) {
                    openSettingsWindow()
                }
            }
        }
        .padding(.horizontal, padding)
        .frame(height: MusicPopupMetrics.headerHeight)
        .padding(.top, padding)
        .musicDarkScope(playerNavigation != nil)
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

/// A 26 pt button of the header row, the Mixer's gear and edit buttons: a hierarchical icon that the pointer lights.
private struct MusicHeaderButton: View {
    let title: String
    let symbol: String
    let weight: Font.Weight
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: weight))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isHovered ? DesignTokens.Colors.interactiveHover : DesignTokens.Colors.interactiveDefault)
                .frame(width: MusicStyle.Size.headerButton, height: MusicStyle.Size.headerButton)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius, style: .continuous)
                        .fill(isHovered ? DesignTokens.Colors.hoverSurface : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel(title)
        .help(title)
    }
}

/// Home, Library and Search as the Mixer's icon-only tab pill: 13 pt icons in 26 pt buttons, the picked one on a
/// raised fill that slides between them. Tapping a tab always reports it, the picked one too, so it pops back to the
/// tab's root.
struct MusicTabPill: View {
    let selection: MusicBrowseStore.Tab
    let onSelect: (MusicBrowseStore.Tab) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MusicBrowseStore.Tab.allCases, id: \.self) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        onSelect(tab)
                    }
                } label: {
                    Image(systemName: tab.symbol(selected: isSelected))
                        .font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
                        .frame(width: MusicStyle.Size.headerButton, height: MusicStyle.Size.headerButton)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                                    .fill(DesignTokens.Colors.glassFillStrong)
                                    .matchedGeometryEffect(id: "musicTab", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 3)
                .fill(DesignTokens.Colors.glassFill)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 3)
                        .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Music tabs")
    }
}
