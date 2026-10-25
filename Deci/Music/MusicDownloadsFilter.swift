// Deci/Music/MusicDownloadsFilter.swift
import Foundation

/// What the Downloads tab shows for the words typed in Library's field: the downloaded playlists and albums that match,
/// whether the pinned Downloaded songs row does, and the count line over them. Worked out from the index, so it filters
/// live with no network call.
@MainActor
struct MusicDownloadsFilter: Equatable {
    /// The collections that match, in the list's own order (newest download first).
    let items: [MusicCollection]
    /// The pinned Downloaded songs row matches too, by its title alone.
    let showsSongsRow: Bool
    /// Rows that match, the pinned row counted, and all the list holds.
    let matched: Int
    let total: Int

    var isEmpty: Bool { matched == 0 }

    /// "1 OF 4 DOWNLOADS".
    var countLine: String {
        "\(matched) OF \(total) \(total == 1 ? "DOWNLOAD" : "DOWNLOADS")"
    }

    static func resolve(collections: [MusicCollection], terms: [String]) -> MusicDownloadsFilter {
        let items = MusicLocalSearch.filter(collections, terms: terms)
        let songsRow = MusicLocalSearch.matches([MusicBrowseStore.downloadedSongs.title], terms: terms)
        return MusicDownloadsFilter(
            items: items,
            showsSongsRow: songsRow,
            matched: items.count + (songsRow ? 1 : 0),
            total: collections.count + 1
        )
    }
}
