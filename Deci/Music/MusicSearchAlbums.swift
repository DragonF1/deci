// Deci/Music/MusicSearchAlbums.swift
import Foundation

/// The albums a global search lists: the owner's own saved albums and playlists that match the words, then the albums
/// YouTube Music found. Kept apart from the service and the view so the joining rules are tested.
nonisolated enum MusicSearchAlbums {
    /// The owner's matches shown ahead of the public albums, at most this many. Public albums have their own cap
    /// (`MusicService.maxAlbumResults`), so a library full of matches never pushes them out.
    static let maxLibraryMatches = 6

    /// The library lists searched, in the order their matches show.
    static let librarySections: [MusicLibrarySection] = [.albums, .playlists]

    /// `library` holds the lists that have loaded; one that has not loaded is left out and adds nothing. The library's
    /// matches come first, each id once; a public album the library's matches already hold is dropped, then the rest
    /// is cut to the public cap. Words that trim to nothing match nothing in the library, not everything.
    @MainActor
    static func resolve(
        query: String,
        library: [MusicLibrarySection: [MusicCollection]],
        found: [MusicCollection]
    ) -> [MusicCollection] {
        let terms = MusicLocalSearch.terms(of: query)
        var seen = Set<String>()
        var mine: [MusicCollection] = []
        if !terms.isEmpty {
            for section in librarySections {
                for item in MusicLocalSearch.filter(library[section] ?? [], terms: terms) where seen.insert(item.browseId).inserted {
                    mine.append(item)
                }
            }
        }
        mine = Array(mine.prefix(maxLibraryMatches))
        var held = Set(mine.map(\.browseId))
        let others = found.filter { held.insert($0.browseId).inserted }
        return mine + Array(others.prefix(MusicService.maxAlbumResults))
    }
}
