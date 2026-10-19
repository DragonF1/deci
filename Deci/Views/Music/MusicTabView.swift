// Deci/Views/Music/MusicTabView.swift
import SwiftUI

/// The Music tab body. Fixed height so the popup does not jump as results come and go.
struct MusicTabView: View {
    @Bindable var host: MusicServiceHost
    let height: CGFloat

    var body: some View {
        Group {
            if let service = host.service, let navigation = host.navigation {
                MusicServiceView(service: service, navigation: navigation, isAccountCardOpen: $host.isAccountCardOpen)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            signedOutView
        case .signingIn:
            VStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Finish signing in in the YouTube Music window.")
                    .font(DesignTokens.Typography.rowDescription)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedIn:
            MusicSignedInView(service: service, navigation: navigation, isAccountCardOpen: $isAccountCardOpen)
        }
    }

    private var signedOutView: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "music.note.list")
                .font(.system(size: 26))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Text("Sign in to search and play from your YouTube Music account.")
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("Sign in to YouTube Music") {
                service.signIn()
            }
            .buttonStyle(.plain)
            .font(DesignTokens.Typography.pickerText)
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .glassButtonStyle()
            if let message = service.lastError {
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MusicSignedInView: View {
    @Bindable var service: MusicService
    /// What shows over Home and Library (results, Up next, Lyrics) and how an artist page opens. Owned by the host,
    /// so it outlives this view: the popup unmounts the tab on a switch to Mixer and builds it again.
    let navigation: MusicSearchNavigation
    /// Owned by the host so the popup's Escape key can close the card.
    @Binding var isAccountCardOpen: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            searchRow

            if let message = service.lastError {
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                MusicSegmentSwitch(segments: MusicBrowseStore.Tab.segments, selection: navigation.isBrowsing ? service.browse.tab : nil) {
                    navigation.select($0)
                }
                Spacer()
            }

            ZStack {
                // Stays alive under search and the queue so it keeps its place.
                MusicBrowseView(service: service)
                    .opacity(navigation.isBrowsing ? 1 : 0)
                    .allowsHitTesting(navigation.isBrowsing)
                    .accessibilityHidden(!navigation.isBrowsing)

                if let picker = service.trackActions.picker {
                    MusicPlaylistPickerView(
                        picker: picker,
                        onBack: { navigation.closePicker() },
                        onChoose: { service.trackActions.choose($0) },
                        onRetry: { service.trackActions.openPicker(for: picker.track) }
                    )
                } else if navigation.showsLyrics {
                    MusicLyricsView(store: service.lyrics) { service.seek(to: $0) }
                } else if navigation.showsQueue {
                    queueList
                } else if navigation.showsResults {
                    resultsList
                }
            }
            .frame(maxHeight: .infinity)
            // What a song action did ("Saved to ...", "Removed from ..."), over the bottom of the list.
            // The animation stays on the line: a removed row lands in the same turn and must not crossfade the list.
            .overlay(alignment: .bottom) {
                ZStack {
                    if let notice = service.trackActions.notice {
                        MusicNoticeLine(notice: notice) { service.trackActions.dismissNotice() }
                            .transition(.opacity)
                    }
                }
                .animation(DesignTokens.Animation.quick, value: service.trackActions.notice)
            }

            MusicMiniTransport(service: service)
        }
        // Every artist name under a song, on any list or in the player, opens the artist through here.
        .environment(\.openMusicArtist, { navigation.openArtist($0) })
        // Every song row's "..." button and right click menu, and the one in the player, run through here.
        .environment(\.musicTrackMenu, MusicTrackMenuHandler(
            actions: { navigation.actions(for: $0, in: $1) },
            perform: { navigation.perform($0, for: $1, in: $2) }
        ))
        .overlay(alignment: .topTrailing) {
            if isAccountCardOpen {
                accountCardLayer
            }
        }
        .animation(DesignTokens.Animation.quick, value: isAccountCardOpen)
        // Leaving the signed-in view (sign out, a dead session, another tab) takes the card with it.
        .onDisappear {
            isAccountCardOpen = false
            service.lyrics.setPanelOpen(false)
            service.trackActions.closePicker()
            navigation.queueForced = false
        }
        .task { searchFocused = true }
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
        // A screen reader hears the line that says what a song action did.
        .onChange(of: service.trackActions.notice?.id) {
            if let text = service.trackActions.notice?.text {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                TextField("Search songs and artists", text: $service.query)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.rowName)
                    .focused($searchFocused)
                    .onSubmit {
                        navigation.submit()
                    }
                if service.isSearching {
                    ProgressView()
                        .controlSize(.mini)
                }
                if !service.query.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") {
                        service.query = ""
                        searchFocused = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
                    .help("Clear search")
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(DesignTokens.Colors.glassFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                            .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
                    )
            )

            if service.lyrics.track != nil {
                Button("Lyrics", systemImage: "quote.bubble") {
                    navigation.toggleLyrics()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(navigation.showsLyrics ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)
                .accessibilityAddTraits(navigation.showsLyrics ? .isSelected : [])
            }

            if !service.queue.isEmpty {
                Button("Up next", systemImage: "list.bullet") {
                    navigation.toggleQueue()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(navigation.showsQueue ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)
                .accessibilityAddTraits(navigation.showsQueue ? .isSelected : [])
            }

            MusicAccountButton(account: service.account, isOpen: isAccountCardOpen) {
                isAccountCardOpen.toggle()
            }
        }
    }

    /// A transparent layer that swallows the click and closes the card (tap outside), with the card
    /// at the trailing edge just under the search row. An overlay, not a Menu or popover: this view
    /// already lives in the menu bar panel, which a nested popover would dismiss.
    private var accountCardLayer: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isAccountCardOpen = false }
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
            .padding(.top, Self.searchRowHeight + DesignTokens.Spacing.xs)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
        }
    }

    private static let searchRowHeight: CGFloat = 28

    @ViewBuilder
    private var resultsList: some View {
        if !navigation.hasResults {
            Text(navigation.emptyResultsText)
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The artists the search found, as a row of tiles above the songs.
                    if let artists = navigation.artistsShelf {
                        MusicShelfView(
                            shelf: artists,
                            nowPlayingId: service.player.nowPlaying?.videoId,
                            isPlaying: service.player.isPlaying,
                            onPlay: { service.play($0) },
                            onOpen: { navigation.openArtist($0) }
                        )
                        if !service.results.isEmpty {
                            MusicSectionTitle(text: "Songs")
                                .padding(.top, DesignTokens.Spacing.md)
                                .padding(.bottom, DesignTokens.Spacing.xs)
                        }
                    }
                    ForEach(service.results) { track in
                        MusicResultRow(
                            track: track,
                            isCurrent: service.player.nowPlaying?.videoId == track.videoId,
                            isPlaying: service.player.nowPlaying?.videoId == track.videoId && service.player.isPlaying
                        ) {
                            service.play(track)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private var queueList: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            MusicQueueHeader(isAutoplayOn: service.isAutoplayOn) {
                service.setAutoplay(!service.isAutoplayOn)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(service.queue.fromCurrent) { track in
                        MusicResultRow(
                            track: track,
                            isCurrent: service.queue.current?.videoId == track.videoId,
                            isPlaying: service.queue.current?.videoId == track.videoId && service.player.isPlaying
                        ) {
                            service.jump(to: track)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
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

    private var offeredActions: [MusicTrackAction] { menu?.actions(track, context) ?? [] }

    private func perform(_ action: MusicTrackAction) {
        menu?.perform(action, track, context)
    }

    var body: some View {
        let actions = offeredActions
        // The row plays on a tap. It is not one Button, because the artist names inside it are buttons of their
        // own, and a button nested in another button's label is unreliable for clicks and for VoiceOver.
        HStack(spacing: DesignTokens.Spacing.sm) {
            MusicThumbnail(url: track.thumbnailURL, size: 40)
                .overlay {
                    if isCurrent {
                        MusicPlayingOverlay(isPlaying: isPlaying)
                    }
                }
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
        .accessibilityLabel(isPlaying ? "\(track.title), \(track.artist), playing" : "\(track.title), \(track.artist)")
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
