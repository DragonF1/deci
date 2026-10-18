// Deci/Views/Music/MusicHomeView.swift
import SwiftUI

/// The Home root: YouTube Music's shelves top to bottom, more as the list reaches its end.
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
            MusicLoadingView()
        case .failed(let message):
            MusicFailedView(message: message) { browse.reloadHome() }
        case .loaded(let shelves) where shelves.isEmpty:
            MusicEmptyView(text: "Nothing on Home yet.")
        case .loaded(let shelves):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
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

    private func loadMore() {
        guard browse.canLoadMoreHome, !browse.isLoadingMoreHome else { return }
        browse.loadMoreHome()
    }
}
