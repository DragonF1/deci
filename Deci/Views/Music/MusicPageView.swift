// Deci/Views/Music/MusicPageView.swift
import SwiftUI

/// The page on top of `browse.path`: an album, an artist, a playlist or Liked music. A Back row stays pinned at the top;
/// under it a header (cover and text), the action pills and the songs scroll together. A playlist's and Liked music's
/// songs sit under a "SONGS" bar with the sort; an album numbers its tracks; an artist shows its top songs and shelves.
struct MusicPageView: View {
    let service: MusicService
    let collection: MusicCollection

    private var browse: MusicBrowseStore { service.browse }

    private var kind: MusicPageKind {
        .resolve(kind: collection.kind, browseId: collection.browseId)
    }

    /// The page this one was opened from on the path, for the Back row's name: the title of the page below it, else the
    /// tab the path started on.
    private var backLabel: String {
        let path = browse.path
        let previous = path.count > 1 ? path[path.count - 2].title : nil
        return MusicPageBackLabel.resolve(previousTitle: previous, tab: browse.tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            MusicBackRow(label: backLabel) { browse.back() }
                .padding(.top, MusicBrowseLayout.pageTop)
                .padding(.horizontal, MusicStyle.Spacing.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            content
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch browse.pageState(collection.browseId) {
        case .idle, .loading:
            MusicLoadingCard()
                .padding(.top, 48)
                .frame(maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            MusicFailedCard(message: message) { browse.reloadPage(collection.browseId) }
                .padding(.top, 48)
                .frame(maxHeight: .infinity, alignment: .top)
        case .loaded(let loaded):
            // A sorted playlist shows, and queues, its sorted songs once all of them are loaded.
            loadedContent(page: browse.displayedPage(collection.browseId) ?? loaded, loaded: loaded)
        }
    }

    private func loadedContent(page: MusicBrowsePage, loaded: MusicBrowsePage) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(page: page)
                actions(page: page, loaded: loaded)

                if kind == .artist {
                    artistBody(page: page)
                        .padding(.top, MusicBrowseLayout.pageGap)
                } else {
                    listBar(page: page)
                    tracks(of: page)
                    shelves(of: page)
                }

                MusicBottomInsetSpacer()
            }
            .padding(.top, MusicBrowseLayout.pageGap)
        }
        .scrollIndicators(.never)
    }

    private func header(page: MusicBrowsePage) -> some View {
        let isComplete = page.continuation == nil
        return MusicPageHeader(
            kind: kind,
            coverURL: page.thumbnailURL ?? collection.thumbnailURL,
            text: MusicPageHeroText.resolve(
                kind: kind,
                title: page.title,
                subtitle: page.subtitle,
                firstArtist: page.tracks.first?.artist,
                isEditable: page.isEditable,
                songCount: isComplete ? page.tracks.count : nil,
                totalSeconds: MusicPageDuration.total(of: page.tracks.map(\.durationSeconds), isComplete: isComplete),
                albumCount: MusicPageHeroText.albumCount(in: page.shelves)
            )
        )
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(page: MusicBrowsePage, loaded: MusicBrowsePage) -> some View {
        let items = menuItems(page: page, loaded: loaded)
        let pills = MusicPagePills.pills(kind: kind, hasTracks: !page.tracks.isEmpty, hasMenuItems: !items.isEmpty)
        if !pills.isEmpty {
            HStack(spacing: MusicBrowseLayout.actionsGap) {
                ForEach(pills, id: \.self) { pill in
                    pillView(pill, page: page, loaded: loaded, items: items)
                }
            }
            .padding(.horizontal, MusicStyle.Spacing.page)
            .padding(.top, MusicBrowseLayout.pageGap)
        }
    }

    @ViewBuilder
    private func pillView(_ pill: MusicPagePill, page: MusicBrowsePage, loaded: MusicBrowsePage, items: [MusicPageMenuItem]) -> some View {
        switch pill {
        case .play:
            MusicPlayPill(title: page.title) {
                if let first = page.tracks.first { service.play(first, in: page) }
            }
        case .shuffle:
            MusicShufflePill(title: page.title) { service.playShuffled(page) }
        case .more:
            MusicPageMoreMenu(title: page.title, items: items) { perform($0, page: page, loaded: loaded) }
        }
    }

    // MARK: - Menu

    /// What the "..." menu holds: an artist's Pin to Home, the Listen again pin of the page elsewhere. The Listen again
    /// pin is the page's own toggle on YouTube Music, not Deci's Home; YouTube offers none for Liked Music and most mixes.
    private func menuItems(page: MusicBrowsePage, loaded: MusicBrowsePage) -> [MusicPageMenuItem] {
        let trackActions = service.trackActions
        let pins = service.pinnedArtists
        return MusicPagePills.menuItems(
            kind: kind,
            listenAgainIsPinned: trackActions.listenAgainPin(for: loaded) == nil ? nil : trackActions.isPinnedToListenAgain(loaded),
            homeIsPinned: pins.isPinned(page.browseId),
            homeCanToggle: pins.canToggle(page.browseId)
        )
    }

    private func perform(_ item: MusicPageMenuItem, page: MusicBrowsePage, loaded: MusicBrowsePage) {
        switch item {
        case .pinListenAgain:
            service.trackActions.togglePin(loaded)
        case .pinHome:
            // The tile keeps the photo of the collection that opened this page: the square or round avatar.
            service.pinnedArtists.toggle(MusicPinnedArtist(page: page, opener: collection))
        }
    }

    // MARK: - Lists

    /// The bar over a playlist's or Liked music's songs: "SONGS" and the sort, and under a sorted list the note about
    /// what the sort has or has not reached. Albums have none, nor does an artist.
    @ViewBuilder
    private func listBar(page: MusicBrowsePage) -> some View {
        if kind == .playlist || kind == .liked {
            let canSort = MusicBrowseStore.canSort(page.browseId)
            let sort = browse.sort(for: page.browseId)
            let note = MusicSortNote.resolve(
                isLoadingAll: browse.loadingAllTracks.contains(page.browseId),
                sortLimit: browse.sortedSongLimit(page.browseId)
            )
            HStack(spacing: 0) {
                MusicSongsKicker()
                Spacer(minLength: 8)
                if canSort {
                    if kind == .liked {
                        MusicLikedSortView(sort: sort) { browse.pickSort($0, for: page.browseId) }
                    } else {
                        MusicSortChipView(sort: sort) { browse.pickSort($0, for: page.browseId) }
                    }
                }
            }
            .frame(height: kind == .liked ? MusicBrowseLayout.miniBarHeight : MusicBrowseLayout.chipBarHeight)
            .padding(.horizontal, MusicStyle.Spacing.page)
            .padding(.top, MusicBrowseLayout.pageGap)
            .padding(.bottom, MusicBrowseLayout.listBarGap)

            if canSort, !sort.isDefault, note != .none {
                MusicSortNoteView(note: note)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, MusicBrowseLayout.listBarGap)
            }
        } else {
            Color.clear.frame(height: MusicBrowseLayout.pageGap)
        }
    }

    /// The songs of an album, a playlist or Liked music, with the footer that loads more of a long one.
    @ViewBuilder
    private func tracks(of page: MusicBrowsePage) -> some View {
        if page.tracks.isEmpty, page.shelves.isEmpty {
            MusicStateCard(message: "No songs here yet.", minHeight: 56)
        } else if !page.tracks.isEmpty {
            // The page the songs sit on decides whether they can leave the playlist or go to this album.
            let context = MusicTrackContext(
                pageBrowseId: page.browseId,
                pageTitle: page.title,
                pageIsEditable: page.isEditable
            )
            let nowPlayingId = service.player.nowPlaying?.videoId
            ForEach(Array(page.tracks.enumerated()), id: \.offset) { index, track in
                MusicSongRow(
                    track: track,
                    isCurrent: nowPlayingId == track.videoId,
                    isPlaying: nowPlayingId == track.videoId && service.player.isPlaying,
                    layout: kind.rowLayout(at: index)
                ) {
                    service.play(track, in: page)
                }
                .musicRowHairline(index > 0)
                .environment(\.musicTrackContext, context)
            }

            let loadingMore = browse.loadingMoreTracks.contains(page.browseId) || browse.loadingAllTracks.contains(page.browseId)
            if page.continuation != nil || loadingMore {
                MusicLoadMoreFooter(isLoading: loadingMore) {
                    guard !browse.loadingMoreTracks.contains(page.browseId) else { return }
                    browse.loadMoreTracks(page.browseId)
                }
            }
        }
    }

    /// Shelves under an album's or a playlist's songs (rare), as on an artist's page.
    @ViewBuilder
    private func shelves(of page: MusicBrowsePage) -> some View {
        ForEach(Array(page.shelves.enumerated()), id: \.offset) { _, shelf in
            shelfSection(shelf)
                .padding(.top, MusicBrowseLayout.artistSectionGap)
        }
    }

    /// An artist's body, under the actions: the top songs as rows, then Albums, Singles and the rest.
    private func artistBody(page: MusicBrowsePage) -> some View {
        VStack(alignment: .leading, spacing: MusicBrowseLayout.artistSectionGap) {
            if page.tracks.isEmpty, page.shelves.isEmpty {
                MusicStateCard(message: "No songs here yet.", minHeight: 56)
            }
            if !page.tracks.isEmpty {
                topSongs(page: page)
            }
            ForEach(Array(page.shelves.enumerated()), id: \.offset) { _, shelf in
                shelfSection(shelf)
            }
        }
    }

    private func topSongs(page: MusicBrowsePage) -> some View {
        let context = MusicTrackContext(pageBrowseId: page.browseId, pageTitle: page.title, pageIsEditable: page.isEditable)
        let nowPlayingId = service.player.nowPlaying?.videoId
        return VStack(alignment: .leading, spacing: MusicBrowseLayout.topSongsTitleGap) {
            MusicSectionHeader(title: "Top songs")
            VStack(spacing: 0) {
                ForEach(Array(page.tracks.enumerated()), id: \.offset) { index, track in
                    MusicSongRow(
                        track: track,
                        isCurrent: nowPlayingId == track.videoId,
                        isPlaying: nowPlayingId == track.videoId && service.player.isPlaying,
                        layout: .topSong
                    ) {
                        service.play(track, in: page)
                    }
                    .musicRowHairline(index > 0)
                    .environment(\.musicTrackContext, context)
                }
            }
        }
    }

    private func shelfSection(_ shelf: MusicShelf) -> some View {
        MusicShelfView(
            shelf: shelf,
            nowPlayingId: service.player.nowPlaying?.videoId,
            isPlaying: service.player.isPlaying,
            onPlay: { service.play($0) },
            onOpen: { browse.open($0) }
        )
    }
}
