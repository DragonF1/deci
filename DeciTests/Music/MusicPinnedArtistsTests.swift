// DeciTests/Music/MusicPinnedArtistsTests.swift
// The "Pinned artists" row on Music Home: pin order, repeats, the cap of 20, refreshed names and photos,
// what gets saved, the tile each pin draws and the Pin to Home button's words.

import Foundation
import Testing
@testable import Deci

@MainActor
private final class PinSink {
    var saved: [[MusicPinnedArtist]] = []
}

@MainActor
@Suite("MusicPinnedArtists")
struct MusicPinnedArtistsTests {
    private static let oldPhoto = "https://img.example.test/old.jpg"
    private static let newPhoto = "https://img.example.test/new.jpg"

    private func artist(_ id: String, title: String? = nil, photo: String? = oldPhoto) -> MusicPinnedArtist {
        MusicPinnedArtist(browseId: id, title: title ?? "Artist \(id)", thumbnailURL: photo)
    }

    private func make(_ initial: [MusicPinnedArtist] = []) -> (pins: MusicPinnedArtists, sink: PinSink) {
        let sink = PinSink()
        return (MusicPinnedArtists(artists: initial, save: { sink.saved.append($0) }), sink)
    }

    private func ids(_ pins: MusicPinnedArtists) -> [String] { pins.artists.map(\.browseId) }

    private func full() -> [MusicPinnedArtist] {
        (1...MusicPinnedArtists.limit).map { artist("UC\($0)") }
    }

    // MARK: - Pinning

    @Test("nothing is pinned to begin with")
    func startsEmpty() {
        let (pins, sink) = make()
        #expect(pins.artists.isEmpty)
        #expect(!pins.isFull)
        #expect(sink.saved.isEmpty)
    }

    @Test("pinning appends, oldest first")
    func pinAppends() {
        let (pins, sink) = make()
        #expect(pins.pin(artist("UCa")))
        #expect(pins.pin(artist("UCb")))
        #expect(pins.pin(artist("UCc")))
        #expect(ids(pins) == ["UCa", "UCb", "UCc"])
        #expect(sink.saved.map { $0.map(\.browseId) } == [["UCa"], ["UCa", "UCb"], ["UCa", "UCb", "UCc"]])
    }

    @Test("pinning the same artist again changes nothing and saves nothing")
    func repeatPinIsNoOp() {
        let (pins, sink) = make()
        pins.pin(artist("UCa", title: "First name"))
        pins.pin(artist("UCb"))
        #expect(!pins.pin(artist("UCa", title: "Other name", photo: Self.newPhoto)))
        #expect(ids(pins) == ["UCa", "UCb"])
        #expect(pins.artists[0].title == "First name")
        #expect(pins.artists[0].thumbnailURL == Self.oldPhoto)
        #expect(sink.saved.count == 2)
    }

    @Test("isPinned goes by the browse id")
    func isPinned() {
        let (pins, _) = make([artist("UCa")])
        #expect(pins.isPinned("UCa"))
        #expect(!pins.isPinned("UCb"))
        #expect(!pins.isPinned(""))
    }

    @Test("unpinning removes the artist and keeps the order of the rest")
    func unpinRemoves() {
        let (pins, sink) = make([artist("UCa"), artist("UCb"), artist("UCc")])
        #expect(pins.unpin("UCb"))
        #expect(ids(pins) == ["UCa", "UCc"])
        #expect(!pins.isPinned("UCb"))
        #expect(sink.saved.map { $0.map(\.browseId) } == [["UCa", "UCc"]])
    }

    @Test("unpinning an artist that is not pinned changes nothing and saves nothing")
    func unpinUnknownIsNoOp() {
        let (pins, sink) = make([artist("UCa")])
        #expect(!pins.unpin("UCz"))
        #expect(ids(pins) == ["UCa"])
        #expect(sink.saved.isEmpty)
    }

    @Test("an artist pinned again after an unpin goes to the end")
    func repinGoesLast() {
        let (pins, _) = make([artist("UCa"), artist("UCb")])
        pins.unpin("UCa")
        pins.pin(artist("UCa"))
        #expect(ids(pins) == ["UCb", "UCa"])
    }

    @Test("toggle pins an artist that is not pinned and unpins one that is")
    func toggle() {
        let (pins, sink) = make()
        pins.toggle(artist("UCa"))
        #expect(ids(pins) == ["UCa"])
        pins.toggle(artist("UCa"))
        #expect(pins.artists.isEmpty)
        #expect(sink.saved.count == 2)
    }

    // MARK: - The cap

    @Test("the cap is 20")
    func capValue() {
        #expect(MusicPinnedArtists.limit == 20)
    }

    @Test("the 21st pin is refused")
    func capRefusesTheNext() {
        let (pins, sink) = make(full())
        #expect(pins.isFull)
        #expect(!pins.pin(artist("UCextra")))
        #expect(pins.artists.count == 20)
        #expect(!pins.isPinned("UCextra"))
        #expect(sink.saved.isEmpty)
    }

    @Test("the 20th pin goes in, and a freed place can be filled again")
    func capBoundary() {
        let (pins, _) = make(Array(full().dropLast()))
        #expect(!pins.isFull)
        #expect(pins.pin(artist("UC20x")))
        #expect(pins.isFull)
        pins.unpin("UC1")
        #expect(!pins.isFull)
        #expect(pins.pin(artist("UC21x")))
        #expect(pins.artists.count == 20)
        #expect(pins.artists.last?.browseId == "UC21x")
    }

    @Test("canToggle: a pinned artist can always be unpinned, a new one only while there is room")
    func canToggle() {
        let (open, _) = make([artist("UCa")])
        #expect(open.canToggle("UCa"))
        #expect(open.canToggle("UCb"))

        let (closed, _) = make(full())
        #expect(closed.canToggle("UC1"))
        #expect(!closed.canToggle("UCextra"))
    }

    @Test("toggle on a full list unpins a pinned artist and refuses a new one")
    func toggleWhenFull() {
        let (pins, _) = make(full())
        pins.toggle(artist("UCextra"))
        #expect(pins.artists.count == 20)
        #expect(!pins.isPinned("UCextra"))
        pins.toggle(artist("UC3"))
        #expect(pins.artists.count == 19)
        #expect(!pins.isPinned("UC3"))
    }

    // MARK: - Loading a saved list

    @Test("a saved list is kept as it is, in order, without saving it again")
    func loadKeepsOrder() {
        let (pins, sink) = make([artist("UCb"), artist("UCa")])
        #expect(ids(pins) == ["UCb", "UCa"])
        #expect(sink.saved.isEmpty)
    }

    @Test("a saved list with repeats, blank ids or too many entries is tidied on load")
    func loadTidies() {
        let messy = [artist("UCa", title: "Kept"), artist(""), artist("UCa", title: "Repeat"), artist("UCb")] +
            (1...30).map { artist("UCx\($0)") }
        let (pins, sink) = make(messy)
        #expect(pins.artists.count == 20)
        #expect(Array(ids(pins).prefix(3)) == ["UCa", "UCb", "UCx1"])
        #expect(pins.artists[0].title == "Kept")
        #expect(Set(ids(pins)).count == 20)
        #expect(!pins.isPinned(""))
        #expect(sink.saved.isEmpty)
    }

    // MARK: - Refreshing

    @Test("refresh updates the stored title, keeps the stored photo and keeps the place in the row")
    func refreshUpdates() {
        let (pins, sink) = make([artist("UCa"), artist("UCb", title: "Old name"), artist("UCc")])
        #expect(pins.refresh(artist("UCb", title: "New name", photo: Self.newPhoto)))
        #expect(ids(pins) == ["UCa", "UCb", "UCc"])
        #expect(pins.artists[1].title == "New name")
        #expect(pins.artists[1].thumbnailURL == Self.oldPhoto)
        #expect(sink.saved.count == 1)
        #expect(sink.saved[0][1].title == "New name")
    }

    @Test("a different photo alone never replaces the stored one, so nothing is saved")
    func refreshOtherPhotoKeepsStored() {
        let (pins, sink) = make([artist("UCa")])
        #expect(!pins.refresh(artist("UCa", photo: Self.newPhoto)))
        #expect(pins.artists[0].thumbnailURL == Self.oldPhoto)
        #expect(sink.saved.isEmpty)
    }

    @Test("a blank stored photo counts as none and is filled in")
    func refreshFillsBlankPhoto() {
        let (pins, _) = make([artist("UCa", photo: "")])
        #expect(pins.refresh(artist("UCa", photo: Self.newPhoto)))
        #expect(pins.artists[0].thumbnailURL == Self.newPhoto)
    }

    @Test("refresh with the same title and photo changes nothing and saves nothing")
    func refreshUnchanged() {
        let (pins, sink) = make([artist("UCa")])
        #expect(!pins.refresh(artist("UCa")))
        #expect(sink.saved.isEmpty)
    }

    @Test("a missing photo never wipes the stored one")
    func refreshNilPhotoKeepsStored() {
        let (pins, sink) = make([artist("UCa", title: "Old name")])
        #expect(pins.refresh(artist("UCa", title: "New name", photo: nil)))
        #expect(pins.artists[0].title == "New name")
        #expect(pins.artists[0].thumbnailURL == Self.oldPhoto)
        #expect(sink.saved.count == 1)

        #expect(!pins.refresh(artist("UCa", title: "New name", photo: nil)))
        #expect(sink.saved.count == 1)
    }

    @Test("a photo fills in for a pin that had none")
    func refreshFillsMissingPhoto() {
        let (pins, _) = make([artist("UCa", photo: nil)])
        #expect(pins.refresh(artist("UCa", photo: Self.newPhoto)))
        #expect(pins.artists[0].thumbnailURL == Self.newPhoto)
    }

    @Test("a blank title never replaces the stored one")
    func refreshBlankTitleKeepsStored() {
        let (pins, sink) = make([artist("UCa", title: "Name")])
        #expect(!pins.refresh(artist("UCa", title: "", photo: Self.oldPhoto)))
        #expect(pins.artists[0].title == "Name")
        #expect(sink.saved.isEmpty)
    }

    @Test("refreshing an artist that is not pinned does nothing and pins nothing")
    func refreshUnpinnedIsNoOp() {
        let (pins, sink) = make([artist("UCa")])
        #expect(!pins.refresh(artist("UCz", title: "Stranger", photo: Self.newPhoto)))
        #expect(ids(pins) == ["UCa"])
        #expect(sink.saved.isEmpty)
    }

    // MARK: - Settings reset

    @Test("a settings reset drops every pin without saving, and the next pin saves only itself")
    func settingsReset() {
        let (pins, sink) = make([artist("UCa"), artist("UCb")])
        pins.settingsDidReset()
        #expect(pins.artists.isEmpty)
        #expect(pins.shelf == nil)
        #expect(sink.saved.isEmpty)

        #expect(pins.pin(artist("UCc")))
        #expect(sink.saved.map { $0.map(\.browseId) } == [["UCc"]])
    }

    // MARK: - Tiles

    @Test("there is no shelf while nothing is pinned")
    func noShelfWhenEmpty() {
        let (pins, _) = make()
        #expect(pins.shelf == nil)
    }

    @Test("the shelf is titled Pinned artists and holds round artist tiles in pin order")
    func shelfShape() {
        let (pins, _) = make([artist("UCb", title: "Bee"), artist("UCa", title: "Ay", photo: nil)])
        let shelf = pins.shelf
        #expect(shelf?.title == "Pinned artists")
        let collections = shelf?.items.compactMap { item -> MusicCollection? in
            if case .collection(let collection) = item { collection } else { nil }
        }
        #expect(collections?.map(\.browseId) == ["UCb", "UCa"])
        #expect(collections?.map(\.title) == ["Bee", "Ay"])
        #expect(collections?.allSatisfy { $0.kind == .artist } == true)
        #expect(collections?.first?.thumbnailURL == URL(string: Self.oldPhoto))
        #expect(collections?.last?.thumbnailURL == nil)
        #expect(shelf?.items.count == 2)
    }

    @Test("the shelf follows a pin and an unpin")
    func shelfFollowsChanges() {
        let (pins, _) = make()
        pins.pin(artist("UCa"))
        #expect(pins.shelf?.items.count == 1)
        pins.unpin("UCa")
        #expect(pins.shelf == nil)
    }

    @Test("a stored photo that is not a URL draws as no photo")
    func badPhotoString() {
        #expect(artist("UCa", photo: "").collection.thumbnailURL == nil)
        #expect(artist("UCa", photo: nil).collection.thumbnailURL == nil)
        #expect(artist("UCa", photo: Self.oldPhoto).collection.thumbnailURL == URL(string: Self.oldPhoto))
    }

    // MARK: - From a page

    @Test("a pin made on a page takes the title of the page and the photo of the tile that opened it")
    func pinFromPageUsesOpenerPhoto() {
        let opener = MusicCollection(
            browseId: "UCa", kind: .artist, title: "Short", subtitle: "Artist", thumbnailURL: URL(string: Self.newPhoto)
        )
        let page = MusicBrowsePage(
            browseId: "UCa", title: "Full Name", subtitle: nil, thumbnailURL: URL(string: Self.oldPhoto),
            tracks: [], continuation: nil, shelves: []
        )
        let pin = MusicPinnedArtist(page: page, opener: opener)
        #expect(pin == MusicPinnedArtist(browseId: "UCa", title: "Full Name", thumbnailURL: Self.newPhoto))
    }

    @Test("with no photo on the tile, a pin takes the photo of the page; with none anywhere, none")
    func pinFromPageFallsBack() {
        let bare = MusicCollection(browseId: "UCa", kind: .artist, title: "T", subtitle: "", thumbnailURL: nil)
        let withPhoto = MusicBrowsePage(
            browseId: "UCa", title: "T", subtitle: nil, thumbnailURL: URL(string: Self.oldPhoto),
            tracks: [], continuation: nil, shelves: []
        )
        let withoutPhoto = MusicBrowsePage(
            browseId: "UCa", title: "T", subtitle: nil, thumbnailURL: nil, tracks: [], continuation: nil, shelves: []
        )
        #expect(MusicPinnedArtist(page: withPhoto, opener: bare).thumbnailURL == Self.oldPhoto)
        #expect(MusicPinnedArtist(page: withPhoto, opener: nil).thumbnailURL == Self.oldPhoto)
        #expect(MusicPinnedArtist(page: withoutPhoto, opener: bare).thumbnailURL == nil)
        #expect(MusicPinnedArtist(page: withoutPhoto, opener: nil).thumbnailURL == nil)
    }

    // MARK: - The button's words

    @Test("the page button reads Pin to Home, and Unpin from Home with a filled pin once pinned")
    func buttonWords() {
        #expect(MusicPageHeader.pinLabel(isPinned: false) == "Pin to Home")
        #expect(MusicPageHeader.pinLabel(isPinned: true) == "Unpin from Home")
        #expect(MusicPageHeader.pinSymbol(isPinned: false) == "pin")
        #expect(MusicPageHeader.pinSymbol(isPinned: true) == "pin.fill")
    }

    @Test("a full Home says so in the button's help text; otherwise the help says what the button does")
    func buttonHelp() {
        let full = MusicPageHeader.pinHelp(isPinned: false, isEnabled: false)
        #expect(full.contains("20"))
        #expect(full != MusicPageHeader.pinHelp(isPinned: false, isEnabled: true))
        #expect(MusicPageHeader.pinHelp(isPinned: true, isEnabled: true) != MusicPageHeader.pinHelp(isPinned: false, isEnabled: true))
        #expect(!MusicPageHeader.pinHelp(isPinned: true, isEnabled: true).contains("20"))
    }
}
