// Deci/Views/Music/MusicTabView.swift
import SwiftUI

/// The Music tab body. Fixed height so the popup does not jump as results come and go.
struct MusicTabView: View {
    @Bindable var host: MusicServiceHost
    let height: CGFloat

    var body: some View {
        Group {
            if let service = host.service {
                MusicServiceView(service: service, isAccountCardOpen: $host.isAccountCardOpen)
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
            MusicSignedInView(service: service, isAccountCardOpen: $isAccountCardOpen)
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
    /// Owned by the host so the popup's Escape key can close the card.
    @Binding var isAccountCardOpen: Bool
    @FocusState private var searchFocused: Bool
    /// The Up next button shows the queue over whatever is on screen.
    @State private var queueForced = false
    /// The query last sent with Return, so a search that found nothing still shows its result.
    @State private var submittedQuery: String?

    private var trimmedQuery: String {
        service.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchIsEmpty: Bool {
        trimmedQuery.isEmpty
    }

    /// The queue shows only when the Up next button asks for it.
    private var showsQueue: Bool {
        !service.queue.isEmpty && queueForced
    }

    /// The lyrics panel is open for the loaded track. The store owns the flag (it also gates the fetch), and
    /// Up next and Lyrics are never both on: turning one on turns the other off.
    private var showsLyrics: Bool {
        service.lyrics.isPanelOpen && service.lyrics.track != nil
    }

    /// Search results show while there is a query and a search for it is running, has results,
    /// or came back empty. Otherwise Home, Library or an open page shows.
    private var showsResults: Bool {
        !searchIsEmpty && (service.isSearching || !service.results.isEmpty || submittedQuery == trimmedQuery)
    }

    private var isBrowsing: Bool {
        !showsQueue && !showsResults && !showsLyrics
    }

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
                MusicSegmentSwitch(segments: MusicBrowseStore.Tab.segments, selection: isBrowsing ? service.browse.tab : nil) {
                    select($0)
                }
                Spacer()
            }

            ZStack {
                // Stays alive under search and the queue so it keeps its place.
                MusicBrowseView(service: service)
                    .opacity(isBrowsing ? 1 : 0)
                    .allowsHitTesting(isBrowsing)
                    .accessibilityHidden(!isBrowsing)

                if showsLyrics {
                    MusicLyricsView(store: service.lyrics) { service.seek(to: $0) }
                } else if showsQueue {
                    queueList
                } else if showsResults {
                    resultsList
                }
            }
            .frame(maxHeight: .infinity)

            MusicMiniTransport(service: service)
        }
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
        }
        .task { searchFocused = true }
        .onChange(of: service.query) {
            queueForced = false
            service.lyrics.setPanelOpen(false)
            // An emptied field stops the search and drops its results, back to browsing.
            if searchIsEmpty, service.isSearching || !service.results.isEmpty {
                service.search()
            }
        }
        // The queue ended: the next song played must not pop Up next open again.
        .onChange(of: service.queue.isEmpty) { _, isEmpty in
            if isEmpty { queueForced = false }
        }
        // Nothing is loaded any more: the button is gone, so the panel goes with it.
        .onChange(of: service.lyrics.track == nil) { _, noTrack in
            if noTrack { service.lyrics.setPanelOpen(false) }
        }
    }

    /// Home or Library from the switch: leaves search and the queue and goes to the tab's root.
    private func select(_ tab: MusicBrowseStore.Tab) {
        queueForced = false
        service.lyrics.setPanelOpen(false)
        if showsResults { service.query = "" }
        service.browse.tab = tab
        service.browse.popToRoot()
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
                        queueForced = false
                        service.lyrics.setPanelOpen(false)
                        submittedQuery = trimmedQuery
                        service.search()
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
                    queueForced = false
                    service.lyrics.setPanelOpen(!service.lyrics.isPanelOpen)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(showsLyrics ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)
                .accessibilityAddTraits(showsLyrics ? .isSelected : [])
            }

            if !service.queue.isEmpty {
                Button("Up next", systemImage: "list.bullet") {
                    service.lyrics.setPanelOpen(false)
                    queueForced.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(showsQueue ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)
                .accessibilityAddTraits(showsQueue ? .isSelected : [])
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
        if service.results.isEmpty {
            Text(emptyResultsText)
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
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

    private var emptyResultsText: String {
        if service.isSearching { return "Searching..." }
        return service.lastError == nil ? "No songs found." : "Search failed. Press Return to try again."
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                MusicThumbnail(url: track.thumbnailURL, size: 40)
                    .overlay {
                        if isCurrent {
                            MusicPlayingOverlay(isPlaying: isPlaying)
                        }
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(DesignTokens.Typography.rowName)
                        .foregroundStyle(isCurrent ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textPrimary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(DesignTokens.Typography.rowDescription)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                if let seconds = track.durationSeconds {
                    Text(MusicTimeFormat.string(TimeInterval(seconds)))
                        .font(DesignTokens.Typography.percentage)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
            .hoverableRow(isFocused: isCurrent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "\(track.title), \(track.artist), playing" : "\(track.title), \(track.artist)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
