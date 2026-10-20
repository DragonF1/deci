// Deci/Views/Music/MusicTabView.swift
import SwiftUI

/// The right column's content, under its header: browse, Lyrics or Up next once signed in, the sign-in note
/// before that. It fills the column; the player column and the header are the popup's.
struct MusicTabView: View {
    let host: MusicServiceHost

    var body: some View {
        Group {
            if let service = host.service, let navigation = host.navigation {
                MusicServiceView(service: service, navigation: navigation)
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
            MusicSignedInView(service: service, navigation: navigation)
        }
    }
}

/// The signed-in right column: the browse screens, kept alive under Lyrics and Up next so they keep
/// their place. Which one shows comes from `navigation.rightColumn`. The tabs and the avatar are the column's header, the
/// song's controls are the player column.
private struct MusicSignedInView: View {
    @Bindable var service: MusicService
    /// What shows over the browse screens (Lyrics, Up next) and how an artist page opens. Owned by the host,
    /// so it outlives this view: the popup unmounts the player when the Music icon is hidden and builds it again.
    let navigation: MusicSearchNavigation

    /// How far the notice floats above the bottom edge of the column.
    private static let noticeBottom: CGFloat = 15

    private var nowPlaying: MusicTrack? { service.player.nowPlaying }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            notice
                .padding(.bottom, Self.noticeBottom)
        }
        // Leaving the signed-in view (sign out, a dead session, the icon hidden) takes the panels with it. The account
        // card is the popup's: it closes there when the session ends, the popup loses focus or the icon is hidden.
        .onDisappear {
            service.lyrics.setPanelOpen(false)
            service.trackActions.closePicker()
            navigation.queueForced = false
            navigation.resetFields()
        }
        .onChange(of: service.query) {
            navigation.queryChanged()
        }
        // The column moved to another tab or page: a field left behind folds away with its words.
        .onChange(of: navigation.currentAnchor) {
            navigation.reconcile()
        }
        // The queue ended: the next song played must not pop Up next open again.
        .onChange(of: service.queue.isEmpty) { _, isEmpty in
            if isEmpty { navigation.queueForced = false }
        }
        // Nothing is loaded any more: the button is gone, so the panel goes with it.
        .onChange(of: service.lyrics.track == nil) { _, noTrack in
            if noTrack { service.lyrics.setPanelOpen(false) }
        }
        // The player was stopped: Lyrics and Up next have nothing to show, so they close.
        .onChange(of: nowPlaying == nil) { _, noTrack in
            if noTrack { navigation.closePanel() }
        }
        // A screen reader hears the line that says what a song action did.
        .onChange(of: service.trackActions.notice?.id) {
            if let text = service.trackActions.notice?.text {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    // MARK: - Layers

    /// The browse screen stays alive under Lyrics and Up next, so it keeps its place; they show in its
    /// place, one at a time.
    private var content: some View {
        let column = navigation.rightColumn
        let showsBrowse = column == .browse
        return ZStack {
            MusicBrowseView(service: service, navigation: navigation)
                .opacity(showsBrowse ? 1 : 0)
                .allowsHitTesting(showsBrowse)
                .accessibilityHidden(!showsBrowse)

            switch column {
            case .browse:
                EmptyView()
            case .lyrics:
                MusicLyricsView(store: service.lyrics) { service.seek(to: $0) }
                    .transition(.opacity)
            case .queue:
                MusicQueueView(service: service, navigation: navigation)
                    .transition(.opacity)
            }
        }
        .animation(DesignTokens.Animation.quick, value: column)
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
}

// MARK: - Shared actions

extension View {
    /// What every song row, artist name and collection tile in the popup runs through, the player column's cover and
    /// title included: an artist name opens its page, a song's menu lists and performs its actions on the real account,
    /// and a song, playlist, album or artist can be pinned to Home. Applied at the popup, over both
    /// columns. Without a service there is nothing to run, and the environment stays as it was.
    func musicActions(service: MusicService?, navigation: MusicSearchNavigation?) -> some View {
        modifier(MusicActionsModifier(service: service, navigation: navigation))
    }
}

private struct MusicActionsModifier: ViewModifier {
    let service: MusicService?
    let navigation: MusicSearchNavigation?

    private var artistOpener: (@MainActor (MusicCollection) -> Void)? {
        guard let navigation else { return nil }
        return { navigation.openArtist($0) }
    }

    private var trackMenu: MusicTrackMenuHandler? {
        guard let service, let navigation else { return nil }
        return MusicTrackMenuHandler(
            actions: { navigation.actions(for: $0, in: $1) },
            perform: { navigation.perform($0, for: $1, in: $2) },
            isPinned: { service.pinnedItems.isPinned($0) }
        )
    }

    /// Also which tiles and rows wear the pin badge: those pinned to Home.
    private var collectionPin: MusicCollectionPinHandler? {
        guard let service else { return nil }
        return MusicCollectionPinHandler(
            homePin: { collection in
                MusicPinnedItem(collection: collection).map { service.pinnedItems.state(for: $0) }
            },
            toggleHome: { collection in
                if let item = MusicPinnedItem(collection: collection) { service.pinnedItems.toggle(item) }
            },
            isPinned: { service.pinnedItems.isPinned($0) }
        )
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openMusicArtist, artistOpener)
            .environment(\.musicTrackMenu, trackMenu)
            .environment(\.musicCollectionPin, collectionPin)
    }
}
