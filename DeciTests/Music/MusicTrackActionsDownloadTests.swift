// DeciTests/Music/MusicTrackActionsDownloadTests.swift
// The Download and Remove download entries of a song's "..." menu: which one a song's download state offers, where
// they sit in the menu, that an id that cannot be downloaded offers neither, and that the menu reaches the download
// service (and does nothing on an album, playlist or artist tile, which have no downloads yet).

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicTrackActions downloads")
struct MusicTrackActionsDownloadTests {
    private let track = MusicSamples.track(DownloadSamples.idA)

    private func actions(
        _ track: Deci.MusicTrack, download: MusicDownloadState?, home: MusicHomePinState? = nil,
        canRate: Bool = false, queue: Bool = false, collectionOnly: Bool = false
    ) -> [MusicTrackAction] {
        MusicTrackActions.available(
            for: track, in: .none, home: home, offersQueue: queue, canRate: canRate, download: download,
            downloadHeldByCollectionOnly: collectionOnly
        )
    }

    // MARK: - By state

    @Test("a song nothing was downloaded for offers Download")
    func offersDownload() {
        #expect(actions(track, download: MusicDownloadState.none) == [.saveToPlaylist, .download, .related])
    }

    @Test("a download that failed offers Download again")
    func failedOffersDownload() {
        #expect(actions(track, download: .failed) == [.saveToPlaylist, .download, .related])
    }

    @Test("a song that is queued, downloading or downloaded offers Remove download")
    func offersRemove() {
        for state in [MusicDownloadState.queued, .downloading(fraction: 0), .downloading(fraction: 0.5), .downloaded] {
            #expect(actions(track, download: state) == [.saveToPlaylist, .removeDownload, .related], "\(state)")
        }
    }

    @Test("with no download state the menu is what it was before downloads")
    func leftOutByDefault() {
        #expect(actions(track, download: nil) == [.saveToPlaylist, .related])
        #expect(MusicTrackActions.available(for: track, in: .none) == [.saveToPlaylist, .related])
    }

    @Test("an id that cannot be a video id offers neither entry")
    func invalidIdOffersNothing() {
        for id in ["", "   ", "v1", "../../etc/passwd", "twelve_chars"] {
            let odd = MusicSamples.track(id)
            let offered = actions(odd, download: MusicDownloadState.none)
            #expect(!offered.contains(.download), "\(id.debugDescription)")
            #expect(!offered.contains(.removeDownload), "\(id.debugDescription)")
        }
    }

    // MARK: - A song only a downloaded page holds

    @Test("a song held only by a downloaded page, queued, downloading or downloaded, offers neither entry")
    func collectionOnlyOffersNeither() {
        for state in [MusicDownloadState.queued, .downloading(fraction: 0), .downloading(fraction: 0.5), .downloaded] {
            #expect(actions(track, download: state, collectionOnly: true) == [.saveToPlaylist, .related], "\(state)")
        }
    }

    @Test("a song of a page that has not arrived, or failed, still offers Download")
    func collectionOnlyStillOffersDownload() {
        #expect(actions(track, download: MusicDownloadState.none, collectionOnly: true) == [.saveToPlaylist, .download, .related])
        #expect(actions(track, download: .failed, collectionOnly: true) == [.saveToPlaylist, .download, .related])
    }

    @Test("a song downloaded on its own offers Remove download whether or not a page lists it")
    func standaloneOffersRemove() {
        #expect(actions(track, download: .downloaded, collectionOnly: false) == [.saveToPlaylist, .removeDownload, .related])
    }

    @Test("the flag changes nothing for a menu with no download state")
    func collectionOnlyWithoutState() {
        #expect(actions(track, download: nil, collectionOnly: true) == [.saveToPlaylist, .related])
    }

    // MARK: - Where they sit

    @Test("the entry sits in the library block after save and pin to Home, ahead of rating, going places and removing")
    func order() {
        var credited = MusicSamples.track(DownloadSamples.idA, albumBrowseId: "MPREbFixture", setVideoId: "set1")
        credited.artistLinks = [MusicArtistLink(name: "Fixture Artist", browseId: "UCfixtureArtist")]
        let own = MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true)

        let offered = MusicTrackActions.available(
            for: credited, in: own, home: .canPin, offersQueue: true, canRate: true, likeStatus: nil, download: MusicDownloadState.none
        )

        #expect(offered == [
            .playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin), .download,
            .like(removing: false), .dislike(removing: false), .goToAlbum, .goToArtist, .related, .removeFromPlaylist,
        ])
        #expect(MusicTrackActions.groups(of: offered) == [
            [.playNext, .addToQueue],
            [.saveToPlaylist, .pinHome(.canPin), .download],
            [.like(removing: false), .dislike(removing: false)],
            [.goToAlbum, .goToArtist, .related],
            [.removeFromPlaylist],
        ])
    }

    @Test("both entries are in the library block, with save")
    func group() {
        #expect(MusicTrackAction.download.group == .library)
        #expect(MusicTrackAction.removeDownload.group == .library)
        #expect(MusicTrackActions.groups(of: actions(track, download: .downloaded)) == [[.saveToPlaylist, .removeDownload], [.related]])
    }

    @Test("the words are Download and Remove download, both on, and neither is a rating")
    func words() {
        #expect(MusicTrackAction.download.title == "Download")
        #expect(MusicTrackAction.removeDownload.title == "Remove download")
        #expect(MusicTrackAction.download.isEnabled)
        #expect(MusicTrackAction.removeDownload.isEnabled)
        #expect(MusicTrackAction.download.ratingStatus == nil)
        #expect(MusicTrackAction.removeDownload.ratingStatus == nil)
    }

    @Test("a tile offers no download entry")
    func tileOffersNone() {
        let tiles = [
            MusicSamples.collection("MPREbTile", kind: .album, title: "Album", audioPlaylistId: "OLAK5uy_tile"),
            MusicSamples.collection("VLPLtile", kind: .playlist, title: "Playlist"),
            MusicSamples.collection("UCtileArtist", kind: .artist, title: "Artist"),
        ]
        for tile in tiles {
            let offered = MusicTrackActions.available(for: tile, in: .none)
            #expect(!offered.contains(.download))
            #expect(!offered.contains(.removeDownload))
        }
    }
}

/// The Music tab's navigation over a service that has a download service (or none).
@MainActor
private struct DownloadNavHarness {
    let rig: DownloadServiceRig
    let service: MusicService
    let nav: MusicSearchNavigation

    init(rig: DownloadServiceRig = DownloadServiceRig(), withDownloads: Bool = true) {
        self.rig = rig
        service = MusicService(
            backend: FakeMusicBackend(signedIn: true),
            player: MusicPlayer(engine: FakePlaybackEngine()),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            downloads: withDownloads ? rig.service : nil,
            refreshOnCreate: false
        )
        nav = MusicSearchNavigation(service: service)
    }
}

@MainActor
@Suite("MusicSearchNavigation download actions")
struct MusicSearchNavigationDownloadTests {
    private let idA = DownloadSamples.idA
    private let track = MusicSamples.track(DownloadSamples.idA)

    @Test("the song menu follows the song's download state, from Download to Remove download and back")
    func menuFollowsState() async {
        let h = DownloadNavHarness()
        defer { h.rig.cleanUp() }
        #expect(h.nav.actions(for: track, in: .none).contains(.download))
        #expect(!h.nav.actions(for: track, in: .none).contains(.removeDownload))

        h.nav.perform(.download, for: track, in: .none)

        #expect(h.rig.service.state(for: idA) == .queued)
        #expect(h.nav.actions(for: track, in: .none).contains(.removeDownload))
        #expect(!h.nav.actions(for: track, in: .none).contains(.download))
        #expect(await h.rig.settles(idA, as: .downloaded))
        #expect(h.nav.actions(for: track, in: .none).contains(.removeDownload))

        h.nav.perform(.removeDownload, for: track, in: .none)

        #expect(h.rig.service.state(for: idA) == .none)
        #expect(h.nav.actions(for: track, in: .none).contains(.download))
    }

    @Test("a song only a downloaded page holds offers neither entry until it is downloaded on its own")
    func collectionSongMenu() async {
        let backend = FakeMusicBackend()
        let h = DownloadNavHarness(rig: DownloadServiceRig(backend: backend))
        defer { h.rig.cleanUp() }
        await h.rig.script("VLPLone", tracks: [track])
        h.rig.service.downloadCollection(h.rig.request("VLPLone"))
        await h.rig.service.waitUntilIdle()

        #expect(h.rig.service.state(for: idA) == .downloaded)
        #expect(!h.nav.actions(for: track, in: .none).contains(.download))
        #expect(!h.nav.actions(for: track, in: .none).contains(.removeDownload))

        h.nav.perform(.download, for: track, in: .none)
        await h.rig.service.waitUntilIdle()

        #expect(h.nav.actions(for: track, in: .none).contains(.removeDownload))
        #expect(!h.nav.actions(for: track, in: .none).contains(.download))

        h.nav.perform(.removeDownload, for: track, in: .none)
        await h.rig.service.waitUntilIdle()

        // The page still holds the file, so the song is downloaded and the menu offers neither again.
        #expect(h.rig.service.state(for: idA) == .downloaded)
        #expect(!h.nav.actions(for: track, in: .none).contains(.download))
        #expect(!h.nav.actions(for: track, in: .none).contains(.removeDownload))
    }

    @Test("Download starts the song's download with the song's own details")
    func downloadCarriesTheTrack() async {
        let h = DownloadNavHarness()
        defer { h.rig.cleanUp() }
        let named = MusicSamples.track(idA, title: "Named song")

        h.nav.perform(.download, for: named, in: .none)
        #expect(await h.rig.settles(idA, as: .downloaded))

        let reloaded = MusicDownloadStore(root: h.rig.folder.root, now: { DownloadSamples.fixedDate })
        #expect(await reloaded.load()[idA]?.track.title == "Named song")
    }

    @Test("Remove download while the song downloads stops it")
    func removeWhileRunning() async {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let h = DownloadNavHarness(rig: DownloadServiceRig { request, index in
            if index == 1 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { h.rig.cleanUp() }
        h.nav.perform(.download, for: track, in: .none)
        await h.rig.transport.waitForRequests(2)

        h.nav.perform(.removeDownload, for: track, in: .none)
        await gate.open()
        await h.rig.service.waitUntilIdle()

        #expect(h.rig.service.state(for: idA) == .none)
        #expect(h.rig.folder.audioFiles.isEmpty)
    }

    @Test("without a download service the menu offers neither entry and the actions do nothing")
    func noService() {
        let h = DownloadNavHarness(withDownloads: false)
        defer { h.rig.cleanUp() }

        let offered = h.nav.actions(for: track, in: .none)
        h.nav.perform(.download, for: track, in: .none)
        h.nav.perform(.removeDownload, for: track, in: .none)

        #expect(!offered.contains(.download))
        #expect(!offered.contains(.removeDownload))
        #expect(h.service.downloads == nil)
    }

    @Test("the entries do nothing on a tile, and the tile menu offers neither")
    func tilesAreUntouched() {
        let h = DownloadNavHarness()
        defer { h.rig.cleanUp() }
        let tile = MusicSamples.collection("MPREbTile", kind: .album, title: "Album", audioPlaylistId: "OLAK5uy_tile")

        h.nav.perform(.download, for: tile, in: .none)
        h.nav.perform(.removeDownload, for: tile, in: .none)

        let offered = h.nav.actions(for: tile, in: .none)
        #expect(!offered.contains(.download))
        #expect(!offered.contains(.removeDownload))
        #expect(h.rig.service.state(for: tile.browseId) == .none)
    }
}

@Suite("MusicDownloadGlyph")
struct MusicDownloadGlyphTests {
    @Test("the lit share of the ring is the progress held to 0 through 1")
    func litShare() {
        #expect(MusicDownloadGlyph.litShare(of: 0) == 0)
        #expect(MusicDownloadGlyph.litShare(of: 0.25) == 0.25)
        #expect(MusicDownloadGlyph.litShare(of: 1) == 1)
        #expect(MusicDownloadGlyph.litShare(of: -0.5) == 0)
        #expect(MusicDownloadGlyph.litShare(of: 7) == 1)
    }

    @Test("a progress that is not a number lights nothing")
    func litShareOfNaN() {
        #expect(MusicDownloadGlyph.litShare(of: .nan) == 0)
        #expect(MusicDownloadGlyph.litShare(of: .infinity) == 0)
        #expect(MusicDownloadGlyph.litShare(of: -.infinity) == 0)
    }

    @Test("VoiceOver hears the states that show a mark, and nothing for the others")
    func spokenState() {
        #expect(MusicDownloadGlyph.spokenState(.downloaded) == "downloaded")
        #expect(MusicDownloadGlyph.spokenState(.queued) == "waiting to download")
        #expect(MusicDownloadGlyph.spokenState(.downloading(fraction: 0.4)) == "downloading")
        #expect(MusicDownloadGlyph.spokenState(MusicDownloadState.none) == nil)
        #expect(MusicDownloadGlyph.spokenState(.failed) == "Download failed")
    }}
