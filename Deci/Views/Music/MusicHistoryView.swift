// Deci/Views/Music/MusicHistoryView.swift
import SwiftUI

/// The History root: what the signed-in account listened to, one list per day (Today, Yesterday, This week...),
/// newest first, more as the list reaches its end. Each day is a section title over hairline separated song rows,
/// the same rows as the Quick picks list on Home. Opening the tab asks YouTube again while the list stays up, so a
/// song played since shows at the top. The header's field filters the days already loaded, live: a count line over the
/// songs that match, the days left empty gone, and nothing is asked of YouTube.
struct MusicHistoryView: View {
    let service: MusicService
    let navigation: MusicSearchNavigation

    /// The days (by place in the list and title) that "See all" has opened past their first rows. Kept while the tab
    /// stays up; a reload that brings different days leaves their keys behind.
    @State private var expandedDays: Set<String> = []

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
            if let filter = navigation.historyFilter {
                filtered(filter)
            } else {
                let listed = Self.days(in: shelves)
                if listed.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(listed.enumerated()), id: \.offset) { index, day in
                        let key = Self.expansionKey(index: index, title: day.title)
                        MusicHistoryDaySection(
                            day: day,
                            service: service,
                            isExpanded: expandedDays.contains(key),
                            toggle: { toggleDay(key) }
                        )
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
    }

    /// The days under the field's words: the count line, then each day with the songs that match, or, when none do, the
    /// block that offers YouTube Music. It never asks for more days: the count line says it is of the ones loaded.
    private func filtered(_ filter: MusicHistoryFilter) -> some View {
        VStack(alignment: .leading, spacing: MusicBrowseLayout.listBarGap) {
            MusicScopeLine(text: filter.countLine)
            if filter.isEmpty {
                let copy = MusicSearchCopy.noResults(
                    noun: .song,
                    query: navigation.filterQuery,
                    place: "your history",
                    beyond: "your history"
                )
                MusicNoResultsBlock(title: copy.title, detail: copy.detail) {
                    navigation.searchYouTubeMusicInstead()
                }
            } else {
                VStack(alignment: .leading, spacing: MusicBrowseLayout.homeSectionGap) {
                    ForEach(Array(Self.days(in: filter.shelves).enumerated()), id: \.offset) { index, day in
                        // Apart from the full list's keys: the same place means another day while filtered.
                        let key = "filtered|" + Self.expansionKey(index: index, title: day.title)
                        MusicHistoryDaySection(
                            day: day,
                            service: service,
                            isExpanded: expandedDays.contains(key),
                            toggle: { toggleDay(key) }
                        )
                    }
                }
            }
        }
        .environment(\.musicHighlightTerms, navigation.browseFilterTerms)
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

        /// Whether the day has rows past the cap, so its header offers "See all".
        var offersMore: Bool { tracks.count > MusicBrowseLayout.historyDayRowCap }

        /// The rows on show: the first ones up to the cap, or every row once the day is opened.
        func visibleTracks(expanded: Bool) -> [MusicTrack] {
            expanded ? tracks : Array(tracks.prefix(MusicBrowseLayout.historyDayRowCap))
        }

        /// The link in the day's header: the words of Home's Quick picks, and none when the day fits the cap.
        func linkTitle(expanded: Bool) -> String? {
            offersMore ? MusicQuickPicks.linkTitle(expanded: expanded) : nil
        }
    }

    /// What keeps a day open: its place in the list and its title.
    static func expansionKey(index: Int, title: String) -> String { "\(index)|\(title)" }

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

    private func toggleDay(_ key: String) {
        if expandedDays.contains(key) {
            expandedDays.remove(key)
        } else {
            expandedDays.insert(key)
        }
    }

    private func loadMore() {
        guard browse.canLoadMoreHistory, !browse.isLoadingMoreHistory else { return }
        browse.loadMoreHistory()
    }
}

/// One day of History: its title over the songs played, as hairline separated rows. The first ten show; a longer day
/// has "See all" in its header, as Home's Quick picks does, which opens it in place, and "Show less" to close it.
struct MusicHistoryDaySection: View {
    let day: MusicHistoryView.Day
    let service: MusicService
    var isExpanded = false
    var toggle: () -> Void = {}

    private var nowPlayingId: String? { service.player.nowPlaying?.videoId }

    var body: some View {
        let linkTitle = day.linkTitle(expanded: isExpanded)
        VStack(alignment: .leading, spacing: MusicBrowseLayout.listTitleGap) {
            MusicSectionHeader(
                title: day.title,
                linkTitle: linkTitle,
                linkAction: linkTitle == nil ? nil : toggle
            )
            // Lazy, so an opened day with hundreds of plays builds only the rows on screen.
            LazyVStack(spacing: 0) {
                ForEach(Array(day.visibleTracks(expanded: isExpanded).enumerated()), id: \.offset) { position, track in
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
