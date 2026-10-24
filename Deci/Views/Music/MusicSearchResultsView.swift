// Deci/Views/Music/MusicSearchResultsView.swift
import SwiftUI

/// The YouTube Music results, which take the right column's content in place while the header's field has words in it:
/// the songs, then the albums as a row of covers (the owner's own first), then the artists as a row of round tiles.
/// Before Return it asks for it; while a search runs it draws skeleton rows. Clearing the field or Esc gives the screen under it back, and an artist opened from here puts these
/// aside and returns to them with Back.
struct MusicSearchResultsView: View {
    let service: MusicService
    let navigation: MusicSearchNavigation

    @Environment(\.musicCollectionPin) private var collectionPin

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content(navigation.panel)
                MusicBottomInsetSpacer()
            }
            .padding(.top, MusicBrowseLayout.homeTop)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func content(_ panel: MusicSearchPanel) -> some View {
        switch panel {
        case .invite:
            EmptyView()
        case .searching:
            MusicSearchSkeleton()
        case .failed:
            MusicStateCard(minHeight: Self.stateCardHeight) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14))
                    .foregroundStyle(MusicStyle.Palette.textSub)
                    .accessibilityHidden(true)
                MusicStateCardMessage(text: panel.message ?? "")
            }
        case .pressReturn, .noResults:
            MusicStateCard(message: panel.message ?? "", minHeight: Self.stateCardHeight)
        case .results:
            sections
        }
    }

    private static let stateCardHeight: CGFloat = 56

    /// The blocks in the order the navigation lists them; one with nothing in it is not there.
    private var sections: some View {
        VStack(alignment: .leading, spacing: MusicBrowseLayout.homeSectionGap) {
            ForEach(navigation.sections, id: \.self) { section in
                switch section {
                case .songs: songs
                case .albums: albums
                case .artists: artists
                }
            }
        }
    }

    private var songs: some View {
        let nowPlayingId = service.player.nowPlaying?.videoId
        return VStack(alignment: .leading, spacing: MusicBrowseLayout.topSongsTitleGap) {
            MusicSectionHeader(title: "Songs")
            VStack(spacing: 0) {
                ForEach(Array(service.results.enumerated()), id: \.element.id) { index, track in
                    MusicSongRow(
                        track: track,
                        isCurrent: nowPlayingId == track.videoId,
                        isPlaying: nowPlayingId == track.videoId && service.player.isPlaying
                    ) {
                        service.play(track)
                    }
                    .musicRowHairline(index > 0)
                }
            }
        }
    }

    /// Covers with the title and YouTube's second line (kind, artist, year); one opens through the same path as an
    /// artist, so the results step aside and Back returns to them.
    private var albums: some View {
        VStack(alignment: .leading, spacing: MusicBrowseLayout.tileTitleGap) {
            MusicSectionHeader(title: "Albums")
            MusicHorizontalShelf {
                ForEach(Array(service.albumResults.enumerated()), id: \.offset) { _, album in
                    MusicCoverTile(
                        title: album.title,
                        subtitle: MusicHomeText.subtitle(album.subtitle),
                        thumbnailURL: album.thumbnailURL,
                        size: MusicBrowseLayout.shelfTile,
                        placeholder: album.kind.placeholderSymbol,
                        isPinned: collectionPin?.isPinned(album) == true
                    ) {
                        navigation.openCollection(album)
                    }
                    .musicCollectionMenu(album)
                }
            }
        }
    }

    private var artists: some View {
        VStack(alignment: .leading, spacing: MusicBrowseLayout.tileTitleGap) {
            MusicSectionHeader(title: "Artists")
            MusicHorizontalShelf(spacing: MusicSearchArtistTile.gap) {
                ForEach(Array(service.artistResults.enumerated()), id: \.offset) { _, artist in
                    MusicSearchArtistTile(
                        collection: artist,
                        isPinned: collectionPin?.isPinned(artist) == true
                    ) {
                        navigation.openArtist(artist)
                    }
                    .musicCollectionMenu(artist)
                }
            }
        }
    }
}

/// An artist the search found: a round 40 pt photo with the name and "Artist" under it, centred in a 92 pt tile.
struct MusicSearchArtistTile: View {
    let collection: MusicCollection
    var isPinned = false
    let action: () -> Void

    static let width: CGFloat = 92
    static let photoSize: CGFloat = 40
    /// The gap between two tiles.
    static let gap: CGFloat = 10

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                MusicThumbnail(
                    url: collection.thumbnailURL,
                    size: Self.photoSize,
                    circular: true,
                    placeholder: MusicCollection.Kind.artist.placeholderSymbol
                )
                .musicPinBadge(isPinned, coverSize: Self.photoSize, circular: true)

                VStack(spacing: 0) {
                    Text(collection.title)
                        .musicText(MusicStyle.Typeface.secondaryMedium)
                        .foregroundStyle(MusicStyle.Palette.textTile)
                        .lineLimit(1)
                    Text("Artist")
                        .musicText(MusicStyle.Typeface.caption)
                        .foregroundStyle(MusicStyle.Palette.textMeta)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
            }
            .frame(width: Self.width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .musicTileHover()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPinned ? "\(collection.title), artist, pinned" : "\(collection.title), artist")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Loading

/// What the results look like while the search runs: a "Songs" label and four song rows, then an "Albums" label and a
/// row of covers, then an "Artists" label and a row of round photos, all as faint bars. It reads as one "Searching"
/// element.
private struct MusicSearchSkeleton: View {
    private static let rowCount = 4
    private static let albumCount = 4
    private static let artistCount = 4

    private static let fill = Color.white.opacity(0.07)

    var body: some View {
        VStack(alignment: .leading, spacing: MusicBrowseLayout.homeSectionGap) {
            VStack(alignment: .leading, spacing: MusicBrowseLayout.topSongsTitleGap) {
                bar(width: 44, height: 10)
                    .padding(.horizontal, MusicStyle.Spacing.page)
                    .frame(height: 16)
                ForEach(0..<Self.rowCount, id: \.self) { index in
                    MusicSkeletonSongRow(index: index)
                }
            }
            VStack(alignment: .leading, spacing: MusicBrowseLayout.tileTitleGap) {
                bar(width: 44, height: 10)
                    .padding(.horizontal, MusicStyle.Spacing.page)
                HStack(spacing: MusicBrowseLayout.tileGap) {
                    ForEach(0..<Self.albumCount, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: MusicStyle.Radius.art, style: .continuous)
                            .fill(Self.fill)
                            .frame(width: MusicBrowseLayout.shelfTile, height: MusicBrowseLayout.shelfTile)
                    }
                }
                .padding(.horizontal, MusicStyle.Spacing.page)
            }
            VStack(alignment: .leading, spacing: MusicBrowseLayout.tileTitleGap) {
                bar(width: 44, height: 10)
                    .padding(.horizontal, MusicStyle.Spacing.page)
                HStack(spacing: MusicSearchArtistTile.gap) {
                    ForEach(0..<Self.artistCount, id: \.self) { _ in
                        Circle()
                            .fill(Self.fill)
                            .frame(width: MusicSearchArtistTile.photoSize, height: MusicSearchArtistTile.photoSize)
                            .frame(width: MusicSearchArtistTile.width)
                    }
                }
                .padding(.horizontal, MusicStyle.Spacing.page)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Searching")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Self.fill)
            .frame(width: width, height: height)
    }
}

/// One song row as faint bars, for a list that is still loading (search results, Up next). `index` varies the widths.
struct MusicSkeletonSongRow: View {
    let index: Int

    private static let titleWidths: [CGFloat] = [150, 118, 172, 132]
    private static let subtitleWidths: [CGFloat] = [96, 124, 84, 108]
    private static let fill = Color.white.opacity(0.07)

    var body: some View {
        HStack(spacing: MusicSongRowLayout.search.contentGap) {
            RoundedRectangle(cornerRadius: MusicSongRowLayout.search.coverRadius, style: .continuous)
                .fill(Self.fill)
                .frame(width: MusicSongRow.coverSize, height: MusicSongRow.coverSize)
            VStack(alignment: .leading, spacing: 5) {
                bar(width: Self.titleWidths[index % Self.titleWidths.count], height: 10)
                bar(width: Self.subtitleWidths[index % Self.subtitleWidths.count], height: 8)
            }
            Spacer(minLength: 0)
        }
        .frame(height: MusicSongRowLayout.search.height)
        .padding(.horizontal, MusicStyle.Spacing.page)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Self.fill)
            .frame(width: width, height: height)
    }
}
