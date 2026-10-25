// DeciTests/Music/MusicTrackActionsLimitedTests.swift
// The song and tile menus while the app is downloads only (the network is down, or the account is gone): nothing that
// needs YouTube Music is offered, the queue entries stay for a song that plays from its file, and the downloads stay.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicTrackActions limited")
struct MusicTrackActionsLimitedTests {
    /// A song with everything an online menu would offer: an album, an artist, an id, a place in an editable playlist.
    private var rich: Deci.MusicTrack {
        var track = MusicSamples.track(DownloadSamples.idA, albumBrowseId: "MPREbFixture", setVideoId: "set1")
        track.artistLinks = [MusicArtistLink(name: "Fixture Artist", browseId: "UCfixtureArtist")]
        return track
    }

    private let editable = MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true)

    private func menu(
        download: MusicDownloadState?, limited: Bool, playsOffline: Bool, in context: MusicTrackContext? = nil, queue: Bool = true
    ) -> [MusicTrackAction] {
        MusicTrackActions.available(
            for: rich, in: context ?? editable, home: .canPin, offersQueue: queue, canRate: true, likeStatus: nil,
            download: download, limited: limited, playsOffline: playsOffline
        )
    }

    @Test("online the menu is whole, so the limits below are what removes the entries")
    func onlineIsWhole() {
        let offered = menu(download: MusicDownloadState.none, limited: false, playsOffline: false)
        #expect(offered == [
            .playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin), .download,
            .like(removing: false), .dislike(removing: false), .goToAlbum, .goToArtist, .related, .removeFromPlaylist,
        ])
    }

    @Test("limited, a song that is not downloaded offers Download only")
    func notDownloaded() {
        #expect(menu(download: MusicDownloadState.none, limited: true, playsOffline: false) == [.download])
        #expect(menu(download: .failed, limited: true, playsOffline: false) == [.download])
    }

    @Test("limited, a downloaded song keeps Play next and Add to queue, and Remove download")
    func downloaded() {
        #expect(menu(download: .downloaded, limited: true, playsOffline: true) == [.playNext, .addToQueue, .removeDownload])
    }

    @Test("limited, a song on its way offers Remove download but no queue entries until it can play")
    func onItsWay() {
        #expect(menu(download: .queued, limited: true, playsOffline: false) == [.removeDownload])
        #expect(menu(download: .downloading(fraction: 0.4), limited: true, playsOffline: false) == [.removeDownload])
    }

    @Test("limited, nothing the account owns is offered: save, pin, like, dislike, go to, related, remove from playlist")
    func noOnlineEntries() {
        let offered = menu(download: .downloaded, limited: true, playsOffline: true)
        let online: [MusicTrackAction] = [
            .saveToPlaylist, .pinHome(.canPin), .like(removing: false), .dislike(removing: false), .goToAlbum, .goToArtist,
            .related, .removeFromPlaylist,
        ]
        for action in online { #expect(!offered.contains(action), "\(action)") }
    }

    @Test("limited, an Up next row keeps Remove from queue, even for a song that cannot play")
    func upNextKeepsRemove() {
        #expect(menu(download: MusicDownloadState.none, limited: true, playsOffline: false, in: .upNext)
            == [.download, .removeFromQueue])
        #expect(menu(download: .downloaded, limited: true, playsOffline: true, in: .upNext)
            == [.playNext, .addToQueue, .removeDownload, .removeFromQueue])
    }

    @Test("limited, the song in the player is not offered to the queue either")
    func playingSongNotQueued() {
        #expect(menu(download: .downloaded, limited: true, playsOffline: true, queue: false) == [.removeDownload])
    }

    @Test("the flags default to a menu that is not limited")
    func defaults() {
        let before = MusicTrackActions.available(for: rich, in: editable, home: .canPin, offersQueue: true, canRate: true)
        let explicit = MusicTrackActions.available(
            for: rich, in: editable, home: .canPin, offersQueue: true, canRate: true, limited: false, playsOffline: false
        )
        #expect(before == explicit)
        #expect(before.contains(.related))
    }

    // MARK: - Tiles

    @Test("limited, an album, a playlist and an artist tile offer nothing")
    func tilesOfferNothing() {
        let tiles = [
            MusicSamples.collection(
                "MPREbTile", kind: .album, title: "Album",
                artistLinks: [MusicArtistLink(name: "Tile Artist", browseId: "UCtileArtist")], audioPlaylistId: "OLAK5uy_tile"
            ),
            MusicSamples.collection("VLPLtile", kind: .playlist, title: "Playlist"),
            MusicSamples.collection("UCtileArtist", kind: .artist, title: "Artist"),
        ]
        for tile in tiles {
            #expect(!MusicTrackActions.available(for: tile, in: .none, home: .canPin).isEmpty, "\(tile.title) online")
            #expect(MusicTrackActions.available(for: tile, in: .none, home: .canPin, limited: true).isEmpty, "\(tile.title) limited")
        }
    }

    // MARK: - Which actions need the account

    @Test("the entries that need YouTube Music, and the ones that do not")
    func needsAccount() {
        let online: [MusicTrackAction] = [
            .saveToPlaylist, .removeFromPlaylist, .pinHome(.canPin), .like(removing: false), .like(removing: true),
            .dislike(removing: false), .dislike(removing: true), .goToAlbum, .goToArtist, .related,
        ]
        for action in online { #expect(action.isOnlineOnly, "\(action)") }
        for action in [MusicTrackAction.playNext, .addToQueue, .removeFromQueue, .download, .removeDownload] {
            #expect(!action.isOnlineOnly, "\(action)")
        }
    }
}
