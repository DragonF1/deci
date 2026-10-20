// Deci/Views/Music/MusicLibraryView.swift
import SwiftUI

/// The Library root: the Playlists / Albums / Artists switch, then the saved list, with Liked music first on
/// Playlists. Playlists and Artists are rows, Albums a grid of covers. One scroll view, so the switch scrolls away with
/// the content. The header's field filters the segment live, from what is loaded: a count line, the rows that match
/// with the words tinted, and a line for what the other segments hold.
struct MusicLibraryView: View {
    let service: MusicService
    let navigation: MusicSearchNavigation
    @Environment(\.musicCollectionPin) private var collectionPin

    private var browse: MusicBrowseStore { service.browse }
    private var section: MusicLibrarySection { browse.librarySection }

    /// What the field holds, for the rows to tint; empty while it is closed.
    private var terms: [String] { navigation.browseFilterTerms }

    /// What the field's words leave of this segment; nil while nothing is typed or the segment is not loaded yet.
    private var filter: MusicLibraryFilter? {
        guard !terms.isEmpty, case .loaded = browse.libraryState(section) else { return nil }
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

    private static let topID = "library-top"

    var body: some View {
        ScrollViewReader { proxy in
            scroll
                // Another section starts at the top.
                .onChange(of: section) {
                    proxy.scrollTo(Self.topID, anchor: .top)
                }
        }
    }

    private var scroll: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                MusicSegmentSwitch(segments: MusicLibrarySection.segments, selection: section) {
                    browse.librarySection = $0
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MusicStyle.Spacing.page)
                .padding(.top, MusicBrowseLayout.libraryTop)
                .padding(.bottom, MusicBrowseLayout.segmentListGap)
                .id(Self.topID)

                if let filter {
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
        .onAppear { browse.loadLibraryIfNeeded(section) }
        .onChange(of: section) { _, newSection in
            browse.loadLibraryIfNeeded(newSection)
        }
        // A channel switch drops what was loaded while this view stays up.
        .onChange(of: browse.libraryState(section) == .idle) { _, isIdle in
            if isIdle { browse.loadLibraryIfNeeded(section) }
        }
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
            ForEach(Array(items.enumerated()), id: \.offset) { _, collection in
                let row = MusicCollectionRow(
                    collection: collection,
                    isPinned: collectionPin?.isPinned(collection) == true
                ) {
                    browse.open(collection)
                }
                if let collectionPin, let listenAgain = collectionPin.pin(collection) {
                    row.contextMenu {
                        MusicListenAgainPinItem(toggle: listenAgain) { collectionPin.toggle(collection) }
                    }
                } else {
                    row
                }
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

    // MARK: - Filtered

    /// The segment under the field's words: the count line, the rows that match (Liked music among them when it does),
    /// the line for the other segments and, when nothing matched, the block that offers YouTube Music.
    @ViewBuilder
    private func filtered(_ filter: MusicLibraryFilter) -> some View {
        VStack(spacing: 0) {
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
            if filter.isEmpty {
                let copy = MusicSearchCopy.noResults(
                    noun: section.noun,
                    query: navigation.filterQuery,
                    place: "your library",
                    beyond: "your library"
                )
                MusicNoResultsBlock(title: copy.title, detail: copy.detail) {
                    navigation.searchYouTubeMusicInstead()
                }
            }
            loadMoreFooter
        }
        .environment(\.musicHighlightTerms, terms)
    }

    /// The saved albums as 70 pt covers, as many to a row as the column holds: four at the default size, three at the
    /// compact one.
    private func albumGrid(_ albums: [MusicCollection]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: MusicBrowseLayout.shelfTile, maximum: MusicBrowseLayout.shelfTile), spacing: MusicBrowseLayout.tileGap)],
            alignment: .leading,
            spacing: MusicBrowseLayout.gridRowGap
        ) {
            ForEach(Array(albums.enumerated()), id: \.offset) { _, album in
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

/// A playlist or artist row that opens its page: a 40 pt cover and two lines on a playlist, a 36 pt round photo and a
/// chevron on an artist. `isLiked` draws the Liked music art in place of a cover.
struct MusicCollectionRow: View {
    let collection: MusicCollection
    var isLiked = false
    /// Pinned to Listen again (a playlist or album) or to Home (an artist): the cover wears the pin badge.
    var isPinned = false
    let action: () -> Void

    static let coverSize: CGFloat = MusicBrowseLayout.playlistArt

    @State private var isHovered = false
    @Environment(\.musicAccent) private var accent
    @Environment(\.musicHighlightTerms) private var highlightTerms

    private var isArtist: Bool { collection.kind == .artist }

    private var artSize: CGFloat { isArtist ? MusicBrowseLayout.artistArt : MusicBrowseLayout.playlistArt }

    private var rowHeight: CGFloat { isArtist ? MusicBrowseLayout.artistRowHeight : MusicBrowseLayout.playlistRowHeight }

    /// Liked music keeps its own line ("Auto playlist"); every other row leads with its kind.
    private var subtitleText: String {
        if isLiked { return MusicHomeText.subtitle(collection.subtitle) }
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
