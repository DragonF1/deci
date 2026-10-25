// DeciTests/Music/MusicOfflineReviewTests.swift
// The review of offline downloads, phase 3. While the app is downloads only (the network is down, or the account is
// gone) the song and tile menus offer nothing that needs YouTube Music and their actions do nothing; the Related panel
// asks for nothing and says why; a launch before the system has reported the network still restores the session; and a
// Next that waited for a radio gives up the moment the network goes. Signed out is the case the user can be in with a
// working network: a stray call there ends in a sign-out that throws them off the Downloads page.

import Foundation
import Testing
@testable import Deci

private let editable = MusicTrackContext(pageBrowseId: "VLPLfixtureMine", pageTitle: "Mine", pageIsEditable: true)

/// A song with everything an online menu would offer: an album, an artist, an id, a place in an editable playlist.
private func richTrack(_ id: String = DownloadSamples.idA) -> MusicTrack {
    var track = MusicSamples.track(id, albumBrowseId: "MPREbFixture", setVideoId: "set1")
    track.artistLinks = [MusicArtistLink(name: "Fixture Artist", browseId: "UCfixtureArtist")]
    return track
}

/// Gives a call that should not be made time to show.
private func pause(milliseconds: Int = 40) async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

private func until(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// The two ways the app is downloads only.
nonisolated enum ReviewLimit: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case offline
    case signedOut

    var testDescription: String { rawValue }

    /// A rig in that state, with `downloaded` already on disk.
    @MainActor
    func rig(downloaded: [String] = []) async -> OfflineRig {
        let rig = OfflineRig(signedIn: self == .offline)
        for id in downloaded { #expect(await rig.download(id)) }
        await rig.service.refreshAuth()
        if self == .offline { rig.goOffline() }
        return rig
    }
}

@MainActor
@Suite("Offline review: song and tile menus")
struct MusicOfflineMenuReviewTests {
    private let idA = DownloadSamples.idA

    @Test("a song that is not downloaded offers Download only, offline and signed out", arguments: ReviewLimit.allCases)
    func undownloadedMenu(limit: ReviewLimit) async {
        let rig = await limit.rig()
        defer { rig.cleanUp() }
        let nav = MusicSearchNavigation(service: rig.service)

        #expect(nav.actions(for: richTrack(), in: editable) == [.download])
        // The player's save button reads the same menu.
        #expect(!nav.actions(for: richTrack(), in: .none).contains(.saveToPlaylist))
    }

    @Test("a downloaded song keeps Play next, Add to queue and Remove download, offline and signed out", arguments: ReviewLimit.allCases)
    func downloadedMenu(limit: ReviewLimit) async {
        let rig = await limit.rig(downloaded: [idA])
        defer { rig.cleanUp() }
        let nav = MusicSearchNavigation(service: rig.service)

        #expect(nav.actions(for: richTrack(), in: editable) == [.playNext, .addToQueue, .removeDownload])
    }

    @Test("online and signed in the menu is whole")
    func wholeMenuOnline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        await rig.service.refreshAuth()
        let nav = MusicSearchNavigation(service: rig.service)

        #expect(nav.actions(for: richTrack(), in: editable) == [
            .playNext, .addToQueue, .saveToPlaylist, .pinHome(.canPin), .download,
            .like(removing: false), .dislike(removing: false), .goToAlbum, .goToArtist, .related, .removeFromPlaylist,
        ])
        #expect(nav.actions(for: MusicSamples.collection("VLPLtile", title: "Playlist"), in: .none).contains(.saveToPlaylist))
    }

    @Test("the entries that need YouTube Music do nothing when they are run anyway", arguments: ReviewLimit.allCases)
    func onlineEntriesDoNothing(limit: ReviewLimit) async {
        let rig = await limit.rig()
        defer { rig.cleanUp() }
        let nav = MusicSearchNavigation(service: rig.service)
        let blocked: [MusicTrackAction] = [
            .saveToPlaylist, .related, .goToAlbum, .goToArtist, .removeFromPlaylist, .pinHome(.canPin),
            .like(removing: false), .dislike(removing: false),
        ]

        for action in blocked { nav.perform(action, for: richTrack(), in: editable) }
        await pause()

        #expect(!nav.showsPicker)
        #expect(rig.service.trackActions.picker == nil)
        #expect(rig.service.browse.path.isEmpty)
        #expect(rig.service.related.state == .idle)
        #expect(!nav.showsRelated)
        #expect(rig.service.pinnedItems.items.isEmpty)
        #expect(await rig.backend.playlistOptionsCalls.isEmpty)
        #expect(await rig.backend.rateCalls.isEmpty)
        #expect(await rig.backend.relatedCalls.isEmpty)
        #expect(await rig.backend.removeFromPlaylistCalls.isEmpty)
        #expect(await rig.backend.pageCalls.isEmpty)
        // A call that finds the session gone would sign the user out of the page they are on.
        #expect(await rig.backend.signOutCount == 0)
    }

    @Test("Play next and Add to queue do nothing for a song that is not downloaded", arguments: ReviewLimit.allCases)
    func queueEntriesNeedAFile(limit: ReviewLimit) async {
        let rig = await limit.rig()
        defer { rig.cleanUp() }
        let nav = MusicSearchNavigation(service: rig.service)

        nav.perform(.playNext, for: richTrack(), in: .none)
        nav.perform(.addToQueue, for: richTrack(), in: .none)
        await rig.settle()

        #expect(rig.service.queue.isEmpty)
        #expect(rig.engine.loads.isEmpty)
        #expect(rig.player.nowPlaying == nil)
        #expect(await rig.backend.resolvedIDs.isEmpty)
    }

    @Test("Play next of a downloaded song plays it from its file", arguments: ReviewLimit.allCases)
    func queueEntriesWorkForAFile(limit: ReviewLimit) async {
        let rig = await limit.rig(downloaded: [idA])
        defer { rig.cleanUp() }
        let nav = MusicSearchNavigation(service: rig.service)

        nav.perform(.playNext, for: richTrack(), in: .none)
        await rig.settle()

        #expect(rig.loadedIDs == [idA])
        #expect(rig.engine.loads.first?.stream.url.path == rig.folder.audioURL(idA).path)
        #expect(await rig.backend.resolvedIDs.isEmpty)
    }

    @Test("Download and Remove download still work", arguments: ReviewLimit.allCases)
    func downloadsStay(limit: ReviewLimit) async {
        let rig = await limit.rig()
        defer { rig.cleanUp() }
        let nav = MusicSearchNavigation(service: rig.service)
        let other = richTrack(DownloadSamples.idB)

        nav.perform(.download, for: other, in: .none)

        #expect(nav.actions(for: other, in: .none).contains(.removeDownload))
        #expect(!nav.actions(for: other, in: .none).contains(.download))

        nav.perform(.removeDownload, for: other, in: .none)

        #expect(nav.actions(for: other, in: .none) == [.download])
    }

    @Test("an album, playlist or artist tile offers nothing, and its actions do nothing", arguments: ReviewLimit.allCases)
    func tiles(limit: ReviewLimit) async {
        let rig = await limit.rig()
        defer { rig.cleanUp() }
        let nav = MusicSearchNavigation(service: rig.service)
        let tiles = [
            MusicSamples.collection(
                "MPREbTile", kind: .album, title: "Album",
                artistLinks: [MusicArtistLink(name: "Tile Artist", browseId: "UCtileArtist")], audioPlaylistId: "OLAK5uy_tile"
            ),
            MusicSamples.collection("VLPLtile", kind: .playlist, title: "Playlist"),
            MusicSamples.collection("UCtileArtist", kind: .artist, title: "Artist"),
        ]

        for tile in tiles {
            #expect(nav.actions(for: tile, in: .none).isEmpty, "\(tile.title)")
            for action in [MusicTrackAction.saveToPlaylist, .pinHome(.canPin), .related, .goToAlbum, .goToArtist] {
                nav.perform(action, for: tile, in: .none)
            }
        }
        await pause()

        #expect(!nav.showsPicker)
        #expect(rig.service.browse.path.isEmpty)
        #expect(rig.service.related.state == .idle)
        #expect(rig.service.pinnedItems.items.isEmpty)
        #expect(await rig.backend.playlistOptionsCalls.isEmpty)
        #expect(await rig.backend.pageCalls.isEmpty)
        #expect(await rig.backend.signOutCount == 0)
    }
}

@MainActor
@Suite("Offline review: Related songs")
struct MusicOfflineRelatedReviewTests {
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB

    private func found() -> [MusicTrack] { [MusicSamples.track("rel1", title: "Related one")] }

    @Test("offline the panel asks for nothing and says so, and loads when the network returns")
    func offlineSong() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        await rig.service.refreshAuth()
        await rig.backend.setRelated(videoId: idA, found())
        rig.goOffline()

        rig.service.related.show(MusicSamples.track(idA))
        await pause()

        #expect(rig.service.related.state == .failed(MusicRelatedStore.offlineMessage))
        #expect(await rig.backend.relatedCalls.isEmpty)

        rig.goOnline()

        #expect(await until { rig.service.related.state == .loaded(found()) })
        #expect(await rig.backend.relatedCalls == [idA])
    }

    @Test("signed out the panel asks for nothing, and loads when the sign-in finishes")
    func signedOutSong() async {
        let rig = OfflineRig(signedIn: false)
        defer { rig.cleanUp() }
        await rig.service.refreshAuth()
        await rig.backend.setRelated(videoId: idA, found())

        rig.service.related.show(MusicSamples.track(idA))
        await pause()

        #expect(rig.service.related.state == .failed(MusicRelatedStore.signedOutMessage))
        #expect(await rig.backend.relatedCalls.isEmpty)
        #expect(await rig.backend.signOutCount == 0)

        await rig.backend.setSignedIn(true)
        await rig.service.refreshAuth()

        #expect(await until { rig.service.related.state == .loaded(found()) })
        #expect(await rig.backend.relatedCalls == [idA])
    }

    @Test("a panel that follows the player asks for nothing as the song changes offline")
    func followingOffline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        await rig.service.refreshAuth()
        rig.goOffline()

        rig.service.related.follow(MusicSamples.track(idA))
        rig.service.related.nowPlayingChanged(MusicSamples.track(idB))
        // Longer than the wait a changed song makes before it asks.
        await pause(milliseconds: 450)

        #expect(rig.service.related.state == .failed(MusicRelatedStore.offlineMessage))
        #expect(await rig.backend.relatedCalls.isEmpty)
    }

    @Test("an album, playlist or artist reads no page offline")
    func offlineCollection() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        await rig.service.refreshAuth()
        let tile = MusicSamples.collection("MPREbTile", kind: .album, title: "Album")
        await rig.backend.setPage(MusicSamples.page("MPREbTile", tracks: [MusicSamples.track(idA)]))
        await rig.backend.setRelated(videoId: idA, found())
        rig.goOffline()

        rig.service.related.show(tile)
        await pause()

        #expect(rig.service.related.state == .failed(MusicRelatedStore.offlineMessage))
        #expect(await rig.backend.pageCalls.isEmpty)
        #expect(await rig.backend.relatedCalls.isEmpty)

        rig.goOnline()

        #expect(await until { rig.service.related.state == .loaded(found()) })
        #expect(await rig.backend.pageCalls == ["MPREbTile"])
    }

    @Test("an answer kept from earlier still shows offline, with no call")
    func keptAnswerShowsOffline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        await rig.service.refreshAuth()
        await rig.backend.setRelated(videoId: idA, found())
        rig.service.related.show(MusicSamples.track(idA))
        #expect(await until { rig.service.related.state == .loaded(found()) })
        rig.goOffline()

        rig.service.related.show(MusicSamples.track(idA))

        #expect(rig.service.related.state == .loaded(found()))
        #expect(await rig.backend.relatedCalls == [idA])
    }

    @Test("a panel closed while it waited does not ask when the network returns")
    func closedPanelStaysClosed() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        await rig.service.refreshAuth()
        rig.goOffline()
        rig.service.related.show(MusicSamples.track(idA))
        rig.service.related.close()

        rig.goOnline()
        await pause()

        #expect(rig.service.related.state == .idle)
        #expect(await rig.backend.relatedCalls.isEmpty)
    }
}

@MainActor
@Suite("Offline review: launch and queue")
struct MusicOfflineLaunchReviewTests {
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB
    private let idC = DownloadSamples.idC
    private let cut = URLError(.notConnectedToInternet)

    // MARK: - A launch before the system has reported the network

    @Test("a restore waits for the first report when the account cannot be read, and restores from the file if there is no network")
    func restoreWaitsThenOffline() async {
        let rig = OfflineRig(pathReported: false)
        defer { rig.cleanUp() }
        #expect(await rig.download(idB))
        rig.seedSession([idA, idB, idC], current: idB)
        await rig.backend.setSessionIdentity(nil)

        rig.service.restoreSession()
        #expect(await until { rig.connectivity.reportWaiters == 1 })
        #expect(rig.engine.loads.isEmpty)

        rig.connectivity.report(isOnline: false)
        await rig.service.restoreTask?.value
        await rig.settleTracking()

        #expect(rig.engine.loads.count == 1)
        #expect(rig.engine.loads.first?.stream.url.path == rig.folder.audioURL(idB).path)
        #expect(rig.engine.loads.first?.autoplay == false)
        #expect(rig.service.queue.current?.videoId == idB)
        #expect(rig.service.queue.tracks.count == 3)
        #expect(await rig.backend.resolvedIDs.isEmpty)
    }

    @Test("a restore that waited and found the network up leaves the session on disk, as an unreadable account always did")
    func restoreWaitsThenOnline() async {
        let rig = OfflineRig(pathReported: false)
        defer { rig.cleanUp() }
        rig.seedSession([idA, idB], current: idB)
        await rig.backend.setSessionIdentity(nil)

        rig.service.restoreSession()
        #expect(await until { rig.connectivity.reportWaiters == 1 })
        rig.connectivity.report(isOnline: true)
        await rig.service.restoreTask?.value

        rig.sessionStore.waitForWrites()
        #expect(rig.service.queue.isEmpty)
        #expect(rig.engine.loads.isEmpty)
        #expect(rig.sessionFolder.fileExists)
    }

    @Test("a restore whose stream failed for the network, with the path still unreported, parks the queue when the report is offline")
    func streamFailureThenOffline() async {
        let rig = OfflineRig(pathReported: false)
        defer { rig.cleanUp() }
        rig.seedSession([idA, idB], current: idB)
        await rig.backend.setResolveError(idB, cut)

        rig.service.restoreSession()
        #expect(await until { rig.connectivity.reportWaiters == 1 })
        rig.connectivity.report(isOnline: false)
        await rig.service.restoreTask?.value
        rig.sessionStore.waitForWrites()

        #expect(rig.sessionFolder.fileExists)
        #expect(rig.service.queue.current?.videoId == idB)
        #expect(rig.service.queue.tracks.count == 2)
        #expect(rig.player.nowPlaying?.videoId == idB)
        #expect(!rig.player.isLoading)
        #expect(rig.engine.loads.isEmpty)
    }

    @Test("the same failure when the report says the network is up is a failure: the session is dropped")
    func streamFailureThenOnline() async {
        let rig = OfflineRig(pathReported: false)
        defer { rig.cleanUp() }
        rig.seedSession([idA, idB], current: idB)
        await rig.backend.setResolveError(idB, cut)

        rig.service.restoreSession()
        #expect(await until { rig.connectivity.reportWaiters == 1 })
        rig.connectivity.report(isOnline: true)
        await rig.service.restoreTask?.value
        rig.sessionStore.waitForWrites()

        #expect(!rig.sessionFolder.fileExists)
        #expect(rig.service.queue.isEmpty)
    }

    @Test("a restore that started on the online path and lost the network while it resolved keeps the session")
    func networkLostWhileResolving() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        rig.seedSession([idA, idB], current: idB)
        let gate = MusicTestGate()
        await rig.backend.setResolveGate(idB, gate)
        await rig.backend.setResolveError(idB, cut)

        rig.service.restoreSession()
        #expect(await until { await rig.backend.resolvedIDs == [idB] })
        rig.goOffline()
        await gate.open()
        await rig.service.restoreTask?.value
        rig.sessionStore.waitForWrites()

        #expect(rig.sessionFolder.fileExists)
        #expect(rig.service.queue.current?.videoId == idB)
        #expect(rig.player.nowPlaying?.videoId == idB)
        #expect(rig.engine.loads.isEmpty)
    }

    @Test("on a path that was reported online all along, a stream failure still drops the session")
    func streamFailureKnownOnline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        rig.seedSession([idA, idB], current: idB)
        await rig.backend.setResolveError(idB, cut)

        rig.service.restoreSession()
        await rig.service.restoreTask?.value
        rig.sessionStore.waitForWrites()

        #expect(!rig.sessionFolder.fileExists)
        #expect(rig.service.queue.isEmpty)
    }

    // MARK: - Next with no network

    @Test("Next at the last downloaded song leaves it playing and asks for nothing")
    func offlineNextAtTheEnd() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        rig.goOffline()
        rig.service.play(rig.song(idA))
        await rig.settle()
        rig.engine.emit(.playingChanged(true))

        rig.service.next()
        await rig.settle()

        #expect(rig.loadedIDs == [idA])
        #expect(rig.service.queue.current?.videoId == idA)
        #expect(rig.player.nowPlaying?.videoId == idA)
        #expect(rig.service.radioTask == nil)
        #expect(await rig.queueRequests() == 0)
    }

    @Test("a Next that waits for the radio is settled the moment the network goes, and the song plays on")
    func nextParkedBehindRadio() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        let gate = MusicTestGate()
        await rig.backend.setRadioGate(seed: idA, gate)
        await rig.backend.setRadio(seed: idA, tracks: [rig.song(idA), rig.song(idB)], continuation: nil)
        rig.service.play(rig.song(idA))
        await rig.service.playTask?.value
        rig.engine.emit(.playingChanged(true))
        #expect(await until { await rig.backend.radioSeeds.count == 1 })
        #expect(rig.service.isFillingQueue)

        rig.service.next()
        #expect(rig.loadedIDs == [idA])

        rig.goOffline()

        // At once: the fetch is cancelled, not waited out.
        #expect(rig.service.radioTask == nil)
        #expect(!rig.service.isFillingQueue)
        #expect(rig.service.queue.current?.videoId == idA)
        #expect(rig.player.nowPlaying?.videoId == idA)
        #expect(rig.loadedIDs == [idA])

        // The answer that was out lands nowhere.
        await gate.open()
        await pause()
        #expect(rig.queuedIDs == [idA])

        // And the network's return asks for the radio again, without playing the Next that was given up.
        rig.goOnline()
        #expect(await until { await rig.backend.radioSeeds.count >= 2 })
        // The same seed again (its answer then asks for the next song's radio, so there may be a third ask).
        #expect(await Array(rig.backend.radioSeeds.prefix(2)) == [idA, idA])
        await rig.settle()
        #expect(rig.loadedIDs == [idA])
        #expect(rig.queuedIDs.first == idA)
    }
}
