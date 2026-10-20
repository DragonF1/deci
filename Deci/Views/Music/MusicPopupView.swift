// Deci/Views/Music/MusicPopupView.swift
import SwiftUI

/// The popup of the Music menu bar item: a split pane on a near black card. The player column on the left is always
/// there; the right column has its own header (Home and Library, the magnifier, the avatar, or the Lyrics and Up next
/// headers) and under it browse, Lyrics or Up next. It is dark whatever the Mixer wears.
///
/// The view stays mounted while the popup is hidden, so it learns about opening and closing from the
/// key window notifications of its own window, found by title (the Mixer popup is a window of the same
/// class). It reports to `PopupVisibilityService` so the HUD stays quiet, and to the host so the lyrics
/// panel fetches and animates only while this popup is on screen, and so does the spectrum, which polls the audio only
/// while the popup is on screen and a song plays.
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

    /// The service while the user is signed in: the avatar's account card has an account only then.
    private var signedInService: MusicService? {
        guard let service = musicHost.service, service.authState == .signedIn else { return nil }
        return service
    }

    /// The spectrum polls while the popup is on screen and a song plays, and rests otherwise.
    private var spectrumShouldRun: Bool {
        musicHost.isPopupVisible && appSettings.showMusicInMenuBar && musicHost.service?.player.isPlaying == true
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MusicPopupMetrics.cornerRadius, style: .continuous)
        HStack(spacing: 0) {
            MusicPlayerColumn(
                service: musicHost.service,
                navigation: musicHost.navigation,
                mixer: musicHost.mixer,
                spectrum: musicHost.spectrum
            )
            Rectangle()
                .fill(MusicStyle.Palette.hairline)
                .frame(width: MusicPopupMetrics.dividerWidth)
                .accessibilityHidden(true)
            rightColumn
        }
        .musicActions(service: musicHost.service, navigation: musicHost.navigation)
        .padding(MusicPopupMetrics.borderWidth)
        .frame(width: popupDimensions.width, height: MusicPopupMetrics.height)
        .background(MusicStyle.Palette.popupBackground)
        .overlay { accountCardLayer }
        .clipShape(shape)
        .overlay(shape.strokeBorder(MusicStyle.Palette.popupBorder, lineWidth: MusicPopupMetrics.borderWidth))
        .musicAccentScope(track: musicHost.service?.player.nowPlaying)
        .environment(\.musicPopupIsVisible, musicHost.isPopupVisible)
        .animation(DesignTokens.Animation.quick, value: musicHost.isAccountCardOpen)
        // Always dark: the window itself, so its chrome and every control read as on dark, and the SwiftUI scheme.
        .background(
            WindowAppearanceBridge(appearance: NSAppearance(named: .darkAqua))
                .frame(width: 0, height: 0)
        )
        .preferredColorScheme(.dark)
        .environment(\.appearancePreference, .dark)
        .musicDarkScope()
        .onChange(of: spectrumShouldRun, initial: true) { _, shouldRun in
            musicHost.spectrum.setActive(shouldRun)
        }
        .onDisappear { musicHost.spectrum.setActive(false) }
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
        .onChange(of: signedInService == nil) {
            // A session that starts or ends under an open card must not leave it up: it holds the other session's rows.
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

    // MARK: - Right column

    /// The column's own header, and under it the content: browse, Lyrics, Up next or the picker. The pages bring their
    /// own side margins, so the column adds none below the header. Lyrics and Up next have a header of their own and sit
    /// on a wash of the song's accent.
    private var rightColumn: some View {
        let column = musicHost.navigation?.rightColumn ?? .browse
        return VStack(spacing: 0) {
            header(for: column)
            if appSettings.showMusicInMenuBar {
                MusicTabView(host: musicHost)
                    .environment(\.musicBottomInset, MusicPopupMetrics.rightPaddingBottom)
            } else {
                // Hidden: the player is unmounted, so its panels close, and the popup keeps its size.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { MusicPanelWash(isOn: column.hasWash) }
    }

    @ViewBuilder
    private func header(for column: MusicRightColumn) -> some View {
        if let service = signedInService, let navigation = musicHost.navigation, column.header == .lyrics {
            MusicLyricsHeader(store: service.lyrics) { navigation.closePanel() }
        } else if let service = signedInService, let navigation = musicHost.navigation, column.header == .queue {
            MusicQueueHeader(service: service, navigation: navigation)
        } else {
            MusicRightColumnHeader(
                service: musicHost.service,
                navigation: musicHost.navigation,
                isAccountCardOpen: $musicHost.isAccountCardOpen
            )
        }
    }

    /// The account card under the avatar, over both columns. Signed out it is the card with Sign in and Settings.
    @ViewBuilder
    private var accountCardLayer: some View {
        if musicHost.isAccountCardOpen {
            MusicAccountCardLayer(
                service: musicHost.service,
                isOpen: $musicHost.isAccountCardOpen,
                onOpenSettings: { openSettingsWindow() }
            )
        }
    }

    // MARK: - Actions

    /// Closes the topmost thing: the account card, then the add-to-playlist picker, Lyrics or Up next, and search at its
    /// root, otherwise the popup itself. It never pops a page: Back is the page's own button.
    private func handleEscape() {
        if musicHost.closeAccountCard() { return }
        if let navigation = musicHost.navigation, navigation.escape() { return }
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
