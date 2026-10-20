// DeciTests/Music/MusicTrackActionsModelTests.swift
// Which song actions a row offers, and in what order: the pure rules behind the row's "..." button and its
// context menu, without any view. Save to playlist, Pin to / Unpin from Home, Go to album, Go to artist and Remove
// from playlist, and the blocks the menu cuts them into.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicTrackActions availability")
struct MusicTrackActionsModelTests {
    private let ownPlaylist = MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true)

    private func actions(
        _ track: Deci.MusicTrack, in context: MusicTrackContext = .none, home: MusicHomePinState? = nil, queue: Bool = false
    ) -> [MusicTrackAction] {
        MusicTrackActions.available(for: track, in: context, home: home, offersQueue: queue)
    }

    // MARK: - Save to playlist

    @Test("A bare song with no page around it can still be saved to a playlist, and nothing else")
    func bareSongOnlySaves() {
        #expect(actions(MusicSamples.track()) == [.saveToPlaylist])
    }

    // MARK: - Order

    @Test("Every action shows in the fixed order: save, go to album, go to artist, remove last")
    func fullSetInOrder() {
        let track = fullTrack()
        #expect(actions(track, in: ownPlaylist) == [.saveToPlaylist, .goToAlbum, .goToArtist, .removeFromPlaylist])
    }

    @Test("Pin to Home sits right after save, ahead of go to album, go to artist and remove")
    func homeEntryInOrder() {
        let track = fullTrack()
        #expect(
            actions(track, in: ownPlaylist, home: .canPin)
                == [.saveToPlaylist, .pinHome(.canPin), .goToAlbum, .goToArtist, .removeFromPlaylist]
        )
        #expect(
            actions(MusicSamples.track("v1"), home: .pinned) == [.saveToPlaylist, .pinHome(.pinned)]
        )
        #expect(actions(MusicSamples.track("v1"), home: .canPin) == [.saveToPlaylist, .pinHome(.canPin)])
    }

    @Test("With no Home state the entry is left out, which is how every list stood before")
    func homeEntryLeftOutByDefault() {
        #expect(!actions(fullTrack(), in: ownPlaylist).contains { if case .pinHome = $0 { true } else { false } })
    }

    @Test("Pin to Home stays in the library block, with save")
    func homeEntryGroup() {
        #expect(MusicTrackAction.pinHome(.canPin).group == .library)
        #expect(MusicTrackAction.pinHome(.pinned).group == .library)
        #expect(MusicTrackAction.pinHome(.full).group == .library)
        #expect(MusicTrackActions.groups(of: actions(fullTrack(), in: ownPlaylist, home: .canPin))
            == [[.saveToPlaylist, .pinHome(.canPin)], [.goToAlbum, .goToArtist], [.removeFromPlaylist]])
    }

    @Test("Only the refusal while Home is full is turned off; every other action is on")
    func enabledState() {
        #expect(MusicTrackAction.pinHome(.canPin).isEnabled)
        #expect(MusicTrackAction.pinHome(.pinned).isEnabled)
        #expect(!MusicTrackAction.pinHome(.full).isEnabled)
        for action in [MusicTrackAction.saveToPlaylist, .removeFromPlaylist, .goToAlbum, .goToArtist, .playNext, .addToQueue, .removeFromQueue] {
            #expect(action.isEnabled)
        }
    }

    /// A song with every extra: an album page, an artist page and its own place in a playlist.
    private func fullTrack() -> Deci.MusicTrack {
        var track = MusicSamples.track("v1", albumBrowseId: "MPREbFixture", setVideoId: "set1")
        track.artistLinks = [MusicArtistLink(name: "Fixture Artist", browseId: "UCfixtureArtist")]
        return track
    }

    // MARK: - Blocks

    @Test("The menu has three blocks: library, go to, and remove, with no empty block between them")
    func blocks() {
        #expect(MusicTrackActions.groups(of: actions(fullTrack(), in: ownPlaylist))
            == [[.saveToPlaylist], [.goToAlbum, .goToArtist], [.removeFromPlaylist]])
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
        #expect(MusicTrackAction.playNext.group == .queue)
        #expect(MusicTrackAction.addToQueue.group == .queue)
        #expect(MusicTrackAction.removeFromQueue.group == .remove)
        #expect(MusicTrackAction.Group.queue < .library)
        #expect(MusicTrackAction.saveToPlaylist.group == .library)
        #expect(MusicTrackAction.goToAlbum.group == .navigate)
        #expect(MusicTrackAction.goToArtist.group == .navigate)
        #expect(MusicTrackAction.removeFromPlaylist.group == .remove)
        #expect(MusicTrackAction.Group.library < .navigate && MusicTrackAction.Group.navigate < .remove)
    }

    // MARK: - Play next, Add to queue, Remove from queue

    @Test("Play next and Add to queue are left out unless the caller offers the queue, which is how every list stood before")
    func queueEntriesAreOptIn() {
        #expect(actions(fullTrack(), in: ownPlaylist).allSatisfy { $0 != .playNext && $0 != .addToQueue })
        #expect(actions(fullTrack(), in: .upNext).allSatisfy { $0 != .removeFromQueue })
    }

    @Test("Play next and Add to queue come first, in a block of their own, ahead of save")
    func queueEntriesFirst() {
        #expect(actions(MusicSamples.track("v1"), queue: true) == [.playNext, .addToQueue, .saveToPlaylist])
        #expect(
            actions(fullTrack(), in: ownPlaylist, home: .canPin, queue: true)
                == [.playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin), .goToAlbum, .goToArtist, .removeFromPlaylist]
        )
        #expect(MusicTrackActions.groups(of: actions(fullTrack(), in: ownPlaylist, home: .canPin, queue: true))
            == [[.playNext, .addToQueue], [.saveToPlaylist, .pinHome(.canPin)], [.goToAlbum, .goToArtist], [.removeFromPlaylist]])
    }

    @Test("Remove from queue shows on an Up next row only, as the last and destructive block")
    func removeFromQueueOnlyInUpNext() {
        let track = MusicSamples.track("v1")
        #expect(!actions(track, in: .none, queue: true).contains(.removeFromQueue))
        #expect(actions(track, in: .upNext, queue: true) == [.playNext, .addToQueue, .saveToPlaylist, .removeFromQueue])
        #expect(MusicTrackActions.groups(of: actions(track, in: .upNext, queue: true))
            == [[.playNext, .addToQueue], [.saveToPlaylist], [.removeFromQueue]])
    }

    @Test("A row that is the song in the player gets no queue entries, even in Up next")
    func noQueueEntriesWithoutOffer() {
        #expect(actions(MusicSamples.track("v1"), in: .upNext, queue: false) == [.saveToPlaylist])
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
        #expect(MusicTrackAction.goToAlbum.title == "Go to album")
        #expect(MusicTrackAction.goToArtist.title == "Go to artist")
        #expect(MusicTrackAction.playNext.title == "Play next")
        #expect(MusicTrackAction.addToQueue.title == "Add to queue")
        #expect(MusicTrackAction.removeFromQueue.title == "Remove from queue")
        #expect(MusicTrackAction.pinHome(.canPin).title == "Pin to Home")
        #expect(MusicTrackAction.pinHome(.pinned).title == "Unpin from Home")
        #expect(MusicTrackAction.pinHome(.full).title == "Pin to Home (Home is full)")
    }

    @Test("No menu word has a dash or an ellipsis, since the menu is text only")
    func noDashesOrEllipses() {
        let all: [MusicTrackAction] = [
            .saveToPlaylist, .removeFromPlaylist, .goToAlbum, .goToArtist,
            .pinHome(.canPin), .pinHome(.pinned), .pinHome(.full),
            .playNext, .addToQueue, .removeFromQueue,
        ]
        for action in all {
            #expect(!action.title.contains("\u{2014}") && !action.title.contains("\u{2013}"))
            #expect(!action.title.contains("...") && !action.title.contains("\u{2026}"))
        }
    }
}
