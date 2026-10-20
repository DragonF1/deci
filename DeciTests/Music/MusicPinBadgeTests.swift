// DeciTests/Music/MusicPinBadgeTests.swift
// The size and place of the pin badge on a cover: it scales with the cover, never under the floor, and a round cover
// is inset further so the dot sits on the circle's edge. Also who wears it: anything pinned to Home.

import CoreGraphics
import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicPinBadge")
struct MusicPinBadgeTests {

    @Test("The dot is 14 on a row and on the covers of the page rows")
    func diameters() {
        #expect(MusicPinBadge.diameter(coverSize: MusicCollectionRow.coverSize) == 14)
        #expect(MusicPinBadge.diameter(coverSize: MusicSongRowLayout.playlist.coverSize ?? 0) == 14)
    }

    @Test("The dot grows with the cover and never falls under the floor")
    func diameterBounds() {
        #expect(MusicPinBadge.diameter(coverSize: 0) == MusicPinBadge.minDiameter)
        #expect(MusicPinBadge.diameter(coverSize: 1) == MusicPinBadge.minDiameter)
        #expect(MusicPinBadge.diameter(coverSize: 200) > MusicPinBadge.diameter(coverSize: 96))
        #expect(MusicPinBadge.diameter(coverSize: 10_000) > 0)
    }

    @Test("A square cover is inset 4 whatever its size")
    func squareInset() {
        for size: CGFloat in [32, 40, 72, 96, 400] {
            #expect(MusicPinBadge.inset(coverSize: size, circular: false) == 4)
        }
    }

    @Test("A round cover is inset a tenth of its size, and no less than a square one")
    func roundInset() {
        #expect(abs(MusicPinBadge.inset(coverSize: 96, circular: true) - 9.6) < 0.0001)
        #expect(abs(MusicPinBadge.inset(coverSize: 72, circular: true) - 7.2) < 0.0001)
        #expect(MusicPinBadge.inset(coverSize: 40, circular: true) == 4)
        #expect(MusicPinBadge.inset(coverSize: 10, circular: true) == 4)
    }

    @Test("The badge stays inside the cover's square on every cover the Music tab draws")
    func badgeFitsTheSquare() {
        let covers: [CGFloat] = [
            MusicBrowseLayout.homeTile, MusicBrowseLayout.shelfTile, MusicCollectionRow.coverSize,
            MusicBrowseLayout.artistArt, MusicSongRowLayout.playlist.coverSize ?? 0,
        ]
        for size in covers {
            for circular in [false, true] {
                let reach = MusicPinBadge.diameter(coverSize: size) + MusicPinBadge.inset(coverSize: size, circular: circular)
                #expect(reach <= size)
            }
        }
    }

    // MARK: - Who wears it

    @Test("A playlist, an album and an artist pinned to Home wear the badge; the same ids as another kind do not")
    func homePinnedCollectionsWearTheBadge() {
        let home = MusicPinnedItems(items: [
            MusicPinnedItem(kind: .playlist, id: "VLPL1", title: "Mix"),
            MusicPinnedItem(kind: .album, id: "MPRE1", title: "Record"),
            MusicPinnedItem(kind: .artist, id: "UCa", title: "Ay"),
        ])
        func wears(_ collection: MusicCollection) -> Bool { home.isPinned(collection) }

        #expect(wears(MusicSamples.collection("VLPL1", kind: .playlist)))
        #expect(wears(MusicSamples.collection("MPRE1", kind: .album)))
        #expect(wears(MusicSamples.collection("UCa", kind: .artist)))
        #expect(!wears(MusicSamples.collection("UCa", kind: .playlist)))
        #expect(!wears(MusicSamples.collection("VLPL1", kind: .album)))
        #expect(!wears(MusicSamples.collection("VLPL2", kind: .playlist)))
    }

    @Test("A tile loses the badge when it is unpinned from Home, and Liked music never wears the Home badge")
    func unpinTakesTheBadgeOff() {
        let home = MusicPinnedItems(items: [MusicPinnedItem(kind: .playlist, id: "VLPL1", title: "Mix")])
        let tile = MusicSamples.collection("VLPL1", kind: .playlist)
        #expect(home.isPinned(tile))

        home.unpin(MusicPinnedItem(kind: .playlist, id: "VLPL1", title: ""))
        #expect(!home.isPinned(tile))
        #expect(!home.isPinned(MusicBrowseStore.likedMusic))
    }

    @Test("A song pinned to Home counts as pinned for its cover's badge, by its video id")
    func homePinnedSongIsPinned() {
        let home = MusicPinnedItems(items: [MusicPinnedItem(kind: .song, id: "vid1", title: "Tune")])
        #expect(home.isPinned(MusicSamples.track("vid1")))
        #expect(!home.isPinned(MusicSamples.track("vid2")))
    }

    @Test("A pinned tile on the Home row is small and the same size for every kind")
    func pinnedRowTileSize() {
        #expect(MusicStyle.Size.pinnedPhoto <= MusicStyle.Size.pinnedTileWidth)
        #expect(MusicStyle.Size.pinnedPhoto < MusicBrowseLayout.homeTile)
    }

    @Test("Each kind of pinned item has its own placeholder until the photo loads")
    func placeholders() {
        let kinds: [MusicPinnedItem.Kind] = [.artist, .playlist, .album, .song]
        #expect(Set(kinds.map(\.placeholderSymbol)).count >= 3)
        #expect(MusicPinnedItem.Kind.song.placeholderSymbol == "music.note")
        #expect(MusicPinnedItem.Kind.artist.placeholderSymbol == MusicCollection.Kind.artist.placeholderSymbol)
    }
}
