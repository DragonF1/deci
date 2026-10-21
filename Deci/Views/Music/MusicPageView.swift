// Deci/Views/Music/MusicPageView.swift
import SwiftUI

/// The page on top of `browse.path`: an album, an artist, a playlist or Liked music. A Back row stays pinned at the top;
/// under it a header (cover and text), the action pills and the songs scroll together. A playlist's and Liked music's
/// songs sit under a "SONGS" bar with the sort; an album numbers its tracks; an artist shows its top songs and shelves.
/// The header's field filters a playlist's, Liked music's or an album's loaded songs in place: a count line takes the
/// bar's place, the matches stay in the list's own order with the words tinted, and the shelves step aside.
struct MusicPageView: View {
    let service: MusicService
    let navigation: MusicSearchNavigation
    let collection: MusicCollection

    private var browse: MusicBrowseStore { service.browse }

    /// What the field holds; empty while it is closed or on an artist page, whose field searches YouTube Music.
    private var terms: [String] { navigation.browseFilterTerms }

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
            loadedContent(page: browse.displayedPage(collection.browseId) ?? loaded)
        }
    }

    private func loadedContent(page: MusicBrowsePage) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(page: page)
                actions(page: page)

                if kind == .artist {
                    artistBody(page: page)
                        .padding(.top, MusicBrowseLayout.pageGap)
                } else if !terms.isEmpty {
                    filteredTracks(of: page)
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
    private func actions(page: MusicBrowsePage) -> some View {
        let items = menuItems(page: page)
        // Play and Shuffle wait while the list does: the songs loaded so far are not in the order the list will have.
        let hasTracks = !page.tracks.isEmpty && !browse.isOrderPending(page.browseId)
        let pills = MusicPagePills.pills(kind: kind, hasTracks: hasTracks, hasMenuItems: !items.isEmpty)
        if !pills.isEmpty {
            HStack(spacing: MusicBrowseLayout.actionsGap) {
                ForEach(pills, id: \.self) { pill in
                    pillView(pill, page: page, items: items)
                }
            }
            .padding(.horizontal, MusicStyle.Spacing.page)
            .padding(.top, MusicBrowseLayout.pageGap)
        }
    }

    @ViewBuilder
    private func pillView(_ pill: MusicPagePill, page: MusicBrowsePage, items: [MusicPageMenuItem]) -> some View {
        switch pill {
        case .play:
            MusicPlayPill(title: page.title) {
                if let first = page.tracks.first { service.play(first, in: page) }
            }
        case .shuffle:
            MusicShufflePill(title: page.title) { service.playShuffled(page) }
        case .more:
            MusicPageMoreMenu(title: page.title, items: items) { perform($0, page: page) }
        }
    }

    // MARK: - Menu

    /// What the "..." menu holds: Pin to Home.
    private func menuItems(page: MusicBrowsePage) -> [MusicPageMenuItem] {
        let pins = service.pinnedItems
        return MusicPagePills.menuItems(
            kind: kind,
            home: MusicPinnedItem(page: page, opener: collection).map { pins.state(for: $0) }
        )
    }

    private func perform(_ item: MusicPageMenuItem, page: MusicBrowsePage) {
        switch item {
        case .pinHome:
            // The tile keeps the photo of the collection that opened this page: the square or round avatar.
            if let item = MusicPinnedItem(page: page, opener: collection) {
                service.pinnedItems.toggle(item)
            }
        }
    }

    // MARK: - Lists

    /// The bar over a playlist's or Liked music's songs: "SONGS" and the sort, and under it the note about what the
    /// sort is waiting for or has not reached. Albums have none, nor does an artist.
    @ViewBuilder
    private func listBar(page: MusicBrowsePage) -> some View {
        if kind == .playlist || kind == .liked {
            let canSort = MusicBrowseStore.canSort(page.browseId)
            let sort = browse.sort(for: page.browseId)
            let note = MusicSortNote.resolve(
                isLoadingAll: browse.isOrderPending(page.browseId),
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

            if canSort, note != .none {
                MusicSortNoteView(note: note)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, MusicBrowseLayout.listBarGap)
            }
        } else {
            Color.clear.frame(height: MusicBrowseLayout.pageGap)
        }
    }

    /// The songs of an album, a playlist or Liked music, with the footer that loads more of a long one. A list whose
    /// order waits for the rest of its songs shows none yet, only the note under the bar.
    @ViewBuilder
    private func tracks(of page: MusicBrowsePage) -> some View {
        if browse.isOrderPending(page.browseId) {
            EmptyView()
        } else if page.tracks.isEmpty, page.shelves.isEmpty {
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

            loadMoreFooter(of: page)
        }
    }

    private func isLoadingMore(_ page: MusicBrowsePage) -> Bool {
        browse.loadingMoreTracks.contains(page.browseId) || browse.loadingAllTracks.contains(page.browseId)
    }

    @ViewBuilder
    private func loadMoreFooter(of page: MusicBrowsePage) -> some View {
        let loadingMore = isLoadingMore(page)
        if page.continuation != nil || loadingMore {
            MusicLoadMoreFooter(isLoading: loadingMore) {
                guard !browse.loadingMoreTracks.contains(page.browseId) else { return }
                browse.loadMoreTracks(page.browseId)
            }
        }
    }

    /// The songs the field's words leave: the count line over them, then the matches with their own numbers and the
    /// words tinted. Of a long list only the loaded part is searched, and the count says so. Nothing matching shows the
    /// block that offers YouTube Music. A list whose order waits for the rest of its songs shows the same note as the
    /// bar does, in place of the matches.
    @ViewBuilder
    private func filteredTracks(of page: MusicBrowsePage) -> some View {
        if browse.isOrderPending(page.browseId) {
            MusicSortNoteView(note: .loadingAll)
                .frame(maxWidth: .infinity)
                .padding(.top, MusicBrowseLayout.pageGap)
        } else {
            matchedTracks(of: page)
        }
    }

    @ViewBuilder
    private func matchedTracks(of page: MusicBrowsePage) -> some View {
        let matches = MusicLocalSearch.indices(of: page.tracks, terms: terms)
        let isPartial = page.continuation != nil || isLoadingMore(page)
        VStack(spacing: 0) {
            MusicScopeLine(
                text: MusicSearchCopy.countLine(matched: matches.count, total: page.tracks.count, noun: .song, isPartial: isPartial)
            ) {
                navigation.clearField()
            }
            .frame(height: MusicBrowseLayout.miniBarHeight)
            .padding(.top, MusicBrowseLayout.pageGap)
            .padding(.bottom, MusicBrowseLayout.listBarGap)

            if matches.isEmpty {
                let copy = MusicSearchCopy.noResults(
                    noun: .song,
                    query: navigation.filterQuery,
                    place: kind == .album ? "this album" : "this playlist",
                    beyond: page.title
                )
                MusicNoResultsBlock(title: copy.title, detail: copy.detail) {
                    navigation.searchYouTubeMusicInstead()
                }
            } else {
                let context = MusicTrackContext(
                    pageBrowseId: page.browseId,
                    pageTitle: page.title,
                    pageIsEditable: page.isEditable
                )
                let nowPlayingId = service.player.nowPlaying?.videoId
                ForEach(Array(matches.enumerated()), id: \.element) { position, index in
                    let track = page.tracks[index]
                    MusicSongRow(
                        track: track,
                        isCurrent: nowPlayingId == track.videoId,
                        isPlaying: nowPlayingId == track.videoId && service.player.isPlaying,
                        layout: kind.rowLayout(at: index)
                    ) {
                        service.play(track, in: page)
                    }
                    .musicRowHairline(position > 0)
                    .environment(\.musicTrackContext, context)
                }
            }
            loadMoreFooter(of: page)
        }
        .environment(\.musicHighlightTerms, terms)
    }

    /// Shelves under an album's or a playlist's songs (rare), as on an artist's page.
    @ViewBuilder
    private func shelves(of page: MusicBrowsePage) -> some View {
        ForEach(Array(page.shelves.enumerated()), id: \.offset) { _, shelf in
            shelfSection(shelf, on: page)
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
                shelfSection(shelf, on: page)
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

    /// A shelf on `page`. Its tiles' menus know the page, so they never offer to open the page they are on; their songs
    /// are not the page's own rows, so the page counts as not editable for them (no Remove).
    private func shelfSection(_ shelf: MusicShelf, on page: MusicBrowsePage) -> some View {
        MusicShelfView(
            shelf: shelf,
            nowPlayingId: service.player.nowPlaying?.videoId,
            isPlaying: service.player.isPlaying,
            onPlay: { service.play($0) },
            onOpen: { browse.open($0) }
        )
        .environment(
            \.musicTrackContext,
            MusicTrackContext(pageBrowseId: page.browseId, pageTitle: page.title, pageIsEditable: false)
        )
    }
}
