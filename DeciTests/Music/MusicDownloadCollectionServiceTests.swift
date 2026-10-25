// DeciTests/Music/MusicDownloadCollectionServiceTests.swift
// Whole playlists and albums through the download service: the pill's three states, the order the queue runs in, the
// back-off after a rate limit, cancelling and removing, and the sync that keeps a downloaded page current. The real
// downloader and store run against a fake transport, a scripted backend and a pause that never waits; every test works
// in a folder of its own under /Volumes/Storage/_test. Nothing touches the network.

import Foundation
import os
import Testing
@testable import Deci

/// Reads a collection's state from inside the transport, which is what its pill would show at that moment.
@MainActor
private final class CollectionProbe {
    var service: MusicDownloadService?
    private(set) var samples: [MusicCollectionDownloadState] = []

    func sample(_ browseId: String) {
        if let service { samples.append(service.collectionState(for: browseId)) }
    }
}

/// Counts the requests a song's first chunk got, which is the number of times the song was tried.
private nonisolated final class AttemptTally: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: [String: Int]())

    /// Notes one more try of the song and returns how many there have been, this one included.
    func note(_ videoId: String) -> Int {
        counts.withLock { counts in
            counts[videoId, default: 0] += 1
            return counts[videoId, default: 0]
        }
    }
}

@MainActor
@Suite("MusicDownloadCollectionService")
struct MusicDownloadCollectionServiceTests {
    private let one = "VLPLone"
    private let two = "VLPLtwo"

    private func id(_ number: Int) -> String { DownloadSamples.id(number) }
    private func ids(_ numbers: Int...) -> [String] { numbers.map(DownloadSamples.id) }

    private func tracks(_ numbers: Int...) -> [MusicTrack] {
        numbers.map { DownloadSamples.track(DownloadSamples.id($0), title: "Song \($0)") }
    }

    private func record(_ rig: DownloadServiceRig, _ browseId: String) async -> MusicDownloadStore.Collection? {
        await rig.store.collectionList()[browseId]
    }

    /// A handler that answers every song from `payload`, except the ones in `failing`, which get `status`.
    private func handler(
        failing: Set<String> = [], status: Int = 429, payload: Data = DownloadSamples.payload(35)
    ) -> FakeDownloadTransport.Handler {
        { request, _ in
            failing.contains(request.videoId)
                ? FakeDownloadTransport.status(status)
                : FakeDownloadTransport.chunk(of: payload, request.range)
        }
    }

    /// A rig on a scripted backend with a page of songs `first...last` under `browseId`.
    private func makeRig(
        _ browseId: String? = nil,
        songs: ClosedRange<Int> = 1...3,
        backend: FakeMusicBackend = FakeMusicBackend(),
        handler: FakeDownloadTransport.Handler? = nil,
        covers: (any MusicCoverFetching)? = nil
    ) async -> DownloadServiceRig {
        let rig = DownloadServiceRig(handler: handler, backend: backend, covers: covers)
        if let browseId { await rig.script(browseId, tracks: DownloadSamples.tracks(songs)) }
        return rig
    }

    /// Polls until `condition` holds; for work parked at a gate that cannot be awaited.
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Downloads the collection and returns once everything has run.
    private func downloaded(_ rig: DownloadServiceRig, _ browseId: String, title: String = "Page") async {
        rig.service.downloadCollection(rig.request(browseId, title: title))
        await rig.service.waitUntilIdle()
    }

    // MARK: - The basics

    @Test("a playlist downloads whole: every song in page order, none standing alone, the record kept")
    func downloadsInPageOrder() async throws {
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(3, 1, 2), title: "Road trip", cover: "https://lh3.googleusercontent.com/c=w544-h544")

        rig.service.downloadCollection(
            rig.request(one, title: "Road trip", cover: "https://lh3.googleusercontent.com/c=w544-h544")
        )
        // Pending at once, before any work has had a turn.
        #expect(rig.service.collectionState(for: one) == .downloading(done: 0, total: 0, fraction: 0))
        await rig.service.waitUntilIdle()

        #expect(rig.service.collectionState(for: one) == .downloaded(done: 3, total: 3))
        #expect(await rig.requestedSongs == ids(3, 1, 2))
        let stored = try #require(await record(rig, one))
        #expect(stored.title == "Road trip")
        #expect(stored.videoIds == ids(3, 1, 2))
        #expect(stored.kind == .playlist)
        #expect(stored.syncResult == .complete)
        #expect(stored.addedAt == rig.clock.now)
        #expect(stored.lastSyncedAt == rig.clock.now)
        #expect(stored.coverURL == URL(string: "https://lh3.googleusercontent.com/c=w544-h544"))
        for number in 1...3 {
            #expect(rig.service.state(for: id(number)) == .downloaded)
            #expect(rig.service.isCollectionOnly(id(number)))
            #expect(rig.service.localStream(for: id(number)) != nil)
        }
        #expect(rig.folder.audioFiles == ids(1, 2, 3).map { "\($0).m4a" })
        // A short rest between songs, and none after the last.
        #expect(rig.pause.waits == [0.5, 0.5])
    }

    @Test("an album is asked for the same way")
    func albumKind() async throws {
        let rig = await makeRig("MPREb_album", songs: 1...2)
        defer { rig.cleanUp() }

        rig.service.downloadCollection(rig.request("MPREb_album", title: "Album", kind: .album))
        await rig.service.waitUntilIdle()

        #expect(try #require(await record(rig, "MPREb_album")).kind == .album)
        #expect(rig.service.collectionState(for: "MPREb_album") == .downloaded(done: 2, total: 2))
    }

    @Test("a long page is read through its continuations, in order")
    func followsContinuations() async throws {
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(1, 2), continuation: "c1")
        await backend.setMoreTracks(browseId: one, continuation: "c1", tracks: tracks(3, 4), next: "c2")
        await backend.setMoreTracks(browseId: one, continuation: "c2", tracks: tracks(5))

        await downloaded(rig, one)

        #expect(try #require(await record(rig, one)).videoIds == ids(1, 2, 3, 4, 5))
        #expect(await rig.requestedSongs == ids(1, 2, 3, 4, 5))
        #expect(await backend.moreTracksCalls.map(\.continuation) == ["c1", "c2"])
    }

    @Test("asking again for a collection that is stored or on its way changes nothing")
    func askingAgain() async throws {
        let backend = FakeMusicBackend()
        let gate = MusicTestGate()
        let rig = await makeRig(one, backend: backend)
        defer { rig.cleanUp() }
        await backend.setPageGate(one, gate)

        rig.service.downloadCollection(rig.request(one))
        rig.service.downloadCollection(rig.request(one))
        #expect(await eventually { await backend.pageCalls.count == 1 })
        await gate.open()
        await rig.service.waitUntilIdle()
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()

        #expect(await backend.pageCalls == [one])
        #expect(await rig.requestedSongs == ids(1, 2, 3))
    }

    @Test("the record is on disk before the first song arrives, so a quit leaves something to finish")
    func recordSavedBeforeSongs() async throws {
        let gate = MusicTestGate()
        let payload = DownloadSamples.payload(35)
        let rig = DownloadServiceRig(handler: { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(1, 2, 3))

        rig.service.downloadCollection(rig.request(one))
        await rig.transport.waitForRequests(1)

        // Song one is on its way; nothing has finished, and the whole list is already stored.
        #expect(rig.service.collectionState(for: one) == .downloading(done: 0, total: 3, fraction: 0))
        #expect(await eventually { await record(rig, one)?.videoIds == ids(1, 2, 3) })
        await gate.open()
        await rig.service.waitUntilIdle()
    }

    @Test("a collection that cannot be read leaves nothing behind: signed out, an error, or an empty page")
    func failedFirstEnumeration() async throws {
        let backend = FakeMusicBackend()
        let rig = await makeRig(one, backend: backend)
        defer { rig.cleanUp() }
        await backend.setPageError(one, MusicError.http(404))
        await rig.script(two, tracks: [])
        await rig.script("VLPLthree", tracks: tracks(1))

        rig.service.downloadCollection(rig.request(one))
        rig.service.downloadCollection(rig.request(two))
        await rig.service.waitUntilIdle()
        #expect(rig.service.collectionState(for: one) == .none)
        #expect(rig.service.collectionState(for: two) == .none)

        await backend.setSignedIn(false)
        rig.service.downloadCollection(rig.request("VLPLthree"))
        await rig.service.waitUntilIdle()

        #expect(rig.service.collectionState(for: "VLPLthree") == .none)
        #expect(await rig.store.collectionList().isEmpty)
        #expect(await rig.transport.requestCount == 0)
        #expect(!rig.folder.exists(rig.folder.audioDirectory) || rig.folder.audioFiles.isEmpty)
    }

    // MARK: - Progress

    @Test("the pill's ring is songs done plus the song on its way, over all the songs")
    func progressFraction() async throws {
        let payload = DownloadSamples.payload(35)
        let clock = MutableClock()
        let probe = CollectionProbe()
        let backend = FakeMusicBackend()
        let browseId = one
        let rig = DownloadServiceRig(clock: clock, payload: payload, handler: { request, index in
            // The second song's second chunk is asked for: its first has arrived, and the first song is done.
            if index == 5 { await probe.sample(browseId) }
            clock.advance(by: 1)
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: backend)
        defer { rig.cleanUp() }
        probe.service = rig.service
        await rig.script(one, tracks: tracks(1, 2, 3))

        await downloaded(rig, one)

        let sample = try #require(probe.samples.first)
        guard case .downloading(let done, let total, let fraction) = sample else {
            Issue.record("Not downloading: \(sample)")
            return
        }
        #expect(done == 1)
        #expect(total == 3)
        #expect(abs(fraction - (1.0 + 10.0 / 35.0) / 3.0) < 1e-9)
    }

    // MARK: - Order

    @Test("a song two collections list downloads once")
    func sharedSongOnce() async throws {
        let rig = await makeRig(one, songs: 1...3)
        defer { rig.cleanUp() }
        await rig.script(two, tracks: tracks(3, 4))

        rig.service.downloadCollection(rig.request(one))
        rig.service.downloadCollection(rig.request(two))
        await rig.service.waitUntilIdle()

        #expect(await rig.requestedSongs == ids(1, 2, 3, 4))
        #expect(await rig.requestCount(for: id(3)) == 4)
        #expect(try #require(await record(rig, two)).videoIds == ids(3, 4))
        #expect(rig.service.collectionState(for: two) == .downloaded(done: 2, total: 2))
    }

    @Test("a song that already has its file is not fetched again, and stays a song of its own")
    func alreadyDownloadedSong() async throws {
        let rig = await makeRig(one, songs: 1...3)
        defer { rig.cleanUp() }
        rig.download(id(2))
        #expect(await rig.settles(id(2), as: .downloaded))

        await downloaded(rig, one)

        #expect(await rig.requestCount(for: id(2)) == 4)
        #expect(await rig.requestedSongs == ids(2, 1, 3))
        #expect(!rig.service.isCollectionOnly(id(2)))
        #expect(rig.service.isCollectionOnly(id(1)))
    }

    @Test("a song asked for on its own while a collection runs goes next")
    func standaloneJumpsAhead() async throws {
        let gate = MusicTestGate()
        let payload = DownloadSamples.payload(35)
        let rig = DownloadServiceRig(handler: { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(1, 2, 3))

        rig.service.downloadCollection(rig.request(one))
        await rig.transport.waitForRequests(1)
        rig.download(id(9))
        #expect(rig.service.state(for: id(9)) == .queued)
        await gate.open()
        await rig.service.waitUntilIdle()

        #expect(await rig.requestedSongs == ids(1, 9, 2, 3))
        #expect(!rig.service.isCollectionOnly(id(9)))
    }

    @Test("asking for a queued collection song on its own moves it up, and it then outlives the collection")
    func promoteQueuedCollectionSong() async throws {
        let gate = MusicTestGate()
        let payload = DownloadSamples.payload(35)
        let rig = DownloadServiceRig(handler: { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(1, 2, 3, 4))

        rig.service.downloadCollection(rig.request(one))
        await rig.transport.waitForRequests(1)
        rig.download(id(4))
        await gate.open()
        await rig.service.waitUntilIdle()

        #expect(await rig.requestedSongs == ids(1, 4, 2, 3))
        #expect(!rig.service.isCollectionOnly(id(4)))
        rig.service.removeCollection(one)
        await rig.service.waitUntilIdle()
        #expect(rig.folder.audioFiles == ["\(id(4)).m4a"])
    }

    // MARK: - Back-off

    @Test("a rate limit holds the queue 30, 60 and 120 seconds, fails that song, rests ten minutes and goes on")
    func rateLimitBackoff() async throws {
        let rig = await makeRig(one, handler: handler(failing: [id(2)], status: 429))
        defer { rig.cleanUp() }

        await downloaded(rig, one)

        #expect(rig.pause.waits == [0.5, 30, 60, 120, 600])
        #expect(await rig.requestCount(for: id(2)) == 4)
        #expect(rig.service.state(for: id(2)) == .failed)
        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(rig.service.state(for: id(3)) == .downloaded)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 3))
        #expect(try #require(await record(rig, one)).syncResult == .failed(1))
        #expect(rig.folder.audioFiles == ids(1, 3).map { "\($0).m4a" })
    }

    @Test("the ten minute rest follows a song that gave up on a rate limit only when more songs wait")
    func rateLimitRestOnlyBeforeMoreSongs() async throws {
        let rig = await makeRig(one, handler: handler(failing: [id(3)], status: 429))
        defer { rig.cleanUp() }

        await downloaded(rig, one)

        // The last song of the collection gives up: nothing is left to hold back.
        #expect(rig.pause.waits == [0.5, 0.5, 30, 60, 120])
        #expect(rig.service.state(for: id(3)) == .failed)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 3))
    }

    @Test("a song that fails for another reason does not rest the queue")
    func otherFailureNoRest() async throws {
        let rig = await makeRig(one, handler: handler(failing: [id(2)], status: 404))
        defer { rig.cleanUp() }

        await downloaded(rig, one)

        #expect(rig.pause.waits == [0.5, 0.5])
        #expect(rig.service.state(for: id(3)) == .downloaded)
    }

    @Test("a server error backs off the same way")
    func serverErrorBackoff() async throws {
        let rig = DownloadServiceRig(handler: handler(failing: [id(1)], status: 503))
        defer { rig.cleanUp() }

        rig.download(id(1))

        #expect(await rig.settles(id(1), as: .failed))
        #expect(rig.pause.waits == [30, 60, 120])
        #expect(await rig.transport.requestCount == 4)
    }

    @Test("a rate limit that lifts is waited out and the song downloads")
    func rateLimitLifts() async throws {
        let payload = DownloadSamples.payload(35)
        let tally = AttemptTally()
        let rig = DownloadServiceRig(handler: { request, _ in
            if request.range.lowerBound == 0, tally.note(request.videoId) <= 2 { return FakeDownloadTransport.status(429) }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }

        rig.download(id(1))

        #expect(await rig.settles(id(1), as: .downloaded))
        #expect(rig.pause.waits == [30, 60])
        #expect(await rig.transport.requestCount == 6)
    }

    @Test("a missing song is not waited for: no back-off on a 404")
    func notFoundNoBackoff() async throws {
        let rig = DownloadServiceRig(handler: handler(failing: [id(1)], status: 404))
        defer { rig.cleanUp() }

        rig.download(id(1))

        #expect(await rig.settles(id(1), as: .failed))
        #expect(rig.pause.waits.isEmpty)
        #expect(await rig.transport.requestCount == 1)
    }

    @Test("a rate limit on the way to the stream backs off too")
    func resolveRateLimit() async throws {
        let resolver = FakeDownloadResolver { videoId, call in
            if call < 2 { throw MusicError.http(503) }
            return FakeDownloadResolver.stream(videoId: videoId, call: call)
        }
        let rig = DownloadServiceRig(resolver: resolver)
        defer { rig.cleanUp() }

        rig.download(id(1))

        #expect(await rig.settles(id(1), as: .downloaded))
        #expect(rig.pause.waits == [30, 60])
    }

    @Test("a rate limit on the listing of a collection backs off before the page is read again")
    func enumerationRateLimit() async throws {
        let backend = FakeMusicBackend()
        let rig = await makeRig(one, backend: backend)
        defer { rig.cleanUp() }
        await backend.setPageError(one, MusicError.http(429))
        let browseId = one
        rig.pause.onWait { _, seconds in
            if seconds >= 30 { await backend.setPageError(browseId, nil) }
        }

        await downloaded(rig, one)

        #expect(rig.pause.waits == [30, 0.5, 0.5])
        #expect(await backend.pageCalls == [one, one])
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 3, total: 3))
    }

    @Test("while a back-off runs nothing else is fetched, and removing the song ends the wait")
    func backoffHoldsTheQueue() async throws {
        let rig = DownloadServiceRig(handler: handler(failing: [id(1)], status: 429))
        defer { rig.cleanUp() }
        rig.pause.blockBackoff()

        rig.download(id(1))
        rig.download(id(2))
        await rig.pause.waitForCount(1)

        #expect(rig.pause.waits == [30])
        #expect(await rig.requestedSongs == [id(1)])
        #expect(rig.service.state(for: id(2)) == .queued)

        rig.service.remove(videoId: id(1))
        #expect(await rig.settles(id(2), as: .downloaded))
        #expect(await rig.requestedSongs == ids(1, 2))
        #expect(rig.service.state(for: id(1)) == .none)
    }

    @Test("cancelling a collection ends a back-off at once")
    func cancelEndsBackoff() async throws {
        let rig = await makeRig(one, handler: handler(failing: [id(1)], status: 429))
        defer { rig.cleanUp() }
        rig.pause.blockBackoff()

        rig.service.downloadCollection(rig.request(one))
        await rig.pause.waitForCount(1)
        rig.service.removeCollection(one)
        await rig.service.waitUntilIdle()

        #expect(rig.pause.backoffs == [30])
        #expect(await rig.requestedSongs == [id(1)])
        #expect(rig.service.collectionState(for: one) == .none)
        #expect(rig.service.state(for: id(2)) == .none)
        #expect(await rig.store.collectionList().isEmpty)
    }

    // MARK: - Cancel and remove

    @Test("cancelling mid-collection stops the song on its way and leaves nothing on disk or in the index")
    func cancelMidCollection() async throws {
        let gate = MusicTestGate()
        let payload = DownloadSamples.payload(35)
        let rig = DownloadServiceRig(handler: { request, index in
            if index == 4 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(1, 2, 3))

        rig.service.downloadCollection(rig.request(one))
        await rig.transport.waitForRequests(5)
        rig.service.removeCollection(one)
        #expect(rig.service.collectionState(for: one) == .none)
        #expect(rig.service.state(for: id(2)) == .none)
        await gate.open()
        await rig.service.waitUntilIdle()

        #expect(await rig.requestedSongs == ids(1, 2))
        #expect(rig.folder.audioFiles.isEmpty)
        #expect(await rig.store.collectionList().isEmpty)
        for number in 1...3 { #expect(rig.service.state(for: id(number)) == .none) }
    }

    @Test("cancelling while the page is being read saves nothing when the page arrives")
    func cancelDuringEnumeration() async throws {
        let backend = FakeMusicBackend()
        let gate = MusicTestGate()
        let rig = await makeRig(one, backend: backend)
        defer { rig.cleanUp() }
        await backend.setPageGate(one, gate)

        rig.service.downloadCollection(rig.request(one))
        #expect(await eventually { await backend.pageCalls.count == 1 })
        rig.service.removeCollection(one)
        await gate.open()
        await rig.service.waitUntilIdle()

        #expect(rig.service.collectionState(for: one) == .none)
        #expect(await rig.store.collectionList().isEmpty)
        #expect(await rig.transport.requestCount == 0)
    }

    @Test("removing a finished collection deletes its songs, and keeps the ones another collection holds")
    func removeKeepsSharedSongs() async throws {
        let rig = await makeRig(one, songs: 1...3)
        defer { rig.cleanUp() }
        await rig.script(two, tracks: tracks(3, 4))
        rig.service.downloadCollection(rig.request(one))
        rig.service.downloadCollection(rig.request(two))
        await rig.service.waitUntilIdle()

        rig.service.removeCollection(one)
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == ids(3, 4).map { "\($0).m4a" })
        #expect(rig.service.state(for: id(1)) == .none)
        #expect(rig.service.state(for: id(3)) == .downloaded)
        #expect(rig.service.collectionState(for: two) == .downloaded(done: 2, total: 2))

        rig.service.removeCollection(two)
        await rig.service.waitUntilIdle()
        #expect(rig.folder.audioFiles.isEmpty)
    }

    @Test("removing a collection keeps the songs downloaded on their own")
    func removeKeepsStandaloneSongs() async throws {
        let rig = await makeRig(one, songs: 1...3)
        defer { rig.cleanUp() }
        rig.download(id(2))
        #expect(await rig.settles(id(2), as: .downloaded))
        await downloaded(rig, one)

        rig.service.removeCollection(one)
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == ["\(id(2)).m4a"])
        #expect(rig.service.state(for: id(2)) == .downloaded)
    }

    @Test("a song playing from its file keeps playing when its collection is removed, and goes when playback leaves it")
    func removeWhilePlaying() async throws {
        let rig = await makeRig(one, songs: 1...2)
        defer { rig.cleanUp() }
        await downloaded(rig, one)
        rig.service.noteLocalPlayback(of: id(1))

        rig.service.removeCollection(one)
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == ["\(id(1)).m4a"])
        #expect(rig.service.state(for: id(1)) == .none)
        rig.service.noteLocalPlayback(of: nil)
        await rig.service.waitUntilIdle()
        #expect(rig.folder.audioFiles.isEmpty)
    }

    @Test("a finished collection is still there after a relaunch, and can be removed then")
    func survivesRelaunch() async throws {
        let first = await makeRig(one, songs: 1...2)
        await downloaded(first, one)
        let second = DownloadServiceRig(folder: first.folder, backend: FakeMusicBackend())
        defer { second.cleanUp() }
        await second.service.waitUntilLoaded()

        #expect(second.service.collectionState(for: one) == .downloaded(done: 2, total: 2))
        #expect(second.service.isCollectionOnly(id(1)))
        second.service.removeCollection(one)
        await second.service.waitUntilIdle()

        #expect(second.folder.audioFiles.isEmpty)
        #expect(await second.store.collectionList().isEmpty)
    }

    // MARK: - Songs in collections

    @Test("a song held only by a collection reports it; downloading it on its own makes it survive the collection")
    func downloadingACollectionSong() async throws {
        let rig = await makeRig(one, songs: 1...2)
        defer { rig.cleanUp() }
        await downloaded(rig, one)
        #expect(rig.service.isCollectionOnly(id(1)))
        #expect(!rig.service.isCollectionOnly(id(9)))

        rig.download(id(1))
        #expect(!rig.service.isCollectionOnly(id(1)))
        rig.service.removeCollection(one)
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == ["\(id(1)).m4a"])
        #expect(await rig.requestCount(for: id(1)) == 4)
    }

    @Test("removing a song that is also in a collection keeps its file until the collection goes")
    func removeStandaloneHeldByCollection() async throws {
        let rig = await makeRig(one, songs: 1...2)
        defer { rig.cleanUp() }
        rig.download(id(1))
        #expect(await rig.settles(id(1), as: .downloaded))
        await downloaded(rig, one)
        #expect(!rig.service.isCollectionOnly(id(1)))

        rig.service.remove(videoId: id(1))
        await rig.service.waitUntilIdle()

        #expect(rig.service.isCollectionOnly(id(1)))
        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(rig.folder.audioFiles == ids(1, 2).map { "\($0).m4a" })
        rig.service.removeCollection(one)
        await rig.service.waitUntilIdle()
        #expect(rig.folder.audioFiles.isEmpty)
    }

    @Test("removing a song only a collection holds does nothing")
    func removeCollectionOnlySong() async throws {
        let rig = await makeRig(one, songs: 1...2)
        defer { rig.cleanUp() }
        await downloaded(rig, one)

        rig.service.remove(videoId: id(2))
        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: id(2)) == .downloaded)
        #expect(rig.folder.audioFiles == ids(1, 2).map { "\($0).m4a" })
    }

    // MARK: - Sync

    @Test("a sync downloads the songs added to the page and deletes the ones taken off it")
    func syncAddsAndRemoves() async throws {
        let rig = await makeRig(one, songs: 1...3)
        defer { rig.cleanUp() }
        await downloaded(rig, one)
        await rig.script(one, tracks: tracks(1, 3, 4))

        rig.service.sync(one)
        await rig.service.waitUntilIdle()

        #expect(try #require(await record(rig, one)).videoIds == ids(1, 3, 4))
        #expect(rig.folder.audioFiles == ids(1, 3, 4).map { "\($0).m4a" })
        #expect(rig.service.state(for: id(2)) == .none)
        #expect(await rig.requestCount(for: id(4)) == 4)
        #expect(await rig.requestCount(for: id(1)) == 4)
        #expect(await rig.requestCount(for: id(3)) == 4)
        #expect(try #require(await record(rig, one)).syncResult == .complete)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 3, total: 3))
    }

    @Test("a reorder on the page changes the stored order and fetches nothing")
    func syncReorder() async throws {
        let rig = await makeRig(one, songs: 1...3)
        defer { rig.cleanUp() }
        await downloaded(rig, one)
        let before = await rig.transport.requestCount
        await rig.script(one, tracks: tracks(3, 1, 2))

        rig.service.sync(one)
        await rig.service.waitUntilIdle()

        #expect(try #require(await record(rig, one)).videoIds == ids(3, 1, 2))
        #expect(await rig.transport.requestCount == before)
        #expect(rig.folder.audioFiles.count == 3)
    }

    @Test("a sync keeps the title and cover chosen when the collection was downloaded")
    func syncKeepsTitle() async throws {
        let rig = await makeRig(one, songs: 1...2)
        defer { rig.cleanUp() }
        await downloaded(rig, one, title: "Chosen title")
        await rig.script(one, tracks: tracks(1, 2, 3), title: "Renamed on the page")

        rig.service.sync(one)
        await rig.service.waitUntilIdle()

        #expect(try #require(await record(rig, one)).title == "Chosen title")
    }

    @Test("songs taken off the page that are still waiting are never fetched")
    func syncDropsQueuedSongs() async throws {
        let gate = MusicTestGate()
        let payload = DownloadSamples.payload(35)
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(handler: { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(1, 2, 3, 4))
        rig.service.downloadCollection(rig.request(one))
        await rig.transport.waitForRequests(1)
        await rig.script(one, tracks: tracks(1, 2))

        rig.service.sync(one)
        await gate.open()
        await rig.service.waitUntilIdle()

        #expect(await rig.requestedSongs == ids(1, 2))
        #expect(try #require(await record(rig, one)).videoIds == ids(1, 2))
        #expect(rig.service.state(for: id(3)) == .none)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 2))
    }

    @Test("a song that failed is tried again by the next sync")
    func syncRetriesFailures() async throws {
        let payload = DownloadSamples.payload(35)
        let failing = OSAllocatedUnfairLock(initialState: true)
        let rig = DownloadServiceRig(handler: { request, _ in
            if request.videoId == DownloadSamples.id(2), failing.withLock({ $0 }) { return FakeDownloadTransport.status(404) }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(1, 2, 3))
        await downloaded(rig, one)
        #expect(try #require(await record(rig, one)).syncResult == .failed(1))
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 3))

        failing.withLock { $0 = false }
        rig.service.sync(one)
        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: id(2)) == .downloaded)
        #expect(try #require(await record(rig, one)).syncResult == .complete)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 3, total: 3))
    }

    @Test("a sync of a collection that is not downloaded does nothing")
    func syncOfNothing() async throws {
        let backend = FakeMusicBackend()
        let rig = await makeRig(one, backend: backend)
        defer { rig.cleanUp() }

        rig.service.sync(one)
        await rig.service.waitUntilIdle()

        #expect(await backend.pageCalls.isEmpty)
        #expect(rig.service.collectionState(for: one) == .none)
        #expect(await rig.store.collectionList().isEmpty)
    }

    // MARK: - Sync safety

    /// A collection of songs 1 to 3, downloaded, with the page then changed to hold only song 1: the page a deleting sync
    /// would act on. The safety tests change what goes wrong and check that nothing is deleted.
    private func downloadedThenShrunk(_ backend: FakeMusicBackend) async -> DownloadServiceRig {
        let rig = await makeRig(one, songs: 1...3, backend: backend)
        await downloaded(rig, one)
        await rig.script(one, tracks: tracks(1))
        return rig
    }

    /// Everything is as it was: the list, the files, the songs shown as downloaded.
    private func expectUntouched(_ rig: DownloadServiceRig, result: MusicDownloadStore.Collection.SyncResult = .unreachable) async throws {
        await rig.service.waitUntilIdle()
        let stored = try #require(await record(rig, one))
        #expect(stored.videoIds == ids(1, 2, 3))
        #expect(stored.syncResult == result)
        #expect(rig.folder.audioFiles == ids(1, 2, 3).map { "\($0).m4a" })
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 3, total: 3))
    }

    @Test("signed out, a sync keeps everything and says it could not reach the page")
    func syncSignedOut() async throws {
        let backend = FakeMusicBackend()
        let rig = await downloadedThenShrunk(backend)
        defer { rig.cleanUp() }
        await backend.setSignedIn(false)

        rig.service.sync(one)

        try await expectUntouched(rig)
        #expect(await backend.pageCalls == [one])
    }

    @Test("a network error keeps everything")
    func syncNetworkError() async throws {
        let backend = FakeMusicBackend()
        let rig = await downloadedThenShrunk(backend)
        defer { rig.cleanUp() }
        await backend.setPageError(one, URLError(.notConnectedToInternet))

        rig.service.sync(one)

        try await expectUntouched(rig)
    }

    @Test("a page that is gone keeps everything")
    func syncNotFound() async throws {
        let backend = FakeMusicBackend()
        let rig = await downloadedThenShrunk(backend)
        defer { rig.cleanUp() }
        await backend.setPageError(one, MusicError.http(404))

        rig.service.sync(one)

        try await expectUntouched(rig)
        #expect(rig.pause.backoffs.isEmpty)
    }

    @Test("a sign-in error keeps everything")
    func syncSignedOutError() async throws {
        let backend = FakeMusicBackend()
        let rig = await downloadedThenShrunk(backend)
        defer { rig.cleanUp() }
        await backend.setPageError(one, MusicError.signedOut)

        rig.service.sync(one)

        try await expectUntouched(rig)
    }

    @Test("an error on a later page keeps everything, even though the first page was readable")
    func syncErrorOnLaterPage() async throws {
        let backend = FakeMusicBackend()
        let rig = await downloadedThenShrunk(backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(1), continuation: "c1")
        await backend.setMoreTracksError(browseId: one, continuation: "c1", URLError(.timedOut))

        rig.service.sync(one)

        try await expectUntouched(rig)
    }

    @Test("a rate limit that does not lift keeps everything")
    func syncRateLimited() async throws {
        let backend = FakeMusicBackend()
        let rig = await downloadedThenShrunk(backend)
        defer { rig.cleanUp() }
        await backend.setPageError(one, MusicError.http(429))

        rig.service.sync(one)

        try await expectUntouched(rig)
        #expect(rig.pause.backoffs == [30, 60, 120])
    }

    @Test("a page that now reads as empty keeps everything")
    func syncEmptyList() async throws {
        let backend = FakeMusicBackend()
        let rig = await downloadedThenShrunk(backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: [])

        rig.service.sync(one)

        try await expectUntouched(rig)
    }

    @Test("a read that stops short of the end of the list keeps everything")
    func syncIncompleteList() async throws {
        let backend = FakeMusicBackend()
        let rig = await downloadedThenShrunk(backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(1), continuation: "c1")
        await backend.setMoreTracks(browseId: one, continuation: "c1", tracks: [], next: "c2")
        await backend.setMoreTracks(browseId: one, continuation: "c2", tracks: [], next: "c3")
        await backend.setMoreTracks(browseId: one, continuation: "c3", tracks: [], next: "c4")

        rig.service.sync(one)

        try await expectUntouched(rig)
    }

    @Test("Liked Music on another channel keeps everything; on the same channel the sync goes through")
    func syncLikedMusicChannel() async throws {
        let backend = FakeMusicBackend()
        let rig = await makeRig("VLLM", songs: 1...3, backend: backend)
        defer { rig.cleanUp() }
        await downloaded(rig, "VLLM")
        await rig.script("VLLM", tracks: tracks(1))
        await backend.setSessionIdentity("channel-b")

        rig.service.sync("VLLM")
        await rig.service.waitUntilIdle()

        let kept = try #require(await record(rig, "VLLM"))
        #expect(kept.videoIds == ids(1, 2, 3))
        #expect(kept.syncResult == .unreachable)
        #expect(rig.folder.audioFiles.count == 3)

        await backend.setSessionIdentity("channel-a")
        rig.service.sync("VLLM")
        await rig.service.waitUntilIdle()

        let synced = try #require(await record(rig, "VLLM"))
        #expect(synced.videoIds == ids(1))
        #expect(synced.syncResult == .complete)
        #expect(rig.folder.audioFiles == ["\(id(1)).m4a"])
    }

    @Test("after a sync that could not run, the next one that can does the work")
    func syncRecovers() async throws {
        let backend = FakeMusicBackend()
        let rig = await downloadedThenShrunk(backend)
        defer { rig.cleanUp() }
        await backend.setPageError(one, URLError(.notConnectedToInternet))
        rig.service.sync(one)
        try await expectUntouched(rig)

        await backend.setPageError(one, nil)
        rig.service.sync(one)
        await rig.service.waitUntilIdle()

        let stored = try #require(await record(rig, one))
        #expect(stored.videoIds == ids(1))
        #expect(stored.syncResult == .complete)
        #expect(rig.folder.audioFiles == ["\(id(1)).m4a"])
    }

    // MARK: - When a sync starts by itself

    @Test("opening a downloaded page syncs it at most once every ten minutes")
    func pageOpenThrottle() async throws {
        let backend = FakeMusicBackend()
        let rig = await makeRig(one, backend: backend)
        defer { rig.cleanUp() }
        await downloaded(rig, one)
        func pageCalls() async -> Int { await backend.pageCalls.count }

        // Downloading the page read it just now.
        rig.service.pageOpened(one)
        await rig.service.waitUntilIdle()
        #expect(await pageCalls() == 1)

        rig.clock.advance(by: 599)
        rig.service.pageOpened(one)
        await rig.service.waitUntilIdle()
        #expect(await pageCalls() == 1)

        rig.clock.advance(by: 1)
        rig.service.pageOpened(one)
        await rig.service.waitUntilIdle()
        #expect(await pageCalls() == 2)

        rig.clock.advance(by: 300)
        rig.service.pageOpened(one)
        await rig.service.waitUntilIdle()
        #expect(await pageCalls() == 2)

        rig.clock.advance(by: 300)
        rig.service.pageOpened(one)
        await rig.service.waitUntilIdle()
        #expect(await pageCalls() == 3)
    }

    @Test("opening a page that is not downloaded syncs nothing")
    func pageOpenIgnoresOtherPages() async throws {
        let backend = FakeMusicBackend()
        let rig = await makeRig(one, backend: backend)
        defer { rig.cleanUp() }
        await downloaded(rig, one)
        rig.clock.advance(by: 3_600)

        rig.service.pageOpened(two)
        rig.service.pageOpened("UCartist")
        await rig.service.waitUntilIdle()

        #expect(await backend.pageCalls == [one])
    }

    @Test("a page opened before the downloads have loaded syncs once they have")
    func pageOpenBeforeLoad() async throws {
        let first = await makeRig(one, songs: 1...2)
        await downloaded(first, one)
        let backend = FakeMusicBackend()
        let second = DownloadServiceRig(folder: first.folder, backend: backend)
        defer { second.cleanUp() }
        await second.script(one, tracks: tracks(1, 2, 3))

        second.service.pageOpened(one)
        await second.service.waitUntilIdle()

        #expect(await backend.pageCalls == [one])
        #expect(try #require(await record(second, one)).videoIds == ids(1, 2, 3))
        #expect(second.folder.audioFiles.count == 3)
    }

    /// Three collections downloaded one after another, so they were added in the order zulu, alpha, mike (not the
    /// alphabet's), then a new service on the same folder with a backend of its own.
    private func threeCollections() async throws -> (rig: DownloadServiceRig, backend: FakeMusicBackend, ids: [String]) {
        let names = ["VLPLzulu", "VLPLalpha", "VLPLmike"]
        let first = await makeRig(nil, backend: FakeMusicBackend())
        for (index, name) in names.enumerated() {
            await first.script(name, tracks: DownloadSamples.tracks((index * 10 + 1)...(index * 10 + 2)))
            first.service.downloadCollection(first.request(name))
            await first.service.waitUntilIdle()
            first.clock.advance(by: 10)
        }
        let backend = FakeMusicBackend()
        let second = DownloadServiceRig(folder: first.folder, clock: first.clock, backend: backend)
        for (index, name) in names.enumerated() {
            await second.script(name, tracks: DownloadSamples.tracks((index * 10 + 1)...(index * 10 + 2)))
        }
        return (second, backend, names)
    }

    @Test("the launch sync waits for sign-in, then goes through the collections oldest first, one at a time, once")
    func launchSync() async throws {
        let (rig, backend, names) = try await threeCollections()
        defer { rig.cleanUp() }
        let gate = MusicTestGate()
        await backend.setPageGate("VLPLalpha", gate)

        // Loaded, idle and not yet known to be signed in: nothing is read.
        await rig.service.waitUntilIdle()
        #expect(await backend.pageCalls.isEmpty)

        rig.service.signInKnown()
        #expect(await eventually { await backend.pageCalls.count == 2 })
        for _ in 0..<50 { await Task.yield() }
        #expect(await backend.pageCalls == ["VLPLzulu", "VLPLalpha"])

        await gate.open()
        await rig.service.waitUntilIdle()
        #expect(await backend.pageCalls == names)

        rig.service.signInKnown()
        await rig.service.waitUntilIdle()
        #expect(await backend.pageCalls == names)
    }

    @Test("the launch sync called before the downloads have loaded runs once they have")
    func launchSyncBeforeLoad() async throws {
        let first = await makeRig(one, songs: 1...2)
        await downloaded(first, one)
        let backend = FakeMusicBackend()
        let second = DownloadServiceRig(folder: first.folder, backend: backend)
        defer { second.cleanUp() }
        await second.script(one, tracks: tracks(1, 2))

        second.service.signInKnown()
        await second.service.waitUntilIdle()

        #expect(await backend.pageCalls == [one])
    }

    @Test("a launch after a quit mid-download fetches the songs that were missing")
    func launchResumesAfterQuit() async throws {
        let folder = DownloadTestFolder()
        let store = MusicDownloadStore(root: folder.root, now: { DownloadSamples.fixedDate })
        _ = await store.load()
        for number in [1, 2] {
            let part = try await store.beginPart(videoId: id(number))
            try DownloadSamples.payload(35).write(to: part)
            _ = try await store.commit(
                DownloadSamples.track(id(number)), expectedBytes: 35, durationSeconds: 200, standalone: false
            )
        }
        try await store.saveCollection(
            one, MusicDownloadStore.Collection(title: "Mix", videoIds: ids(1, 2, 3, 4), addedAt: DownloadSamples.fixedDate)
        )
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(folder: folder, backend: backend)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: tracks(1, 2, 3, 4))
        await rig.service.waitUntilLoaded()
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 4))

        rig.service.signInKnown()
        await rig.service.waitUntilIdle()

        #expect(await rig.requestedSongs == ids(3, 4))
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 4, total: 4))
        #expect(try #require(await record(rig, one)).syncResult == .complete)
        #expect(rig.folder.audioFiles.count == 4)
    }

    // MARK: - Covers

    @Test("the collection's cover and each song's thumbnail are saved small, and offered by file")
    func coversSaved() async throws {
        let fetcher = FakeCoverFetcher()
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(backend: backend, covers: fetcher)
        defer { rig.cleanUp() }
        let coverText = "https://lh3.googleusercontent.com/col=w544-h544"
        let songs = [
            DownloadSamples.track(id(1)).withCover("https://lh3.googleusercontent.com/one=w544-h544"),
            DownloadSamples.track(id(2)).withCover("https://lh3.googleusercontent.com/two=w544-h544"),
        ]
        await rig.script(one, tracks: songs, cover: coverText)

        rig.service.downloadCollection(rig.request(one, cover: coverText))
        await rig.service.waitUntilIdle()

        let small = ["col", "one", "two"].map { URL(string: "https://lh3.googleusercontent.com/\($0)=w226-h226")! }
        #expect(Set(await fetcher.requested) == Set(small))
        let collectionCover = try #require(rig.service.localCoverURL(forCollection: one))
        #expect(rig.folder.read(collectionCover) == FakeCoverFetcher.image(for: small[0]))
        #expect(collectionCover.lastPathComponent == MusicDownloadCovers.name(for: small[0]))
        let songCover = try #require(rig.service.localCoverURL(forVideoId: id(1)))
        #expect(rig.folder.read(songCover) == FakeCoverFetcher.image(for: small[1]))
        #expect(rig.service.localCoverURL(forVideoId: id(9)) == nil)
        #expect(rig.service.localCoverURL(forCollection: two) == nil)
    }

    @Test("two songs with one thumbnail keep one file")
    func sharedThumbnail() async throws {
        let fetcher = FakeCoverFetcher()
        let rig = DownloadServiceRig(backend: FakeMusicBackend(), covers: fetcher)
        defer { rig.cleanUp() }
        let shared = "https://lh3.googleusercontent.com/album=w544-h544"
        await rig.script(one, tracks: [
            DownloadSamples.track(id(1)).withCover(shared), DownloadSamples.track(id(2)).withCover(shared),
        ])

        await downloaded(rig, one)

        let first = try #require(rig.service.localCoverURL(forVideoId: id(1)))
        #expect(rig.service.localCoverURL(forVideoId: id(2)) == first)
        let covers = rig.folder.root.appendingPathComponent("covers", isDirectory: true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: covers.path)) ?? []).count == 1)
    }

    @Test("a cover that cannot be fetched does not fail the song")
    func coverFailure() async throws {
        let fetcher = FakeCoverFetcher(failing: { _ in true })
        let rig = DownloadServiceRig(backend: FakeMusicBackend(), covers: fetcher)
        defer { rig.cleanUp() }
        await rig.script(one, tracks: [DownloadSamples.track(id(1)).withCover("https://lh3.googleusercontent.com/x=w544-h544")])

        await downloaded(rig, one)

        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 1, total: 1))
        #expect(rig.service.localCoverURL(forVideoId: id(1)) == nil)
    }

    @Test("a song downloaded on its own gets its thumbnail too, and loses it when removed")
    func standaloneCover() async throws {
        let fetcher = FakeCoverFetcher()
        let rig = DownloadServiceRig(covers: fetcher)
        defer { rig.cleanUp() }
        rig.service.download(DownloadSamples.track(id(1)).withCover("https://lh3.googleusercontent.com/solo=w544-h544"))
        #expect(await rig.settles(id(1), as: .downloaded))
        #expect(rig.service.localCoverURL(forVideoId: id(1)) != nil)

        rig.service.remove(videoId: id(1))
        await rig.service.waitUntilIdle()

        let covers = rig.folder.root.appendingPathComponent("covers", isDirectory: true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: covers.path)) ?? []).isEmpty)
        #expect(rig.service.localCoverURL(forVideoId: id(1)) == nil)
    }

    @Test("removing a collection removes its covers with its songs")
    func coversCleanedUp() async throws {
        let fetcher = FakeCoverFetcher()
        let rig = DownloadServiceRig(backend: FakeMusicBackend(), covers: fetcher)
        defer { rig.cleanUp() }
        let coverText = "https://lh3.googleusercontent.com/col=w544-h544"
        await rig.script(one, tracks: [DownloadSamples.track(id(1)).withCover("https://lh3.googleusercontent.com/one=w544-h544")], cover: coverText)
        rig.service.downloadCollection(rig.request(one, cover: coverText))
        await rig.service.waitUntilIdle()
        let covers = rig.folder.root.appendingPathComponent("covers", isDirectory: true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: covers.path)) ?? []).count == 2)

        rig.service.removeCollection(one)
        await rig.service.waitUntilIdle()

        #expect(((try? FileManager.default.contentsOfDirectory(atPath: covers.path)) ?? []).isEmpty)
        #expect(rig.service.localCoverURL(forCollection: one) == nil)
    }
}
