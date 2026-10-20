// Deci/Views/Music/MusicShelfView.swift
import SwiftUI

/// One titled shelf of a page: an artist's Albums, Singles and the rest. A shelf of songs only shows song rows; any
/// other shelf scrolls sideways through 70 pt cover tiles, starting one page margin in and sliding under the popover's edge.
struct MusicShelfView: View {
    let shelf: MusicShelf
    /// videoId of the track in the player, for the playing indicator.
    let nowPlayingId: String?
    let isPlaying: Bool
    let onPlay: (MusicTrack) -> Void
    let onOpen: (MusicCollection) -> Void
    @Environment(\.musicCollectionPin) private var collectionPin
    @Environment(\.musicTrackMenu) private var trackMenu

    /// Song rows a songs-only shelf shows.
    static let maxSongRows = 6

    /// The shelf's songs when every item is one, else nil.
    private var songs: [MusicTrack]? {
        let tracks = shelf.items.compactMap { item -> MusicTrack? in
            if case .track(let track) = item { return track }
            return nil
        }
        return !tracks.isEmpty && tracks.count == shelf.items.count ? tracks : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: songs == nil ? MusicBrowseLayout.tileTitleGap : MusicBrowseLayout.listTitleGap) {
            MusicSectionHeader(title: shelf.title)

            if let songs {
                VStack(spacing: 0) {
                    ForEach(Array(songs.prefix(Self.maxSongRows).enumerated()), id: \.offset) { index, track in
                        MusicSongRow(
                            track: track,
                            isCurrent: nowPlayingId == track.videoId,
                            isPlaying: nowPlayingId == track.videoId && isPlaying,
                            layout: .playlist
                        ) {
                            onPlay(track)
                        }
                        .musicRowHairline(index > 0)
                    }
                }
            } else {
                MusicHorizontalShelf {
                    ForEach(Array(shelf.items.enumerated()), id: \.offset) { _, item in
                        tile(for: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tile(for item: MusicShelfItem) -> some View {
        switch item {
        case .track(let track):
            MusicCoverTile(
                title: track.title,
                subtitle: track.artist,
                thumbnailURL: track.thumbnailURL,
                size: MusicBrowseLayout.shelfTile,
                isPinned: trackMenu?.isPinned(track) == true,
                isCurrent: nowPlayingId == track.videoId,
                isPlaying: nowPlayingId == track.videoId && isPlaying
            ) {
                onPlay(track)
            }
        case .collection(let collection):
            MusicCoverTile(
                title: collection.title,
                subtitle: MusicHomeText.subtitle(collection.subtitle),
                thumbnailURL: collection.thumbnailURL,
                size: MusicBrowseLayout.shelfTile,
                circular: collection.kind == .artist,
                placeholder: collection.kind.placeholderSymbol,
                isPinned: collectionPin?.isPinned(collection) == true
            ) {
                onOpen(collection)
            }
            .musicCollectionMenu(collection)
        }
    }
}

/// The dimmed cover with a speaker on the row or tile that is in the player. The speaker
/// animates while audio plays and holds still while paused.
struct MusicPlayingOverlay: View {
    let isPlaying: Bool
    var circular = false
    var symbolSize: CGFloat = 14
    /// The corner radius of a square cover; the button radius when nil.
    var radius: CGFloat?

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isPlaying)
        }
        .clipShape(MusicCoverShape(circular: circular, radius: radius))
        .accessibilityHidden(true)
    }
}

/// The end of a list that has more. It asks for the next page when it scrolls into view and
/// shows a spinner while that loads. If a load fails it offers Load more instead of retrying
/// on its own.
struct MusicLoadMoreFooter: View {
    let isLoading: Bool
    let loadMore: () -> Void

    var body: some View {
        ZStack {
            if isLoading {
                MusicSpinner(size: 14, lineWidth: 1.5)
                    .accessibilityElement()
                    .accessibilityLabel("Loading more")
            } else {
                Button("Load more", action: loadMore)
                    .buttonStyle(.plain)
                    .musicText(MusicStyle.Typeface.secondaryMedium)
                    .foregroundStyle(MusicStyle.Palette.textSecondary)
                    .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .onAppear {
            if !isLoading { loadMore() }
        }
    }
}
