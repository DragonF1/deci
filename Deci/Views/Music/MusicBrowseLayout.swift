// Deci/Views/Music/MusicBrowseLayout.swift
import CoreGraphics
import Foundation

// The measures and small rules of the tabs and the detail pages in the right column, kept apart from the views so
// they are tested without drawing anything.

/// Where things sit in the right column's browse screens. Every screen lays its own content under the 32 pt header, and
/// its rows pad themselves by the page margin.
nonisolated enum MusicBrowseLayout {
    /// How far under the header each screen starts: Home's chips row sits 15 under it, the Library switch and a page's
    /// Back row 13.
    static let homeTop: CGFloat = 15
    static let libraryTop: CGFloat = 13
    static let pageTop: CGFloat = 13

    /// The gap between two Home sections.
    static let homeSectionGap: CGFloat = 14

    /// How many rows a History day shows before the rest sits behind its "See all". A day of this many or fewer has no link.
    static let historyDayRowCap = 10

    /// The gap between a section's title and its rows, and its tiles. An artist's Top songs sit closer.
    static let listTitleGap: CGFloat = 4
    static let tileTitleGap: CGFloat = 8
    static let topSongsTitleGap: CGFloat = 2

    /// The cover of a Home tile, and of a tile in the Albums grid and on an artist's shelf.
    static let homeTile: CGFloat = 68
    static let shelfTile: CGFloat = 70
    /// The gap between two tiles in a row, and between a cover and its text.
    static let tileGap: CGFloat = 8
    static let tileTextGap: CGFloat = 3
    /// The gap between two rows of the Albums grid.
    static let gridRowGap: CGFloat = 14

    /// The gap between the Library switch and the list.
    static let segmentListGap: CGFloat = 12

    /// A Library row: a playlist's cover is square, an artist's round.
    static let playlistRowHeight: CGFloat = 48
    static let playlistArt: CGFloat = 40
    static let artistRowHeight: CGFloat = 46
    static let artistArt: CGFloat = 36
    static let libraryArtRadius: CGFloat = 4
    static let libraryRowGap: CGFloat = 12
    static let libraryChevron: CGFloat = 10

    /// The gap between a page's Back row, its header, its actions and its list.
    static let pageGap: CGFloat = 12
    static let backRowHeight: CGFloat = 13
    static let pageArt: CGFloat = 72
    static let pageArtRadius: CGFloat = 5
    /// The gap between a page's art and its text.
    static let pageArtGap: CGFloat = 12
    /// The gap between the lines of the header's text, which is centred beside the art.
    static let pageInfoGap: CGFloat = 3
    static let actionsHeight: CGFloat = 26
    static let actionsGap: CGFloat = 8
    /// The list bar over a page's songs: the "SONGS" kicker with the sort chip (Playlist) or the small sort (Liked).
    static let chipBarHeight: CGFloat = 23
    static let miniBarHeight: CGFloat = 13
    static let listBarGap: CGFloat = 4
    /// The gap between an artist's Top songs and the shelves under them.
    static let artistSectionGap: CGFloat = 14

    /// How far a row's hover surface reaches past the row's content on each side.
    static let rowHoverInset: CGFloat = 6
    static let rowHoverRadius: CGFloat = 6
}

// MARK: - Quick picks

/// How many songs Home's Quick picks shows. The list is five rows and "See all" opens it in place to more.
nonisolated enum MusicQuickPicks {
    static let collapsedCount = 5
    static let expandedCount = 20

    static func visibleCount(total: Int, expanded: Bool) -> Int {
        guard total > 0 else { return 0 }
        return min(total, expanded ? expandedCount : collapsedCount)
    }

    /// Whether the shelf has rows beyond the first five to open.
    static func offersMore(total: Int) -> Bool { total > collapsedCount }

    static func linkTitle(expanded: Bool) -> String { expanded ? "Show less" : "See all" }
}

// MARK: - Sort chip

/// What a page's sort chip and Liked music's small sort say.
nonisolated struct MusicSortChip: Equatable {
    /// "Sort: Title", and "Sort: Date added" on a playlist the user made at rest.
    let label: String
    /// An arrow for a key with a direction, to tell which way it runs; nil for Playlist order, which has none.
    let directionSymbol: String?

    static func resolve(_ sort: MusicPlaylistSort) -> MusicSortChip {
        MusicSortChip(
            label: "Sort: " + sort.field.label,
            directionSymbol: sort.isPlaylistOrder ? nil : (sort.ascending ? "arrow.up" : "arrow.down")
        )
    }

    /// The small sort of Liked music: YouTube lists it newest first, so Date added with the newest first, where it
    /// rests, reads "Recently liked".
    static func likedLabel(_ sort: MusicPlaylistSort) -> String {
        sort.field == .dateAdded && !sort.ascending ? "Recently liked" : sort.field.label
    }

    /// The mark in the sort menu next to the picked key: a check for Playlist order, else the direction.
    static func menuSymbol(for sort: MusicPlaylistSort) -> String {
        sort.isPlaylistOrder ? "checkmark" : (sort.ascending ? "arrow.up" : "arrow.down")
    }
}

// MARK: - Back

/// What the Back row of a page is called: the screen it goes back to.
nonisolated enum MusicPageBackLabel {
    /// The title of the page below this one on the path, else the tab the path started on. A page opened from search
    /// results sits on the tab the search was typed on, so Back reads "Home" and lands on the results.
    static func resolve(previousTitle: String?, tab: MusicBrowseStore.Tab) -> String {
        if let title = previousTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        switch tab {
        case .home: return "Home"
        case .library: return "Library"
        case .history: return "History"
        }
    }
}

// MARK: - Liked art

/// The art of Liked music: a warm dark base under a vertical wash of the accent, and an accent heart.
nonisolated enum MusicLikedArtStyle {
    static let baseHex: UInt32 = 0x2A1D14
    /// The accent's opacity at the top of the art and at its bottom.
    static let topOpacity = 0.42
    static let bottomOpacity = 0.10
    /// The heart's size as a share of the art's side.
    static let heartScale: CGFloat = 0.42

    static func heartSize(art side: CGFloat) -> CGFloat {
        guard side.isFinite, side > 0 else { return 0 }
        return side * heartScale
    }
}
