// DeciTests/Music/MusicTrackActionsModelTests.swift
// Which song actions a row offers, and in what order: the pure rules behind the row's "..." button and its
// context menu, without any view. Save to playlist, Pin to / Unpin from Listen again, Go to album, Go to artist and
// Remove from playlist, and the blocks the menu cuts them into.

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

    @Test("Every action shows in the fixed order: save, pin, go to album, go to artist, remove last")
    func fullSetInOrder() {
        let track = fullTrack()
        #expect(actions(track, in: ownPlaylist) == [.saveToPlaylist, .pinToListenAgain, .goToAlbum, .goToArtist, .removeFromPlaylist])
    }

    @Test("A pinned song offers Unpin instead of Pin, in the same place")
    func pinnedOffersUnpin() {
        var track = fullTrack()
        track.listenAgainPin = MusicSamples.pinToggle(isPinned: true)
        #expect(actions(track, in: ownPlaylist) == [.saveToPlaylist, .unpinFromListenAgain, .goToAlbum, .goToArtist, .removeFromPlaylist])
    }

    /// A song with every extra: an album page, an artist page, a pin toggle and its own place in a playlist.
    private func fullTrack() -> Deci.MusicTrack {
        var track = MusicSamples.track("v1", albumBrowseId: "MPREbFixture", setVideoId: "set1", pin: MusicSamples.pinToggle())
        track.artistLinks = [MusicArtistLink(name: "Fixture Artist", browseId: "UCfixtureArtist")]
        return track
    }

    // MARK: - Blocks

    @Test("The menu has three blocks: library, go to, and remove, with no empty block between them")
    func blocks() {
        #expect(MusicTrackActions.groups(of: actions(fullTrack(), in: ownPlaylist))
            == [[.saveToPlaylist, .pinToListenAgain], [.goToAlbum, .goToArtist], [.removeFromPlaylist]])
        #expect(MusicTrackActions.groups(of: [.saveToPlaylist]) == [[.saveToPlaylist]])
        #expect(MusicTrackActions.groups(of: [.saveToPlaylist, .goToAlbum]) == [[.saveToPlaylist], [.goToAlbum]])
        #expect(MusicTrackActions.groups(of: [.saveToPlaylist, .removeFromPlaylist]) == [[.saveToPlaylist], [.removeFromPlaylist]])
    }

    @Test("A bare song has one block, so the menu draws no line")
    func bareSongOneBlock() {
        #expect(MusicTrackActions.groups(of: actions(MusicSamples.track())) == [[.saveToPlaylist]])
        #expect(MusicTrackActions.groups(of: []).isEmpty)
    }

    @Test("Every action belongs to the block the menu draws it in")
    func groupOfEachAction() {
        #expect(MusicTrackAction.saveToPlaylist.group == .library)
        #expect(MusicTrackAction.pinToListenAgain.group == .library)
        #expect(MusicTrackAction.unpinFromListenAgain.group == .library)
        #expect(MusicTrackAction.goToAlbum.group == .navigate)
        #expect(MusicTrackAction.goToArtist.group == .navigate)
        #expect(MusicTrackAction.removeFromPlaylist.group == .remove)
        #expect(MusicTrackAction.Group.library < .navigate && MusicTrackAction.Group.navigate < .remove)
    }

    // MARK: - Go to artist

    @Test("Go to artist needs a credited artist with a page")
    func artistNeedsLink() {
        #expect(!actions(MusicSamples.track("v1")).contains(.goToArtist))
        var track = MusicSamples.track("v1")
        track.artistLinks = [MusicArtistLink(name: "Nobody", browseId: "")]
        #expect(!actions(track).contains(.goToArtist))
        track.artistLinks = [MusicArtistLink(name: "Fixture Artist", browseId: "UCfixtureArtist")]
        #expect(actions(track).contains(.goToArtist))
    }

    @Test("Go to artist opens the first credited artist, and hides on that artist's own page")
    func artistFirstLinkAndOwnPage() {
        var track = MusicSamples.track("v1")
        track.artistLinks = [
            MusicArtistLink(name: "First", browseId: "UCfirst"),
            MusicArtistLink(name: "Second", browseId: "UCsecond"),
        ]
        #expect(MusicTrackActions.artistCollection(for: track, in: .none)
            == MusicCollection(browseId: "UCfirst", kind: .artist, title: "First", subtitle: "", thumbnailURL: nil))
        let own = MusicTrackContext(pageBrowseId: "UCfirst", pageTitle: "First", pageIsEditable: false)
        let other = MusicTrackContext(pageBrowseId: "UCsecond", pageTitle: "Second", pageIsEditable: false)
        #expect(!actions(track, in: own).contains(.goToArtist))
        #expect(actions(track, in: other).contains(.goToArtist))
        #expect(MusicTrackActions.artistCollection(for: MusicSamples.track("v1"), in: .none) == nil)
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
        #expect(MusicTrackAction.saveToPlaylist.title == "Save to playlist")
        #expect(MusicTrackAction.removeFromPlaylist.title == "Remove from playlist")
        #expect(MusicTrackAction.pinToListenAgain.title == "Pin to Listen again")
        #expect(MusicTrackAction.unpinFromListenAgain.title == "Unpin from Listen again")
        #expect(MusicTrackAction.goToAlbum.title == "Go to album")
        #expect(MusicTrackAction.goToArtist.title == "Go to artist")
    }

    @Test("No menu word has a dash or an ellipsis, since the menu is text only")
    func noDashesOrEllipses() {
        let all: [MusicTrackAction] = [
            .saveToPlaylist, .removeFromPlaylist, .pinToListenAgain, .unpinFromListenAgain, .goToAlbum, .goToArtist,
        ]
        for action in all {
            #expect(!action.title.contains("\u{2014}") && !action.title.contains("\u{2013}"))
            #expect(!action.title.contains("...") && !action.title.contains("\u{2026}"))
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
