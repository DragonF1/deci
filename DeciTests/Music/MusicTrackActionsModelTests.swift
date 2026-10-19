// DeciTests/Music/MusicTrackActionsModelTests.swift
// Which song actions a row offers, and in what order: the pure rules behind the row's "..." button and its
// context menu, without any view. Save to playlist, Remove from playlist, Pin to / Unpin from Listen again, Go to album.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicTrackActions availability")
struct MusicTrackActionsModelTests {
    private let ownPlaylist = MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true)

    private func actions(_ track: Deci.MusicTrack, in context: MusicTrackContext = .none) -> [MusicTrackAction] {
        MusicTrackActions.available(for: track, in: context)
    }

    // MARK: - Save to playlist

    @Test("A bare song with no page around it can still be saved to a playlist, and nothing else")
    func bareSongOnlySaves() {
        #expect(actions(MusicSamples.track()) == [.saveToPlaylist])
    }

    // MARK: - Order

    @Test("Every action shows in the fixed order: save, remove, pin, go to album")
    func fullSetInOrder() {
        let track = MusicSamples.track("v1", albumBrowseId: "MPREbFixture", setVideoId: "set1", pin: MusicSamples.pinToggle())
        #expect(actions(track, in: ownPlaylist) == [.saveToPlaylist, .removeFromPlaylist, .pinToListenAgain, .goToAlbum])
    }

    @Test("A pinned song offers Unpin instead of Pin, in the same place")
    func pinnedOffersUnpin() {
        let track = MusicSamples.track("v1", albumBrowseId: "MPREbFixture", setVideoId: "set1", pin: MusicSamples.pinToggle(isPinned: true))
        #expect(actions(track, in: ownPlaylist) == [.saveToPlaylist, .removeFromPlaylist, .unpinFromListenAgain, .goToAlbum])
    }

    // MARK: - Remove from playlist

    @Test("Remove shows only on a page the user can edit")
    func removeNeedsEditablePage() {
        let track = MusicSamples.track("v1", setVideoId: "set1")
        let readOnly = MusicTrackContext(pageBrowseId: "VLPLfixtureTheirs", pageTitle: "Theirs", pageIsEditable: false)
        #expect(actions(track, in: readOnly) == [.saveToPlaylist])
        #expect(actions(track, in: ownPlaylist).contains(.removeFromPlaylist))
    }

    @Test("Remove needs the row's own place in the playlist")
    func removeNeedsSetVideoId() {
        #expect(actions(MusicSamples.track("v1"), in: ownPlaylist) == [.saveToPlaylist])
    }

    @Test("Remove never shows on Liked Music, in either spelling of its id, even when the page claims to be editable")
    func removeNeverOnLikedMusic() {
        let track = MusicSamples.track("v1", setVideoId: "set1")
        for id in ["VLLM", "LM"] {
            let liked = MusicTrackContext(pageBrowseId: id, pageTitle: "Liked music", pageIsEditable: true)
            #expect(actions(track, in: liked) == [.saveToPlaylist], "page \(id)")
        }
    }

    @Test("Remove never shows on an album or an artist page")
    func removeNeverOnAlbumOrArtist() {
        let track = MusicSamples.track("v1", setVideoId: "set1")
        for id in ["MPREbFixture", "UCfixtureArtist"] {
            let page = MusicTrackContext(pageBrowseId: id, pageTitle: "Not a playlist", pageIsEditable: true)
            #expect(!actions(track, in: page).contains(.removeFromPlaylist), "page \(id)")
        }
    }

    @Test("Remove does not show with no page, as in search results, Up next and the mini player")
    func removeNeedsAPage() {
        let track = MusicSamples.track("v1", setVideoId: "set1")
        #expect(actions(track, in: .none) == [.saveToPlaylist])
        let unnamed = MusicTrackContext(pageBrowseId: nil, pageTitle: nil, pageIsEditable: true)
        #expect(actions(track, in: unnamed) == [.saveToPlaylist])
    }

    // MARK: - Pin to Listen again

    @Test("Pin shows only when YouTube offered the toggle for the row")
    func pinNeedsToggle() {
        #expect(!actions(MusicSamples.track("v1")).contains(.pinToListenAgain))
        #expect(actions(MusicSamples.track("v1", pin: MusicSamples.pinToggle())).contains(.pinToListenAgain))
    }

    @Test("A toggle with no token for its next move offers nothing")
    func pinNeedsNextToken() {
        let noPinToken = MusicSamples.pinToggle(isPinned: false, pin: nil, unpin: "unpin-token")
        let noUnpinToken = MusicSamples.pinToggle(isPinned: true, pin: "pin-token", unpin: nil)
        #expect(actions(MusicSamples.track("v1", pin: noPinToken)) == [.saveToPlaylist])
        #expect(actions(MusicSamples.track("v1", pin: noUnpinToken)) == [.saveToPlaylist])
    }

    // MARK: - Go to album

    @Test("Go to album needs the album's page id")
    func albumNeedsId() {
        #expect(!actions(MusicSamples.track("v1")).contains(.goToAlbum))
        #expect(!actions(MusicSamples.track("v1", albumBrowseId: "")).contains(.goToAlbum))
        #expect(actions(MusicSamples.track("v1", albumBrowseId: "MPREbFixture")).contains(.goToAlbum))
    }

    @Test("Go to album hides on that album's own page and shows on any other page")
    func albumHidesOnItsOwnPage() {
        let track = MusicSamples.track("v1", albumBrowseId: "MPREbFixture")
        let own = MusicTrackContext(pageBrowseId: "MPREbFixture", pageTitle: "Fixture Album", pageIsEditable: false)
        let other = MusicTrackContext(pageBrowseId: "MPREbOther", pageTitle: "Other Album", pageIsEditable: false)
        #expect(!actions(track, in: own).contains(.goToAlbum))
        #expect(actions(track, in: other).contains(.goToAlbum))
        #expect(actions(track, in: ownPlaylist).contains(.goToAlbum))
    }

    @Test("The album a song opens carries its id, its name when the row has one, and no cover")
    func albumCollection() {
        var track = MusicSamples.track("v1", albumBrowseId: "MPREbFixture")
        #expect(MusicTrackActions.albumCollection(for: track)
            == MusicCollection(browseId: "MPREbFixture", kind: .album, title: "Album", subtitle: "", thumbnailURL: nil))
        track = Deci.MusicTrack(videoId: "v1", title: "T", artist: "A", album: "Fixture Album", durationSeconds: nil, thumbnailURL: nil, albumBrowseId: "MPREbFixture")
        #expect(MusicTrackActions.albumCollection(for: track)?.title == "Fixture Album")
        #expect(MusicTrackActions.albumCollection(for: MusicSamples.track("v1")) == nil)
        #expect(MusicTrackActions.albumCollection(for: MusicSamples.track("v1", albumBrowseId: "")) == nil)
    }

    // MARK: - Words

    @Test("The menu words are the ones the owner asked for")
    func titles() {
        #expect(MusicTrackAction.saveToPlaylist.title == "Save to playlist...")
        #expect(MusicTrackAction.removeFromPlaylist.title == "Remove from playlist")
        #expect(MusicTrackAction.pinToListenAgain.title == "Pin to Listen again")
        #expect(MusicTrackAction.unpinFromListenAgain.title == "Unpin from Listen again")
        #expect(MusicTrackAction.goToAlbum.title == "Go to album")
    }

    @Test("No menu word has a dash and every action has an icon")
    func noDashesAndIcons() {
        let all: [MusicTrackAction] = [.saveToPlaylist, .removeFromPlaylist, .pinToListenAgain, .unpinFromListenAgain, .goToAlbum]
        for action in all {
            #expect(!action.title.contains("\u{2014}") && !action.title.contains("\u{2013}"))
            #expect(!action.systemImage.isEmpty)
        }
    }

    // MARK: - Toggle

    @Test("A toggle's next token is the one for the other state, and flipping it faces it the other way")
    func toggleNextToken() {
        let off = MusicSamples.pinToggle(isPinned: false)
        #expect(off.nextToken == "pin-token")
        #expect(off.flipped().isPinned)
        #expect(off.flipped().nextToken == "unpin-token")
        #expect(off.flipped().flipped() == off)
    }
}
