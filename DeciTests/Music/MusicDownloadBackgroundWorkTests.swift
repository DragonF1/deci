// DeciTests/Music/MusicDownloadBackgroundWorkTests.swift
// What the download queue must not do on the way: rewrite the whole index for every song, or wait for a cover picture
// before the next song. The real store and downloader run against a fake transport; every test works in a folder of its
// own under /Volumes/Storage/_test. Nothing touches the network.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicDownloadBackgroundWork")
struct MusicDownloadBackgroundWorkTests {
    private let one = "VLPLone"

    private func id(_ number: Int) -> String { DownloadSamples.id(number) }

    private func coverTracks(_ count: Int) -> [MusicTrack] {
        (1...count).map {
            DownloadSamples.track(id($0), title: "Song \($0)").withCover("https://lh3.googleusercontent.com/s\($0)=w544-h544")
        }
    }

    // MARK: - The index

    @Test("a collection of two hundred songs writes the index a handful of times, and the file lists every song")
    func indexWritesAreCoalesced() async throws {
        let rig = DownloadServiceRig(backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...200))

        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()

        let writes = await rig.store.indexWriteCount
        #expect(writes >= 1)
        #expect(writes <= 8)
        // The queue going idle wrote what was waiting, without a wait for the timer.
        let data = try #require(rig.folder.read(rig.folder.indexURL))
        let index = try #require(MusicDownloadStore.Index.decode(data))
        #expect(index.entries.count == 200)
        #expect(index.collections[one]?.videoIds.count == 200)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 200, total: 200))
    }

    @Test("quitting writes the changes that were waiting for the timer")
    func quitFlushesTheIndex() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        await rig.service.waitUntilLoaded()
        let part = try await rig.store.beginPart(videoId: id(1))
        try DownloadSamples.payload(35).write(to: part)
        _ = try await rig.store.commit(DownloadSamples.track(id(1)), expectedBytes: 35, durationSeconds: 200, standalone: true)
        #expect(await rig.store.indexWriteCount == 0)

        rig.service.flushOnQuit()

        #expect(await rig.store.indexWriteCount == 1)
        let data = try #require(rig.folder.read(rig.folder.indexURL))
        #expect(MusicDownloadStore.Index.decode(data)?.entries[id(1)] != nil)
    }

    // MARK: - Covers

    @Test("a cover that is slow to arrive does not hold up the next song, and arrives when it can")
    func slowCoverDoesNotHoldTheQueue() async throws {
        let gate = MusicTestGate()
        let fetcher = FakeCoverFetcher(gate: gate)
        let rig = DownloadServiceRig(backend: FakeMusicBackend(), covers: fetcher)
        defer { rig.cleanUp() }
        // However the test ends, the covers must not stay parked.
        defer { Task { await gate.open() } }
        await rig.script(one, tracks: coverTracks(3))

        rig.service.downloadCollection(rig.request(one))
        #expect(await rig.eventually { rig.service.collectionState(for: one) == .downloaded(done: 3, total: 3) })
        #expect(await fetcher.requested.count >= 1)
        #expect(rig.service.localCoverURL(forVideoId: id(1)) == nil)

        await gate.open()
        await rig.service.waitUntilIdle()

        for number in 1...3 { #expect(rig.service.localCoverURL(forVideoId: id(number)) != nil) }
        #expect(Set(await fetcher.requested).count == 3)
    }

    @Test("a cover that arrives after its song was removed is not kept")
    func coverAfterRemoval() async throws {
        let gate = MusicTestGate()
        let fetcher = FakeCoverFetcher(gate: gate)
        let rig = DownloadServiceRig(backend: FakeMusicBackend(), covers: fetcher)
        defer { rig.cleanUp() }
        defer { Task { await gate.open() } }
        await rig.script(one, tracks: coverTracks(1))

        rig.service.downloadCollection(rig.request(one))
        #expect(await rig.eventually { await fetcher.requested.count == 1 })
        rig.service.removeCollection(one)
        await gate.open()
        await rig.service.waitUntilIdle()

        let covers = rig.folder.root.appendingPathComponent("covers", isDirectory: true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: covers.path)) ?? []).isEmpty)
        #expect(rig.service.localCoverURL(forVideoId: id(1)) == nil)
        #expect(rig.folder.audioFiles.isEmpty)
    }
}
