// DeciTests/Music/MusicBrowseLayoutTests.swift
// The measures and small rules of Home, Library and the pages in the right column, the mini spectrum on the playing
// row and the art of Liked music. Nothing here draws a view.

import CoreGraphics
import Testing
@testable import Deci

@Suite("MusicBrowseLayout")
struct MusicBrowseLayoutTests {
    @Test("each screen starts a little under the header: Home 15, the Library switch 13, a page's Back row 13")
    func tops() {
        #expect(MusicBrowseLayout.homeTop == 15)
        #expect(MusicBrowseLayout.libraryTop == 13)
        #expect(MusicBrowseLayout.pageTop == 13)
    }

    @Test("Home's sections sit 14 apart, a list 4 under its title and a row of tiles 8")
    func homeGaps() {
        #expect(MusicBrowseLayout.homeSectionGap == 14)
        #expect(MusicBrowseLayout.listTitleGap == 4)
        #expect(MusicBrowseLayout.tileTitleGap == 8)
        #expect(MusicBrowseLayout.topSongsTitleGap == 2)
    }

    @Test("tiles are 68 pt on Home and 70 pt on a shelf and in the Albums grid, 8 apart, the text 3 under the cover")
    func tiles() {
        #expect(MusicBrowseLayout.homeTile == 68)
        #expect(MusicBrowseLayout.shelfTile == 70)
        #expect(MusicBrowseLayout.tileGap == 8)
        #expect(MusicBrowseLayout.tileTextGap == 3)
        #expect(MusicBrowseLayout.gridRowGap == 14)
    }

    @Test("a playlist row is 48 pt with a 40 pt cover, an artist row 46 pt with a 36 pt round photo")
    func libraryRows() {
        #expect(MusicBrowseLayout.playlistRowHeight == 48)
        #expect(MusicBrowseLayout.playlistArt == 40)
        #expect(MusicBrowseLayout.artistRowHeight == 46)
        #expect(MusicBrowseLayout.artistArt == 36)
        #expect(MusicBrowseLayout.libraryArtRadius == 4)
        #expect(MusicBrowseLayout.playlistRowHeight > MusicBrowseLayout.playlistArt)
        #expect(MusicBrowseLayout.artistRowHeight > MusicBrowseLayout.artistArt)
        #expect(MusicBrowseLayout.segmentListGap == 12)
    }

    @Test("a page has a 72 pt cover, 12 pt between its parts, a 26 pt action row and a 23 pt sort bar")
    func pages() {
        #expect(MusicBrowseLayout.pageArt == 72)
        #expect(MusicBrowseLayout.pageArtRadius == 5)
        #expect(MusicBrowseLayout.pageGap == 12)
        #expect(MusicBrowseLayout.pageArtGap == 12)
        #expect(MusicBrowseLayout.pageInfoGap == 3)
        #expect(MusicBrowseLayout.backRowHeight == 13)
        #expect(MusicBrowseLayout.actionsHeight == 26)
        #expect(MusicBrowseLayout.actionsGap == 8)
        #expect(MusicBrowseLayout.chipBarHeight == 23)
        #expect(MusicBrowseLayout.miniBarHeight == 13)
        #expect(MusicBrowseLayout.artistSectionGap == 14)
    }

    @Test("the hover surface of a row reaches 6 pt past it, inside the 16 pt page margin")
    func hover() {
        #expect(MusicBrowseLayout.rowHoverInset == 6)
        #expect(MusicBrowseLayout.rowHoverRadius == 6)
        #expect(MusicBrowseLayout.rowHoverInset < MusicStyle.Spacing.page)
    }

    @Test("the right column's content width at both popup sizes")
    func contentWidths() {
        // The default and the compact popup, 510 and 470 wide.
        #expect(MusicPopupMetrics.rightColumnContentWidth(popupWidth: 510) == 305)
        #expect(MusicPopupMetrics.rightColumnContentWidth(popupWidth: 470) == 265)
    }
}

@Suite("MusicBrowseLayout history")
struct MusicBrowseLayoutHistoryTests {
    @Test("a History day shows ten rows before the rest sits behind See all")
    func dayRowCap() {
        #expect(MusicBrowseLayout.historyDayRowCap == 10)
    }
}

@Suite("MusicQuickPicks")
struct MusicQuickPicksTests {
    @Test("the list shows five rows, and twenty once it is opened")
    func counts() {
        #expect(MusicQuickPicks.collapsedCount == 5)
        #expect(MusicQuickPicks.expandedCount == 20)
    }

    @Test("it never shows more than the shelf has")
    func visible() {
        #expect(MusicQuickPicks.visibleCount(total: 0, expanded: false) == 0)
        #expect(MusicQuickPicks.visibleCount(total: 0, expanded: true) == 0)
        #expect(MusicQuickPicks.visibleCount(total: 3, expanded: false) == 3)
        #expect(MusicQuickPicks.visibleCount(total: 3, expanded: true) == 3)
        #expect(MusicQuickPicks.visibleCount(total: 12, expanded: false) == 5)
        #expect(MusicQuickPicks.visibleCount(total: 12, expanded: true) == 12)
        #expect(MusicQuickPicks.visibleCount(total: 40, expanded: true) == 20)
        #expect(MusicQuickPicks.visibleCount(total: -2, expanded: true) == 0)
    }

    @Test("See all is offered only when there is something past the first five")
    func offersMore() {
        #expect(!MusicQuickPicks.offersMore(total: 0))
        #expect(!MusicQuickPicks.offersMore(total: 5))
        #expect(MusicQuickPicks.offersMore(total: 6))
    }

    @Test("the link says See all, and Show less once the list is open")
    func linkTitle() {
        #expect(MusicQuickPicks.linkTitle(expanded: false) == "See all")
        #expect(MusicQuickPicks.linkTitle(expanded: true) == "Show less")
    }
}

@Suite("MusicSortChip")
struct MusicSortChipTests {
    private let title = MusicPlaylistSort(field: .title, ascending: true)
    private let duration = MusicPlaylistSort(field: .duration, ascending: false)
    private let oldestFirst = MusicPlaylistSort(field: .dateAdded, ascending: true)

    @Test("the chip says Playlist order for a playlist that is not the user's at rest, with no arrow")
    func atRest() {
        let chip = MusicSortChip.resolve(.playlistOrder)
        #expect(chip.label == "Sort: Playlist order")
        #expect(chip.directionSymbol == nil)
    }

    @Test("the chip of a playlist the user made at rest says Date added with the arrow down")
    func ownedAtRest() {
        #expect(MusicSortChip.resolve(.dateAddedNewestFirst) == MusicSortChip(label: "Sort: Date added", directionSymbol: "arrow.down"))
    }

    @Test("Date added oldest first reads the same with the arrow up")
    func dateAddedOldestFirst() {
        #expect(MusicSortChip.resolve(oldestFirst) == MusicSortChip(label: "Sort: Date added", directionSymbol: "arrow.up"))
    }

    @Test("a picked key is named, with an arrow that tells the direction")
    func picked() {
        #expect(MusicSortChip.resolve(title) == MusicSortChip(label: "Sort: Title", directionSymbol: "arrow.up"))
        #expect(MusicSortChip.resolve(duration) == MusicSortChip(label: "Sort: Duration", directionSymbol: "arrow.down"))
    }

    @Test("Liked music says Recently liked at rest, which is Date added newest first, else the key")
    func liked() {
        #expect(MusicSortChip.likedLabel(.dateAddedNewestFirst) == "Recently liked")
        #expect(MusicSortChip.likedLabel(title) == "Title")
        #expect(MusicSortChip.likedLabel(duration) == "Duration")
    }

    @Test("Liked music names Date added oldest first by the key and Playlist order by its own name")
    func likedPicked() {
        #expect(MusicSortChip.likedLabel(oldestFirst) == "Date added")
        #expect(MusicSortChip.likedLabel(.playlistOrder) == "Playlist order")
    }

    @Test("the menu marks Playlist order with a check and the other keys with their direction")
    func menuSymbol() {
        #expect(MusicSortChip.menuSymbol(for: .playlistOrder) == "checkmark")
        #expect(MusicSortChip.menuSymbol(for: title) == "arrow.up")
        #expect(MusicSortChip.menuSymbol(for: duration) == "arrow.down")
    }

    @Test("the menu marks Date added with the arrow of its direction, never a check")
    func menuSymbolDateAdded() {
        #expect(MusicSortChip.menuSymbol(for: .dateAddedNewestFirst) == "arrow.down")
        #expect(MusicSortChip.menuSymbol(for: oldestFirst) == "arrow.up")
    }

    @Test("an artist's songs list calls YouTube's order Popular, with no arrow")
    func artistSongsAtRest() {
        #expect(MusicSortChip.resolve(.playlistOrder, artistSongs: true) == MusicSortChip(label: "Sort: Popular", directionSymbol: nil))
    }

    @Test("an artist's songs list names Plays and Album with the arrow of their direction")
    func artistSongsPicked() {
        let plays = MusicPlaylistSort(field: .plays, ascending: false)
        let album = MusicPlaylistSort(field: .album, ascending: true)
        #expect(MusicSortChip.resolve(plays, artistSongs: true) == MusicSortChip(label: "Sort: Plays", directionSymbol: "arrow.down"))
        #expect(MusicSortChip.resolve(plays.picking(.plays), artistSongs: true) == MusicSortChip(label: "Sort: Plays", directionSymbol: "arrow.up"))
        #expect(MusicSortChip.resolve(album, artistSongs: true) == MusicSortChip(label: "Sort: Album", directionSymbol: "arrow.up"))
    }

    @Test("an artist's songs list names Release date, newest first with the down arrow")
    func artistSongsReleaseDate() {
        let newest = MusicPlaylistSort.playlistOrder.picking(.releaseDate)
        #expect(MusicSortChip.resolve(newest, artistSongs: true) == MusicSortChip(label: "Sort: Release date", directionSymbol: "arrow.down"))
        #expect(MusicSortChip.resolve(newest.picking(.releaseDate), artistSongs: true) == MusicSortChip(label: "Sort: Release date", directionSymbol: "arrow.up"))
        #expect(MusicSortChip.menuSymbol(for: newest) == "arrow.down")
    }

    @Test("any other page still calls it Playlist order, and the menu marks Popular with a check")
    func otherPagesKeepTheirWords() {
        #expect(MusicSortChip.resolve(.playlistOrder, artistSongs: false) == MusicSortChip.resolve(.playlistOrder))
        #expect(MusicSortChip.resolve(.playlistOrder, artistSongs: false).label == "Sort: Playlist order")
        #expect(MusicSortChip.resolve(title, artistSongs: false) == MusicSortChip.resolve(title))
        #expect(MusicSortChip.menuSymbol(for: .playlistOrder) == "checkmark")
        #expect(MusicSortChip.menuSymbol(for: MusicPlaylistSort(field: .plays, ascending: false)) == "arrow.down")
    }
}

@Suite("MusicPageBackLabel")
struct MusicPageBackLabelTests {
    @Test("the Back row names the page below this one on the path")
    func previousTitle() {
        #expect(MusicPageBackLabel.resolve(previousTitle: "Fake Artist", tab: .home) == "Fake Artist")
        #expect(MusicPageBackLabel.resolve(previousTitle: "  Fake Album  ", tab: .library) == "Fake Album")
    }

    @Test("with no page below it names the tab the path started on")
    func tab() {
        #expect(MusicPageBackLabel.resolve(previousTitle: nil, tab: .home) == "Home")
        #expect(MusicPageBackLabel.resolve(previousTitle: nil, tab: .library) == "Library")
        #expect(MusicPageBackLabel.resolve(previousTitle: nil, tab: .history) == "History")
    }

    @Test("a blank title counts as none")
    func blank() {
        #expect(MusicPageBackLabel.resolve(previousTitle: "", tab: .library) == "Library")
        #expect(MusicPageBackLabel.resolve(previousTitle: "   ", tab: .home) == "Home")
        #expect(MusicPageBackLabel.resolve(previousTitle: " ", tab: .history) == "History")
    }
}

@Suite("MusicLikedArtStyle")
struct MusicLikedArtStyleTests {
    @Test("a warm dark base under an accent wash that fades down")
    func colours() {
        #expect(MusicLikedArtStyle.baseHex == 0x2A1D14)
        #expect(MusicLikedArtStyle.topOpacity == 0.42)
        #expect(MusicLikedArtStyle.bottomOpacity == 0.10)
        #expect(MusicLikedArtStyle.topOpacity > MusicLikedArtStyle.bottomOpacity)
    }

    @Test("the heart is 42 percent of the art")
    func heart() {
        #expect(abs(MusicLikedArtStyle.heartSize(art: 40) - 16.8) < 0.0001)
        #expect(abs(MusicLikedArtStyle.heartSize(art: 72) - 30.24) < 0.0001)
        #expect(MusicLikedArtStyle.heartScale == 0.42)
    }

    @Test("no art, a negative one or one that is not a number has no heart")
    func heartOdd() {
        #expect(MusicLikedArtStyle.heartSize(art: 0) == 0)
        #expect(MusicLikedArtStyle.heartSize(art: -10) == 0)
        #expect(MusicLikedArtStyle.heartSize(art: .nan) == 0)
        #expect(MusicLikedArtStyle.heartSize(art: .infinity) == 0)
    }
}

@Suite("MusicMiniSpectrum")
struct MusicMiniSpectrumTests {
    @Test("four 2 pt bars on a 4 pt pitch fill a 14 by 12 box exactly")
    func geometry() {
        #expect(MusicMiniSpectrum.barCount == 4)
        #expect(MusicMiniSpectrum.barWidth == 2)
        #expect(MusicMiniSpectrum.pitch == 4)
        #expect(MusicMiniSpectrum.width == 14)
        #expect(MusicMiniSpectrum.height == 12)
        #expect(MusicMiniSpectrum.barX(0) == 0)
        #expect(MusicMiniSpectrum.barX(3) == 12)
        #expect(MusicMiniSpectrum.barX(MusicMiniSpectrum.barCount - 1) + MusicMiniSpectrum.barWidth == MusicMiniSpectrum.width)
    }

    @Test("at rest the bars stand at 7, 12, 5 and 10, whatever the time")
    func rest() {
        #expect(MusicMiniSpectrum.restHeights == [7, 12, 5, 10])
        for time in [0.0, 0.37, 12.5, 1_000_000] {
            #expect(MusicMiniSpectrum.heights(at: time, isAnimating: false) == MusicMiniSpectrum.restHeights)
        }
    }

    @Test("a time that is not a number leaves the bars at rest, even while animating")
    func nonFiniteTime() {
        #expect(MusicMiniSpectrum.heights(at: .nan, isAnimating: true) == MusicMiniSpectrum.restHeights)
        #expect(MusicMiniSpectrum.heights(at: .infinity, isAnimating: true) == MusicMiniSpectrum.restHeights)
        #expect(MusicMiniSpectrum.heights(at: -.infinity, isAnimating: true) == MusicMiniSpectrum.restHeights)
    }

    @Test("while animating every bar stays between 3 and 12")
    func bounds() {
        for step in 0..<400 {
            let heights = MusicMiniSpectrum.heights(at: Double(step) * 0.05, isAnimating: true)
            #expect(heights.count == MusicMiniSpectrum.barCount)
            for height in heights {
                #expect(height >= MusicMiniSpectrum.minHeight && height <= MusicMiniSpectrum.maxHeight)
            }
        }
        // A time far from now and a negative one are still in range.
        for time in [-5_000.0, 1e7] {
            for height in MusicMiniSpectrum.heights(at: time, isAnimating: true) {
                #expect(height >= MusicMiniSpectrum.minHeight && height <= MusicMiniSpectrum.maxHeight)
            }
        }
    }

    @Test("the bars move, and not all in step")
    func moves() {
        var seen = Set<[CGFloat]>()
        for step in 0..<40 {
            seen.insert(MusicMiniSpectrum.heights(at: Double(step) * 0.11, isAnimating: true))
        }
        #expect(seen.count > 10)
        let heights = MusicMiniSpectrum.heights(at: 0.3, isAnimating: true)
        #expect(Set(heights).count > 1)
        #expect(MusicMiniSpectrum.periods.count == MusicMiniSpectrum.barCount)
        #expect(Set(MusicMiniSpectrum.periods).count == MusicMiniSpectrum.barCount)
    }

    @Test("the rest heights sit inside the bar range")
    func restInRange() {
        for height in MusicMiniSpectrum.restHeights {
            #expect(height >= MusicMiniSpectrum.minHeight && height <= MusicMiniSpectrum.maxHeight)
        }
    }
}
