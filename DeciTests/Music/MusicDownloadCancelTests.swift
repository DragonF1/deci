// DeciTests/Music/MusicDownloadCancelTests.swift
// Cancel and Remove on a downloaded playlist or album. Cancelling a first download drops the collection; cancelling an
// update of a finished one only stops the fetching, and Remove deletes. The real store and downloader run against a fake
// transport and a scripted backend; every test works in a folder of its own under /Volumes/Storage/_test. Nothing touches
// the network.

import Foundation
import os
import Testing
@testable import Deci

/// A transport handler that can park the first request of one song until `gate` opens, and answer other songs with a 404.
private nonisolated final class SongGate: Sendable {
    let gate = MusicTestGate()
    private let held = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let failing = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private let payload = DownloadSamples.payload(35)

    /// From now on the first request of `videoId` waits at the gate.
    func hold(_ videoId: String) { held.withLock { $0 = videoId } }

    /// From now on exactly these songs answer with a 404.
    func fail(_ videoIds: Set<String>) { failing.withLock { $0 = videoIds } }

    var handler: FakeDownloadTransport.Handler {
        { [self] request, _ in
            if failing.withLock({ $0.contains(request.videoId) }) { return FakeDownloadTransport.status(404) }
            if request.range.lowerBound == 0, held.withLock({ $0 }) == request.videoId { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
    }
}

@MainActor
@Suite("MusicDownloadCancel")
struct MusicDownloadCancelTests {
    private let one = "VLPLone"
    private let two = "VLPLtwo"

    private func id(_ number: Int) -> String { DownloadSamples.id(number) }
    private func ids(_ range: ClosedRange<Int>) -> [String] { range.map(DownloadSamples.id) }
    private func file(_ number: Int) -> String { "\(id(number)).m4a" }
    private func files(_ range: ClosedRange<Int>) -> [String] { range.map(file) }

    private func record(_ rig: DownloadServiceRig, _ browseId: String? = nil) async -> MusicDownloadStore.Collection? {
        await rig.store.collectionList()[browseId ?? one]
    }

    /// A rig whose collection `one` (songs 1 to 3) is downloaded and idle, with the page then grown to songs 1 to 6.
    private func finishedRig(songs: SongGate = SongGate()) async -> DownloadServiceRig {
        let rig = DownloadServiceRig(handler: songs.handler, backend: FakeMusicBackend())
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        await rig.script(one, tracks: DownloadSamples.tracks(1...6))
        return rig
    }

    /// Starts the sync that adds songs 4 to 6 and returns once the first request of `videoId` has gone out.
    private func syncUntilFetching(_ rig: DownloadServiceRig, _ videoId: String) async {
        rig.service.sync(one)
        _ = await rig.eventually { await rig.requestCount(for: videoId) == 1 }
    }

    // MARK: - Cancel on a finished collection

    @Test("cancelling an update stops the fetching, keeps every file and the record, and the pill reads downloaded")
    func cancelUpdateKeepsEverything() async throws {
        let songs = SongGate()
        let rig = await finishedRig(songs: songs)
        defer { rig.cleanUp() }
        songs.hold(id(5))

        await syncUntilFetching(rig, id(5))
        // Songs 1 to 4 are on disk, 5 is on its way and 6 waits.
        guard case .updating(let done, let total, let fraction) = rig.service.collectionState(for: one) else {
            Issue.record("The state was \(rig.service.collectionState(for: one)), not updating")
            return
        }
        #expect(done == 4)
        #expect(total == 6)
        #expect(fraction >= 4.0 / 6.0)

        rig.service.cancelCollectionDownload(one)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 4, total: 6))
        #expect(rig.service.state(for: id(5)) == .none)
        #expect(rig.service.state(for: id(6)) == .none)
        await songs.gate.open()
        await rig.service.waitUntilIdle()

        let stored = try #require(await record(rig))
        #expect(stored.videoIds == ids(1...6))
        #expect(stored.syncResult == .failed(2))
        #expect(rig.folder.audioFiles == files(1...4))
        #expect(await rig.requestedSongs == ids(1...5))
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 4, total: 6))
        for number in 1...4 { #expect(rig.service.state(for: id(number)) == .downloaded) }
        #expect(rig.service.state(for: id(5)) == .none)
        #expect(rig.service.state(for: id(6)) == .none)
    }

    @Test("a song the user asked for on its own keeps downloading when the update is cancelled")
    func cancelKeepsStandaloneRequests() async throws {
        let songs = SongGate()
        let rig = await finishedRig(songs: songs)
        defer { rig.cleanUp() }
        songs.hold(id(4))

        await syncUntilFetching(rig, id(4))
        rig.download(id(6))
        #expect(rig.service.state(for: id(6)) == .queued)
        rig.service.cancelCollectionDownload(one)
        await songs.gate.open()
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == files(1...3) + [file(6)])
        #expect(rig.service.state(for: id(6)) == .downloaded)
        #expect(!rig.service.isCollectionOnly(id(6)))
        #expect(rig.service.state(for: id(4)) == .none)
        #expect(rig.service.state(for: id(5)) == .none)
        #expect(await rig.requestedSongs == ids(1...3) + [id(4), id(6)])
    }

    @Test("a song another collection lists keeps downloading when the update is cancelled")
    func cancelKeepsOtherCollectionsSongs() async throws {
        let songs = SongGate()
        let rig = await finishedRig(songs: songs)
        defer { rig.cleanUp() }
        // Collection two lists songs 5 and 7; song 5 fails the first time.
        await rig.script(two, tracks: [DownloadSamples.track(id(5), title: "Song 5"), DownloadSamples.track(id(7), title: "Song 7")])
        songs.fail([id(5)])
        rig.service.downloadCollection(rig.request(two))
        await rig.service.waitUntilIdle()
        #expect(rig.service.state(for: id(5)) == .failed)
        songs.fail([])
        songs.hold(id(4))

        await syncUntilFetching(rig, id(4))
        rig.service.cancelCollectionDownload(one)
        await songs.gate.open()
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == files(1...3) + [file(5), file(7)])
        #expect(rig.service.state(for: id(5)) == .downloaded)
        #expect(rig.service.collectionState(for: two) == .downloaded(done: 2, total: 2))
        #expect(rig.service.state(for: id(4)) == .none)
        #expect(await rig.requestCount(for: id(6)) == 0)
    }

    @Test("cancelling while the update reads the page leaves the collection and its last result as they were")
    func cancelWhileReadingThePage() async throws {
        let rig = await finishedRig()
        defer { rig.cleanUp() }
        let backend = try #require(rig.backend)
        // The page now lists only song 1: a read that finished would delete songs 2 and 3.
        await rig.script(one, tracks: DownloadSamples.tracks(1...1))
        let gate = MusicTestGate()
        await backend.setPageGate(one, gate)

        rig.service.sync(one)
        #expect(await rig.eventually { await backend.pageCalls.count == 2 })
        rig.service.cancelCollectionDownload(one)
        await gate.open()
        await rig.service.waitUntilIdle()

        let stored = try #require(await record(rig))
        #expect(stored.videoIds == ids(1...3))
        #expect(stored.syncResult == .complete)
        #expect(rig.folder.audioFiles == files(1...3))
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 3, total: 3))
    }

    @Test("cancelling a collection that is idle, or one that is not downloaded, deletes nothing")
    func cancelWhenNothingRuns() async throws {
        let rig = await finishedRig()
        defer { rig.cleanUp() }

        rig.service.cancelCollectionDownload(one)
        rig.service.cancelCollectionDownload("VLPLnothing")
        await rig.service.waitUntilIdle()

        #expect(rig.service.collectionState(for: one) == .downloaded(done: 3, total: 3))
        #expect(rig.service.collectionState(for: "VLPLnothing") == .none)
        #expect(rig.folder.audioFiles == files(1...3))
        #expect(try #require(await record(rig)).syncResult == .complete)
    }

    // MARK: - Cancel on a first download, and Remove

    @Test("cancelling a first download drops the collection, stops the song on its way and deletes what was fetched")
    func cancelFirstDownload() async throws {
        let songs = SongGate()
        let rig = DownloadServiceRig(handler: songs.handler, backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        songs.hold(id(2))

        rig.service.downloadCollection(rig.request(one))
        _ = await rig.eventually { await rig.requestCount(for: id(2)) == 1 }
        rig.service.cancelCollectionDownload(one)
        #expect(rig.service.collectionState(for: one) == .none)
        await songs.gate.open()
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles.isEmpty)
        #expect(await rig.store.collectionList().isEmpty)
        for number in 1...3 { #expect(rig.service.state(for: id(number)) == .none) }
        #expect(await rig.requestedSongs == ids(1...2))
    }

    @Test("a first download that a quit cut short is still a first download: cancelling it drops the collection")
    func cancelResumedFirstDownload() async throws {
        let songs = SongGate()
        let folder = DownloadTestFolder()
        let store = MusicDownloadStore(root: folder.root, now: { DownloadSamples.fixedDate })
        _ = await store.load()
        // The record was written and no sync ever finished.
        try await store.saveCollection(
            one, MusicDownloadStore.Collection(title: "Mix", videoIds: ids(1...3), addedAt: DownloadSamples.fixedDate)
        )
        let rig = DownloadServiceRig(folder: folder, handler: songs.handler, backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        await rig.service.waitUntilLoaded()
        songs.hold(id(2))

        rig.service.signInKnown()
        _ = await rig.eventually { await rig.requestCount(for: id(2)) == 1 }
        rig.service.cancelCollectionDownload(one)
        await songs.gate.open()
        await rig.service.waitUntilIdle()

        #expect(rig.service.collectionState(for: one) == .none)
        #expect(await rig.store.collectionList().isEmpty)
        #expect(rig.folder.audioFiles.isEmpty)
    }

    @Test("removing a collection while it updates deletes every file and the record")
    func removeDuringUpdate() async throws {
        let songs = SongGate()
        let rig = await finishedRig(songs: songs)
        defer { rig.cleanUp() }
        songs.hold(id(5))

        await syncUntilFetching(rig, id(5))
        rig.service.removeCollection(one)
        #expect(rig.service.collectionState(for: one) == .none)
        await songs.gate.open()
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles.isEmpty)
        #expect(await rig.store.collectionList().isEmpty)
        for number in 1...6 { #expect(rig.service.state(for: id(number)) == .none) }
    }

    // MARK: - What the store answers

    @Test("a collection removed before the index loaded loses its songs from the app as well as from the disk")
    func removeBeforeLoad() async throws {
        let first = DownloadServiceRig(backend: FakeMusicBackend())
        await first.script(one, tracks: DownloadSamples.tracks(1...3))
        first.service.downloadCollection(first.request(one))
        await first.service.waitUntilIdle()
        let second = DownloadServiceRig(folder: first.folder, backend: FakeMusicBackend())
        defer { second.cleanUp() }

        second.service.removeCollection(one)
        await second.service.waitUntilIdle()

        #expect(second.folder.audioFiles.isEmpty)
        for number in 1...3 {
            #expect(second.service.state(for: id(number)) == .none)
            #expect(second.service.localStream(for: id(number)) == nil)
        }
        #expect(second.service.collectionState(for: one) == .none)
    }

    @Test("a removal whose index write fails puts the collection and its songs back")
    func removalRestoredWhenTheWriteFails() async throws {
        let rig = DownloadServiceRig(backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        try rig.folder.lock(rig.folder.root)

        rig.service.removeCollection(one)
        await rig.service.waitUntilIdle()
        try rig.folder.unlock(rig.folder.root, isDirectory: true)

        #expect(rig.service.collectionState(for: one) == .downloaded(done: 3, total: 3))
        for number in 1...3 {
            #expect(rig.service.state(for: id(number)) == .downloaded)
            #expect(rig.service.isCollectionOnly(id(number)))
        }
        #expect(rig.folder.audioFiles == files(1...3))
        #expect(await record(rig) != nil)
    }

    @Test("asking for a collection the index already holds, before it has loaded, reads no page and changes nothing")
    func askingBeforeLoadForAStoredCollection() async throws {
        let first = DownloadServiceRig(backend: FakeMusicBackend())
        await first.script(one, tracks: DownloadSamples.tracks(1...2))
        first.service.downloadCollection(first.request(one))
        await first.service.waitUntilIdle()
        let backend = FakeMusicBackend()
        let second = DownloadServiceRig(folder: first.folder, backend: backend)
        defer { second.cleanUp() }
        await second.script(one, tracks: DownloadSamples.tracks(1...1))

        second.service.downloadCollection(second.request(one))
        await second.service.waitUntilIdle()

        #expect(await backend.pageCalls.isEmpty)
        #expect(second.service.collectionState(for: one) == .downloaded(done: 2, total: 2))
        #expect(second.folder.audioFiles == files(1...2))
    }
}
