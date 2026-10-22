// Deci/Views/Music/MusicRelatedView.swift
import SwiftUI

/// The body of the Related panel, under its header (`MusicRelatedHeader`): the songs YouTube Music suggests next to the
/// seed, as song rows in a list that scrolls. A tap on a song plays it, and its menu is the song's own, which also
/// offers Related songs, so the panel moves on from any row. While the songs are asked for it draws skeleton rows; when
/// there are none, no song to ask about or the call failed, it says so in the words of the other panels' state cards,
/// with Retry after a failure.
struct MusicRelatedView: View {
    let service: MusicService

    private var store: MusicRelatedStore { service.related }

    var body: some View {
        content
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle:
            // The panel is closing; nothing is asked for and there is nothing to show.
            EmptyView()
        case .loading:
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { MusicSkeletonSongRow(index: $0) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading related songs")
        case .loaded(let tracks):
            list(tracks)
        case .empty:
            MusicStateCard(message: MusicRelatedStore.emptyMessage, minHeight: 60)
        case .noSeed:
            MusicStateCard(message: MusicRelatedStore.noSeedMessage, minHeight: 60)
        case .failed(let message):
            MusicFailedCard(message: message) { store.retry() }
        }
    }

    private func list(_ tracks: [MusicTrack]) -> some View {
        let nowPlayingId = service.player.nowPlaying?.videoId
        return ScrollView {
            LazyVStack(spacing: 0) {
                // Keyed by place: the list is replaced as a whole and YouTube Music may repeat a song.
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    MusicSongRow(
                        track: track,
                        isCurrent: nowPlayingId == track.videoId,
                        isPlaying: nowPlayingId == track.videoId && service.player.isPlaying,
                        layout: .playlist
                    ) {
                        // In a panel that follows the player, a tapped song plays and so becomes the new seed.
                        service.play(track)
                    }
                    .musicRowHairline(index > 0)
                }
            }
            .padding(.bottom, Self.fadeHeight)
        }
        .scrollIndicators(.never)
        .mask(bottomFade)
        // A new seed starts at the top.
        .id(store.seed?.videoId)
    }

    /// The last rows dissolve into the bottom of the column.
    private static let fadeHeight: CGFloat = 24

    private var bottomFade: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeHeight)
        }
    }
}
