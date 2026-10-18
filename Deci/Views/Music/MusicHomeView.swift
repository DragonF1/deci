// Deci/Views/Music/MusicHomeView.swift
import SwiftUI

/// The Home root: the pinned artists at the very top, then YouTube Music's shelves top to bottom, more as the
/// list reaches its end.
struct MusicHomeView: View {
    let service: MusicService

    private var browse: MusicBrowseStore { service.browse }

    var body: some View {
        content
            .onAppear { browse.loadHomeIfNeeded() }
            // A channel switch drops what was loaded while this view stays up.
            .onChange(of: browse.home == .idle) { _, isIdle in
                if isIdle { browse.loadHomeIfNeeded() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch browse.home {
        case .idle, .loading:
            abovePinnedRow { MusicLoadingView() }
        case .failed(let message):
            abovePinnedRow { MusicFailedView(message: message) { browse.reloadHome() } }
        case .loaded(let shelves) where shelves.isEmpty:
            abovePinnedRow { MusicEmptyView(text: "Nothing on Home yet.") }
        case .loaded(let shelves):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    pinnedRow

                    ForEach(Array(shelves.enumerated()), id: \.offset) { index, shelf in
                        MusicShelfView(
                            shelf: shelf,
                            nowPlayingId: service.player.nowPlaying?.videoId,
                            isPlaying: service.player.isPlaying,
                            onPlay: { service.play($0) },
                            onOpen: { browse.open($0) }
                        )
                        .onAppear {
                            if index == shelves.count - 1 { loadMore() }
                        }
                    }

                    if browse.canLoadMoreHome || browse.isLoadingMoreHome {
                        MusicLoadMoreFooter(isLoading: browse.isLoadingMoreHome) { loadMore() }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// Round artist tiles in pin order. Local data, so it is there while YouTube's shelves are still loading or
    /// have failed; nothing at all while no artist is pinned.
    @ViewBuilder
    private var pinnedRow: some View {
        if let shelf = service.pinnedArtists.shelf {
            MusicShelfView(
                shelf: shelf,
                nowPlayingId: service.player.nowPlaying?.videoId,
                isPlaying: service.player.isPlaying,
                onPlay: { service.play($0) },
                onOpen: { browse.open($0) },
                onUnpin: { service.pinnedArtists.unpin($0.browseId) }
            )
        }
    }

    /// A state that fills the Home tab (loading, failed, empty), with the pinned row above it when there is one.
    @ViewBuilder
    private func abovePinnedRow<State: View>(@ViewBuilder _ state: () -> State) -> some View {
        if service.pinnedArtists.shelf == nil {
            state()
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                pinnedRow
                state()
            }
        }
    }

    private func loadMore() {
        guard browse.canLoadMoreHome, !browse.isLoadingMoreHome else { return }
        browse.loadMoreHome()
    }
}
