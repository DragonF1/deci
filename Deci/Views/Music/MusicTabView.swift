// Deci/Views/Music/MusicTabView.swift
import SwiftUI

/// The Music popover body. It fills the whole popover, edge to edge: the popup lays its 32 pt header strip over the
/// top of it, and the signed-in screens leave that strip clear themselves.
struct MusicTabView: View {
    @Bindable var host: MusicServiceHost

    var body: some View {
        Group {
            if let service = host.service, let navigation = host.navigation {
                MusicServiceView(service: service, navigation: navigation, isAccountCardOpen: $host.isAccountCardOpen)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .environment(\.colorScheme, .dark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MusicStyle.Palette.base)
    }
}

private struct MusicServiceView: View {
    @Bindable var service: MusicService
    let navigation: MusicSearchNavigation
    @Binding var isAccountCardOpen: Bool

    var body: some View {
        switch service.authState {
        case .unknown:
            ProgressView()
                .controlSize(.small)
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            MusicSignedOutView(service: service, isSigningIn: false)
        case .signingIn:
            MusicSignedOutView(service: service, isSigningIn: true)
        case .signedIn:
            MusicSignedInView(service: service, navigation: navigation, isAccountCardOpen: $isAccountCardOpen)
        }
    }
}

/// The signed-in shell: a browse screen with the floating tab bar and mini player over it, or one of the player
/// screens that fill the popover. Which one shows comes from `navigation.screen`.
private struct MusicSignedInView: View {
    @Bindable var service: MusicService
    /// What shows over the browse screens (Now Playing, Up next, Lyrics, the picker) and how an artist page opens.
    /// Owned by the host, so it outlives this view: the popup unmounts the player when the Music icon is hidden and
    /// builds it again.
    let navigation: MusicSearchNavigation
    /// Owned by the host so the popup's Escape key can close the card.
    @Binding var isAccountCardOpen: Bool

    /// The colour of the bottom scrim: the darker bottom of the open detail page, else the base colour.
    @State private var scrimColor: Color?

    private var nowPlaying: MusicTrack? { service.player.nowPlaying }

    var body: some View {
        let screen = navigation.screen
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                backdrop(isPlayer: screen.isPlayer)

                content(screen: screen)
                    .padding(.top, MusicPopupMetrics.headerHeight)
                    .environment(
                        \.musicBottomInset,
                        MusicShellLayout.bottomInset(hasMiniPlayer: nowPlaying != nil)
                    )

                if screen.isPlayer {
                    notice
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, MusicPopupMetrics.headerHeight + 4)
                } else {
                    chrome(width: proxy.size.width, showsBrowse: isBrowseInView(screen))
                }
            }
            .animation(DesignTokens.Animation.quick, value: screen.isPlayer)
            .onPreferenceChange(MusicScrimColorKey.self) { scrimColor = $0 }
            .overlayPreferenceValue(MusicAvatarAnchorKey.self) { anchor in
                GeometryReader { overlay in
                    if isAccountCardOpen {
                        accountCardLayer(avatar: anchor.map { overlay[$0] }, size: overlay.size)
                    }
                }
            }
            .animation(DesignTokens.Animation.quick, value: isAccountCardOpen)
        }
        // The avatar in a screen header opens and closes the card, which is drawn above.
        .environment(\.musicAccountCard, MusicAccountCardControl(isOpen: isAccountCardOpen) {
            isAccountCardOpen.toggle()
        })
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
        // Leaving the signed-in view (sign out, a dead session, the icon hidden) takes the card and the panels with it.
        .onDisappear {
            isAccountCardOpen = false
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

    /// The base colour, and over it the song's tint on the player screens.
    private func backdrop(isPlayer: Bool) -> some View {
        ZStack {
            MusicStyle.Palette.base
            MusicPlayerBackdrop(track: nowPlaying)
                .opacity(isPlayer ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    /// Whether the browse screen is the one in view: it is not under the player screens or the playlist picker.
    private func isBrowseInView(_ screen: MusicShellScreen) -> Bool {
        screen == .browse && !navigation.showsPicker
    }

    /// The browse screen stays alive under the player screens and the picker, so it keeps its place.
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
                MusicPlayerScreen(service: service, navigation: navigation, screen: screen)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// The fade the lists dissolve into, the mini player and the tab bar, bottom up.
    /// The page's scrim colour counts only while browse is in view: the hidden browse view keeps its preference value.
    private func chrome(width: CGFloat, showsBrowse: Bool) -> some View {
        let scrim = (showsBrowse ? scrimColor : nil) ?? MusicStyle.Palette.base
        return ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: scrim.opacity(0), location: 0),
                    .init(color: scrim.opacity(0.9), location: 0.35),
                    .init(color: scrim, location: 0.6),
                    .init(color: scrim, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: MusicShellLayout.scrimHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                notice
                if let track = nowPlaying {
                    MusicMiniPlayer(service: service, track: track) { navigation.openNowPlaying() }
                }
            }
            .frame(width: MusicShellLayout.miniPlayerWidth(forWidth: width))
            .padding(.bottom, MusicShellLayout.miniPlayerBottom)

            MusicTabBar(
                selection: service.browse.tab,
                width: MusicShellLayout.tabBarWidth(forWidth: width)
            ) {
                navigation.select($0)
            }
            .padding(.bottom, MusicShellLayout.tabBarBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// A dim over the popover with the avatar left out of it and ringed, and the card hanging under the avatar. A tap
    /// anywhere closes it. An overlay, not a Menu or popover: this view already lives in the menu bar panel, which a
    /// nested popover would dismiss. With no avatar on screen (its header scrolled away) the card hangs from where
    /// the avatar sits at the top of a screen.
    private func accountCardLayer(avatar: CGRect?, size: CGSize) -> some View {
        let side = MusicAccountButton.size
        let rect = avatar ?? CGRect(
            x: size.width - MusicShellLayout.pageMargin - side,
            y: MusicPopupMetrics.headerHeight + 4,
            width: side,
            height: side
        )
        return ZStack(alignment: .topTrailing) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addEllipse(in: rect)
            }
            .fill(MusicStyle.Palette.dimModal, style: FillStyle(eoFill: true))
            .contentShape(Rectangle())
            .onTapGesture { isAccountCardOpen = false }
            .accessibilityHidden(true)

            Circle()
                .strokeBorder(MusicStyle.Palette.lineFocus, lineWidth: 2)
                .frame(width: rect.width + 4, height: rect.height + 4)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            MusicAccountCard(
                account: service.account,
                isBrandChannel: service.isBrandChannel,
                isSwitchingChannel: service.isSwitchingChannel,
                isAddingAccount: service.isAddingAccount,
                onSwitchChannel: {
                    isAccountCardOpen = false
                    service.switchChannel()
                },
                onUseAnotherAccount: {
                    isAccountCardOpen = false
                    service.useAnotherAccount()
                },
                onSignOut: {
                    isAccountCardOpen = false
                    service.signOut()
                }
            )
            .padding(.top, rect.maxY + 8)
            .padding(.trailing, max(0, size.width - rect.maxX))
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Up next" and the Autoplay toggle: when a playlist or an album ends, recommended songs carry on.
struct MusicQueueHeader: View {
    let isAutoplayOn: Bool
    let onToggleAutoplay: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text("Up next")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggleAutoplay) {
                Label("Autoplay", systemImage: "infinity")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(isAutoplayOn ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)
            .contentShape(Rectangle())
            .accessibilityAddTraits(isAutoplayOn ? .isSelected : [])
            .help("Keep playing recommended songs after a playlist or an album ends")
        }
    }
}

/// A song row with the playing indicator, for search results, the queue, Quick picks and pages.
struct MusicResultRow: View {
    let track: MusicTrack
    let isCurrent: Bool
    /// True only on the current row while audio plays, so play and pause redraw one row. The
    /// speaker animates then and holds still while paused.
    let isPlaying: Bool
    let action: () -> Void

    /// Set while Full Keyboard Access has put keyboard focus on the row, so it shows the hover surface.
    @FocusState private var isKeyboardFocused: Bool
    @State private var isHovered = false
    @Environment(\.musicTrackMenu) private var menu
    @Environment(\.musicTrackContext) private var context

    static let coverSize: CGFloat = 40

    private var offeredActions: [MusicTrackAction] { menu?.actions(track, context) ?? [] }

    /// Pinned to Listen again, as last left this session: the cover wears the pin badge.
    private var isPinned: Bool { menu?.isPinned(track) == true }

    private func perform(_ action: MusicTrackAction) {
        menu?.perform(action, track, context)
    }

    private var accessibilityText: String {
        var text = "\(track.title), \(track.artist)"
        if isPinned { text += ", pinned" }
        if isPlaying { text += ", playing" }
        return text
    }

    var body: some View {
        let actions = offeredActions
        // The row plays on a tap. It is not one Button, because the artist names inside it are buttons of their
        // own, and a button nested in another button's label is unreliable for clicks and for VoiceOver.
        HStack(spacing: DesignTokens.Spacing.sm) {
            MusicThumbnail(url: track.thumbnailURL, size: Self.coverSize)
                .overlay {
                    if isCurrent {
                        MusicPlayingOverlay(isPlaying: isPlaying)
                    }
                }
                .musicPinBadge(isPinned, coverSize: Self.coverSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(isCurrent ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                MusicArtistLine(artist: track.artist, links: track.artistLinks, hidesPlainTextFromVoiceOver: true)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            if let seconds = track.durationSeconds {
                Text(MusicTimeFormat.string(TimeInterval(seconds)))
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .accessibilityHidden(true)
            }

            // Its room is kept whether or not it shows, so the duration never moves when the pointer arrives. A
            // button of its own, like the artist names: its click opens the menu and does not play the row. It stays
            // clickable while faded: an open menu can end the row's hover, and the button must not vanish under it.
            if !actions.isEmpty {
                let showsMore = isHovered || isKeyboardFocused
                MusicTrackMoreButton(track: track, actions: actions, perform: perform)
                    .opacity(showsMore ? 1 : 0)
                    .accessibilityHidden(!showsMore)
                    .animation(DesignTokens.Animation.hover, value: showsMore)
            }
        }
        .hoverableRow(isFocused: isCurrent || isKeyboardFocused)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        // The same actions as the "..." button, for a right click anywhere on the row.
        .contextMenu {
            MusicTrackMenuItems(actions: actions, perform: perform)
        }
        // A name's own button takes its click first; a click anywhere else on the row plays.
        .onTapGesture(perform: action)
        // What the Button gave the row: reachable with Full Keyboard Access only (a plain Tab stays on the search
        // field and the popup's arrow keys), and Space or Return plays. A key goes to the row only while it has
        // focus, so typing in the search field never reaches it.
        .focusable(interactions: .activate)
        .focused($isKeyboardFocused)
        .onKeyPress(keys: [.space, .return], phases: .down) { _ in
            action()
            return .handled
        }
        // A container, so each artist name inside stays its own button for VoiceOver; the row plays by its action.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityAction(named: "Play", action)
        .accessibilityAction(.default, action)
        // The "..." button hides until the pointer or the keyboard is on the row; VoiceOver gets the actions here.
        .accessibilityActions {
            ForEach(actions, id: \.self) { action in
                Button(action.title) { perform(action) }
            }
        }
    }
}
