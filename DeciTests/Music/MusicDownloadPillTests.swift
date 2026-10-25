// DeciTests/Music/MusicDownloadPillTests.swift
// The Download pill on a playlist or album page, kept apart from the drawing: which pages get it, where it sits among the
// other pills, what each state says in the header and to VoiceOver, which entries its menu holds, and the request it makes
// from the page. No view is drawn.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicDownloadPill")
struct MusicDownloadPillTests {
    private func downloading(_ done: Int, of total: Int, fraction: Double = 0) -> MusicCollectionDownloadState {
        .downloading(done: done, total: total, fraction: fraction)
    }

    private func updating(_ done: Int, of total: Int, fraction: Double = 0) -> MusicCollectionDownloadState {
        .updating(done: done, total: total, fraction: fraction)
    }

    // MARK: - Which pages

    @Test("playlists, Liked music and albums can be downloaded")
    func downloadablePages() {
        for browseId in ["VLPLabc123", "VLLM", "VLOLAK5uy_x", "VLRDCLAK5uy_curated", "MPREb_album"] {
            #expect(MusicDownloadPage.canDownload(browseId: browseId), "\(browseId)")
        }
    }

    @Test("an artist, a mix, a radio and every other page cannot")
    func notDownloadablePages() {
        for browseId in ["UCartist", "VLRDAMVMabc", "VLRDTMAK5uy_mix", "RDCLAK5uy_x", "MPADartist", "FEmusic_home", "VL", "MPRE", ""] {
            #expect(!MusicDownloadPage.canDownload(browseId: browseId), "\(browseId)")
        }
    }

    // MARK: - Pills

    @Test("the pill sits after Shuffle and before the round menu button")
    func pillOrder() {
        for kind in [MusicPageKind.album, .playlist, .liked] {
            #expect(
                MusicPagePills.pills(kind: kind, hasTracks: true, hasMenuItems: true, canDownload: true)
                    == [.play, .shuffle, .download, .more]
            )
            #expect(
                MusicPagePills.pills(kind: kind, hasTracks: true, hasMenuItems: false, canDownload: true)
                    == [.play, .shuffle, .download]
            )
        }
    }

    @Test("a page with no songs listed still offers the pill, so a downloaded page can be removed")
    func pillWithoutTracks() {
        #expect(MusicPagePills.pills(kind: .playlist, hasTracks: false, hasMenuItems: false, canDownload: true) == [.download])
        #expect(MusicPagePills.pills(kind: .album, hasTracks: false, hasMenuItems: true, canDownload: true) == [.download, .more])
    }

    @Test("without the permission the pills are what they were")
    func pillOffByDefault() {
        #expect(MusicPagePills.pills(kind: .album, hasTracks: true, hasMenuItems: true) == [.play, .shuffle, .more])
        #expect(MusicPagePills.pills(kind: .album, hasTracks: true, hasMenuItems: true, canDownload: false) == [.play, .shuffle, .more])
        #expect(MusicPagePills.pills(kind: .artist, hasTracks: true, hasMenuItems: true, canDownload: false) == [.play, .more])
    }

    // MARK: - The header's line

    @Test("the meta line says how far a download has got")
    func metaDownloading() {
        #expect(MusicDownloadPage.metaText(downloading(12, of: 40, fraction: 0.3)) == "Downloading 12 of 40")
        #expect(MusicDownloadPage.metaText(downloading(0, of: 40)) == "Downloading 0 of 40")
        #expect(MusicDownloadPage.metaText(downloading(0, of: 0)) == "Downloading")
    }

    @Test("a downloaded page fetching new songs reads like a download in progress")
    func metaUpdating() {
        #expect(MusicDownloadPage.metaText(updating(38, of: 40, fraction: 0.95)) == "Downloading 38 of 40")
        #expect(MusicDownloadPage.metaText(updating(0, of: 0)) == "Downloading")
    }

    @Test("a finished download says Downloaded, and one with failures says how many arrived")
    func metaDownloaded() {
        #expect(MusicDownloadPage.metaText(.downloaded(done: 40, total: 40)) == "Downloaded")
        #expect(MusicDownloadPage.metaText(.downloaded(done: 38, total: 40)) == "38 of 40 downloaded")
        #expect(MusicDownloadPage.metaText(.downloaded(done: 0, total: 3)) == "0 of 3 downloaded")
    }

    @Test("a page that is not downloaded adds nothing")
    func metaNone() {
        #expect(MusicDownloadPage.metaText(.none) == nil)
    }

    @Test("the line is added to the header's meta after a middle dot, or stands alone when the header has none")
    func appendToMeta() {
        let state = MusicCollectionDownloadState.downloaded(done: 40, total: 40)

        #expect(MusicPageHeroText.appending(download: state, to: "40 songs \u{00B7} 2 hr 31 min") == "40 songs \u{00B7} 2 hr 31 min \u{00B7} Downloaded")
        #expect(MusicPageHeroText.appending(download: state, to: nil) == "Downloaded")
        #expect(MusicPageHeroText.appending(download: state, to: "") == "Downloaded")
        #expect(MusicPageHeroText.appending(download: .none, to: "40 songs") == "40 songs")
        #expect(MusicPageHeroText.appending(download: .none, to: nil) == nil)
        #expect(
            MusicPageHeroText.appending(download: downloading(12, of: 40), to: "40 songs")
                == "40 songs \u{00B7} Downloading 12 of 40"
        )
    }

    // MARK: - Glyph, ring and menu

    @Test("the glyph is the open arrow circle until the page is downloaded, then the filled one")
    func symbols() {
        #expect(MusicDownloadPage.symbol(for: .none) == "arrow.down.circle")
        #expect(MusicDownloadPage.symbol(for: .downloaded(done: 3, total: 3)) == "arrow.down.circle.fill")
        // A download with failures wears the same glyph as one without.
        #expect(MusicDownloadPage.symbol(for: .downloaded(done: 2, total: 3)) == "arrow.down.circle.fill")
        // Fetching new songs into a downloaded page draws the ring, so the glyph under it is the open one.
        #expect(MusicDownloadPage.symbol(for: updating(2, of: 3)) == "arrow.down.circle")
    }

    @Test("a ring shows only while downloading or updating, held to 0 through 1")
    func ring() {
        #expect(MusicDownloadPage.ringFraction(for: .none) == nil)
        #expect(MusicDownloadPage.ringFraction(for: .downloaded(done: 3, total: 3)) == nil)
        #expect(MusicDownloadPage.ringFraction(for: downloading(1, of: 4, fraction: 0.4)) == 0.4)
        #expect(MusicDownloadPage.ringFraction(for: downloading(0, of: 0, fraction: 0)) == 0)
        #expect(MusicDownloadPage.ringFraction(for: downloading(1, of: 4, fraction: 7)) == 1)
        #expect(MusicDownloadPage.ringFraction(for: downloading(1, of: 4, fraction: -1)) == 0)
        #expect(MusicDownloadPage.ringFraction(for: downloading(1, of: 4, fraction: .nan)) == 0)
        #expect(MusicDownloadPage.ringFraction(for: updating(3, of: 4, fraction: 0.8)) == 0.8)
        #expect(MusicDownloadPage.ringFraction(for: updating(3, of: 4, fraction: 7)) == 1)
    }

    @Test("a first download offers Cancel download, a finished one Remove download, and a bare page a click")
    func menuEntries() {
        #expect(MusicDownloadPage.menuEntries(for: downloading(1, of: 4)) == [.cancel])
        #expect(MusicDownloadPage.menuEntries(for: downloading(0, of: 0)) == [.cancel])
        #expect(MusicDownloadPage.menuEntries(for: .downloaded(done: 4, total: 4)) == [.remove])
        #expect(MusicDownloadPage.menuEntries(for: .downloaded(done: 3, total: 4)) == [.remove])
        #expect(MusicDownloadPage.menuEntries(for: .none).isEmpty)
    }

    @Test("a downloaded page fetching new songs offers both, Cancel first")
    func menuEntriesWhileUpdating() {
        #expect(MusicDownloadPage.menuEntries(for: updating(38, of: 40)) == [.cancel, .remove])
        #expect(MusicDownloadPage.menuEntries(for: updating(0, of: 0)) == [.cancel, .remove])
    }

    @Test("the entries are worded Cancel download and Remove download")
    func menuTitles() {
        #expect(MusicDownloadMenuEntry.cancel.title == "Cancel download")
        #expect(MusicDownloadMenuEntry.remove.title == "Remove download")
    }

    @Test("the tooltip and the VoiceOver label name the action and the page, as the other pills do")
    func words() {
        #expect(MusicDownloadPage.tooltip(for: .none) == "Download")
        #expect(MusicDownloadPage.tooltip(for: downloading(1, of: 4)) == "Downloading")
        #expect(MusicDownloadPage.tooltip(for: updating(3, of: 4)) == "Downloading")
        #expect(MusicDownloadPage.tooltip(for: .downloaded(done: 4, total: 4)) == "Downloaded")

        #expect(MusicDownloadPage.accessibilityLabel(for: .none, title: "Road trip") == "Download Road trip")
        #expect(MusicDownloadPage.accessibilityLabel(for: downloading(1, of: 4), title: "Road trip") == "Downloading Road trip")
        #expect(MusicDownloadPage.accessibilityLabel(for: updating(3, of: 4), title: "Road trip") == "Downloading Road trip")
        #expect(MusicDownloadPage.accessibilityLabel(for: .downloaded(done: 4, total: 4), title: "Road trip") == "Downloaded Road trip")
        #expect(
            MusicDownloadPage.accessibilityLabel(for: .downloaded(done: 3, total: 4), title: "Road trip")
                == "Downloaded Road trip, 1 failed"
        )
    }

    @Test("VoiceOver hears the count as the pill's value while it downloads")
    func accessibilityValue() {
        #expect(MusicDownloadPage.accessibilityValue(for: downloading(12, of: 40)) == "12 of 40")
        #expect(MusicDownloadPage.accessibilityValue(for: downloading(0, of: 0)) == nil)
        #expect(MusicDownloadPage.accessibilityValue(for: updating(38, of: 40)) == "38 of 40")
        #expect(MusicDownloadPage.accessibilityValue(for: .downloaded(done: 4, total: 4)) == nil)
        #expect(MusicDownloadPage.accessibilityValue(for: .none) == nil)
    }

    // MARK: - The request

    @Test("the request names the page, takes an album's kind from its id, and has no subtitle where the page has none")
    func request() {
        let cover = URL(string: "https://lh3.googleusercontent.com/c=w544-h544")
        let playlist = MusicDownloadPage.request(browseId: "VLPLabc", title: "Road trip", subtitle: "Playlist", coverURL: cover)
        let album = MusicDownloadPage.request(browseId: "MPREb_album", title: "Album", subtitle: nil, coverURL: nil)
        let liked = MusicDownloadPage.request(browseId: "VLLM", title: "Liked music", subtitle: nil, coverURL: nil)

        #expect(playlist == MusicCollectionRequest(browseId: "VLPLabc", title: "Road trip", subtitle: "Playlist", kind: .playlist, coverURL: cover))
        #expect(album == MusicCollectionRequest(browseId: "MPREb_album", title: "Album", subtitle: "", kind: .album, coverURL: nil))
        #expect(liked.kind == .playlist)
    }
}

/// The three places downloads meet the rest of the Music service: the sign-in that starts the launch sync, and the
/// launch check that builds the service for a Mac with downloaded collections.
@MainActor
@Suite("MusicDownloadLaunch")
struct MusicDownloadLaunchTests {
    private let one = "VLPLone"

    /// A service on a download rig whose folder already holds the collection `one`, with a fake backend serving it.
    private func makeServiceWithStoredCollection(
        signedIn: Bool
    ) async -> (service: MusicService, rig: DownloadServiceRig, backend: FakeMusicBackend) {
        let first = DownloadServiceRig(backend: FakeMusicBackend())
        await first.script(one, tracks: DownloadSamples.tracks(1...2))
        first.service.downloadCollection(first.request(one))
        await first.service.waitUntilIdle()

        let backend = FakeMusicBackend(signedIn: signedIn)
        let rig = DownloadServiceRig(folder: first.folder, backend: backend)
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        let service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: FakePlaybackEngine()),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            downloads: rig.service,
            refreshOnCreate: false
        )
        return (service, rig, backend)
    }

    @Test("once the session is known to be signed in, the downloaded collections are synced, once")
    func signInStartsTheSync() async {
        let (service, rig, backend) = await makeServiceWithStoredCollection(signedIn: true)
        defer { rig.cleanUp() }
        await rig.service.waitUntilIdle()
        #expect(await backend.pageCalls.isEmpty)

        await service.refreshAuth()
        await rig.service.waitUntilIdle()
        await service.refreshAuth()
        await rig.service.waitUntilIdle()

        #expect(await backend.pageCalls == [one])
    }

    @Test("signed out, nothing is synced")
    func signedOutSyncsNothing() async {
        let (service, rig, backend) = await makeServiceWithStoredCollection(signedIn: false)
        defer { rig.cleanUp() }

        await service.refreshAuth()
        await rig.service.waitUntilIdle()

        #expect(await backend.pageCalls.isEmpty)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 2))
    }

    // MARK: - The launch check

    private func makeHost(hasCollections: Bool) -> MusicServiceHost {
        MusicServiceHost(
            makeService: {
                MusicService(
                    backend: FakeMusicBackend(),
                    player: MusicPlayer(engine: FakePlaybackEngine()),
                    presentSignIn: { _ in },
                    nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
                    refreshOnCreate: false
                )
            },
            hasStoredCollections: { hasCollections }
        )
    }

    @Test("a Mac with downloaded collections builds the service at launch, so the sync can run without the popup")
    func launchBuildsTheService() async {
        let host = makeHost(hasCollections: true)

        await host.syncDownloadsIfAny().value

        #expect(host.service != nil)
    }

    @Test("a Mac with none leaves the service lazy")
    func launchLeavesItLazy() async {
        let host = makeHost(hasCollections: false)

        await host.syncDownloadsIfAny().value

        #expect(host.service == nil)
    }

    @Test("a service that already exists is left alone")
    func launchKeepsTheService() async throws {
        let host = makeHost(hasCollections: true)
        host.loadIfNeeded()
        let service = try #require(host.service)

        await host.syncDownloadsIfAny().value

        #expect(host.service === service)
    }
}
