// Deci/Music/MusicPlaylistSort.swift
import Foundation

/// What a playlist's songs can be sorted by.
enum MusicSortField: String, CaseIterable, Identifiable, Sendable {
    /// When the song was added to the playlist. YouTube Music gives no date, but it appends a new song to the end of a
    /// playlist, so the song's place in the playlist stands for it.
    case dateAdded
    /// The order the playlist has on YouTube Music.
    case playlistOrder
    case title
    case artist
    case album
    case duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateAdded: "Date added"
        case .playlistOrder: "Playlist order"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .duration: "Duration"
        }
    }
}

/// A sort option and its direction: a pure description of an order for a playlist's songs.
struct MusicPlaylistSort: Equatable, Sendable {
    var field: MusicSortField
    var ascending: Bool

    /// The order the playlist has on YouTube Music.
    static let playlistOrder = MusicPlaylistSort()
    /// Date added with the newest song first: where a playlist the user made and Liked music rest.
    static let dateAddedNewestFirst = MusicPlaylistSort(field: .dateAdded, ascending: false)

    init(field: MusicSortField = .playlistOrder, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }

    var isPlaylistOrder: Bool { field == .playlistOrder }

    /// What picking `picked` in the sort menu gives: a new option starts ascending, except Date added, which starts
    /// with the newest song first; the same option again flips the direction, and Playlist order has no direction.
    func picking(_ picked: MusicSortField) -> MusicPlaylistSort {
        if picked == .playlistOrder { return .playlistOrder }
        if picked == field { return MusicPlaylistSort(field: field, ascending: !ascending) }
        return MusicPlaylistSort(field: picked, ascending: picked != .dateAdded)
    }

    /// Whether this sort puts a playlist's songs in another order than YouTube lists them, so the songs have to be
    /// all here before the list can show it. `newestFirst` says YouTube lists the playlist with the newest song
    /// first, as it does Liked music; it matters only to Date added, which then needs no reorder for newest first.
    func reorders(newestFirst: Bool) -> Bool {
        switch field {
        case .playlistOrder: false
        case .dateAdded: ascending == newestFirst
        case .title, .artist, .album, .duration: true
        }
    }

    /// `tracks` in this order. Text ignores case, accents and width and reads numbers by value; songs that tie
    /// keep the order they had, in both directions; songs with no value for the field go last in both.
    /// The text of each song is folded once, before the sort, and the comparisons only read numbers by value.
    /// Date added reads the place of a song in `tracks` and nothing else: `newestFirst` says `tracks` already run
    /// newest first (Liked music), else they run oldest first.
    func sorted(_ tracks: [MusicTrack], newestFirst: Bool = false) -> [MusicTrack] {
        guard reorders(newestFirst: newestFirst), tracks.count > 1 else { return tracks }
        if field == .dateAdded { return tracks.reversed() }
        let keyed = tracks.enumerated().map { Keyed(index: $0.offset, track: $0.element, key: key(of: $0.element)) }
        let ordered = keyed.sorted { lhs, rhs in
            switch (lhs.key, rhs.key) {
            case (nil, nil): return lhs.index < rhs.index
            case (nil, _?): return false
            case (_?, nil): return true
            case let (left?, right?):
                let order = left.compare(to: right)
                if order == .orderedSame { return lhs.index < rhs.index }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
        return ordered.map(\.track)
    }

    private struct Keyed {
        let index: Int
        let track: MusicTrack
        let key: Key?
    }

    private enum Key {
        /// Text with case, accents and width already folded away.
        case text(String)
        case number(Int)

        func compare(to other: Key) -> ComparisonResult {
            switch (self, other) {
            case let (.text(left), .text(right)):
                return left.compare(right, options: [.numeric], range: nil, locale: .current)
            case let (.number(left), .number(right)):
                return left < right ? .orderedAscending : (left > right ? .orderedDescending : .orderedSame)
            default:
                return .orderedSame
            }
        }
    }

    /// The value the sort reads; nil when the song has none, which puts it last.
    private func key(of track: MusicTrack) -> Key? {
        switch field {
        case .playlistOrder, .dateAdded: nil
        case .title: Self.text(track.title)
        case .artist: Self.text(track.artist)
        case .album: Self.text(track.album)
        case .duration: track.durationSeconds.map(Key.number)
        }
    }

    private static func text(_ value: String?) -> Key? {
        guard let value, !value.isEmpty else { return nil }
        return .text(value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current))
    }
}
