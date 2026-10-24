// Deci/Music/MusicScopedSearch.swift
import Foundation

// What the local search scopes find in what is already loaded: an artist page's songs and collections, the Songs block
// over a filtered Library, and a filtered History. Pure and tested; the navigation hands them the loaded pages and the
// views only draw the answer.

/// What the field of an artist page finds: the songs among the Top songs and the artist's full songs list, and the
/// albums and playlists on the page's shelves.
@MainActor
struct MusicArtistSearch {
    /// The matching songs, each once: the Top songs in their order, then the ones only the full list holds.
    let songs: [MusicTrack]
    /// The matching albums and playlists of every shelf, each once.
    let collections: [MusicCollection]
    /// A page of songs has more to load, so the songs found are of the ones loaded.
    let isPartial: Bool

    private let page: MusicBrowsePage
    private let songsPage: MusicBrowsePage?

    var isEmpty: Bool { songs.isEmpty && collections.isEmpty }

    /// `songsPage` is the artist's full songs list once it has loaded, nil until then.
    static func resolve(page: MusicBrowsePage, songsPage: MusicBrowsePage?, terms: [String]) -> MusicArtistSearch {
        var seen = Set<String>()
        var songs: [MusicTrack] = []
        let top = MusicLocalSearch.filter(page.tracks, terms: terms)
        let listed = MusicLocalSearch.filter(songsPage?.tracks ?? [], terms: terms)
        for track in top + listed where seen.insert(track.videoId).inserted {
            songs.append(track)
        }

        var seenCollections = Set<String>()
        var found: [MusicCollection] = []
        for shelf in page.shelves {
            for case .collection(let collection) in shelf.items where collection.kind != .artist {
                guard MusicLocalSearch.matches(MusicLocalSearch.fields(of: collection), terms: terms),
                      seenCollections.insert(collection.browseId).inserted else { continue }
                found.append(collection)
            }
        }
        let isPartial = page.continuation != nil || songsPage?.continuation != nil
        return MusicArtistSearch(songs: songs, collections: found, isPartial: isPartial, page: page, songsPage: songsPage)
    }

    /// The page a tap on `track` plays in: the artist page for a song of its Top songs, as a tap on the page does, else
    /// the full songs list that holds it.
    func playPage(for track: MusicTrack) -> MusicBrowsePage {
        guard let songsPage, !page.tracks.contains(where: { $0.videoId == track.videoId }) else { return page }
        return songsPage
    }
}

/// The Songs block over a filtered Library: the first few songs of Liked music that match, and how many there are.
@MainActor
struct MusicLikedSongs {
    /// The most songs the block lists.
    static let cap = 5

    let songs: [MusicTrack]
    /// All the loaded songs that match, the ones listed included.
    let matched: Int
    /// Liked music as loaded; a tap plays in it. Nil until it has loaded.
    let page: MusicBrowsePage?
    /// Liked music has more songs to load, so the count is of the ones loaded.
    let isPartial: Bool

    var isEmpty: Bool { matched == 0 }

    /// The link that opens Liked music with the words applied; nil when the block lists every match.
    var showAllTitle: String? {
        matched > Self.cap ? MusicSearchCopy.showAllSongs(count: matched, isPartial: isPartial) : nil
    }

    static func resolve(page: MusicBrowsePage?, terms: [String]) -> MusicLikedSongs {
        let found = MusicLocalSearch.filter(page?.tracks ?? [], terms: terms)
        return MusicLikedSongs(songs: Array(found.prefix(cap)), matched: found.count, page: page, isPartial: page?.continuation != nil)
    }
}

/// What History shows for the words typed in its field: the days with only the items that match, the days left empty
/// gone, and the count of songs over them. Worked out from the days already loaded, so it sends nothing.
@MainActor
struct MusicHistoryFilter {
    let shelves: [MusicShelf]
    /// The songs that match, and all the songs loaded. History lists songs only, so these are what the count line counts.
    let matched: Int
    let total: Int
    /// History has more days to load, so the count is of the days loaded.
    let isPartial: Bool

    var countLine: String {
        MusicSearchCopy.countLine(matched: matched, total: total, noun: .song, isPartial: isPartial)
    }

    var isEmpty: Bool { matched == 0 }

    static func resolve(shelves: [MusicShelf], terms: [String], isPartial: Bool) -> MusicHistoryFilter {
        var kept: [MusicShelf] = []
        var matched = 0
        var total = 0
        for shelf in shelves {
            var items: [MusicShelfItem] = []
            for item in shelf.items {
                switch item {
                case .track(let track):
                    total += 1
                    guard MusicLocalSearch.matches(MusicLocalSearch.fields(of: track), terms: terms) else { continue }
                    matched += 1
                    items.append(item)
                case .collection(let collection):
                    guard MusicLocalSearch.matches(MusicLocalSearch.fields(of: collection), terms: terms) else { continue }
                    items.append(item)
                }
            }
            if !items.isEmpty { kept.append(MusicShelf(title: shelf.title, items: items)) }
        }
        return MusicHistoryFilter(shelves: kept, matched: matched, total: total, isPartial: isPartial)
    }
}
