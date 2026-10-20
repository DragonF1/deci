// Deci/Views/Music/MusicHomeView.swift
import SwiftUI

/// The Home root: the pinned artists at the top, then YouTube Music's shelves top to bottom (Listen again tiles, the
/// Quick picks list, other tile shelves), more as the list reaches its end. Rows and tiles sit in the right column's
/// Signal look, under a 13 pt section title.
struct MusicHomeView: View {
    let service: MusicService

    @Environment(\.musicTrackMenu) private var trackMenu
    @Environment(\.musicCollectionPin) private var collectionPin

    /// The Quick picks shelves (by position) that "See all" has opened to their longer list.
    @State private var expandedQuickPicks: Set<Int> = []

    private var browse: MusicBrowseStore { service.browse }

    private var nowPlayingId: String? { service.player.nowPlaying?.videoId }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicBrowseLayout.homeSectionGap) {
                pinnedRow
                shelves
                MusicBottomInsetSpacer()
            }
            .padding(.top, MusicBrowseLayout.homeTop)
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
                section(shelf, style: styles[index], index: index)
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
            VStack(alignment: .leading, spacing: MusicBrowseLayout.tileTitleGap) {
                MusicSectionHeader(title: "Pinned artists")

                MusicHorizontalShelf {
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
    private func section(_ shelf: MusicShelf, style: MusicHomeSectionStyle, index: Int) -> some View {
        switch style {
        case .quickPicks:
            quickPicks(shelf, index: index)
        case .tiles:
            VStack(alignment: .leading, spacing: MusicBrowseLayout.tileTitleGap) {
                MusicSectionHeader(title: shelf.title)
                MusicHorizontalShelf {
                    ForEach(shelf.items) { coverTile($0) }
                }
            }
        }
    }

    /// The songs as hairline separated rows. Five show at first; "See all" opens the list in place to twenty.
    private func quickPicks(_ shelf: MusicShelf, index: Int) -> some View {
        let tracks = shelf.items.compactMap { item -> MusicTrack? in
            if case .track(let track) = item { return track }
            return nil
        }
        let isExpanded = expandedQuickPicks.contains(index)
        let offersMore = MusicQuickPicks.offersMore(total: tracks.count)
        let visible = MusicQuickPicks.visibleCount(total: tracks.count, expanded: isExpanded)
        return VStack(alignment: .leading, spacing: MusicBrowseLayout.listTitleGap) {
            MusicSectionHeader(
                title: shelf.title,
                linkTitle: offersMore ? MusicQuickPicks.linkTitle(expanded: isExpanded) : nil,
                linkAction: offersMore ? { toggleQuickPicks(index) } : nil
            )
            VStack(spacing: 0) {
                ForEach(Array(tracks.prefix(visible).enumerated()), id: \.offset) { position, track in
                    MusicSongRow(
                        track: track,
                        isCurrent: nowPlayingId == track.videoId,
                        isPlaying: nowPlayingId == track.videoId && service.player.isPlaying,
                        layout: .playlist
                    ) {
                        service.play(track)
                    }
                    .musicRowHairline(position > 0)
                }
            }
        }
    }

    private func toggleQuickPicks(_ index: Int) {
        if expandedQuickPicks.contains(index) {
            expandedQuickPicks.remove(index)
        } else {
            expandedQuickPicks.insert(index)
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
