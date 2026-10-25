// Deci/Views/Music/MusicLibraryView.swift
import SwiftUI

/// The Library root: the Playlists / Albums / Downloads switch, then the saved list, with Liked music first on
/// Playlists. Playlists are rows, Albums a grid of covers, Downloads the pinned Downloaded songs row over the downloaded
/// playlists and albums, read from the download index so it works with no network and signed out (offline, and signed
/// out, it is the only tab that answers). One scroll view, so the switch scrolls away with
/// the content. The header's field filters the segment live, from what is loaded: a count line, the rows that match
/// with the words tinted, and a line for what the other segments hold.
struct MusicLibraryView: View {
    let service: MusicService
    let navigation: MusicSearchNavigation
    @Environment(\.musicCollectionPin) private var collectionPin

    private var browse: MusicBrowseStore { service.browse }
    /// The tab on screen. Offline it is Downloads whatever was picked.
    private var tab: MusicLibraryTab { browse.libraryTab }
    /// The account list Playlists or Albums shows; the last one picked while Downloads is on screen.
    private var section: MusicLibrarySection { browse.librarySection }

    /// What the field holds, for the rows to tint; empty while it is closed.
    private var terms: [String] { navigation.browseFilterTerms }

    /// What the field's words leave of this segment; nil while nothing is typed or the segment is not loaded yet.
    private var filter: MusicLibraryFilter? {
        guard tab != .downloads, !terms.isEmpty, case .loaded = browse.libraryState(section) else { return nil }
        let loaded = browse.library.compactMapValues { load -> [MusicCollection]? in
            if case .loaded(let items) = load { items } else { nil }
        }
        return MusicLibraryFilter.resolve(
            section: section,
            loaded: loaded,
            hasMore: browse.libraryHasMore,
            terms: terms
        )
    }

    /// What the field's words leave of the Downloads tab; nil while nothing is typed or another tab is on screen.
    private var downloadsFilter: MusicDownloadsFilter? {
        guard tab == .downloads, !terms.isEmpty else { return nil }
        return MusicDownloadsFilter.resolve(collections: browse.downloadedCollectionRows, terms: terms)
    }

    private static let topID = "library-top"

    var body: some View {
        ScrollViewReader { proxy in
            scroll
                // Another tab starts at the top.
                .onChange(of: tab) {
                    proxy.scrollTo(Self.topID, anchor: .top)
                }
        }
    }

    private var scroll: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                MusicSegmentSwitch(
                    segments: MusicLibraryTab.segments(isEnabled: browse.isLibraryTabEnabled),
                    selection: tab
                ) {
                    browse.selectLibraryTab($0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MusicStyle.Spacing.page)
                .padding(.top, MusicBrowseLayout.libraryTop)
                .padding(.bottom, MusicBrowseLayout.segmentListGap)
                .id(Self.topID)

                if tab == .downloads {
                    downloads
                } else if let filter {
                    filtered(filter)
                } else {
                    // Always first on Playlists, whatever state the list under it is in.
                    likedMusic
                    list
                }

                MusicBottomInsetSpacer()
            }
        }
        .scrollIndicators(.never)
        .onAppear { loadListIfNeeded() }
        .onChange(of: tab) { loadListIfNeeded() }
        // A channel switch drops what was loaded while this view stays up.
        .onChange(of: browse.libraryState(section) == .idle) { _, isIdle in
            if isIdle { loadListIfNeeded() }
        }
    }

    /// Asks for the account list the tab shows. Downloads is no list of the account's: nothing is asked for.
    private func loadListIfNeeded() {
        guard let shown = tab.section else { return }
        browse.loadLibraryIfNeeded(shown)
    }

    @ViewBuilder
    private var list: some View {
        switch browse.libraryState(section) {
        case .idle, .loading:
            MusicLoadingCard()
        case .failed(let message):
            MusicFailedCard(message: message) { browse.reloadLibrary(section) }
        case .loaded(let items) where items.isEmpty:
            MusicStateCard(message: section.emptyText)
        case .loaded(let items):
            rows(items)
            loadMoreFooter
        }
    }

    /// The saved rows of the segment, or its grid of covers.
    @ViewBuilder
    private func rows(_ items: [MusicCollection]) -> some View {
        if section == .albums {
            albumGrid(items)
        } else {
            // By browse id, not position: a list that grows or reorders keeps each row's state and hover.
            ForEach(items, id: \.browseId) { collection in
                MusicCollectionRow(
                    collection: collection,
                    isPinned: collectionPin?.isPinned(collection) == true
                ) {
                    browse.open(collection)
                }
                .musicCollectionMenu(collection)
            }
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        let loadingMore = browse.loadingMoreLibrary.contains(section)
        if browse.libraryHasMore.contains(section) || loadingMore {
            MusicLoadMoreFooter(isLoading: loadingMore) {
                guard !browse.loadingMoreLibrary.contains(section) else { return }
                browse.loadMoreLibrary(section)
            }
        }
    }

    // MARK: - Downloads

    /// The Downloaded songs row over the downloaded playlists and albums, newest download first; the empty state when
    /// nothing is downloaded or on its way; the matches under the field's words.
    @ViewBuilder
    private var downloads: some View {
        if let filter = downloadsFilter {
            filteredDownloads(filter)
        } else if !browse.hasDownloads {
            noDownloads
        } else {
            downloadedSongsRow
            downloadedRows(browse.downloadedCollectionIds)
        }
    }

    /// Pinned first like Liked music is on Playlists: the art with the download arrow and the count of songs.
    private var downloadedSongsRow: some View {
        MusicCollectionRow(collection: browse.downloadedSongsRow, isDownloads: true) {
            browse.open(MusicBrowseStore.downloadedSongs)
        }
    }

    /// The rows are laid out from the ids alone; each one reads its own download state (see `MusicDownloadedCollectionRow`).
    private func downloadedRows(_ browseIds: [String]) -> some View {
        ForEach(browseIds, id: \.self) { browseId in
            MusicDownloadedCollectionRow(browse: browse, browseId: browseId)
        }
    }

    private var noDownloads: some View {
        MusicStateCard(minHeight: MusicBrowseLayout.offlineNoteHeight) {
            MusicStateIconCircle(symbol: MusicBrowseLayout.downloadsSymbol)
            Text(MusicOfflineCopy.noDownloadsTitle)
                .musicText(MusicStyle.Typeface.stateTitle)
                .foregroundStyle(MusicStyle.Palette.textPlaying)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            MusicStateCardMessage(text: MusicOfflineCopy.noDownloadsDetail)
        }
    }

    @ViewBuilder
    private func filteredDownloads(_ filter: MusicDownloadsFilter) -> some View {
        VStack(spacing: 0) {
            MusicScopeLine(text: filter.countLine)
                .padding(.bottom, MusicBrowseLayout.listBarGap)
            if filter.showsSongsRow {
                downloadedSongsRow
            }
            downloadedRows(filter.items.map(\.browseId))
            if filter.isEmpty {
                MusicStateCard(message: MusicOfflineCopy.noMatch(query: navigation.filterQuery))
            }
        }
        .environment(\.musicHighlightTerms, terms)
    }

    // MARK: - Filtered

    /// The segment under the field's words: the count line, the rows that match (Liked music among them when it does),
    /// the line for the other segments and, when nothing matched, the block that offers YouTube Music.
    @ViewBuilder
    private func filtered(_ filter: MusicLibraryFilter) -> some View {
        VStack(spacing: 0) {
            if let liked = navigation.likedSongs, !liked.isEmpty {
                likedSongs(liked)
                    .padding(.bottom, MusicBrowseLayout.homeSectionGap)
            }
            MusicScopeLine(text: filter.countLine)
                .padding(.bottom, MusicBrowseLayout.listBarGap)
            if filter.showsLiked {
                MusicCollectionRow(collection: MusicBrowseStore.likedMusic, isLiked: true) {
                    browse.open(MusicBrowseStore.likedMusic)
                }
            }
            rows(filter.items)
            if let other = filter.other {
                MusicOtherMatchesRow(match: other) {
                    browse.librarySection = MusicLibrarySection(noun: other.target)
                }
            }
            if navigation.libraryHasNoMatch(filter) {
                let copy = MusicSearchCopy.noResults(
                    noun: section.noun,
                    query: navigation.filterQuery,
                    place: "your library",
                    beyond: "your library",
                    isPartial: navigation.likedSongs?.isPartial ?? false
                )
                MusicNoResultsBlock(title: copy.title, detail: copy.detail) {
                    navigation.searchYouTubeMusicInstead()
                }
            }
            loadMoreFooter
        }
        .environment(\.musicHighlightTerms, terms)
    }

    /// The Songs block over the count line: up to five songs of Liked music that match, which play in Liked music, and the
    /// link that opens Liked music with the same words when it holds more.
    private func likedSongs(_ liked: MusicLikedSongs) -> some View {
        let nowPlayingId = service.player.nowPlaying?.videoId
        return VStack(alignment: .leading, spacing: MusicBrowseLayout.topSongsTitleGap) {
            MusicSectionHeader(
                title: "Songs",
                linkTitle: liked.showAllTitle,
                linkAction: liked.showAllTitle == nil ? nil : { navigation.showAllLikedSongs() }
            )
            VStack(spacing: 0) {
                ForEach(Array(liked.songs.enumerated()), id: \.offset) { index, track in
                    MusicSongRow(
                        track: track,
                        isCurrent: nowPlayingId == track.videoId,
                        isPlaying: nowPlayingId == track.videoId && service.player.isPlaying,
                        layout: .liked
                    ) {
                        if let page = liked.page { service.play(track, in: page) } else { service.play(track) }
                    }
                    .musicRowHairline(index > 0)
                    .environment(
                        \.musicTrackContext,
                        MusicTrackContext(
                            pageBrowseId: MusicBrowseStore.likedMusic.browseId,
                            pageTitle: MusicBrowseStore.likedMusic.title,
                            pageIsEditable: false
                        )
                    )
                }
            }
        }
    }

    /// The saved albums as 70 pt covers, as many to a row as the column holds: four at the default size, three at the
    /// compact one.
    private func albumGrid(_ albums: [MusicCollection]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: MusicBrowseLayout.shelfTile, maximum: MusicBrowseLayout.shelfTile), spacing: MusicBrowseLayout.tileGap)],
            alignment: .leading,
            spacing: MusicBrowseLayout.gridRowGap
        ) {
            ForEach(albums, id: \.browseId) { album in
                MusicCoverTile(
                    title: album.title,
                    subtitle: MusicHomeText.subtitle(album.subtitle),
                    thumbnailURL: album.thumbnailURL,
                    size: MusicBrowseLayout.shelfTile,
                    placeholder: album.kind.placeholderSymbol,
                    isPinned: collectionPin?.isPinned(album) == true
                ) {
                    browse.open(album)
                }
                .musicCollectionMenu(album)
            }
        }
        .padding(.horizontal, MusicStyle.Spacing.page)
    }

    /// Liked music is the first row of Playlists, whatever the list below it holds.
    @ViewBuilder
    private var likedMusic: some View {
        if section == .playlists {
            MusicCollectionRow(collection: MusicBrowseStore.likedMusic, isLiked: true) {
                browse.open(MusicBrowseStore.likedMusic)
            }
        }
    }
}

/// One downloaded playlist or album row. It reads its own download state (the subtitle says how far a download has got),
/// so a progress tick redraws this row and not the whole list; the list passes the id and nothing else.
private struct MusicDownloadedCollectionRow: View {
    let browse: MusicBrowseStore
    let browseId: String
    @Environment(\.musicCollectionPin) private var collectionPin

    var body: some View {
        if let collection = browse.downloadedCollectionRow(browseId) {
            MusicCollectionRow(
                collection: collection,
                isPinned: collectionPin?.isPinned(collection) == true
            ) {
                browse.open(collection)
            }
            .musicCollectionMenu(collection)
        }
    }
}

/// A playlist or artist row that opens its page: a 40 pt cover and two lines on a playlist, a 36 pt round photo and a
/// chevron on an artist. `isLiked` draws the Liked music art in place of a cover, `isDownloads` the same art with the
/// download arrow, for the Downloaded songs row.
struct MusicCollectionRow: View {
    let collection: MusicCollection
    var isLiked = false
    var isDownloads = false
    /// Pinned to Home: the cover wears the pin badge.
    var isPinned = false
    let action: () -> Void

    static let coverSize: CGFloat = MusicBrowseLayout.playlistArt

    @State private var isHovered = false
    @Environment(\.musicAccent) private var accent
    @Environment(\.musicHighlightTerms) private var highlightTerms

    private var isArtist: Bool { collection.kind == .artist }

    private var artSize: CGFloat { isArtist ? MusicBrowseLayout.artistArt : MusicBrowseLayout.playlistArt }

    private var rowHeight: CGFloat { isArtist ? MusicBrowseLayout.artistRowHeight : MusicBrowseLayout.playlistRowHeight }

    /// Liked music keeps its own line ("Auto playlist") and Downloaded songs its count; every other row leads with its kind.
    private var subtitleText: String {
        if isLiked || isDownloads { return MusicHomeText.subtitle(collection.subtitle) }
        return MusicHomeText.librarySubtitle(kind: collection.kind, youtubeSubtitle: collection.subtitle)
    }

    var body: some View {
        // Worked out once per draw: the text, the "is there a line" check and the VoiceOver label all use it.
        let subtitle = subtitleText
        Button(action: action) {
            HStack(spacing: MusicBrowseLayout.libraryRowGap) {
                cover

                VStack(alignment: .leading, spacing: 1) {
                    Text.highlighted(collection.title, terms: highlightTerms, color: accent.solid)
                        .musicText(MusicStyle.Typeface.row)
                        .foregroundStyle(MusicStyle.Palette.textRow)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text.highlighted(subtitle, terms: highlightTerms, color: accent.solid)
                            .musicText(MusicStyle.Typeface.secondary)
                            .foregroundStyle(MusicStyle.Palette.textSub)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if isArtist {
                    Image(systemName: "chevron.right")
                        .font(.system(size: MusicBrowseLayout.libraryChevron, weight: .semibold))
                        .foregroundStyle(MusicStyle.Palette.chevron)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: rowHeight)
            .padding(.horizontal, MusicBrowseLayout.rowHoverInset)
            .background(
                RoundedRectangle(cornerRadius: MusicBrowseLayout.rowHoverRadius, style: .continuous)
                    .fill(isHovered ? MusicStyle.Palette.rowHover : .clear)
            )
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .padding(.horizontal, MusicStyle.Spacing.page - MusicBrowseLayout.rowHoverInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(subtitle: subtitle))
        .accessibilityAddTraits(.isButton)
    }

    private func accessibilityText(subtitle: String) -> String {
        let base = subtitle.isEmpty ? collection.title : "\(collection.title), \(subtitle)"
        return isPinned ? base + ", pinned" : base
    }

    @ViewBuilder
    private var cover: some View {
        if isLiked {
            MusicLikedArt(size: artSize, cornerRadius: MusicBrowseLayout.libraryArtRadius)
        } else if isDownloads {
            MusicLikedArt(size: artSize, cornerRadius: MusicBrowseLayout.libraryArtRadius, symbol: MusicBrowseLayout.downloadsSymbol)
        } else {
            MusicThumbnail(
                url: collection.thumbnailURL,
                size: artSize,
                circular: isArtist,
                placeholder: collection.kind.placeholderSymbol,
                cornerRadius: MusicBrowseLayout.libraryArtRadius
            )
            .overlay {
                if isArtist {
                    Circle().strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: MusicBrowseLayout.libraryArtRadius, style: .continuous)
                        .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                }
            }
            .musicPinBadge(isPinned, coverSize: artSize, circular: isArtist, diameter: 14, inset: 2)
        }
    }
}
