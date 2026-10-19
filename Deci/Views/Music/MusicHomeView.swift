// Deci/Views/Music/MusicHomeView.swift
import SwiftUI

/// The Home root: the pinned artists at the top, then YouTube Music's shelves top to bottom (Top Picks cards, Listen
/// again tiles, two column Quick picks), more as the list reaches its end, each under a small Mixer section header.
struct MusicHomeView: View {
    let service: MusicService

    @Environment(\.musicTrackMenu) private var trackMenu
    @Environment(\.musicCollectionPin) private var collectionPin

    private var browse: MusicBrowseStore { service.browse }

    private var nowPlayingId: String? { service.player.nowPlaying?.videoId }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicStyle.Spacing.sectionGap) {
                pinnedRow
                shelves
                MusicBottomInsetSpacer()
            }
        }
        .scrollIndicators(.never)
        .onAppear { browse.loadHomeIfNeeded() }
        // A channel switch drops what was loaded while this view stays up.
        .onChange(of: browse.home == .idle) { _, isIdle in
            if isIdle { browse.loadHomeIfNeeded() }
        }
    }

    @ViewBuilder
    private var shelves: some View {
        switch browse.home {
        case .idle, .loading:
            MusicLoadingCard()
        case .failed(let message):
            MusicFailedCard(message: message) { browse.reloadHome() }
        case .loaded(let shelves) where shelves.isEmpty:
            MusicStateCard(message: "Nothing on Home yet.")
        case .loaded(let shelves):
            let styles = MusicHomeSectionStyle.styles(for: shelves)
            ForEach(Array(shelves.enumerated()), id: \.offset) { index, shelf in
                section(shelf, style: styles[index])
                    .onAppear {
                        if index == shelves.count - 1 { loadMore() }
                    }
            }

            if browse.canLoadMoreHome || browse.isLoadingMoreHome {
                MusicLoadMoreFooter(isLoading: browse.isLoadingMoreHome) { loadMore() }
            }
        }
    }

    // MARK: - Pinned artists

    /// Round artist tiles in pin order. Local data, so it is there while YouTube's shelves are still loading or
    /// have failed; nothing at all while no artist is pinned.
    @ViewBuilder
    private var pinnedRow: some View {
        if let shelf = service.pinnedArtists.shelf {
            VStack(alignment: .leading, spacing: MusicStyle.Spacing.sectionContent) {
                MusicSectionHeader(title: "Pinned artists")

                shelfRow(spacing: MusicStyle.Spacing.pinnedGap) {
                    ForEach(shelf.items) { item in
                        if case .collection(let artist) = item {
                            MusicPinnedArtistTile(collection: artist) { browse.open(artist) }
                                .musicCollectionMenu(artist) { service.pinnedArtists.unpin($0.browseId) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shelves

    @ViewBuilder
    private func section(_ shelf: MusicShelf, style: MusicHomeSectionStyle) -> some View {
        VStack(alignment: .leading, spacing: MusicStyle.Spacing.sectionContent) {
            MusicSectionHeader(title: shelf.title)
            switch style {
            case .quickPicks:
                quickPicks(shelf)
            case .topPicks:
                shelfRow(spacing: MusicStyle.Spacing.shelfGap) {
                    ForEach(shelf.items) { topPick($0) }
                }
            case .coverTiles:
                shelfRow(spacing: MusicStyle.Spacing.shelfGap) {
                    ForEach(shelf.items) { coverTile($0) }
                }
            }
        }
    }

    /// A sideways row of tiles, as on every shelf of the popover.
    private func shelfRow<Content: View>(spacing: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        MusicHorizontalShelf(spacing: spacing) { content() }
    }

    private func quickPicks(_ shelf: MusicShelf) -> some View {
        let tracks = shelf.items.compactMap { item -> MusicTrack? in
            if case .track(let track) = item { return track }
            return nil
        }
        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: MusicShellLayout.quickPickColumnGap),
                GridItem(.flexible()),
            ],
            spacing: 0
        ) {
            ForEach(Array(tracks.prefix(MusicHomeSectionStyle.maxQuickPicks).enumerated()), id: \.offset) { _, track in
                MusicQuickPickRow(
                    track: track,
                    isCurrent: nowPlayingId == track.videoId,
                    isPlaying: nowPlayingId == track.videoId && service.player.isPlaying
                ) {
                    service.play(track)
                }
            }
        }
        .padding(.horizontal, MusicStyle.Spacing.page)
    }

    @ViewBuilder
    private func topPick(_ item: MusicShelfItem) -> some View {
        switch item {
        case .track(let track):
            MusicTopPickCard(
                kicker: MusicHomeSectionStyle.kicker(for: item),
                title: track.title,
                subtitle: track.artist,
                thumbnailURL: track.thumbnailURL,
                tintKey: track.videoId,
                isPinned: trackMenu?.isPinned(track) == true,
                isCurrent: nowPlayingId == track.videoId,
                isPlaying: nowPlayingId == track.videoId && service.player.isPlaying
            ) {
                service.play(track)
            }
        case .collection(let collection):
            MusicTopPickCard(
                kicker: MusicHomeSectionStyle.kicker(for: item),
                title: collection.title,
                subtitle: MusicHomeText.subtitle(collection.subtitle),
                thumbnailURL: collection.thumbnailURL,
                tintKey: collection.browseId,
                isPinned: collectionPin?.isPinned(collection) == true
            ) {
                browse.open(collection)
            }
            .musicCollectionMenu(collection)
        }
    }

    @ViewBuilder
    private func coverTile(_ item: MusicShelfItem) -> some View {
        switch item {
        case .track(let track):
            MusicCoverTile(
                title: track.title,
                subtitle: track.artist,
                thumbnailURL: track.thumbnailURL,
                isPinned: trackMenu?.isPinned(track) == true,
                isCurrent: nowPlayingId == track.videoId,
                isPlaying: nowPlayingId == track.videoId && service.player.isPlaying
            ) {
                service.play(track)
            }
        case .collection(let collection):
            MusicCoverTile(
                title: collection.title,
                subtitle: MusicHomeText.subtitle(collection.subtitle),
                thumbnailURL: collection.thumbnailURL,
                circular: collection.kind == .artist,
                placeholder: collection.kind.placeholderSymbol,
                isPinned: collectionPin?.isPinned(collection) == true
            ) {
                browse.open(collection)
            }
            .musicCollectionMenu(collection)
        }
    }

    private func loadMore() {
        guard browse.canLoadMoreHome, !browse.isLoadingMoreHome else { return }
        browse.loadMoreHome()
    }
}
