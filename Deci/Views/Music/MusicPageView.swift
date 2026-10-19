// Deci/Views/Music/MusicPageView.swift
import SwiftUI

/// The page on top of `browse.path`: an album, an artist, a playlist or Liked music. A tinted hero bleeds to the top
/// of the popover and scrolls away with the list; the nav row stays pinned over it, with a bar that fades in behind it
/// once the hero is gone. The page's colour is taken from its cover, and the shell's bottom scrim follows it.
struct MusicPageView: View {
    let service: MusicService
    let collection: MusicCollection

    /// The colour of the cover once it is known; until then the page wears the hash palette's tint of its id.
    @State private var coverTint: MusicTint?
    /// How opaque the bar behind the header and nav row is. Only the top layer reads it, so a step of the fade does
    /// not run this body again or rebuild the lists.
    @State private var bar = MusicPageBar()

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
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                background
                content(width: proxy.size.width)
                MusicPageTopLayer(
                    bar: bar,
                    title: loadedPage?.title ?? collection.title,
                    barColor: palette.page,
                    onBack: { browse.back() }
                )
            }
        }
        // The shell's scrim over the lists takes the page's darker colour.
        .preference(key: MusicScrimColorKey.self, value: palette.pageBottom)
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

    // MARK: - Layers

    /// The page gradient across the whole popover: the page colour, then the darker bottom colour.
    private var background: some View {
        let hold = kind.backgroundHold
        let stops: [Gradient.Stop] = hold > 0
            ? [
                .init(color: palette.page, location: 0),
                .init(color: palette.page, location: hold),
                .init(color: palette.pageBottom, location: 1),
            ]
            : [
                .init(color: palette.page, location: 0),
                .init(color: palette.pageBottom, location: 1),
            ]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .accessibilityHidden(true)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch browse.pageState(collection.browseId) {
        case .idle, .loading:
            MusicLoadingCard()
                .padding(.top, MusicPopupMetrics.headerHeight + 72)
                .frame(maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            MusicFailedCard(message: message) { browse.reloadPage(collection.browseId) }
                .padding(.top, MusicPopupMetrics.headerHeight + 72)
                .frame(maxHeight: .infinity, alignment: .top)
        case .loaded(let loaded):
            // A sorted playlist shows, and queues, its sorted songs once all of them are loaded.
            loadedContent(page: browse.displayedPage(collection.browseId) ?? loaded, loaded: loaded, width: width)
        }
    }

    private func loadedContent(page: MusicBrowsePage, loaded: MusicBrowsePage, width: CGFloat) -> some View {
        let heroHeight = kind.heroHeight
        let isSorted = MusicBrowseStore.canSort(page.browseId) && !browse.sort(for: page.browseId).isDefault
        let note = MusicSortNote.resolve(
            isLoadingAll: browse.loadingAllTracks.contains(page.browseId),
            sortLimit: browse.sortedSongLimit(page.browseId)
        )
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                hero(page: page, loaded: loaded, width: width)
                    // Over the list that follows, so the pin limit tooltip is not cut by its first rows.
                    .zIndex(1)

                if kind == .artist {
                    artistBody(page: page)
                } else {
                    if isSorted, note != .none {
                        MusicSortNoteView(note: note)
                            .padding(.top, 8)
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

    private func hero(page: MusicBrowsePage, loaded: MusicBrowsePage, width: CGFloat) -> some View {
        let pills = MusicPagePills.pills(
            kind: kind,
            hasTracks: !page.tracks.isEmpty,
            canSort: MusicBrowseStore.canSort(page.browseId),
            hasListenAgainPin: listenAgainControl(for: loaded) != nil
        )
        return MusicPageHero(
            kind: kind,
            palette: palette,
            width: width,
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
            MusicPlayPill(
                fill: kind == .artist ? MusicPagePalette.artistPlayFill : palette.light,
                ink: kind == .artist ? MusicPagePalette.artistPlayInk : palette.ink,
                width: kind == .artist ? 100 : nil,
                title: page.title
            ) {
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
            MusicStateCard(message: "No songs here yet.", minHeight: 72)
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
                    playingColor: palette.light
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

    /// An artist's body, 20 under the name row: the top songs in two columns, then Albums, Singles and the rest.
    private func artistBody(page: MusicBrowsePage) -> some View {
        VStack(alignment: .leading, spacing: MusicPageKind.artistBodyGap) {
            if page.tracks.isEmpty, page.shelves.isEmpty {
                MusicStateCard(message: "No songs here yet.", minHeight: 72)
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

/// The bar's opacity, in a model of its own: the scroll sets it, and only `MusicPageTopLayer` reads it.
@Observable
final class MusicPageBar {
    var opacity: Double = 0
}

/// The nav row at popover y 40, and behind it and the header strip the bar that shows once the hero has scrolled off.
private struct MusicPageTopLayer: View {
    let bar: MusicPageBar
    let title: String
    let barColor: Color
    let onBack: () -> Void

    var body: some View {
        let opacity = bar.opacity
        ZStack(alignment: .top) {
            barColor.opacity(0.94)
                .frame(height: MusicPageScroll.barHeight)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(MusicStyle.Palette.lineHairline).frame(height: 1)
                }
                .opacity(opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ZStack {
                Text(title)
                    .musicText(MusicStyle.Typeface.row15SB)
                    .foregroundStyle(MusicStyle.Palette.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 16 + MusicNavBackButton.size + 8)
                    .opacity(opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                HStack(spacing: 0) {
                    MusicNavBackButton(action: onBack)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
            }
            .frame(height: MusicNavBackButton.size)
            .padding(.top, MusicPopupMetrics.headerHeight + 8)
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
