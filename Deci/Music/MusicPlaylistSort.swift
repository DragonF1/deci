// Deci/Music/MusicPlaylistSort.swift
import Foundation

/// What a playlist's songs can be sorted by.
enum MusicSortField: String, CaseIterable, Identifiable, Sendable {
    /// The order the playlist has on YouTube Music.
    case defaultOrder
    case title
    case artist
    case album
    case duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultOrder: "Default order"
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

    static let `default` = MusicPlaylistSort()

    init(field: MusicSortField = .defaultOrder, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }

    var isDefault: Bool { field == .defaultOrder }

    /// What picking `picked` in the sort menu gives: a new option starts ascending, the same option again flips
    /// the direction, and Default order has no direction.
    func picking(_ picked: MusicSortField) -> MusicPlaylistSort {
        if picked == .defaultOrder { return .default }
        if picked == field { return MusicPlaylistSort(field: field, ascending: !ascending) }
        return MusicPlaylistSort(field: picked, ascending: true)
    }

    /// `tracks` in this order. Text ignores case, accents and width and reads numbers by value; songs that tie
    /// keep the order they had, in both directions; songs with no value for the field go last in both.
    /// The text of each song is folded once, before the sort, and the comparisons only read numbers by value.
    func sorted(_ tracks: [MusicTrack]) -> [MusicTrack] {
        guard field != .defaultOrder, tracks.count > 1 else { return tracks }
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
        case .defaultOrder: nil
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
