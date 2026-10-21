// Deci/Views/Music/MusicHistoryView.swift
import SwiftUI

/// The History root: what the signed-in account listened to, one list per day (Today, Yesterday, This week...),
/// newest first, more as the list reaches its end. Each day is a section title over hairline separated song rows,
/// the same rows as the Quick picks list on Home. Opening the tab asks YouTube again while the list stays up, so a
/// song played since shows at the top.
struct MusicHistoryView: View {
    let service: MusicService

    private var browse: MusicBrowseStore { service.browse }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicBrowseLayout.homeSectionGap) {
                days
                MusicBottomInsetSpacer()
            }
            .padding(.top, MusicBrowseLayout.homeTop)
        }
        .scrollIndicators(.never)
        .onAppear { browse.refreshHistory() }
        // A channel switch drops what was loaded while this view stays up.
        .onChange(of: browse.history == .idle) { _, isIdle in
            if isIdle { browse.loadHistoryIfNeeded() }
        }
    }

    @ViewBuilder
    private var days: some View {
        switch browse.history {
        case .idle, .loading:
            MusicLoadingCard()
        case .failed(let message):
            MusicFailedCard(message: message) { browse.reloadHistory() }
        case .loaded(let shelves):
            let listed = Self.days(in: shelves)
            if listed.isEmpty {
                emptyState
            } else {
                ForEach(Array(listed.enumerated()), id: \.offset) { index, day in
                    MusicHistoryDaySection(day: day, service: service)
                        .onAppear {
                            if index == listed.count - 1 { loadMore() }
                        }
                }
                if browse.canLoadMoreHistory || browse.isLoadingMoreHistory {
                    MusicLoadMoreFooter(isLoading: browse.isLoadingMoreHistory) { loadMore() }
                }
            }
        }
    }

    /// No days to show: still waiting on the next page, or it did not load, or there is no history.
    @ViewBuilder
    private var emptyState: some View {
        if browse.isLoadingMoreHistory {
            MusicLoadingCard()
        } else if browse.canLoadMoreHistory {
            MusicFailedCard(message: "History did not load.") { loadMore() }
        } else {
            MusicStateCard(message: "Nothing in your history yet.")
        }
    }

    // MARK: - Days

    /// One day of listening: its title and the songs played.
    struct Day: Equatable {
        let title: String
        let tracks: [MusicTrack]
    }

    /// The days that have songs to show; History lists songs only.
    static func days(in shelves: [MusicShelf]) -> [Day] {
        shelves.compactMap { shelf in
            let tracks = shelf.items.compactMap { item -> MusicTrack? in
                if case .track(let track) = item { return track }
                return nil
            }
            return tracks.isEmpty ? nil : Day(title: shelf.title, tracks: tracks)
        }
    }

    private func loadMore() {
        guard browse.canLoadMoreHistory, !browse.isLoadingMoreHistory else { return }
        browse.loadMoreHistory()
    }
}

/// One day of History: its title over the songs played, as hairline separated rows.
struct MusicHistoryDaySection: View {
    let day: MusicHistoryView.Day
    let service: MusicService

    private var nowPlayingId: String? { service.player.nowPlaying?.videoId }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicBrowseLayout.listTitleGap) {
            MusicSectionHeader(title: day.title)
            // Lazy, so a day with hundreds of plays builds only the rows on screen.
            LazyVStack(spacing: 0) {
                ForEach(Array(day.tracks.enumerated()), id: \.offset) { position, track in
                    MusicSongRow(
                        track: track,
                        isCurrent: nowPlayingId == track.videoId,
                        isPlaying: nowPlayingId == track.videoId && service.player.isPlaying,
                        layout: .playlist
                    ) {
                        service.play(track)
                    }
                    .musicRowHairline(position > 0)
                }
            }
        }
    }
}
