// Deci/Music/MusicLibraryFilter.swift
import Foundation

extension MusicLibrarySection {
    /// What the segment holds, for the count line and the other matches.
    var noun: MusicSearchNoun {
        switch self {
        case .playlists: .playlist
        case .albums: .album
        }
    }

    init(noun: MusicSearchNoun) {
        switch noun {
        case .album: self = .albums
        case .artist, .playlist, .song: self = .playlists
        }
    }
}

/// What Library shows for the words typed in its field: the rows of the segment that match, the count line over them
/// and what the other segments hold. Worked out from what is loaded, so it filters live with no network call.
@MainActor
struct MusicLibraryFilter: Equatable {
    /// The rows of the segment that match, in the segment's own order. Liked music is not among them.
    let items: [MusicCollection]
    /// Liked music, the first row of Playlists, matches too, by its title alone.
    let showsLiked: Bool
    /// Rows the segment holds that match, Liked music counted, and all it holds. Of what is loaded when `isPartial`.
    let matched: Int
    let total: Int
    let isPartial: Bool
    let section: MusicLibrarySection
    let other: MusicOtherMatches?

    var countLine: String {
        MusicSearchCopy.countLine(matched: matched, total: total, noun: section.noun, isPartial: isPartial)
    }

    var isEmpty: Bool { matched == 0 }

    /// `loaded` holds the lists that are loaded, by segment; a segment that is not is left out of the other matches.
    /// `hasMore` holds the segments that have more pages to load, whose count is of the loaded rows only.
    static func resolve(
        section: MusicLibrarySection,
        loaded: [MusicLibrarySection: [MusicCollection]],
        hasMore: Set<MusicLibrarySection>,
        terms: [String]
    ) -> MusicLibraryFilter {
        let rows = loaded[section] ?? []
        let items = MusicLocalSearch.filter(rows, terms: terms)
        let likedMatches = MusicLocalSearch.matches([MusicBrowseStore.likedMusic.title], terms: terms)
        let likedIsRow = section == .playlists
        let showsLiked = likedIsRow && likedMatches

        var counts: [MusicSearchNoun: Int] = [:]
        for other in MusicLibrarySection.allCases where other != section {
            guard let list = loaded[other] else { continue }
            let extra = other == .playlists && likedMatches ? 1 : 0
            counts[other.noun] = MusicLocalSearch.filter(list, terms: terms).count + extra
        }

        return MusicLibraryFilter(
            items: items,
            showsLiked: showsLiked,
            matched: items.count + (showsLiked ? 1 : 0),
            total: rows.count + (likedIsRow ? 1 : 0),
            isPartial: hasMore.contains(section),
            section: section,
            other: MusicOtherMatches.resolve(current: section.noun, counts: counts)
        )
    }
}
