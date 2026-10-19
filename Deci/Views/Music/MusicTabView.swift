// Deci/Views/Music/MusicTabView.swift
import SwiftUI

/// The Music popover body. It fills the whole popover, edge to edge: the popup lays its header row (tabs, avatar and
/// gear) over the top of it, and the signed-in screens leave that room clear themselves (`musicContentTop`).
struct MusicTabView: View {
    let host: MusicServiceHost

    var body: some View {
        Group {
            if let service = host.service, let navigation = host.navigation {
                MusicServiceView(
                    service: service,
                    navigation: navigation,
                    mixer: host.mixer
                )
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MusicServiceView: View {
    @Bindable var service: MusicService
    let navigation: MusicSearchNavigation
    let mixer: MusicMixerState?

    var body: some View {
        switch service.authState {
        case .unknown:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            MusicSignedOutView(service: service, isSigningIn: false)
        case .signingIn:
            MusicSignedOutView(service: service, isSigningIn: true)
        case .signedIn:
            MusicSignedInView(service: service, navigation: navigation, mixer: mixer)
        }
    }
}

/// The signed-in shell: a browse screen with the glass mini player over it, or one of the player screens that fill the
/// popover. Which one shows comes from `navigation.screen`. The tabs, the avatar and the gear are the popup's header.
private struct MusicSignedInView: View {
    @Bindable var service: MusicService
    /// What shows over the browse screens (Now Playing, Up next, Lyrics, the picker) and how an artist page opens.
    /// Owned by the host, so it outlives this view: the popup unmounts the player when the Music icon is hidden and
    /// builds it again.
    let navigation: MusicSearchNavigation
    /// The Mixer's state, for the player's volume slider and output control. Nil where there is no Mixer.
    let mixer: MusicMixerState?

    @Environment(\.musicContentTop) private var contentTop

    private var nowPlaying: MusicTrack? { service.player.nowPlaying }

    var body: some View {
        let screen = navigation.screen
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                content(screen: screen)
                    .padding(.top, contentTop)
                    // Over the padded area too, so a page's wash and a player backdrop can reach under the header.
                    .mask { bottomFade(hasMiniPlayer: isBrowseInView(screen) && nowPlaying != nil) }
                    .environment(
                        \.musicBottomInset,
                        MusicShellLayout.bottomInset(hasMiniPlayer: nowPlaying != nil)
                    )

                if screen.isPlayer {
                    notice
                        .musicDarkScope()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, contentTop + 4)
                } else {
                    chrome(width: proxy.size.width)
                }
            }
            .animation(DesignTokens.Animation.quick, value: screen.isPlayer)
        }
        // Every artist name under a song, on any list or in the player, opens the artist through here.
        .environment(\.openMusicArtist, { navigation.openArtist($0) })
        // Every song row's "..." button and right click menu, and the one in the player, run through here.
        .environment(\.musicTrackMenu, MusicTrackMenuHandler(
            actions: { navigation.actions(for: $0, in: $1) },
            perform: { navigation.perform($0, for: $1, in: $2) },
            isPinned: { service.trackActions.isPinnedToListenAgain($0) }
        ))
        // Pin / Unpin to Listen again on every playlist and album tile and Library row, on the real account. Also
        // which tiles and rows wear the pin badge: those pinned to Listen again, and artists pinned to Home.
        .environment(\.musicCollectionPin, MusicCollectionPinHandler(
            pin: { service.trackActions.listenAgainPin(for: $0) },
            toggle: { service.trackActions.togglePin($0) },
            isPinned: {
                MusicCollectionPinHandler.wearsPinBadge($0, actions: service.trackActions, artists: service.pinnedArtists)
            }
        ))
        // Leaving the signed-in view (sign out, a dead session, the icon hidden) takes the panels with it. The account
        // card is the popup's: it closes there when the session ends, the popup loses focus or the icon is hidden.
        .onDisappear {
            service.lyrics.setPanelOpen(false)
            service.trackActions.closePicker()
            navigation.queueForced = false
            navigation.isNowPlayingOpen = false
        }
        .onChange(of: service.query) {
            navigation.queryChanged()
        }
        // The queue ended: the next song played must not pop Up next open again.
        .onChange(of: service.queue.isEmpty) { _, isEmpty in
            if isEmpty { navigation.queueForced = false }
        }
        // Nothing is loaded any more: the button is gone, so the panel goes with it.
        .onChange(of: service.lyrics.track == nil) { _, noTrack in
            if noTrack { service.lyrics.setPanelOpen(false) }
        }
        // The player was stopped: Now Playing has nothing to show, so it closes.
        .onChange(of: nowPlaying == nil) { _, noTrack in
            if noTrack { navigation.dismissPlayer() }
        }
        // A screen reader hears the line that says what a song action did.
        .onChange(of: service.trackActions.notice?.id) {
            if let text = service.trackActions.notice?.text {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    // MARK: - Layers

    /// Whether the browse screen is the one in view: it is not under the player screens or the playlist picker.
    private func isBrowseInView(_ screen: MusicShellScreen) -> Bool {
        screen == .browse && !navigation.showsPicker
    }

    /// The browse screen stays alive under the player screens and the picker, so it keeps its place. While the mini
    /// player shows, the last rows dissolve into it.
    private func content(screen: MusicShellScreen) -> some View {
        let showsBrowse = isBrowseInView(screen)
        return ZStack {
            MusicBrowseView(service: service, navigation: navigation, isActive: showsBrowse)
                .opacity(showsBrowse ? 1 : 0)
                .allowsHitTesting(showsBrowse)
                .accessibilityHidden(!showsBrowse)

            if let picker = service.trackActions.picker {
                MusicPlaylistPickerView(
                    picker: picker,
                    onBack: { navigation.closePicker() },
                    onChoose: { service.trackActions.choose($0) },
                    onRetry: { service.trackActions.openPicker(for: picker.track) }
                )
            } else if screen.isPlayer {
                MusicPlayerScreen(service: service, navigation: navigation, screen: screen, mixer: mixer)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opaque down to the mini player's neighbourhood, then clear at the bottom edge. Nothing to fade without a player.
    private func bottomFade(hasMiniPlayer: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: hasMiniPlayer ? MusicShellLayout.scrimHeight : 0)
        }
    }

    /// What a song action did ("Saved to ...", "Removed from ..."). The animation stays on the line: a removed row
    /// lands in the same turn and must not crossfade the list.
    private var notice: some View {
        ZStack {
            if let notice = service.trackActions.notice {
                MusicNoticeLine(notice: notice) { service.trackActions.dismissNotice() }
                    .transition(.opacity)
            }
        }
        .animation(DesignTokens.Animation.quick, value: service.trackActions.notice)
    }

    /// The slim glass mini player near the bottom edge, with the notice line above it.
    private func chrome(width: CGFloat) -> some View {
        VStack(spacing: 4) {
            notice
            if let track = nowPlaying {
                MusicMiniPlayer(service: service, track: track) { navigation.openNowPlaying() }
            }
        }
        .frame(width: MusicShellLayout.miniPlayerWidth(forWidth: width))
        .padding(.bottom, MusicShellLayout.miniPlayerBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(alignment: .bottom) {
            if nowPlaying != nil { miniPlayerShield }
        }
    }

    /// The band the mini player stands in, side margins and the gap under it included. The fade only dims the rows
    /// there, it does not stop them taking a click or a hover, so this clear layer takes those instead. It is under the
    /// mini player, whose own buttons stay live, and scrolling still reaches the list.
    private var miniPlayerShield: some View {
        Color.clear
            .frame(height: MusicShellLayout.miniPlayerFootprint)
            .contentShape(Rectangle())
            .onTapGesture {}
            .accessibilityHidden(true)
    }
}

/// The account card layer of the popup: a light dim over everything (a tap anywhere closes it) and the card hanging
/// under the avatar. An overlay, not a Menu or popover: the popup is a menu bar panel, which a nested popover would
/// dismiss. It sits above the header, so the avatar's tap closes the card too.
struct MusicAccountCardLayer: View {
    let service: MusicService
    @Binding var isOpen: Bool
    let contentPadding: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MusicStyle.Palette.dimModal
                .contentShape(Rectangle())
                .onTapGesture { isOpen = false }
                .accessibilityHidden(true)

            MusicAccountCard(
                account: service.account,
                isBrandChannel: service.isBrandChannel,
                isSwitchingChannel: service.isSwitchingChannel,
                isAddingAccount: service.isAddingAccount,
                onSwitchChannel: {
                    isOpen = false
                    service.switchChannel()
                },
                onUseAnotherAccount: {
                    isOpen = false
                    service.useAnotherAccount()
                },
                onSignOut: {
                    isOpen = false
                    service.signOut()
                }
            )
            .padding(.top, MusicPopupMetrics.accountCardTop(contentPadding: contentPadding))
            .padding(.trailing, MusicPopupMetrics.avatarTrailingInset(contentPadding: contentPadding))
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
