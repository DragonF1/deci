// DeciTests/Music/MusicDownloadRemoveAllServiceTests.swift
// "Remove all downloads" in the service: what runs is stopped first (the song on its way, the songs and listings that
// wait, the cover being fetched, a page being read), nothing that finishes late can bring a song or a collection back,
// changes that were waiting for their timer do not come back either, the song playing keeps its file until playback
// leaves it, and afterwards every state, count and list reads zero and the service downloads again. The real store and
// downloader run against a fake transport and a scripted backend, in a folder under /Volumes/Storage/_test shaped like
// Application Support/Deci/Downloads. Nothing touches the network.

import Foundation
import os
import Testing
@testable import Deci

/// A transport handler that parks the first request of one song until `gate` opens.
nonisolated final class WipeSongGate: Sendable {
    let gate = MusicTestGate()
    private let held = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let payload = DownloadSamples.payload(35)

    func hold(_ videoId: String) { held.withLock { $0 = videoId } }

    var handler: FakeDownloadTransport.Handler {
        { [self] request, _ in
            if request.range.lowerBound == 0, held.withLock({ $0 }) == request.videoId { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
    }
}

/// Says a removal that runs in a task of its own has ended.
@MainActor
private final class RemovalProbe {
    private(set) var wipe: MusicDownloadStore.Wipe?
    var isDone: Bool { wipe != nil }

    func start(_ service: MusicDownloadService) {
        Task { @MainActor in wipe = await service.removeAll() }
    }
}

@MainActor
@Suite("MusicDownloadRemoveAllService")
struct MusicDownloadRemoveAllServiceTests {
    private let one = "VLPLone"
    private let two = "VLPLtwo"

    private func id(_ number: Int) -> String { DownloadSamples.id(number) }
    private func ids(_ range: ClosedRange<Int>) -> [String] { range.map(DownloadSamples.id) }

    private func makeRig(
        songs: WipeSongGate = WipeSongGate(), shaped: Bool = true, covers: (any MusicCoverFetching)? = nil,
        idleTimeout: Duration = MusicDownloadService.idleTimeout
    ) -> DownloadServiceRig {
        DownloadServiceRig(
            folder: DownloadTestFolder(shaped: shaped), handler: songs.handler, backend: FakeMusicBackend(), covers: covers,
            idleTimeout: idleTimeout
        )
    }

    /// Starts the removal in a task of its own and returns once it has begun.
    private func startRemoval(_ rig: DownloadServiceRig) async -> RemovalProbe {
        let probe = RemovalProbe()
        probe.start(rig.service)
        // A removal with nothing to wait for may be over before the first look.
        _ = await rig.eventually { rig.service.isRemovingAll || probe.isDone }
        return probe
    }

    // MARK: - The plain case

    @Test("a song, a playlist and a cover are deleted, and every count and state reads zero afterwards")
    func removesEverythingAndReadsZero() async throws {
        let rig = makeRig(covers: FakeCoverFetcher())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3), cover: "https://img.example.test/cover=w544-h544")
        rig.service.downloadCollection(rig.request(one))
        rig.download(id(9))
        await rig.service.waitUntilIdle()
        #expect(rig.service.downloadedSongCount == 4)
        #expect(rig.folder.rootFiles.contains("covers"))

        let wipe = await rig.service.removeAll()

        #expect(!wipe.refused)
        #expect(wipe.failed == 0)
        #expect(wipe.removed > 0)
        #expect(!rig.service.isRemovingAll)
        #expect(rig.service.downloadedSongCount == 0)
        #expect(rig.service.downloadedSongs.isEmpty)
        #expect(rig.service.downloadedCollectionIds.isEmpty)
        #expect(rig.service.collectionState(for: one) == .none)
        for number in [1, 2, 3, 9] {
            #expect(rig.service.state(for: id(number)) == .none)
            #expect(rig.service.localStream(for: id(number)) == nil)
        }
        #expect(rig.service.localCoverURL(forCollection: one) == nil)
        #expect(rig.folder.rootFiles == ["downloads.json"])
        #expect(await rig.store.collectionList().isEmpty)
        #expect(await rig.store.entries.isEmpty)
        let index = try #require(rig.folder.read(rig.folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
        #expect(index.entries.isEmpty && index.collections.isEmpty)
    }

    @Test("downloading works again after the wipe, a song and a whole playlist")
    func downloadsAgainAfterTheWipe() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        rig.service.downloadCollection(rig.request(one))
        rig.download(id(9))
        await rig.service.waitUntilIdle()
        await rig.service.removeAll()

        rig.download(id(9))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: id(9)) == .downloaded)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 2))
        #expect(rig.service.downloadedSongCount == 3)
        #expect(await rig.store.collectionList().keys.sorted() == [one])
    }

    // MARK: - Work that is running

    @Test("the song on its way is stopped, waiting songs and listings are never fetched, and no part file is left")
    func cancelsInFlightAndQueuedWork() async throws {
        let songs = WipeSongGate()
        let rig = makeRig(songs: songs)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        await rig.script(two, tracks: DownloadSamples.tracks(4...5))
        songs.hold(id(2))
        rig.service.downloadCollection(rig.request(one))
        rig.service.downloadCollection(rig.request(two))
        rig.download(id(9))
        #expect(await rig.eventually { await rig.requestCount(for: id(2)) == 1 })
        #expect(rig.service.state(for: id(2)) == .downloading(fraction: 0))
        #expect(rig.service.state(for: id(3)) == .queued)

        let removal = await startRemoval(rig)
        // At once, before the disk has caught up, nothing reads as downloaded, queued or on its way.
        for number in [1, 2, 3, 4, 5, 9] { #expect(rig.service.state(for: id(number)) == .none) }
        #expect(rig.service.collectionState(for: one) == .none)
        #expect(rig.service.collectionState(for: two) == .none)
        #expect(rig.service.downloadedCollectionIds.isEmpty)
        await songs.gate.open()
        #expect(await rig.eventually { removal.isDone })
        await rig.service.waitUntilIdle()

        #expect(await rig.requestedSongs == [id(9), id(1), id(2)])
        #expect(rig.folder.rootFiles == ["downloads.json"])
        #expect(await rig.store.collectionList().isEmpty)
        #expect(await rig.store.entries.isEmpty)
        for number in [1, 2, 3, 4, 5, 9] { #expect(rig.service.state(for: id(number)) == .none) }
    }

    @Test("a song that failed is cleared too: its state reads none, not failed")
    func clearsFailures() async throws {
        let rig = DownloadServiceRig(
            folder: DownloadTestFolder(shaped: true),
            handler: { _, _ in FakeDownloadTransport.status(404) }
        )
        defer { rig.cleanUp() }
        rig.download(id(1))
        #expect(await rig.settles(id(1), as: .failed))

        await rig.service.removeAll()

        #expect(rig.service.state(for: id(1)) == .none)
    }

    @Test("a rest after a rate limit does not hold the removal up")
    func removalDoesNotWaitOutARateLimitRest() async throws {
        let pause = RecordingPause()
        // The ten minute rest parks until it is cancelled, as the real one does.
        pause.onWait { _, seconds in
            if seconds >= MusicDownloadService.rateLimitHold { try? await Task.sleep(for: .seconds(3_600)) }
        }
        let rig = DownloadServiceRig(
            folder: DownloadTestFolder(shaped: true),
            handler: { _, _ in FakeDownloadTransport.status(429) },
            pause: pause
        )
        defer { rig.cleanUp() }
        rig.download(id(1))
        rig.download(id(2))
        // Three back-offs, then the rest: song 2 still waits behind it.
        #expect(await rig.eventually { pause.waits.count >= 4 })
        #expect(pause.waits.last == MusicDownloadService.rateLimitHold)

        let removal = await startRemoval(rig)

        #expect(await rig.eventually { removal.isDone })
        #expect(rig.service.state(for: id(2)) == .none)
        #expect(await rig.requestedSongs == [id(1)])
        #expect(rig.folder.rootFiles == ["downloads.json"])
    }

    @Test("a cover being fetched is finished before the wipe, so it cannot be written after it")
    func coverInFlightDoesNotComeBack() async throws {
        let gate = MusicTestGate()
        let fetcher = FakeCoverFetcher(gate: gate)
        let rig = makeRig(covers: fetcher)
        defer { rig.cleanUp() }
        rig.service.download(DownloadSamples.track(id(1)).withCover("https://img.example.test/a=w120-h120"))
        #expect(await rig.eventually { await fetcher.requested.count == 1 })
        #expect(rig.service.state(for: id(1)) == .downloaded)

        let removal = await startRemoval(rig)
        await gate.open()
        #expect(await rig.eventually { removal.isDone })
        await rig.service.waitUntilIdle()

        #expect(rig.folder.rootFiles == ["downloads.json"])
        #expect(rig.service.downloadedSongCount == 0)
        #expect(rig.service.localCoverURL(forVideoId: id(1)) == nil)
    }

    // MARK: - Results that arrive late

    @Test("a sync whose page is read after the wipe adds nothing and downloads nothing")
    func lateSyncResultDoesNotResurrect() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let backend = try #require(rig.backend)
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        // The page has grown: a sync that finished would queue songs 4 to 6.
        await rig.script(one, tracks: DownloadSamples.tracks(1...6))
        let gate = MusicTestGate()
        await backend.setPageGate(one, gate)
        rig.service.sync(one)
        #expect(await rig.eventually { await backend.pageCalls.count == 2 })

        let removal = await startRemoval(rig)
        await gate.open()
        #expect(await rig.eventually { removal.isDone })
        await rig.service.waitUntilIdle()

        #expect(await rig.requestedSongs == ids(1...3))
        #expect(await rig.store.collectionList().isEmpty)
        #expect(await rig.store.entries.isEmpty)
        #expect(rig.service.downloadedCollectionIds.isEmpty)
        #expect(rig.service.collectionState(for: one) == .none)
        for number in 1...6 { #expect(rig.service.state(for: id(number)) == .none) }
        #expect(rig.folder.rootFiles == ["downloads.json"])
    }

    @Test("a first download whose page is read after the wipe stores no collection and fetches no song")
    func lateFirstReadDoesNotResurrect() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let backend = try #require(rig.backend)
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        let gate = MusicTestGate()
        await backend.setPageGate(one, gate)
        rig.service.downloadCollection(rig.request(one))
        #expect(await rig.eventually { await backend.pageCalls.count == 1 })
        #expect(rig.service.collectionState(for: one) == .downloading(done: 0, total: 0, fraction: 0))

        let removal = await startRemoval(rig)
        #expect(rig.service.collectionState(for: one) == .none)
        await gate.open()
        #expect(await rig.eventually { removal.isDone })
        await rig.service.waitUntilIdle()

        #expect(await rig.requestedIDs.isEmpty)
        #expect(await rig.store.collectionList().isEmpty)
        #expect(rig.service.downloadedCollectionIds.isEmpty)
        #expect(rig.service.collectionState(for: one) == .none)
        // Nothing was ever written, so the wipe has nothing to clear and creates nothing.
        #expect(rig.folder.rootFiles.isEmpty)
    }

    @Test("index changes that were waiting for their timer are not written after the wipe")
    func pendingWritesDoNotResurrect() async throws {
        let songs = WipeSongGate()
        let rig = makeRig(songs: songs)
        defer { rig.cleanUp() }
        songs.hold(id(2))
        rig.download(id(1))
        rig.download(id(2))
        #expect(await rig.eventually { await rig.requestCount(for: id(2)) == 1 })
        // Song 1 is on disk and listed in memory, and the index does not say so yet.
        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(rig.folder.read(rig.folder.indexURL) == nil)

        let removal = await startRemoval(rig)
        await songs.gate.open()
        #expect(await rig.eventually { removal.isDone })
        await rig.service.waitUntilIdle()
        await rig.store.flushIndex()

        let index = try #require(rig.folder.read(rig.folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
        #expect(index.entries.isEmpty)
        #expect(rig.folder.rootFiles == ["downloads.json"])
        #expect(await rig.store.entries.isEmpty)
    }

    // MARK: - While it runs

    @Test("downloads asked for while the removal runs are ignored, and a second removal does nothing")
    func requestsDuringTheRemovalAreIgnored() async throws {
        let songs = WipeSongGate()
        let rig = makeRig(songs: songs)
        defer { rig.cleanUp() }
        await rig.script(two, tracks: DownloadSamples.tracks(4...5))
        songs.hold(id(1))
        rig.download(id(1))
        #expect(await rig.eventually { await rig.requestCount(for: id(1)) == 1 })
        let removal = await startRemoval(rig)
        #expect(rig.service.isRemovingAll)

        rig.download(id(9))
        rig.service.downloadCollection(rig.request(two))
        rig.service.sync(two)
        let second = await rig.service.removeAll()

        #expect(second == MusicDownloadStore.Wipe())
        #expect(rig.service.state(for: id(9)) == .none)
        #expect(rig.service.collectionState(for: two) == .none)
        await songs.gate.open()
        #expect(await rig.eventually { removal.isDone })
        await rig.service.waitUntilIdle()

        #expect(await rig.requestedSongs == [id(1)])
        #expect(rig.service.state(for: id(9)) == .none)
        #expect(rig.service.collectionState(for: two) == .none)
        #expect(rig.folder.rootFiles == ["downloads.json"])
    }

    // MARK: - The song that is playing

    @Test("the song playing from its file keeps it until playback leaves, then the file goes")
    func playingFileIsDeletedWhenPlaybackLeaves() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.download(id(1))
        rig.download(id(2))
        await rig.service.waitUntilIdle()
        rig.service.noteLocalPlayback(of: id(1))

        await rig.service.removeAll()

        #expect(rig.folder.audioFiles == ["\(id(1)).m4a"])
        #expect(rig.service.state(for: id(1)) == .none)
        #expect(rig.service.state(for: id(2)) == .none)
        #expect(rig.service.downloadedSongCount == 0)
        #expect(rig.service.localStream(for: id(1)) == nil)

        rig.service.noteLocalPlayback(of: id(3))
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles.isEmpty)
    }

    @Test("a song downloaded again while its old file is kept for the player is not deleted when playback leaves")
    func playingFileDownloadedAgainSurvives() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        rig.service.noteLocalPlayback(of: id(1))
        await rig.service.removeAll()

        rig.download(id(1))
        await rig.service.waitUntilIdle()
        rig.service.noteLocalPlayback(of: id(3))
        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(rig.folder.audioFiles == ["\(id(1)).m4a"])
    }

    @Test("deleting the kept file once playback leaves is a change of the disk the counts do not show, and leaves no folder")
    func keptFileDeletionBumpsTheDiskRevision() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        rig.service.noteLocalPlayback(of: id(1))
        await rig.service.removeAll()
        let before = rig.service.diskRevision

        rig.service.noteLocalPlayback(of: id(3))
        await rig.service.waitUntilIdle()

        #expect(rig.service.diskRevision > before)
        #expect(rig.folder.rootFiles == ["downloads.json"])
        #expect(rig.service.downloadedSongCount == 0)
    }

    @Test("a wipe is a change of the disk, and a song finishing alone is not (its count says so)")
    func diskRevisionMeansChangesCountsDoNotShow() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        #expect(rig.service.diskRevision == 0)
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        #expect(rig.service.diskRevision == 0)

        await rig.service.removeAll()

        #expect(rig.service.diskRevision > 0)
    }

    @Test("a cover picture saved is a change of the disk the counts do not show")
    func coverSaveBumpsTheDiskRevision() async throws {
        let rig = makeRig(covers: FakeCoverFetcher())
        defer { rig.cleanUp() }
        rig.service.download(DownloadSamples.track(id(1)).withCover("https://img.example.test/a=w120-h120"))
        await rig.service.waitUntilIdle()

        #expect(rig.service.diskRevision > 0)
        #expect(rig.service.localCoverURL(forVideoId: id(1)) != nil)
    }

    @Test("the collection count is the length of the list, stored and on their way alike")
    func collectionCountMatchesTheList() async throws {
        let gate = MusicTestGate()
        let rig = makeRig()
        defer { rig.cleanUp() }
        let backend = try #require(rig.backend)
        #expect(rig.service.downloadedCollectionCount == 0)
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        #expect(rig.service.downloadedCollectionCount == 1)

        await rig.script(two, tracks: DownloadSamples.tracks(3...4))
        await backend.setPageGate(two, gate)
        rig.service.downloadCollection(rig.request(two))
        #expect(await rig.eventually { await backend.pageCalls.count >= 2 })

        // One stored and one still being read.
        #expect(rig.service.downloadedCollectionIds.count == 2)
        #expect(rig.service.downloadedCollectionCount == 2)
        await gate.open()
        await rig.service.waitUntilIdle()
        #expect(rig.service.downloadedCollectionCount == rig.service.downloadedCollectionIds.count)
    }

    // MARK: - A removal that cannot wait for ever

    @Test("work that never ends does not hold the wipe up for ever: it goes ahead after the idle limit, and the late result adds nothing")
    func hungWorkIsNotWaitedOutForEver() async throws {
        let rig = makeRig(idleTimeout: .milliseconds(150))
        defer { rig.cleanUp() }
        let backend = try #require(rig.backend)
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        await rig.script(one, tracks: DownloadSamples.tracks(1...6))
        let gate = MusicTestGate()
        await backend.setPageGate(one, gate)
        rig.service.sync(one)
        #expect(await rig.eventually { await backend.pageCalls.count == 2 })

        // The page read never answers; the removal must not wait for it.
        let removal = await startRemoval(rig)
        #expect(await rig.eventually { removal.isDone }, "the removal waited for work that never ends")
        #expect(!rig.service.isRemovingAll)
        #expect(rig.service.downloadedSongCount == 0)
        #expect(rig.service.downloadedCollectionIds.isEmpty)
        #expect(rig.folder.rootFiles == ["downloads.json"])

        // The page answers at last: it finds a service that was wiped and adds nothing.
        await gate.open()
        await rig.service.waitUntilIdle()
        #expect(await rig.requestedSongs == ids(1...3))
        #expect(await rig.store.collectionList().isEmpty)
        #expect(await rig.store.entries.isEmpty)
        #expect(rig.service.downloadedCollectionIds.isEmpty)
        #expect(rig.service.collectionState(for: one) == .none)
        #expect(rig.folder.rootFiles == ["downloads.json"])
    }

    @Test("a song that never finishes is stopped, the wipe goes ahead, and the song that comes back late is deleted again")
    func hungSongIsDeletedWhenItComesBack() async throws {
        let songs = WipeSongGate()
        let rig = makeRig(songs: songs, idleTimeout: .milliseconds(150))
        defer { rig.cleanUp() }
        songs.hold(id(1))
        rig.download(id(1))
        #expect(await rig.eventually { await rig.requestCount(for: id(1)) == 1 })

        let removal = await startRemoval(rig)
        #expect(await rig.eventually { removal.isDone }, "the removal waited for a song that never ends")
        #expect(rig.service.state(for: id(1)) == .none)

        await songs.gate.open()
        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: id(1)) == .none)
        #expect(rig.service.downloadedSongCount == 0)
        #expect(rig.folder.audioFiles.isEmpty)
        #expect(await rig.store.entries.isEmpty)
    }

    // MARK: - Refusal and failure

    @Test("a refused wipe cancels nothing: the download on its way finishes and what was downloaded stays")
    func refusalChangesNothing() async throws {
        let songs = WipeSongGate()
        let rig = makeRig(songs: songs, shaped: false)
        defer { rig.cleanUp() }
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        songs.hold(id(2))
        rig.download(id(2))
        #expect(await rig.eventually { await rig.requestCount(for: id(2)) == 1 })

        let wipe = await rig.service.removeAll()

        #expect(wipe.refused)
        #expect(!rig.service.isRemovingAll)
        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(rig.service.state(for: id(2)) == .downloading(fraction: 0))
        await songs.gate.open()
        await rig.service.waitUntilIdle()
        #expect(rig.service.state(for: id(2)) == .downloaded)
        #expect(rig.folder.audioFiles == ["\(id(1)).m4a", "\(id(2)).m4a"])
    }

    @Test("a file that cannot be deleted stays downloaded: the service reads what the store kept")
    func survivorsStayDownloaded() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.folder.audioDirectory.path)
        defer { try? rig.folder.unlock(rig.folder.audioDirectory, isDirectory: true) }

        let wipe = await rig.service.removeAll()

        #expect(wipe.failed > 0)
        #expect(!rig.service.isRemovingAll)
        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(rig.service.downloadedSongCount == 1)
        try rig.folder.unlock(rig.folder.audioDirectory, isDirectory: true)
        #expect(rig.folder.audioFiles == ["\(id(1)).m4a"])
    }
}
