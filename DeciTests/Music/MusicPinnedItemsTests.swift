// DeciTests/Music/MusicPinnedItemsTests.swift
// The "Pinned" row on Music Home: pin order, the cap of 30 across every kind, repeats, refreshed names and photos,
// what gets saved, the tile each pin draws, how a pin is made from a tile, a page or a song, what an album pin keeps
// so its menu can go to the artist and save the album, and the Pin to Home button's words.

import Foundation
import SwiftUI
import Testing
@testable import Deci

@MainActor
private final class PinSink {
    var saved: [[MusicPinnedItem]] = []
}

@MainActor
@Suite("MusicPinnedItems")
struct MusicPinnedItemsTests {
    private static let oldPhoto = "https://img.example.test/old.jpg"
    private static let newPhoto = "https://img.example.test/new.jpg"

    private func item(
        _ id: String,
        kind: MusicPinnedItem.Kind = .artist,
        title: String? = nil,
        photo: String? = oldPhoto
    ) -> MusicPinnedItem {
        MusicPinnedItem(kind: kind, id: id, title: title ?? "Title \(id)", thumbnailURL: photo)
    }

    private func make(_ initial: [MusicPinnedItem] = []) -> (pins: MusicPinnedItems, sink: PinSink) {
        let sink = PinSink()
        return (MusicPinnedItems(items: initial, save: { sink.saved.append($0) }), sink)
    }

    private func ids(_ pins: MusicPinnedItems) -> [String] { pins.items.map(\.id) }

    private func full() -> [MusicPinnedItem] {
        (1...MusicPinnedItems.limit).map { item("UC\($0)") }
    }

    // MARK: - Pinning

    @Test("nothing is pinned to begin with")
    func startsEmpty() {
        let (pins, sink) = make()
        #expect(pins.items.isEmpty)
        #expect(pins.isEmpty)
        #expect(!pins.isFull)
        #expect(sink.saved.isEmpty)
    }

    @Test("pinning appends, oldest first")
    func pinAppends() {
        let (pins, sink) = make()
        #expect(pins.pin(item("UCa")))
        #expect(pins.pin(item("UCb")))
        #expect(pins.pin(item("UCc")))
        #expect(ids(pins) == ["UCa", "UCb", "UCc"])
        #expect(sink.saved.map { $0.map(\.id) } == [["UCa"], ["UCa", "UCb"], ["UCa", "UCb", "UCc"]])
        #expect(!pins.isEmpty)
    }

    @Test("every kind can be pinned, and the row keeps the order they were pinned in")
    func everyKindKeepsPinOrder() {
        let (pins, _) = make()
        #expect(pins.pin(item("VLPL1", kind: .playlist)))
        #expect(pins.pin(item("UCa", kind: .artist)))
        #expect(pins.pin(item("vid1", kind: .song)))
        #expect(pins.pin(item("MPRE1", kind: .album)))
        #expect(pins.items.map(\.kind) == [.playlist, .artist, .song, .album])
        #expect(ids(pins) == ["VLPL1", "UCa", "vid1", "MPRE1"])
    }

    @Test("pinning the same item again changes nothing and saves nothing")
    func repeatPinIsNoOp() {
        let (pins, sink) = make()
        pins.pin(item("UCa", title: "First name"))
        pins.pin(item("UCb"))
        #expect(!pins.pin(item("UCa", title: "Other name", photo: Self.newPhoto)))
        #expect(ids(pins) == ["UCa", "UCb"])
        #expect(pins.items[0].title == "First name")
        #expect(pins.items[0].thumbnailURL == Self.oldPhoto)
        #expect(sink.saved.count == 2)
    }

    @Test("an item with no id is never pinned")
    func blankIdRefused() {
        let (pins, sink) = make()
        #expect(!pins.pin(item("")))
        #expect(pins.items.isEmpty)
        #expect(sink.saved.isEmpty)
    }

    @Test("a playlist and an artist that share an id are two different pins")
    func kindIsPartOfIdentity() {
        let (pins, _) = make([item("same", kind: .artist)])
        #expect(!pins.isPinned(item("same", kind: .playlist)))
        #expect(pins.pin(item("same", kind: .playlist)))
        #expect(pins.items.count == 2)
        #expect(pins.unpin(item("same", kind: .artist)))
        #expect(pins.items.map(\.kind) == [.playlist])
    }

    @Test("isPinned asks by collection and by song, with the kind in mind")
    func isPinnedByCollectionAndTrack() {
        let (pins, _) = make([
            item("UCa", kind: .artist),
            item("VLPL1", kind: .playlist),
            item("MPRE1", kind: .album),
            item("vid1", kind: .song),
        ])
        #expect(pins.isPinned(MusicSamples.collection("UCa", kind: .artist)))
        #expect(pins.isPinned(MusicSamples.collection("VLPL1", kind: .playlist)))
        #expect(pins.isPinned(MusicSamples.collection("MPRE1", kind: .album)))
        #expect(pins.isPinned(MusicSamples.track("vid1")))
        #expect(!pins.isPinned(MusicSamples.collection("UCa", kind: .playlist)))
        #expect(!pins.isPinned(MusicSamples.collection("vid1", kind: .album)))
        #expect(!pins.isPinned(MusicSamples.track("UCa")))
        #expect(!pins.isPinned(MusicSamples.track("")))
    }

    @Test("unpinning removes the item and keeps the order of the rest")
    func unpinRemoves() {
        let (pins, sink) = make([item("UCa"), item("UCb"), item("UCc")])
        #expect(pins.unpin(item("UCb")))
        #expect(ids(pins) == ["UCa", "UCc"])
        #expect(!pins.isPinned(item("UCb")))
        #expect(sink.saved.map { $0.map(\.id) } == [["UCa", "UCc"]])
    }

    @Test("unpinning an item that is not pinned changes nothing and saves nothing")
    func unpinUnknownIsNoOp() {
        let (pins, sink) = make([item("UCa")])
        #expect(!pins.unpin(item("UCz")))
        #expect(ids(pins) == ["UCa"])
        #expect(sink.saved.isEmpty)
    }

    @Test("an item pinned again after an unpin goes to the end")
    func repinGoesLast() {
        let (pins, _) = make([item("UCa"), item("UCb")])
        pins.unpin(item("UCa"))
        pins.pin(item("UCa"))
        #expect(ids(pins) == ["UCb", "UCa"])
    }

    @Test("toggle pins an item that is not pinned and unpins one that is")
    func toggle() {
        let (pins, sink) = make()
        pins.toggle(item("UCa"))
        #expect(ids(pins) == ["UCa"])
        pins.toggle(item("UCa"))
        #expect(pins.items.isEmpty)
        #expect(sink.saved.count == 2)
    }

    // MARK: - The cap

    @Test("the cap is 30")
    func capValue() {
        #expect(MusicPinnedItems.limit == 30)
    }

    @Test("the 31st pin is refused, whatever its kind")
    func capRefusesTheNext() {
        let (pins, sink) = make(full())
        #expect(pins.isFull)
        for kind in [MusicPinnedItem.Kind.artist, .playlist, .album, .song] {
            #expect(!pins.pin(item("UCextra", kind: kind)))
        }
        #expect(pins.items.count == 30)
        #expect(!pins.isPinned(item("UCextra")))
        #expect(sink.saved.isEmpty)
    }

    @Test("the cap counts every kind together")
    func capSpansKinds() {
        let mixed = (1...15).map { item("UC\($0)") } + (1...15).map { item("PL\($0)", kind: .playlist) }
        let (pins, _) = make(mixed)
        #expect(pins.isFull)
        #expect(!pins.pin(item("vidX", kind: .song)))
    }

    @Test("the 30th pin goes in, and a freed place can be filled again")
    func capBoundary() {
        let (pins, _) = make(Array(full().dropLast()))
        #expect(!pins.isFull)
        #expect(pins.pin(item("UC30x", kind: .song)))
        #expect(pins.isFull)
        pins.unpin(item("UC1"))
        #expect(!pins.isFull)
        #expect(pins.pin(item("UC31x", kind: .album)))
        #expect(pins.items.count == 30)
        #expect(pins.items.last?.id == "UC31x")
    }

    @Test("canToggle: a pinned item can always be unpinned, a new one only while there is room")
    func canToggle() {
        let (open, _) = make([item("UCa")])
        #expect(open.canToggle(item("UCa")))
        #expect(open.canToggle(item("UCb")))

        let (closed, _) = make(full())
        #expect(closed.canToggle(item("UC1")))
        #expect(!closed.canToggle(item("UCextra")))
    }

    @Test("toggle on a full list unpins a pinned item and refuses a new one")
    func toggleWhenFull() {
        let (pins, _) = make(full())
        pins.toggle(item("UCextra"))
        #expect(pins.items.count == 30)
        #expect(!pins.isPinned(item("UCextra")))
        pins.toggle(item("UC3"))
        #expect(pins.items.count == 29)
        #expect(!pins.isPinned(item("UC3")))
    }

    // MARK: - The Pin to Home entry

    @Test("the entry's words: Pin to Home, Unpin from Home, and Home is full")
    func stateTitles() {
        #expect(MusicHomePinState.canPin.title == "Pin to Home")
        #expect(MusicHomePinState.pinned.title == "Unpin from Home")
        #expect(MusicHomePinState.full.title == "Pin to Home (Home is full)")
    }

    @Test("only a full Home turns the entry off")
    func stateEnabled() {
        #expect(MusicHomePinState.canPin.isEnabled)
        #expect(MusicHomePinState.pinned.isEnabled)
        #expect(!MusicHomePinState.full.isEnabled)
    }

    @Test("state(for:) is canPin, pinned or full")
    func stateFor() {
        let (open, _) = make([item("UCa")])
        #expect(open.state(for: item("UCa")) == .pinned)
        #expect(open.state(for: item("UCb")) == .canPin)

        let (closed, _) = make(full())
        #expect(closed.state(for: item("UC1")) == .pinned)
        #expect(closed.state(for: item("UCextra")) == .full)
        #expect(closed.state(for: item("UC1", kind: .song)) == .full)
    }

    // MARK: - Loading a saved list

    @Test("a saved list is kept as it is, in order, without saving it again")
    func loadKeepsOrder() {
        let (pins, sink) = make([item("UCb"), item("UCa")])
        #expect(ids(pins) == ["UCb", "UCa"])
        #expect(sink.saved.isEmpty)
    }

    @Test("a saved list with repeats, blank ids or too many entries is tidied on load")
    func loadTidies() {
        let messy = [item("UCa", title: "Kept"), item(""), item("UCa", title: "Repeat"), item("UCb")] +
            (1...40).map { item("UCx\($0)") }
        let (pins, sink) = make(messy)
        #expect(pins.items.count == 30)
        #expect(Array(ids(pins).prefix(3)) == ["UCa", "UCb", "UCx1"])
        #expect(pins.items[0].title == "Kept")
        #expect(Set(pins.items.map(\.key)).count == 30)
        #expect(!pins.isPinned(item("")))
        #expect(sink.saved.isEmpty)
    }

    @Test("repeats are judged by kind and id, so the same id as two kinds survives the tidy")
    func loadKeepsSameIdOfTwoKinds() {
        let (pins, _) = make([item("same", kind: .artist), item("same", kind: .playlist), item("same", kind: .artist)])
        #expect(pins.items.map(\.kind) == [.artist, .playlist])
    }

    // MARK: - Refreshing

    @Test("refresh updates the stored title, keeps the stored photo and keeps the place in the row")
    func refreshUpdates() {
        let (pins, sink) = make([item("UCa"), item("UCb", title: "Old name"), item("UCc")])
        #expect(pins.refresh(item("UCb", title: "New name", photo: Self.newPhoto)))
        #expect(ids(pins) == ["UCa", "UCb", "UCc"])
        #expect(pins.items[1].title == "New name")
        #expect(pins.items[1].thumbnailURL == Self.oldPhoto)
        #expect(sink.saved.count == 1)
        #expect(sink.saved[0][1].title == "New name")
    }

    @Test("a playlist and an album are refreshed the same way")
    func refreshOtherKinds() {
        let (pins, _) = make([
            item("VLPL1", kind: .playlist, title: "Old list"),
            item("MPRE1", kind: .album, title: "Old album"),
        ])
        #expect(pins.refresh(item("VLPL1", kind: .playlist, title: "New list")))
        #expect(pins.refresh(item("MPRE1", kind: .album, title: "New album")))
        #expect(pins.items.map(\.title) == ["New list", "New album"])
    }

    @Test("a refresh for another kind with the same id leaves the pin alone")
    func refreshWrongKindIsNoOp() {
        let (pins, sink) = make([item("same", kind: .artist, title: "Artist name")])
        #expect(!pins.refresh(item("same", kind: .playlist, title: "Playlist name")))
        #expect(pins.items[0].title == "Artist name")
        #expect(sink.saved.isEmpty)
    }

    @Test("a different photo alone never replaces the stored one, so nothing is saved")
    func refreshOtherPhotoKeepsStored() {
        let (pins, sink) = make([item("UCa")])
        #expect(!pins.refresh(item("UCa", photo: Self.newPhoto)))
        #expect(pins.items[0].thumbnailURL == Self.oldPhoto)
        #expect(sink.saved.isEmpty)
    }

    @Test("a blank stored photo counts as none and is filled in")
    func refreshFillsBlankPhoto() {
        let (pins, _) = make([item("UCa", photo: "")])
        #expect(pins.refresh(item("UCa", photo: Self.newPhoto)))
        #expect(pins.items[0].thumbnailURL == Self.newPhoto)
    }

    @Test("refresh with the same title and photo changes nothing and saves nothing")
    func refreshUnchanged() {
        let (pins, sink) = make([item("UCa")])
        #expect(!pins.refresh(item("UCa")))
        #expect(sink.saved.isEmpty)
    }

    @Test("a missing photo never wipes the stored one")
    func refreshNilPhotoKeepsStored() {
        let (pins, sink) = make([item("UCa", title: "Old name")])
        #expect(pins.refresh(item("UCa", title: "New name", photo: nil)))
        #expect(pins.items[0].title == "New name")
        #expect(pins.items[0].thumbnailURL == Self.oldPhoto)
        #expect(sink.saved.count == 1)

        #expect(!pins.refresh(item("UCa", title: "New name", photo: nil)))
        #expect(sink.saved.count == 1)
    }

    @Test("a photo fills in for a pin that had none")
    func refreshFillsMissingPhoto() {
        let (pins, _) = make([item("UCa", photo: nil)])
        #expect(pins.refresh(item("UCa", photo: Self.newPhoto)))
        #expect(pins.items[0].thumbnailURL == Self.newPhoto)
    }

    @Test("a blank title never replaces the stored one")
    func refreshBlankTitleKeepsStored() {
        let (pins, sink) = make([item("UCa", title: "Name")])
        #expect(!pins.refresh(item("UCa", title: "", photo: Self.oldPhoto)))
        #expect(pins.items[0].title == "Name")
        #expect(sink.saved.isEmpty)
    }

    @Test("refreshing an item that is not pinned does nothing and pins nothing")
    func refreshUnpinnedIsNoOp() {
        let (pins, sink) = make([item("UCa")])
        #expect(!pins.refresh(item("UCz", title: "Stranger", photo: Self.newPhoto)))
        #expect(ids(pins) == ["UCa"])
        #expect(sink.saved.isEmpty)
    }

    // MARK: - Settings reset

    @Test("a settings reset drops every pin without saving, and the next pin saves only itself")
    func settingsReset() {
        let (pins, sink) = make([item("UCa"), item("UCb", kind: .song)])
        pins.settingsDidReset()
        #expect(pins.items.isEmpty)
        #expect(pins.isEmpty)
        #expect(sink.saved.isEmpty)

        #expect(pins.pin(item("UCc")))
        #expect(sink.saved.map { $0.map(\.id) } == [["UCc"]])
    }

    // MARK: - The row

    @Test("the row is titled exactly Pinned")
    func rowTitle() {
        #expect(MusicPinnedItems.shelfTitle == "Pinned")
    }

    @Test("an artist's tile is a collection tile of the artist kind with no second line")
    func shelfItemArtist() {
        let pin = MusicPinnedItem(kind: .artist, id: "UCa", title: "Bee", thumbnailURL: Self.oldPhoto)
        guard case .collection(let collection) = pin.shelfItem else {
            Issue.record("an artist opens its page")
            return
        }
        #expect(collection.browseId == "UCa")
        #expect(collection.kind == .artist)
        #expect(collection.title == "Bee")
        #expect(collection.thumbnailURL == URL(string: Self.oldPhoto))
    }

    @Test("a playlist's and an album's tile open their page with the kind they were pinned as")
    func shelfItemPlaylistAndAlbum() {
        let playlist = MusicPinnedItem(kind: .playlist, id: "VLPL1", title: "Mix", subtitle: "Playlist", thumbnailURL: nil)
        let album = MusicPinnedItem(kind: .album, id: "MPRE1", title: "Record", subtitle: "Album", thumbnailURL: nil)
        guard case .collection(let first) = playlist.shelfItem, case .collection(let second) = album.shelfItem else {
            Issue.record("a playlist and an album open their page")
            return
        }
        #expect(first.kind == .playlist)
        #expect(first.browseId == "VLPL1")
        #expect(first.subtitle == "Playlist")
        #expect(first.thumbnailURL == nil)
        #expect(second.kind == .album)
        #expect(second.browseId == "MPRE1")
    }

    @Test("an album's tile has the artist links and album playlist id it was pinned with; an older pin has neither")
    func shelfItemAlbumExtras() {
        let pin = MusicPinnedItem(
            kind: .album, id: "MPRE1", title: "Record", subtitle: "Album",
            album: MusicPinnedAlbum(audioPlaylistId: "OLAK5uy_a", artists: [.init(name: "Ay", browseId: "UCa"), .init(name: "Bee", browseId: "UCb")])
        )
        guard case .collection(let collection) = pin.shelfItem else {
            Issue.record("an album opens its page")
            return
        }
        #expect(collection.audioPlaylistId == "OLAK5uy_a")
        #expect(collection.artistLinks == [MusicArtistLink(name: "Ay", browseId: "UCa"), MusicArtistLink(name: "Bee", browseId: "UCb")])

        let old = MusicPinnedItem(kind: .album, id: "MPRE1", title: "Record", subtitle: "Album")
        guard case .collection(let bare) = old.shelfItem else {
            Issue.record("an album opens its page")
            return
        }
        #expect(bare.audioPlaylistId == nil)
        #expect(bare.artistLinks.isEmpty)
    }

    @Test("only an album tile carries extras: a playlist or artist pin made with some draws without them")
    func shelfItemOtherKindsNoExtras() {
        let extras = MusicPinnedAlbum(audioPlaylistId: "OLAK5uy_a", artists: [.init(name: "Ay", browseId: "UCa")])
        for kind in [MusicPinnedItem.Kind.playlist, .artist] {
            let pin = MusicPinnedItem(kind: kind, id: "id1", title: "Name", album: extras)
            #expect(pin.album == nil, "kind \(kind)")
            guard case .collection(let collection) = pin.shelfItem else {
                Issue.record("a \(kind) opens its page")
                continue
            }
            #expect(collection.audioPlaylistId == nil)
            #expect(collection.artistLinks.isEmpty)
        }
    }

    @Test("a song's tile plays the song with what the row it came from knew")
    func shelfItemSong() {
        let pin = MusicPinnedItem(
            kind: .song,
            id: "vid1",
            title: "Tune",
            subtitle: "Ay, Bee",
            thumbnailURL: Self.oldPhoto,
            song: MusicPinnedSong(
                album: "Record",
                albumBrowseId: "MPRE1",
                durationSeconds: 215,
                artists: [.init(name: "Ay", browseId: "UCa"), .init(name: "Bee", browseId: "UCb")]
            )
        )
        guard case .track(let track) = pin.shelfItem else {
            Issue.record("a song plays")
            return
        }
        #expect(track.videoId == "vid1")
        #expect(track.title == "Tune")
        #expect(track.artist == "Ay, Bee")
        #expect(track.album == "Record")
        #expect(track.albumBrowseId == "MPRE1")
        #expect(track.durationSeconds == 215)
        #expect(track.thumbnailURL == URL(string: Self.oldPhoto))
        #expect(track.artistLinks.map(\.browseId) == ["UCa", "UCb"])
    }

    @Test("a song with no saved extras still plays")
    func shelfItemBareSong() {
        let pin = MusicPinnedItem(kind: .song, id: "vid1", title: "Tune")
        guard case .track(let track) = pin.shelfItem else {
            Issue.record("a song plays")
            return
        }
        #expect(track.videoId == "vid1")
        #expect(track.artist.isEmpty)
        #expect(track.album == nil)
        #expect(track.durationSeconds == nil)
        #expect(track.artistLinks.isEmpty)
    }

    @Test("a stored photo that is not a URL draws as no photo")
    func badPhotoString() {
        #expect(item("UCa", photo: "").photoURL == nil)
        #expect(item("UCa", photo: nil).photoURL == nil)
        #expect(item("UCa", photo: Self.oldPhoto).photoURL == URL(string: Self.oldPhoto))
    }

    @Test("every kind draws a Home tile as wide as the others, drawn offscreen with no photo")
    func tilesShareOneWidth() throws {
        for kind in [MusicPinnedItem.Kind.artist, .playlist, .album, .song] {
            let tile = MusicPinnedTile(item: item("id1", kind: kind, title: "Name", photo: nil)) {}
            let renderer = ImageRenderer(content: tile)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(CGFloat(image.width) == MusicStyle.Size.pinnedTileWidth)
            #expect(CGFloat(image.height) >= MusicStyle.Size.pinnedPhoto)
        }
    }

    // MARK: - From a tile

    @Test("a playlist, album or artist tile makes a pin of its own kind with its second line")
    func pinFromCollection() {
        let playlist = MusicCollection(
            browseId: "VLPL1", kind: .playlist, title: "Mix", subtitle: "Playlist \u{2022} 12 songs",
            thumbnailURL: URL(string: Self.oldPhoto)
        )
        let pin = MusicPinnedItem(collection: playlist)
        #expect(pin == MusicPinnedItem(
            kind: .playlist, id: "VLPL1", title: "Mix", subtitle: "Playlist \u{2022} 12 songs", thumbnailURL: Self.oldPhoto
        ))

        let album = MusicPinnedItem(collection: MusicSamples.collection("MPRE1", kind: .album, title: "Record", subtitle: "Album"))
        #expect(album?.kind == .album)
        #expect(album?.id == "MPRE1")
        #expect(album?.thumbnailURL == nil)

        let artist = MusicPinnedItem(collection: MusicSamples.collection("UCa", kind: .artist, title: "Ay", subtitle: "Artist"))
        #expect(artist?.kind == .artist)
        #expect(artist?.subtitle == nil)
    }

    @Test("an album tile makes a pin that keeps its artist links and album playlist id")
    func pinFromAlbumTileKeepsExtras() {
        let tile = MusicSamples.collection(
            "MPRE1", kind: .album, title: "Record", subtitle: "Album",
            artistLinks: [MusicArtistLink(name: "Ay", browseId: "UCa")], audioPlaylistId: "OLAK5uy_a"
        )
        let pin = MusicPinnedItem(collection: tile)
        #expect(pin?.album == MusicPinnedAlbum(audioPlaylistId: "OLAK5uy_a", artists: [.init(name: "Ay", browseId: "UCa")]))
        // The pin plays back as the tile it was made from.
        if let pin, case .collection(let back) = pin.shelfItem {
            #expect(back == tile)
        } else {
            Issue.record("an album pin opens its page")
        }
    }

    @Test("an album tile with neither extra makes a pin with none, equal to one made before they existed")
    func pinFromBareAlbumTile() {
        let pin = MusicPinnedItem(collection: MusicSamples.collection("MPRE1", kind: .album, title: "Record", subtitle: "Album"))
        #expect(pin?.album == nil)
        #expect(pin == MusicPinnedItem(kind: .album, id: "MPRE1", title: "Record", subtitle: "Album"))
    }

    @Test("a playlist or artist tile keeps no extras, whatever the tile held")
    func pinFromOtherTilesKeepsNoExtras() {
        for kind in [MusicCollection.Kind.playlist, .artist] {
            let tile = MusicSamples.collection(
                "id1", kind: kind, artistLinks: [MusicArtistLink(name: "Ay", browseId: "UCa")], audioPlaylistId: "OLAK5uy_a"
            )
            #expect(MusicPinnedItem(collection: tile)?.album == nil, "kind \(kind)")
        }
    }

    @Test("Liked music and a tile with no id cannot be pinned to Home")
    func noPinFromLikedOrBlank() {
        #expect(MusicPinnedItem(collection: MusicBrowseStore.likedMusic) == nil)
        #expect(MusicPinnedItem(collection: MusicSamples.collection("")) == nil)
    }

    @Test("a blank second line is dropped")
    func blankSubtitleDropped() {
        let pin = MusicPinnedItem(collection: MusicSamples.collection("VLPL1", subtitle: "  "))
        #expect(pin?.subtitle == nil)
    }

    // MARK: - From a song

    @Test("a song row makes a song pin that keeps its album, length and artist links")
    func pinFromTrack() {
        var track = MusicTrack(
            videoId: "vid1", title: "Tune", artist: "Ay, Bee", album: "Record", durationSeconds: 215,
            thumbnailURL: URL(string: Self.oldPhoto)
        )
        track.albumBrowseId = "MPRE1"
        track.artistLinks = [MusicArtistLink(name: "Ay", browseId: "UCa")]
        let pin = MusicPinnedItem(track: track)
        #expect(pin?.kind == .song)
        #expect(pin?.id == "vid1")
        #expect(pin?.title == "Tune")
        #expect(pin?.subtitle == "Ay, Bee")
        #expect(pin?.thumbnailURL == Self.oldPhoto)
        #expect(pin?.song?.album == "Record")
        #expect(pin?.song?.albumBrowseId == "MPRE1")
        #expect(pin?.song?.durationSeconds == 215)
        #expect(pin?.song?.artists == [MusicPinnedSong.Artist(name: "Ay", browseId: "UCa")])
    }

    @Test("a song with no video id cannot be pinned")
    func noPinFromBlankTrack() {
        #expect(MusicPinnedItem(track: MusicSamples.track("")) == nil)
    }

    @Test("a song pinned and played back is the song that was pinned")
    func songRoundTripsThroughShelfItem() {
        var track = MusicTrack(
            videoId: "vid1", title: "Tune", artist: "Ay", album: "Record", durationSeconds: 215,
            thumbnailURL: URL(string: Self.oldPhoto)
        )
        track.albumBrowseId = "MPRE1"
        track.artistLinks = [MusicArtistLink(name: "Ay", browseId: "UCa")]
        guard let pin = MusicPinnedItem(track: track), case .track(let played) = pin.shelfItem else {
            Issue.record("a song pin plays")
            return
        }
        #expect(played == track)
    }

    // MARK: - From a page

    private func page(
        _ id: String, title: String = "Full Name", photo: String? = oldPhoto, subtitle: String? = nil
    ) -> MusicBrowsePage {
        MusicBrowsePage(
            browseId: id, title: title, subtitle: subtitle, thumbnailURL: photo.flatMap { URL(string: $0) },
            tracks: [], continuation: nil, shelves: []
        )
    }

    @Test("an artist pin made on a page takes the title of the page and the photo of the tile that opened it")
    func pinFromArtistPageUsesOpenerPhoto() {
        let opener = MusicCollection(
            browseId: "UCa", kind: .artist, title: "Short", subtitle: "Artist", thumbnailURL: URL(string: Self.newPhoto)
        )
        let pin = MusicPinnedItem(page: page("UCa"), opener: opener)
        #expect(pin == MusicPinnedItem(kind: .artist, id: "UCa", title: "Full Name", thumbnailURL: Self.newPhoto))
    }

    @Test("an artist pin with no photo on the tile takes the photo of the page; with none anywhere, none")
    func pinFromArtistPageFallsBack() {
        let bare = MusicCollection(browseId: "UCa", kind: .artist, title: "T", subtitle: "", thumbnailURL: nil)
        #expect(MusicPinnedItem(page: page("UCa", photo: Self.oldPhoto), opener: bare)?.thumbnailURL == Self.oldPhoto)
        #expect(MusicPinnedItem(page: page("UCa", photo: nil), opener: bare)?.thumbnailURL == nil)
    }

    @Test("a playlist or album pin takes the cover of the page, else the tile's")
    func pinFromCollectionPage() {
        let opener = MusicCollection(
            browseId: "MPRE1", kind: .album, title: "Short", subtitle: "Album \u{2022} Ay", thumbnailURL: URL(string: Self.newPhoto)
        )
        let withCover = MusicPinnedItem(page: page("MPRE1", title: "Record"), opener: opener)
        #expect(withCover?.kind == .album)
        #expect(withCover?.id == "MPRE1")
        #expect(withCover?.title == "Record")
        #expect(withCover?.subtitle == "Album \u{2022} Ay")
        #expect(withCover?.thumbnailURL == Self.oldPhoto)

        let withoutCover = MusicPinnedItem(page: page("MPRE1", title: "Record", photo: nil), opener: opener)
        #expect(withoutCover?.thumbnailURL == Self.newPhoto)

        let list = MusicSamples.collection("VLPL1", kind: .playlist, subtitle: "")
        let fromPlaylist = MusicPinnedItem(page: page("VLPL1", title: "Mix", subtitle: "Playlist \u{2022} 9 songs"), opener: list)
        #expect(fromPlaylist?.kind == .playlist)
        #expect(fromPlaylist?.subtitle == "Playlist \u{2022} 9 songs")
    }

    @Test("an album pin made on a page keeps the extras of the tile that opened it")
    func pinFromAlbumPageKeepsOpenerExtras() {
        let opener = MusicSamples.collection(
            "MPRE1", kind: .album, title: "Short", subtitle: "Album",
            artistLinks: [MusicArtistLink(name: "Ay", browseId: "UCa")], audioPlaylistId: "OLAK5uy_a"
        )
        let pin = MusicPinnedItem(page: page("MPRE1", title: "Record"), opener: opener)
        #expect(pin?.album == MusicPinnedAlbum(audioPlaylistId: "OLAK5uy_a", artists: [.init(name: "Ay", browseId: "UCa")]))

        let bare = MusicPinnedItem(page: page("MPRE1", title: "Record"), opener: MusicSamples.collection("MPRE1", kind: .album))
        #expect(bare?.album == nil)
        let playlist = MusicSamples.collection("VLPL1", artistLinks: [MusicArtistLink(name: "Ay", browseId: "UCa")])
        #expect(MusicPinnedItem(page: page("VLPL1", title: "Mix"), opener: playlist)?.album == nil)
    }

    @Test("a refreshed title and photo leave the album extras as they were")
    func refreshKeepsAlbumExtras() {
        let extras = MusicPinnedAlbum(audioPlaylistId: "OLAK5uy_a", artists: [.init(name: "Ay", browseId: "UCa")])
        let (pins, _) = make([MusicPinnedItem(kind: .album, id: "MPRE1", title: "Old", album: extras)])
        pins.refresh(MusicPinnedItem(kind: .album, id: "MPRE1", title: "New"))
        #expect(pins.items.first?.title == "New")
        #expect(pins.items.first?.album == extras)
    }

    @Test("a page with a blank title keeps the title of the tile that opened it")
    func pinFromPageBlankTitle() {
        let opener = MusicSamples.collection("VLPL1", title: "Tile title")
        #expect(MusicPinnedItem(page: page("VLPL1", title: ""), opener: opener)?.title == "Tile title")
    }

    @Test("the Liked music page cannot be pinned to Home")
    func noPinFromLikedPage() {
        #expect(MusicPinnedItem(page: page("VLLM", title: "Liked music"), opener: MusicBrowseStore.likedMusic) == nil)
        #expect(MusicPinnedItem(page: page(""), opener: MusicSamples.collection("VLPL1")) == nil)
    }
}
