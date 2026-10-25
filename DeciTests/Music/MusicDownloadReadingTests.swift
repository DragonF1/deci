// DeciTests/Music/MusicDownloadReadingTests.swift
// What the Downloads tab and the offline pages read from the download service: every downloaded song newest first, the
// "Downloaded songs" page, the downloaded playlists and albums newest first (with how far a running download has got in
// the subtitle), a stored collection's page built from the index alone, and the saved cover for a remote address. All of
// it comes from the index in memory; nothing here touches the network.

import Foundation
import Observation
import os
import Testing
@testable import Deci

@MainActor
@Suite("MusicDownloadReading")
struct MusicDownloadReadingTests {
    private let one = "VLPLone"
    private let two = "VLPLtwo"
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB
    private let idC = DownloadSamples.idC

    private func id(_ number: Int) -> String { DownloadSamples.id(number) }

    /// A rig whose index stamps each download with the clock, so songs and collections get different times.
    private func makeRig(
        handler: FakeDownloadTransport.Handler? = nil, backend: FakeMusicBackend? = nil,
        covers: (any MusicCoverFetching)? = nil
    ) -> DownloadServiceRig {
        let clock = MutableClock()
        return DownloadServiceRig(
            clock: clock, handler: handler, storeNow: { clock.now }, backend: backend, covers: covers
        )
    }

    private func download(_ rig: DownloadServiceRig, _ ids: String...) async {
        for id in ids {
            rig.service.download(DownloadSamples.track(id, title: "Title \(id.prefix(1))"))
            await rig.service.waitUntilIdle()
            rig.clock.advance(by: 10)
        }
    }

    // MARK: - Songs

    @Test("downloaded songs come newest first, with the title and artist that were stored")
    func songsNewestFirst() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }

        await download(rig, idA, idB, idC)

        #expect(rig.service.downloadedSongs.map(\.videoId) == [idC, idB, idA])
        #expect(rig.service.downloadedSongs.map(\.title) == ["Title C", "Title B", "Title A"])
        #expect(rig.service.downloadedSongs.first?.artist == "Artist")
        #expect(rig.service.downloadedSongCount == 3)
    }

    @Test("songs downloaded in the same instant keep a steady order")
    func songsTie() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idB)
        rig.download(idA)
        rig.download(idC)
        await rig.service.waitUntilIdle()

        #expect(rig.service.downloadedSongs.map(\.videoId) == [idA, idB, idC])
    }

    @Test("a song that is queued or failed is not a downloaded song")
    func queuedIsNotDownloaded() async throws {
        let rig = DownloadServiceRig(handler: { _, _ in FakeDownloadTransport.status(404) })
        defer { rig.cleanUp() }
        rig.download(idA)
        _ = await rig.settles(idA, as: .failed)

        #expect(rig.service.downloadedSongs.isEmpty)
        #expect(rig.service.downloadedSongCount == 0)
    }

    @Test("the song count is observable, so the Downloads tab redraws when a download finishes")
    func songCountObservable() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        await rig.service.waitUntilLoaded()
        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = rig.service.downloadedSongCount } onChange: { fired.withLock { $0 = true } }

        rig.download(idA)
        _ = await rig.settles(idA, as: .downloaded)

        #expect(fired.withLock { $0 })
    }

    @Test("the Downloaded songs page: its own id, a title, the count, every song newest first, nothing to continue")
    func songsPage() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await download(rig, idA, idB)

        let page = rig.service.downloadedSongsPage()

        #expect(page.browseId == MusicDownloadService.songsBrowseId)
        #expect(MusicDownloadService.songsBrowseId == "DECI_DOWNLOADS")
        #expect(page.title == "Downloaded songs")
        #expect(page.subtitle == "2 songs")
        #expect(page.tracks.map(\.videoId) == [idB, idA])
        #expect(page.continuation == nil)
        #expect(page.shelves.isEmpty)
        #expect(page.thumbnailURL == nil)
        #expect(!page.isEditable)
    }

    @Test("the Downloaded songs page counts one song and none")
    func songsPageCounts() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await rig.service.waitUntilLoaded()
        #expect(rig.service.downloadedSongsPage().subtitle == "No songs")

        await download(rig, idA)

        #expect(rig.service.downloadedSongsPage().subtitle == "1 song")
    }

    // MARK: - Collections

    @Test("downloaded collections come newest first, each with its kind, title and stored subtitle")
    func collectionsNewestFirst() async throws {
        let backend = FakeMusicBackend()
        let rig = makeRig(backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        await rig.script("MPREb_album", tracks: DownloadSamples.tracks(3...4))
        rig.service.downloadCollection(rig.request(one, title: "Road trip"))
        await rig.service.waitUntilIdle()
        rig.clock.advance(by: 10)
        rig.service.downloadCollection(rig.request("MPREb_album", title: "Debut", kind: .album))
        await rig.service.waitUntilIdle()

        let collections = rig.service.downloadedCollections

        #expect(collections.map(\.browseId) == ["MPREb_album", one])
        #expect(collections.map(\.title) == ["Debut", "Road trip"])
        #expect(collections.map(\.kind) == [.album, .playlist])
        #expect(collections.map(\.subtitle) == ["Playlist", "Playlist"])
    }

    @Test("Liked music is a downloaded collection like the others")
    func likedMusicListed() async throws {
        let backend = FakeMusicBackend()
        let rig = makeRig(backend: backend)
        defer { rig.cleanUp() }
        await rig.script("VLLM", tracks: DownloadSamples.tracks(1...2), title: "Liked music")
        rig.service.downloadCollection(rig.request("VLLM", title: "Liked music"))
        await rig.service.waitUntilIdle()

        #expect(rig.service.downloadedCollections.map(\.browseId) == ["VLLM"])
    }

    @Test("a collection whose page has not been read yet is listed first, as Downloading")
    func pendingCollectionListed() async throws {
        let backend = FakeMusicBackend()
        let rig = makeRig(backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        rig.clock.advance(by: 10)
        let gate = MusicTestGate()
        await backend.setPageGate(two, gate)
        await rig.script(two, tracks: DownloadSamples.tracks(3...4))
        rig.service.downloadCollection(rig.request(two, title: "Next up"))
        #expect(await rig.eventually { await backend.pageCalls.contains(two) })

        let pending = rig.service.downloadedCollections

        #expect(pending.map(\.browseId) == [two, one])
        #expect(pending.first?.title == "Next up")
        #expect(pending.first?.subtitle == "Downloading")
        await gate.open()
        await rig.service.waitUntilIdle()
        #expect(rig.service.downloadedCollections.map(\.browseId) == [two, one])
        #expect(rig.service.downloadedCollections.first?.subtitle == "Playlist")
    }

    @Test("the ids a list lays its rows out from come in the order of the collections, a pending one first")
    func collectionIdsMatchTheList() async throws {
        let backend = FakeMusicBackend()
        let rig = makeRig(backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        rig.clock.advance(by: 10)
        let gate = MusicTestGate()
        await backend.setPageGate(two, gate)
        await rig.script(two, tracks: DownloadSamples.tracks(3...4))
        rig.service.downloadCollection(rig.request(two, title: "Next up"))
        #expect(await rig.eventually { await backend.pageCalls.contains(two) })

        #expect(rig.service.downloadedCollectionIds == [two, one])
        #expect(rig.service.downloadedCollectionIds == rig.service.downloadedCollections.map(\.browseId))
        await gate.open()
        await rig.service.waitUntilIdle()
        #expect(rig.service.downloadedCollectionIds == rig.service.downloadedCollections.map(\.browseId))
    }

    @Test("one collection is read by its id, the same as in the list, and an unknown id reads nothing")
    func oneCollectionById() async throws {
        let backend = FakeMusicBackend()
        let rig = makeRig(backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        rig.service.downloadCollection(rig.request(one, title: "Road trip"))
        await rig.service.waitUntilIdle()

        #expect(rig.service.downloadedCollection(browseId: one) == rig.service.downloadedCollections.first)
        #expect(rig.service.downloadedCollection(browseId: one)?.title == "Road trip")
        #expect(rig.service.downloadedCollection(browseId: "VLPLunknown") == nil)
    }

    @Test("a collection on its way says how far it has got")
    func collectionProgress() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let backend = FakeMusicBackend()
        // Song 1 takes requests 0 to 3; song 2 waits at its first.
        let rig = makeRig(handler: { request, index in
            if index == 4 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))

        rig.service.downloadCollection(rig.request(one))
        await rig.transport.waitForRequests(5)

        #expect(rig.service.downloadedCollections.first?.subtitle == "Downloading 1 of 3")
        await gate.open()
        await rig.service.waitUntilIdle()
        #expect(rig.service.downloadedCollections.first?.subtitle == "Playlist")
    }

    @Test("a collection with songs that did not arrive says how many did")
    func collectionPartial() async throws {
        let payload = DownloadSamples.payload(35)
        let backend = FakeMusicBackend()
        let rig = makeRig(handler: { request, _ in
            request.videoId == DownloadSamples.id(2)
                ? FakeDownloadTransport.status(404)
                : FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))

        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()

        #expect(rig.service.downloadedCollections.first?.subtitle == "2 of 3 downloaded")
    }

    @Test("a collection's cover is the saved file when there is one, else the address it came with")
    func collectionCover() async throws {
        let fetcher = FakeCoverFetcher(failing: { $0.absoluteString.contains("two") })
        let backend = FakeMusicBackend()
        let rig = makeRig(backend: backend, covers: fetcher)
        defer { rig.cleanUp() }
        let cover = "https://lh3.googleusercontent.com/col=w544-h544"
        await rig.script(one, tracks: DownloadSamples.tracks(1...2), cover: cover)
        await rig.script(two, tracks: DownloadSamples.tracks(3...4))
        rig.service.downloadCollection(rig.request(one, cover: cover))
        rig.service.downloadCollection(rig.request(two, cover: "https://example.test/two.jpg"))
        await rig.service.waitUntilIdle()

        let byID = Dictionary(uniqueKeysWithValues: rig.service.downloadedCollections.map { ($0.browseId, $0) })

        let saved = try #require(rig.service.localCoverURL(forCollection: one))
        #expect(byID[one]?.thumbnailURL == saved)
        #expect(rig.service.localCoverURL(forCollection: two) == nil)
        #expect(byID[two]?.thumbnailURL == URL(string: "https://example.test/two.jpg"))
    }

    // MARK: - A page from the index

    @Test("a stored collection's page: its title, subtitle and cover, and its songs in the stored order")
    func pageFromIndex() async throws {
        let fetcher = FakeCoverFetcher()
        let backend = FakeMusicBackend()
        let rig = makeRig(backend: backend, covers: fetcher)
        defer { rig.cleanUp() }
        let cover = "https://lh3.googleusercontent.com/col=w544-h544"
        let tracks = [3, 1, 2].map { DownloadSamples.track(id($0), title: "Song \($0)") }
        await rig.script(one, tracks: tracks, title: "Road trip", cover: cover)
        rig.service.downloadCollection(rig.request(one, title: "Road trip", cover: cover))
        await rig.service.waitUntilIdle()

        let page = try #require(rig.service.downloadedPage(browseId: one))

        #expect(page.browseId == one)
        #expect(page.title == "Road trip")
        #expect(page.subtitle == "Playlist")
        #expect(page.tracks.map(\.videoId) == [id(3), id(1), id(2)])
        #expect(page.tracks.map(\.title) == ["Song 3", "Song 1", "Song 2"])
        #expect(page.thumbnailURL == rig.service.localCoverURL(forCollection: one))
        #expect(page.thumbnailURL?.isFileURL == true)
        #expect(page.continuation == nil)
        #expect(page.shelves.isEmpty)
        #expect(!page.isEditable)
    }

    @Test("a page from the index lists only the songs that are on disk")
    func pageSkipsMissingSongs() async throws {
        let payload = DownloadSamples.payload(35)
        let backend = FakeMusicBackend()
        let rig = makeRig(handler: { request, _ in
            request.videoId == DownloadSamples.id(2)
                ? FakeDownloadTransport.status(404)
                : FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()

        let page = try #require(rig.service.downloadedPage(browseId: one))

        #expect(page.tracks.map(\.videoId) == [id(1), id(3)])
    }

    @Test("a page that is not a stored collection has nothing to show")
    func pageOfNothing() async throws {
        let backend = FakeMusicBackend()
        let rig = makeRig(backend: backend)
        defer { rig.cleanUp() }
        await rig.script(two, tracks: DownloadSamples.tracks(1...2))
        let gate = MusicTestGate()
        await backend.setPageGate(two, gate)
        rig.service.downloadCollection(rig.request(two))

        #expect(rig.service.downloadedPage(browseId: two) == nil)
        #expect(rig.service.downloadedPage(browseId: one) == nil)
        #expect(rig.service.downloadedPage(browseId: MusicDownloadService.songsBrowseId) == nil)
        await gate.open()
        await rig.service.waitUntilIdle()
    }

    // MARK: - Covers by address

    @Test("a remote cover address of any size maps to the saved file, and an unknown one to nothing")
    func coverForAddress() async throws {
        let fetcher = FakeCoverFetcher()
        let backend = FakeMusicBackend()
        let rig = makeRig(backend: backend, covers: fetcher)
        defer { rig.cleanUp() }
        let cover = "https://lh3.googleusercontent.com/col=w544-h544"
        let songs = [DownloadSamples.track(id(1)).withCover("https://lh3.googleusercontent.com/one=w544-h544")]
        await rig.script(one, tracks: songs, cover: cover)
        rig.service.downloadCollection(rig.request(one, cover: cover))
        await rig.service.waitUntilIdle()
        let songFile = try #require(rig.service.localCoverURL(forVideoId: id(1)))
        let collectionFile = try #require(rig.service.localCoverURL(forCollection: one))

        #expect(rig.service.localCoverURL(for: URL(string: "https://lh3.googleusercontent.com/one=w544-h544")) == songFile)
        #expect(rig.service.localCoverURL(for: URL(string: "https://lh3.googleusercontent.com/one=w60-h60")) == songFile)
        #expect(rig.service.localCoverURL(for: URL(string: cover)) == collectionFile)
        #expect(rig.service.localCoverURL(for: URL(string: "https://lh3.googleusercontent.com/other=w544-h544")) == nil)
        #expect(rig.service.localCoverURL(for: nil) == nil)
    }
}
