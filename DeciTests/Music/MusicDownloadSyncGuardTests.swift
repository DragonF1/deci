// DeciTests/Music/MusicDownloadSyncGuardTests.swift
// When a sync may delete a downloaded song: the hold on a big drop, the greyed-out rows that are still part of the page,
// the count the header states, and the channel Liked music is read under. The real store and downloader run against a fake
// transport and a scripted backend; every test works in a folder of its own under /Volumes/Storage/_test. Nothing touches
// the network.

import Foundation
import os
import Testing
@testable import Deci

@MainActor
@Suite("MusicDownloadSyncGuard")
struct MusicDownloadSyncGuardTests {
    private let one = "VLPLone"
    private let two = "VLPLtwo"

    private func id(_ number: Int) -> String { DownloadSamples.id(number) }
    private func ids(_ range: ClosedRange<Int>) -> [String] { range.map(DownloadSamples.id) }
    private func files(_ range: ClosedRange<Int>) -> [String] { ids(range).map { "\($0).m4a" } }
    private func file(_ number: Int) -> String { "\(id(number)).m4a" }

    private func record(_ rig: DownloadServiceRig, _ browseId: String? = nil) async -> MusicDownloadStore.Collection? {
        await rig.store.collectionList()[browseId ?? one]
    }

    /// A rig with songs 1 to `count` downloaded as the collection `one`.
    private func downloadedRig(count: Int = 30, backend: FakeMusicBackend = FakeMusicBackend()) async -> DownloadServiceRig {
        let rig = DownloadServiceRig(backend: backend)
        await rig.script(one, tracks: DownloadSamples.tracks(1...count))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        return rig
    }

    private func sync(_ rig: DownloadServiceRig, _ browseId: String? = nil) async {
        rig.service.sync(browseId ?? one)
        await rig.service.waitUntilIdle()
    }

    // MARK: - A big drop is held

    @Test("a drop of more than a tenth of the list is held, and applied by a later read an hour on that still misses it")
    func largeDropHeldThenApplied() async throws {
        let rig = await downloadedRig()
        defer { rig.cleanUp() }
        let firstMiss = rig.clock.now
        // Ten songs left the page, and one is new.
        await rig.script(one, tracks: DownloadSamples.tracks(11...31))

        await sync(rig)

        let held = try #require(await record(rig))
        #expect(held.videoIds == ids(1...31))
        #expect(held.heldDrop == .init(videoIds: ids(1...10), since: firstMiss))
        #expect(rig.folder.audioFiles == files(1...31))
        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(await rig.requestCount(for: id(31)) == 4)

        // A second read a second short of the hour changes nothing, and the hold keeps its first time.
        rig.clock.advance(by: 3_599)
        await sync(rig)
        let waiting = try #require(await record(rig))
        #expect(waiting.heldDrop == held.heldDrop)
        #expect(waiting.videoIds == ids(1...31))
        #expect(rig.folder.audioFiles == files(1...31))

        rig.clock.advance(by: 1)
        await sync(rig)
        let applied = try #require(await record(rig))
        #expect(applied.videoIds == ids(11...31))
        #expect(applied.heldDrop == nil)
        #expect(rig.folder.audioFiles == files(11...31))
        #expect(rig.service.state(for: id(1)) == .none)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 21, total: 21))
    }

    @Test("songs that come back cancel the hold, and a later miss starts the hour again")
    func heldDropCancelledWhenSongsReturn() async throws {
        let rig = await downloadedRig()
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(11...30))
        await sync(rig)
        #expect(try #require(await record(rig)).heldDrop?.videoIds == ids(1...10))

        rig.clock.advance(by: 3_600)
        await rig.script(one, tracks: DownloadSamples.tracks(1...30))
        await sync(rig)
        let back = try #require(await record(rig))
        #expect(back.heldDrop == nil)
        #expect(back.videoIds == ids(1...30))
        #expect(rig.folder.audioFiles == files(1...30))

        // Missing again: an hour has passed since the first miss, but not since this one, so nothing goes.
        await rig.script(one, tracks: DownloadSamples.tracks(11...30))
        await sync(rig)
        let again = try #require(await record(rig))
        #expect(again.heldDrop == .init(videoIds: ids(1...10), since: rig.clock.now))
        #expect(again.videoIds == ids(1...30))
        #expect(rig.folder.audioFiles == files(1...30))
    }

    @Test("a hold survives a relaunch, and the first read an hour on that still misses the songs applies it")
    func holdSurvivesRelaunch() async throws {
        let first = await downloadedRig()
        await first.script(one, tracks: DownloadSamples.tracks(11...30))
        await sync(first)
        #expect(try #require(await record(first)).heldDrop?.videoIds == ids(1...10))

        let backend = FakeMusicBackend()
        let second = DownloadServiceRig(folder: first.folder, clock: first.clock, backend: backend)
        defer { second.cleanUp() }
        await second.script(one, tracks: DownloadSamples.tracks(11...30))
        await second.service.waitUntilLoaded()
        second.clock.advance(by: 3_600)

        await sync(second)

        let applied = try #require(await record(second))
        #expect(applied.videoIds == ids(11...30))
        #expect(applied.heldDrop == nil)
        #expect(second.folder.audioFiles == files(11...30))
    }

    @Test("what one sync deletes at once is at most five songs or a tenth of the list", arguments: [
        (1, true), (3, true), (5, true), (6, false), (15, false),
    ])
    func dropSize(removed: Int, goesAtOnce: Bool) async throws {
        let rig = await downloadedRig()
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks((removed + 1)...30))

        await sync(rig)

        let stored = try #require(await record(rig))
        if goesAtOnce {
            #expect(stored.videoIds == ids((removed + 1)...30))
            #expect(stored.heldDrop == nil)
            #expect(rig.folder.audioFiles == files((removed + 1)...30))
        } else {
            #expect(stored.videoIds == ids(1...30))
            #expect(stored.heldDrop?.videoIds == ids(1...removed))
            #expect(rig.folder.audioFiles == files(1...30))
        }
    }

    @Test("a hold lets the songs that stay be reordered and the songs that are new be downloaded")
    func holdDoesNotBlockAdditions() async throws {
        let rig = await downloadedRig()
        defer { rig.cleanUp() }
        await rig.script(one, tracks: Array(DownloadSamples.tracks(11...30).reversed()) + DownloadSamples.tracks(31...32))

        await sync(rig)

        let stored = try #require(await record(rig))
        #expect(Set(stored.videoIds) == Set(ids(1...32)))
        // The songs held come first, then the page in its own order.
        #expect(stored.videoIds == ids(1...10) + Array(ids(11...30).reversed()) + ids(31...32))
        #expect(stored.heldDrop?.videoIds == ids(1...10))
        #expect(rig.folder.audioFiles == files(1...32))
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 32, total: 32))
    }

    // MARK: - Rows the page greys out

    @Test("rows the page lists but greys out stay in the list with their files, and are never fetched")
    func greyedRowsKept() async throws {
        let rig = await downloadedRig()
        defer { rig.cleanUp() }
        let before = await rig.transport.requestCount
        // Ten songs playable, five greyed on the first page, fifteen and one the list never had on the second.
        await rig.script(
            one, tracks: DownloadSamples.tracks(1...10), continuation: "c1", subtitle: "Playlist \u{2022} 30 songs",
            unavailable: ids(11...15)
        )
        await rig.backend?.setMoreTracks(
            browseId: one, continuation: "c1", tracks: [], unavailable: ids(16...30) + [id(99)]
        )

        await sync(rig)

        let stored = try #require(await record(rig))
        #expect(stored.videoIds == ids(1...30))
        #expect(stored.heldDrop == nil)
        #expect(stored.syncResult == .complete)
        #expect(rig.folder.audioFiles == files(1...30))
        #expect(await rig.transport.requestCount == before)
        #expect(await rig.requestCount(for: id(99)) == 0)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 30, total: 30))
    }

    @Test("a row that is greyed out and not on disk is not queued, and stays listed")
    func greyedRowNotQueued() async throws {
        let payload = DownloadSamples.payload(35)
        // Song 3 cannot be fetched, so the first download leaves it listed and not on disk.
        let rig = DownloadServiceRig(handler: { request, _ in
            request.videoId == DownloadSamples.id(3)
                ? FakeDownloadTransport.status(404)
                : FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        #expect(await rig.requestCount(for: id(3)) == 1)
        await rig.script(one, tracks: DownloadSamples.tracks(1...2), subtitle: "Playlist \u{2022} 3 songs", unavailable: [id(3)])

        await sync(rig)

        #expect(try #require(await record(rig)).videoIds == ids(1...3))
        #expect(await rig.requestCount(for: id(3)) == 1)
        // Still marked as the first try left it (failed), not queued again.
        #expect(rig.service.state(for: id(3)) == .failed)
    }

    // MARK: - The count in the header

    @Test("a page that lists far fewer songs than its header states deletes nothing, and still adds")
    func shortCountBlocksDeletes() async throws {
        let rig = await downloadedRig()
        defer { rig.cleanUp() }
        // 28 listed of 40 stated; songs 28 to 30 are missing, a small drop that would go at once on a complete read.
        await rig.script(
            one, tracks: DownloadSamples.tracks(1...27) + [DownloadSamples.track(id(31), title: "Song 31")],
            subtitle: "Playlist \u{2022} 40 songs"
        )

        await sync(rig)

        let kept = try #require(await record(rig))
        #expect(Set(kept.videoIds) == Set(ids(1...31)))
        #expect(kept.heldDrop == nil)
        #expect(rig.folder.audioFiles == files(1...31))
        #expect(await rig.requestCount(for: id(31)) == 4)

        // The same page with a header that matches it: now the three songs go.
        await rig.script(
            one, tracks: DownloadSamples.tracks(1...27) + [DownloadSamples.track(id(31), title: "Song 31")],
            subtitle: "Playlist \u{2022} 28 songs"
        )
        await sync(rig)
        #expect(try #require(await record(rig)).videoIds == ids(1...27) + [id(31)])
        #expect(rig.folder.audioFiles == files(1...27) + [file(31)])
    }

    @Test("a header that states no count does not block a small removal")
    func noStatedCountSkipsTheCheck() async throws {
        let rig = await downloadedRig()
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...27), subtitle: "Playlist")

        await sync(rig)

        #expect(try #require(await record(rig)).videoIds == ids(1...27))
        #expect(rig.folder.audioFiles == files(1...27))
    }

    @Test("a count that falls short by no more than five, or a tenth, is trusted")
    func shortByLittleIsComplete() async throws {
        let rig = await downloadedRig()
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...27), subtitle: "Playlist \u{2022} 31 songs")

        await sync(rig)

        #expect(try #require(await record(rig)).videoIds == ids(1...27))
    }

    // MARK: - The channel under a Liked music read

    /// A source that reads pages from `backend` and answers the session's identity from `answers`, one answer per call, the
    /// last one for every call after.
    private func source(over backend: FakeMusicBackend, identities answers: [String]) -> MusicCollectionSource {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        return MusicCollectionSource(
            page: { try await backend.page(browseId: $0) },
            moreTracks: { try await backend.moreTracks(browseId: $0, continuation: $1) },
            isSignedIn: { true },
            identity: {
                calls.withLock { (count: inout Int) -> String in
                    defer { count += 1 }
                    return answers[min(count, answers.count - 1)]
                }
            }
        )
    }

    @Test("Liked music read while the channel changes keeps everything")
    func channelChangesDuringSync() async throws {
        let first = DownloadServiceRig(backend: FakeMusicBackend())
        await first.script("VLLM", tracks: DownloadSamples.tracks(1...3))
        first.service.downloadCollection(first.request("VLLM"))
        await first.service.waitUntilIdle()
        #expect(try #require(await record(first, "VLLM")).channelKey == "channel-a")

        // The channel is the stored one before the page is read and another after it.
        let backend = FakeMusicBackend()
        let second = DownloadServiceRig(
            folder: first.folder, clock: first.clock, backend: backend,
            source: source(over: backend, identities: ["channel-a", "channel-b"])
        )
        defer { second.cleanUp() }
        await second.script("VLLM", tracks: DownloadSamples.tracks(1...1))
        await second.service.waitUntilLoaded()

        await sync(second, "VLLM")

        let kept = try #require(await record(second, "VLLM"))
        #expect(kept.videoIds == ids(1...3))
        #expect(kept.syncResult == .unreachable)
        #expect(second.folder.audioFiles == files(1...3))
    }

    @Test("a first download of Liked music read while the channel changes stores nothing")
    func channelChangesDuringFirstDownload() async throws {
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(backend: backend, source: source(over: backend, identities: ["channel-a", "channel-b"]))
        defer { rig.cleanUp() }
        await rig.script("VLLM", tracks: DownloadSamples.tracks(1...3))

        rig.service.downloadCollection(rig.request("VLLM"))
        await rig.service.waitUntilIdle()

        #expect(rig.service.collectionState(for: "VLLM") == .none)
        #expect(await rig.store.collectionList().isEmpty)
        #expect(await rig.transport.requestCount == 0)
    }

    @Test("a first download of Liked music stores the channel read before the page, not one read after it")
    func storesTheKeyReadBeforeThePage() async throws {
        let backend = FakeMusicBackend()
        // Two reads (before and after the page) agree; a third would be another channel.
        let rig = DownloadServiceRig(
            backend: backend, source: source(over: backend, identities: ["channel-a", "channel-a", "channel-b"])
        )
        defer { rig.cleanUp() }
        await rig.script("VLLM", tracks: DownloadSamples.tracks(1...2))

        rig.service.downloadCollection(rig.request("VLLM"))
        await rig.service.waitUntilIdle()

        #expect(try #require(await record(rig, "VLLM")).channelKey == "channel-a")
        #expect(rig.service.collectionState(for: "VLLM") == .downloaded(done: 2, total: 2))
    }

    // MARK: - Playback while a sync waits for the disk

    @Test("a song that starts playing while the sync waits for the disk keeps its file when the sync removes it")
    func playbackStartsDuringTheWait() async throws {
        // The store parks in the removal of collection two, after its first download.
        let blocker = StoreBlocker(browseId: two, skipping: 1)
        let backend = FakeMusicBackend()
        let rig = DownloadServiceRig(backend: backend, beforeCollectionChange: blocker.hook)
        defer { rig.cleanUp() }
        // However the test ends, the store must not stay parked.
        defer { blocker.open() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...3))
        await rig.script(two, tracks: DownloadSamples.tracks(4...5))
        rig.service.downloadCollection(rig.request(one))
        rig.service.downloadCollection(rig.request(two))
        await rig.service.waitUntilIdle()

        // The page of one now lists only song 1, and its read is held.
        let gate = MusicTestGate()
        await rig.script(one, tracks: DownloadSamples.tracks(1...1))
        await backend.setPageGate(one, gate)
        rig.service.sync(one)
        #expect(await rig.eventually { await backend.pageCalls.filter { $0 == one }.count == 2 })
        rig.service.removeCollection(two)
        #expect(await rig.eventually { blocker.hasEntered })

        // The read ends while the store is busy, and song 3 starts playing from its file before the store is free.
        await gate.open()
        try? await Task.sleep(for: .milliseconds(150))
        rig.service.noteLocalPlayback(of: id(3))
        blocker.open()
        await rig.service.waitUntilIdle()

        #expect(try #require(await record(rig)).videoIds == ids(1...1))
        #expect(rig.folder.audioFiles == [file(1), file(3)])
        rig.service.noteLocalPlayback(of: nil)
        await rig.service.waitUntilIdle()
        #expect(rig.folder.audioFiles == files(1...1))
    }
}
