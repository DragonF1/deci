// Deci/Views/Music/MusicPageView.swift
import SwiftUI

/// The page on top of `browse.path`: an album, an artist, a playlist or Liked music. A small nav row (Back, and the
/// page's title once its header has scrolled away) stays pinned; under it a compact header with the cover on the left
/// and the title and actions on its right, over a soft wash of the cover's colour that fades into the list and away
/// as the list scrolls.
struct MusicPageView: View {
    let service: MusicService
    let collection: MusicCollection

    /// The colour of the cover once it is known; until then the page wears the hash palette's tint of its id.
    @State private var coverTint: MusicTint?
    /// How opaque the nav row's title is. Only the nav row and the wash read it, so a step of the fade does not run
    /// this body again or rebuild the lists.
    @State private var bar = MusicPageBar()
    @Environment(\.musicContentTop) private var contentTop
    @Environment(\.colorScheme) private var colorScheme

    init(service: MusicService, collection: MusicCollection) {
        self.service = service
        self.collection = collection
        _coverTint = State(initialValue: MusicCoverTintStore.shared.cachedTint(for: collection.thumbnailURL))
    }

    private var browse: MusicBrowseStore { service.browse }

    private var kind: MusicPageKind {
        .resolve(kind: collection.kind, browseId: collection.browseId)
    }

    private var palette: MusicPagePalette {
        .resolve(kind: kind, coverTint: coverTint, fallback: MusicTint.forKey(collection.browseId))
    }

    private var loadedPage: MusicBrowsePage? {
        if case .loaded(let page) = browse.pageState(collection.browseId) { return page }
        return nil
    }

    /// The cover the tint is taken from: one URL for the page's whole life (see `MusicPageCover`).
    private var tintURL: URL? {
        MusicPageCover.tintURL(page: loadedPage?.thumbnailURL, collection: collection.thumbnailURL)
    }

    var body: some View {
        ZStack(alignment: .top) {
            MusicPageWash(
                bar: bar,
                color: palette.wash(for: colorScheme),
                height: contentTop + MusicPageScroll.barHeight + kind.washDepth
            )
            VStack(spacing: 0) {
                MusicPageNavRow(bar: bar, title: loadedPage?.title ?? collection.title) { browse.back() }
                    .padding(.top, contentTop)
                content
            }
        }
        // The cover's colour: from the cache at once, else after the cover is fetched. Failing leaves the fallback.
        .task(id: tintURL) {
            guard kind != .liked, let url = tintURL else { return }
            if let cached = MusicCoverTintStore.shared.cachedTint(for: url) {
                coverTint = cached
                return
            }
            if let tint = await MusicCoverTintStore.shared.tint(for: url), !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.35)) { coverTint = tint }
            }
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
        let heroHeight = kind.heroHeight
        let isSorted = MusicBrowseStore.canSort(page.browseId) && !browse.sort(for: page.browseId).isDefault
        let note = MusicSortNote.resolve(
            isLoadingAll: browse.loadingAllTracks.contains(page.browseId),
            sortLimit: browse.sortedSongLimit(page.browseId)
        )
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(page: page, loaded: loaded)
                    // Over the list that follows, so the pin limit tooltip is not cut by its first rows.
                    .zIndex(1)

                if kind == .artist {
                    artistBody(page: page)
                } else {
                    if isSorted, note != .none {
                        MusicSortNoteView(note: note)
                            .padding(.top, 4)
                            .frame(maxWidth: .infinity)
                            .frame(height: MusicPageKind.sortNoteBlock, alignment: .top)
                    } else {
                        Color.clear.frame(height: MusicPageKind.listGap)
                    }
                    tracks(of: page)
                    shelves(of: page)
                }

                MusicBottomInsetSpacer()
            }
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: Double.self) { geometry in
            MusicPageScroll.barOpacity(offset: geometry.contentOffset.y + geometry.contentInsets.top, heroHeight: heroHeight)
        } action: { _, opacity in
            bar.opacity = opacity
        }
    }

    private func header(page: MusicBrowsePage, loaded: MusicBrowsePage) -> some View {
        let pills = MusicPagePills.pills(
            kind: kind,
            hasTracks: !page.tracks.isEmpty,
            canSort: MusicBrowseStore.canSort(page.browseId),
            hasListenAgainPin: listenAgainControl(for: loaded) != nil
        )
        return MusicPageHeader(
            kind: kind,
            coverURL: page.thumbnailURL ?? collection.thumbnailURL,
            text: MusicPageHeroText.resolve(
                kind: kind,
                title: page.title,
                subtitle: page.subtitle,
                firstArtist: page.tracks.first?.artist
            )
        ) {
            ForEach(pills, id: \.self) { pill in
                pillView(pill, page: page, loaded: loaded)
            }
        }
    }

    @ViewBuilder
    private func pillView(_ pill: MusicPagePill, page: MusicBrowsePage, loaded: MusicBrowsePage) -> some View {
        switch pill {
        case .play:
            MusicPlayPill(title: page.title) {
                if let first = page.tracks.first { service.play(first, in: page) }
            }
        case .shuffle:
            MusicShufflePill(title: page.title) { service.playShuffled(page) }
        case .sort:
            MusicSortPill(sort: browse.sort(for: page.browseId)) { browse.pickSort($0, for: page.browseId) }
        case .pinHome:
            let pin = pinControl(for: page)
            MusicPinHomePill(title: page.title, isPinned: pin.isPinned, isEnabled: pin.isEnabled, toggle: pin.toggle)
        case .pinListenAgain:
            MusicRoundPinButton(title: page.title, isPinned: isPinned(loaded)) {
                service.trackActions.togglePin(loaded)
            }
        }
    }

    // MARK: - Pins

    /// The Pin to Home pill of an artist. The tile keeps the photo of the collection that opened this page: the square
    /// or round avatar.
    private func pinControl(for page: MusicBrowsePage) -> (isPinned: Bool, isEnabled: Bool, toggle: () -> Void) {
        let pins = service.pinnedArtists
        return (
            pins.isPinned(page.browseId),
            pins.canToggle(page.browseId),
            { pins.toggle(MusicPinnedArtist(page: page, opener: collection)) }
        )
    }

    /// The page's own Listen again toggle, from its header menu: on YouTube Music, not on Deci's Home. Nil when
    /// YouTube offers none (artist pages, Liked Music, most mixes).
    private func listenAgainControl(for page: MusicBrowsePage) -> MusicFeedbackToggle? {
        service.trackActions.listenAgainPin(for: page)
    }

    /// Whether the page is pinned to Listen again. It reads the toggle itself, so a pin YouTube gives no unpin token
    /// for still shows as pinned.
    private func isPinned(_ page: MusicBrowsePage) -> Bool {
        service.trackActions.isPinnedToListenAgain(page)
    }

    // MARK: - Lists

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
                    layout: kind == .album ? .album(number: index + 1) : .playlist,
                    playingColor: MusicStyle.Palette.accent
                ) {
                    service.play(track, in: page)
                }
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
                .padding(.top, MusicStyle.Spacing.sectionGap)
        }
    }

    /// An artist's body, under the header: the top songs in two columns, then Albums, Singles and the rest.
    private func artistBody(page: MusicBrowsePage) -> some View {
        VStack(alignment: .leading, spacing: MusicPageKind.artistBodyGap) {
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
        return VStack(alignment: .leading, spacing: MusicStyle.Spacing.sectionContent) {
            MusicSectionHeader(title: "Top songs")
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: MusicShellLayout.quickPickColumnGap),
                    GridItem(.flexible()),
                ],
                spacing: 0
            ) {
                ForEach(Array(page.tracks.enumerated()), id: \.offset) { index, track in
                    MusicSongRow(
                        track: track,
                        isCurrent: nowPlayingId == track.videoId,
                        isPlaying: nowPlayingId == track.videoId && service.player.isPlaying,
                        layout: .topSong(number: index + 1)
                    ) {
                        service.play(track, in: page)
                    }
                    .environment(\.musicTrackContext, context)
                }
            }
            .padding(.horizontal, MusicStyle.Spacing.page)
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

/// The nav row's opacity, in a model of its own: the scroll sets it, and only the nav row and the wash read it.
@Observable
final class MusicPageBar {
    var opacity: Double = 0
}

/// The soft wash of the cover's colour behind the header, from the popover's top edge (under the header row) down,
/// fading to clear. It goes away as the list scrolls up, so rows never sit on it.
private struct MusicPageWash: View {
    let bar: MusicPageBar
    let color: Color
    let height: CGFloat

    var body: some View {
        LinearGradient(colors: [color, color.opacity(0)], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .top)
            .opacity(1 - bar.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The pinned nav row: the Back button, and the page's title once the header has scrolled away.
private struct MusicPageNavRow: View {
    let bar: MusicPageBar
    let title: String
    let onBack: () -> Void

    var body: some View {
        let opacity = bar.opacity
        HStack(spacing: DesignTokens.Spacing.xs) {
            MusicNavBackButton(action: onBack)
            Text(title)
                .musicText(MusicStyle.Typeface.heading)
                .foregroundStyle(MusicStyle.Palette.textPrimary)
                .lineLimit(1)
                .opacity(opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MusicStyle.Spacing.page - 4)
        .frame(height: MusicPageScroll.barHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MusicStyle.Palette.lineHairline).frame(height: 1).opacity(opacity)
        }
    }
}

/// Back chevron and the page title.
struct MusicPageTopBar: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .help("Back")

            Text(title)
                .font(DesignTokens.Typography.rowNameBold)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
