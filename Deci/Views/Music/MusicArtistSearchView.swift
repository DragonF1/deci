// Deci/Views/Music/MusicArtistSearchView.swift
import SwiftUI

/// What the artist page's field finds, in place of the page while it has words: the artist's songs (Top songs and the
/// full songs list, as far as it has loaded), then their albums and playlists as a row of covers. A song plays as a tap on
/// the artist page does; a cover opens like any tile. Nothing found offers the same words on YouTube Music.
struct MusicArtistSearchView: View {
    let service: MusicService
    let navigation: MusicSearchNavigation
    let search: MusicArtistSearch

    @Environment(\.musicCollectionPin) private var collectionPin

    private var terms: [String] { navigation.browseFilterTerms }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content
                MusicBottomInsetSpacer()
            }
            .padding(.top, MusicBrowseLayout.homeTop)
        }
        .scrollIndicators(.never)
        .environment(\.musicHighlightTerms, terms)
    }

    @ViewBuilder
    private var content: some View {
        if !search.isEmpty {
            VStack(alignment: .leading, spacing: MusicBrowseLayout.homeSectionGap) {
                if !search.songs.isEmpty { songs }
                if !search.collections.isEmpty { collections }
            }
        } else if navigation.isScopedLoadPending {
            MusicLoadingCard()
        } else {
            let copy = MusicSearchCopy.noResults(
                noun: .song,
                query: navigation.filterQuery,
                place: "this artist",
                beyond: service.browse.path.last?.title ?? "this artist"
            )
            MusicNoResultsBlock(title: copy.title, detail: copy.detail) {
                navigation.searchYouTubeMusicInstead()
            }
        }
    }

    private var songs: some View {
        let nowPlayingId = service.player.nowPlaying?.videoId
        return VStack(alignment: .leading, spacing: MusicBrowseLayout.topSongsTitleGap) {
            MusicSectionHeader(title: "Songs")
            VStack(spacing: 0) {
                ForEach(Array(search.songs.enumerated()), id: \.offset) { index, track in
                    let page = search.playPage(for: track)
                    MusicSongRow(
                        track: track,
                        isCurrent: nowPlayingId == track.videoId,
                        isPlaying: nowPlayingId == track.videoId && service.player.isPlaying,
                        layout: .topSong
                    ) {
                        service.play(track, in: page)
                    }
                    .musicRowHairline(index > 0)
                    .environment(
                        \.musicTrackContext,
                        MusicTrackContext(pageBrowseId: page.browseId, pageTitle: page.title, pageIsEditable: page.isEditable)
                    )
                }
            }
        }
    }

    /// Covers with the title and YouTube's second line; one opens through the same path as every tile.
    private var collections: some View {
        VStack(alignment: .leading, spacing: MusicBrowseLayout.tileTitleGap) {
            MusicSectionHeader(title: "Albums and playlists")
            MusicHorizontalShelf {
                ForEach(Array(search.collections.enumerated()), id: \.offset) { _, collection in
                    MusicCoverTile(
                        title: collection.title,
                        subtitle: MusicHomeText.subtitle(collection.subtitle),
                        thumbnailURL: collection.thumbnailURL,
                        size: MusicBrowseLayout.shelfTile,
                        placeholder: collection.kind.placeholderSymbol,
                        isPinned: collectionPin?.isPinned(collection) == true
                    ) {
                        navigation.openCollection(collection)
                    }
                    .musicCollectionMenu(collection)
                }
            }
            .environment(
                \.musicTrackContext,
                MusicTrackContext(
                    pageBrowseId: service.browse.path.last?.browseId,
                    pageTitle: service.browse.path.last?.title,
                    pageIsEditable: false
                )
            )
        }
    }
}
