// DeciTests/Music/MusicDownloadOfflineTests.swift
// What downloads do when the network goes: the pump pauses, a song or a page cut by the loss is put back at the front of
// the queue (it is not a failure and it does not use up a back-off), the launch sync and the page-open sync wait for the
// network and run once when it returns, and the queue's requeue keeps the order. The connectivity is driven by hand
// through `MusicConnectivity.update`; the real downloader and store run against a fake transport and a scripted backend.

import Foundation
import os
import Testing
@testable import Deci

@Suite("MusicDownloadQueue requeue")
struct MusicDownloadQueueRequeueTests {
    private func track(_ number: Int) -> MusicTrack { DownloadSamples.track(DownloadSamples.id(number)) }
    private func ids(_ numbers: [Int]) -> [String] { numbers.map(DownloadSamples.id) }

    private func drain(_ queue: inout MusicDownloadQueue) -> [String] {
        var order: [String] = []
        while let job = queue.next() {
            switch job {
            case .collection(let browseId): order.append("collection:\(browseId)")
            case .song(let track): order.append(track.videoId)
            }
        }
        return order
    }

    @Test("a standalone song put back runs before the standalone songs still waiting")
    func standaloneGoesFirst() {
        var queue = MusicDownloadQueue()
        queue.enqueueStandalone(track(20))
        queue.enqueueStandalone(track(21))
        queue.enqueueListed(track(1))
        queue.enqueueListed(track(2))
        guard case .song(let taken)? = queue.next() else {
            Issue.record("the first job is a song")
            return
        }
        #expect(taken.videoId == DownloadSamples.id(20))

        queue.requeueFront(taken, standalone: true)

        #expect(queue.songCount == 4)
        #expect(queue.isStandalone(DownloadSamples.id(20)))
        #expect(drain(&queue) == ids([20, 21, 1, 2]))
    }

    @Test("a collection song put back runs before the collection songs still waiting, and after the standalone ones")
    func listedGoesFirst() {
        var queue = MusicDownloadQueue()
        for number in 1...3 { queue.enqueueListed(track(number)) }
        guard case .song(let taken)? = queue.next() else {
            Issue.record("the first job is a song")
            return
        }
        queue.enqueueStandalone(track(20))

        queue.requeueFront(taken, standalone: false)

        #expect(!queue.isStandalone(DownloadSamples.id(1)))
        #expect(drain(&queue) == ids([20, 1, 2, 3]))
    }

    @Test("putting back several songs in turn keeps the order they were taken in")
    func severalPutBack() {
        var queue = MusicDownloadQueue()
        for number in 1...4 { queue.enqueueListed(track(number)) }
        var taken: [MusicTrack] = []
        for _ in 0..<2 {
            if case .song(let next)? = queue.next() { taken.append(next) }
        }

        // The newest first: the song taken last goes back first, so the song taken first ends up in front.
        for song in taken.reversed() { queue.requeueFront(song, standalone: false) }

        #expect(drain(&queue) == ids([1, 2, 3, 4]))
    }

    @Test("a song that waits already is not queued twice")
    func noDuplicates() {
        var queue = MusicDownloadQueue()
        queue.enqueueListed(track(1))

        queue.requeueFront(track(1), standalone: false)
        queue.requeueFront(track(1), standalone: true)

        #expect(queue.songCount == 1)
        #expect(drain(&queue) == ids([1]))
    }

    @Test("a collection listing put back runs before the listings waiting, and once")
    func collectionPutBack() {
        var queue = MusicDownloadQueue()
        queue.enqueueCollection("VLPLtwo")
        queue.enqueueListed(track(1))

        queue.requeueCollection("VLPLone")
        queue.requeueCollection("VLPLone")
        queue.requeueCollection("VLPLtwo")

        #expect(drain(&queue) == ["collection:VLPLone", "collection:VLPLtwo"] + ids([1]))
    }

    @Test("a standalone song put back can still be demoted to the collection songs")
    func demoteAfterRequeue() {
        var queue = MusicDownloadQueue()
        for number in 1...3 { queue.enqueueListed(track(number)) }
        queue.enqueueStandalone(track(2))
        guard case .song(let taken)? = queue.next() else {
            Issue.record("the first job is a song")
            return
        }
        #expect(taken.videoId == DownloadSamples.id(2))
        queue.requeueFront(taken, standalone: true)

        queue.demote(DownloadSamples.id(2))

        #expect(!queue.isStandalone(DownloadSamples.id(2)))
        #expect(drain(&queue).sorted() == ids([1, 2, 3]))
    }
}

@MainActor
@Suite("MusicDownloadOffline")
struct MusicDownloadOfflineTests {
    private let one = "VLPLone"
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB

    private func id(_ number: Int) -> String { DownloadSamples.id(number) }
    private func ids(_ numbers: Int...) -> [String] { numbers.map(DownloadSamples.id) }

    private func record(_ rig: DownloadServiceRig, _ browseId: String) async -> MusicDownloadStore.Collection? {
        await rig.store.collectionList()[browseId]
    }

    // MARK: - Songs

    @Test("a song asked for offline waits, with no request and no rest, and downloads when the network returns")
    func songQueuedOffline() async throws {
        let connectivity = MusicConnectivity(isOnline: false)
        let rig = DownloadServiceRig(connectivity: connectivity)
        defer { rig.cleanUp() }

        rig.download(idA)
        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: idA) == .queued)
        #expect(await rig.transport.requestCount == 0)
        #expect(rig.pause.waits.isEmpty)

        connectivity.update(isOnline: true)

        #expect(await rig.settles(idA, as: .downloaded))
        #expect(await rig.requestedSongs == [idA])
    }

    @Test("the network vanishing mid-song puts the song back, not into failed, and the queue waits")
    func networkVanishesMidSong() async throws {
        let payload = DownloadSamples.payload(35)
        let connectivity = MusicConnectivity()
        let rig = DownloadServiceRig(handler: { request, index in
            if index == 1 {
                await connectivity.update(isOnline: false)
                throw URLError(.notConnectedToInternet)
            }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, connectivity: connectivity)
        defer { rig.cleanUp() }

        rig.download(idA)
        rig.download(idB)
        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: idA) == .queued)
        #expect(rig.service.state(for: idB) == .queued)
        #expect(await rig.requestedIDs == [idA, idA])
        #expect(rig.pause.waits.isEmpty)
        // Nothing half-written is left on disk.
        #expect(rig.folder.audioFiles.isEmpty)

        connectivity.update(isOnline: true)

        #expect(await rig.settles(idA, as: .downloaded))
        #expect(rig.service.state(for: idB) == .downloaded)
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
        #expect(rig.folder.read(rig.folder.audioURL(idB)) == payload)
    }

    @Test("a network that is gone and back before the song's error arrives still retries the song")
    func flapDuringSong() async throws {
        let payload = DownloadSamples.payload(35)
        let connectivity = MusicConnectivity()
        let rig = DownloadServiceRig(handler: { request, index in
            if index == 1 {
                await connectivity.update(isOnline: false)
                await connectivity.update(isOnline: true)
                throw URLError(.networkConnectionLost)
            }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, connectivity: connectivity)
        defer { rig.cleanUp() }

        rig.download(idA)

        #expect(await rig.settles(idA, as: .downloaded))
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
    }

    @Test("a back-off cut short by the network going is not used up: the song starts its back-offs afresh online")
    func backoffNotConsumed() async throws {
        let payload = DownloadSamples.payload(35)
        let connectivity = MusicConnectivity()
        let rig = DownloadServiceRig(handler: { request, index in
            if index == 0 { return FakeDownloadTransport.status(429) }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, connectivity: connectivity)
        defer { rig.cleanUp() }
        rig.pause.blockBackoff()
        rig.pause.onWait { _, seconds in
            if seconds >= 1 { await connectivity.update(isOnline: false) }
        }

        rig.download(idA)
        await rig.service.waitUntilIdle()

        #expect(rig.pause.backoffs == [30])
        #expect(rig.service.state(for: idA) == .queued)

        rig.pause.blockBackoff(false)
        rig.pause.onWait(nil)
        connectivity.update(isOnline: true)

        #expect(await rig.settles(idA, as: .downloaded))
        #expect(rig.pause.backoffs == [30])
    }

    @Test("a song that really failed stays failed through a trip offline and back")
    func realFailureStaysFailed() async throws {
        let connectivity = MusicConnectivity()
        let rig = DownloadServiceRig(handler: { _, _ in FakeDownloadTransport.status(404) }, connectivity: connectivity)
        defer { rig.cleanUp() }
        rig.download(idA)
        #expect(await rig.settles(idA, as: .failed))
        let requests = await rig.transport.requestCount

        connectivity.update(isOnline: false)
        connectivity.update(isOnline: true)
        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: idA) == .failed)
        #expect(await rig.transport.requestCount == requests)
    }

    @Test("a song removed while offline is never fetched")
    func removeWhileOffline() async throws {
        let connectivity = MusicConnectivity(isOnline: false)
        let rig = DownloadServiceRig(connectivity: connectivity)
        defer { rig.cleanUp() }
        rig.download(idA)
        rig.download(idB)

        rig.service.remove(videoId: idA)
        connectivity.update(isOnline: true)

        #expect(await rig.settles(idB, as: .downloaded))
        #expect(rig.service.state(for: idA) == .none)
        #expect(await rig.requestedSongs == [idB])
    }

    // MARK: - Collections

    @Test("a collection asked for offline reads its page and downloads once the network returns")
    func collectionAskedOffline() async throws {
        let connectivity = MusicConnectivity(isOnline: false)
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(backend: backend, connectivity: connectivity)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))

        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()

        #expect(await backend.pageCalls.isEmpty)
        #expect(rig.service.collectionState(for: one) == .downloading(done: 0, total: 0, fraction: 0))

        connectivity.update(isOnline: true)
        await rig.service.waitUntilIdle()

        #expect(await backend.pageCalls == [one])
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 2))
        #expect(try #require(await record(rig, one)).syncResult == .complete)
    }

    @Test("the network going while the first page is being read keeps the request and reads the page again")
    func firstReadCut() async throws {
        let connectivity = MusicConnectivity()
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(backend: backend, connectivity: connectivity)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        let gate = MusicTestGate()
        await backend.setPageGate(one, gate)
        await backend.queuePageErrors(one, [URLError(.notConnectedToInternet)])

        rig.service.downloadCollection(rig.request(one))
        #expect(await rig.eventually { await backend.pageCalls.count == 1 })
        connectivity.update(isOnline: false)
        await gate.open()
        await rig.service.waitUntilIdle()

        #expect(rig.service.collectionState(for: one) == .downloading(done: 0, total: 0, fraction: 0))
        #expect(await record(rig, one) == nil)

        connectivity.update(isOnline: true)
        await rig.service.waitUntilIdle()

        #expect(await backend.pageCalls == [one, one])
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 2))
    }

    @Test("the network going mid-collection leaves the rest queued and the record unfinished until it returns")
    func midCollectionCut() async throws {
        let payload = DownloadSamples.payload(35)
        let connectivity = MusicConnectivity()
        let backend = FakeMusicBackend()
        // Song 1 takes requests 0 to 3; the network goes on the second request of song 2.
        let rig = DownloadServiceRig(handler: { request, index in
            if index == 5 {
                await connectivity.update(isOnline: false)
                throw URLError(.notConnectedToInternet)
            }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: backend, connectivity: connectivity)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))

        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(rig.service.state(for: id(2)) == .queued)
        #expect(rig.service.state(for: id(3)) == .queued)
        #expect(rig.service.collectionState(for: one) == .downloading(done: 1, total: 3, fraction: 1.0 / 3.0))
        let paused = try #require(await record(rig, one))
        #expect(paused.lastSyncedAt == nil)

        connectivity.update(isOnline: true)
        await rig.service.waitUntilIdle()

        #expect(rig.service.collectionState(for: one) == .downloaded(done: 3, total: 3))
        #expect(try #require(await record(rig, one)).syncResult == .complete)
        #expect(await rig.requestedSongs == ids(1, 2, 3))
        #expect(await rig.requestCount(for: id(1)) == 4)
    }

    @Test("a sync cut by the network is not an unreachable page: the last result stays, and the page is read again")
    func syncCut() async throws {
        let connectivity = MusicConnectivity()
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(backend: backend, connectivity: connectivity)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        #expect(try #require(await record(rig, one)).syncResult == .complete)
        let gate = MusicTestGate()
        await backend.setPageGate(one, gate)
        await backend.queuePageErrors(one, [URLError(.networkConnectionLost)])

        rig.service.sync(one)
        #expect(await rig.eventually { await backend.pageCalls.count == 2 })
        connectivity.update(isOnline: false)
        await gate.open()
        await rig.service.waitUntilIdle()

        #expect(try #require(await record(rig, one)).syncResult == .complete)

        connectivity.update(isOnline: true)
        await rig.service.waitUntilIdle()

        #expect(await backend.pageCalls.count == 3)
        #expect(try #require(await record(rig, one)).syncResult == .complete)
    }

    // MARK: - Syncs that start by themselves

    @Test("the launch sync waits for the network, then runs once, however often the network flaps")
    func launchSyncDeferred() async throws {
        let first = DownloadServiceRig(backend: FakeMusicBackend())
        await first.script(one, tracks: DownloadSamples.tracks(1...2))
        first.service.downloadCollection(first.request(one))
        await first.service.waitUntilIdle()
        let connectivity = MusicConnectivity(isOnline: false)
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(folder: first.folder, backend: backend, connectivity: connectivity)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))

        rig.service.signInKnown()
        await rig.service.waitUntilIdle()
        #expect(await backend.pageCalls.isEmpty)

        connectivity.update(isOnline: true)
        await rig.service.waitUntilIdle()
        #expect(await backend.pageCalls == [one])

        connectivity.update(isOnline: false)
        connectivity.update(isOnline: true)
        await rig.service.waitUntilIdle()
        #expect(await backend.pageCalls == [one])
    }

    @Test("a downloaded page opened offline syncs when the network returns, under the ten minute rule")
    func pageOpenDeferred() async throws {
        let connectivity = MusicConnectivity()
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(backend: backend, connectivity: connectivity)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        rig.clock.advance(by: 700)

        connectivity.update(isOnline: false)
        rig.service.pageOpened(one)
        await rig.service.waitUntilIdle()
        #expect(await backend.pageCalls == [one])

        connectivity.update(isOnline: true)
        await rig.service.waitUntilIdle()
        #expect(await backend.pageCalls == [one, one])

        // Opened again, offline, within ten minutes of that read: nothing to do when the network returns.
        rig.clock.advance(by: 100)
        connectivity.update(isOnline: false)
        rig.service.pageOpened(one)
        connectivity.update(isOnline: true)
        await rig.service.waitUntilIdle()
        #expect(await backend.pageCalls == [one, one])
    }

    @Test("a page opened offline that is not downloaded is forgotten, not synced on return")
    func pageOpenOfOtherPage() async throws {
        let connectivity = MusicConnectivity(isOnline: false)
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(backend: backend, connectivity: connectivity)
        defer { rig.cleanUp() }

        rig.service.pageOpened("VLPLother")
        connectivity.update(isOnline: true)
        await rig.service.waitUntilIdle()

        #expect(await backend.pageCalls.isEmpty)
    }
}
