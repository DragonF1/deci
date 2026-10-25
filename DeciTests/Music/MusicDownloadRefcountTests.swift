// DeciTests/Music/MusicDownloadRefcountTests.swift
// The store is the only thing that knows which collections list a song, so it alone decides whether a removal deletes the
// file. The service's own copy of the lists lags the store, and these tests act in the gap. The real store and downloader
// run against a fake transport; every test works in a folder of its own under /Volumes/Storage/_test. Nothing touches the
// network.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicDownloadRefcount")
struct MusicDownloadRefcountTests {
    private let one = "VLPLone"

    private func id(_ number: Int) -> String { DownloadSamples.id(number) }
    private func file(_ number: Int) -> String { "\(id(number)).m4a" }

    @Test("removing a song on its own while the store saves a collection that lists it keeps the file")
    func removeWhileTheCollectionIsSaved() async throws {
        let blocker = StoreBlocker(browseId: one)
        let rig = DownloadServiceRig(backend: FakeMusicBackend(), beforeCollectionChange: blocker.hook)
        defer { rig.cleanUp() }
        // However the test ends, the store must not stay parked.
        defer { blocker.open() }
        rig.download(id(1))
        #expect(await rig.settles(id(1), as: .downloaded))
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))

        // The store is inside the save of the record that lists song 1, which the service does not know yet.
        rig.service.downloadCollection(rig.request(one))
        #expect(await rig.eventually { blocker.hasEntered })
        rig.service.remove(videoId: id(1))
        blocker.open()
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == [file(1), file(2)])
        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(rig.service.isCollectionOnly(id(1)))
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 2))
        #expect(await rig.requestCount(for: id(1)) == 4)
        #expect(await rig.store.entries[id(1)]?.standalone == false)
        #expect(rig.service.localStream(for: id(1)) != nil)
    }

    @Test("a song that finishes after its removal is kept when a stored collection lists it")
    func finishesAfterRemovalWhileListed() async throws {
        let gate = MusicTestGate()
        let payload = DownloadSamples.payload(35)
        let rig = DownloadServiceRig(handler: { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }, backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))

        rig.download(id(1))
        await rig.transport.waitForRequests(1)
        rig.service.downloadCollection(rig.request(one))
        #expect(await rig.eventually { rig.service.collectionState(for: one) != .none && rig.service.isCollectionOnly(id(1)) == false })
        rig.service.remove(videoId: id(1))
        await gate.open()
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == [file(1), file(2)])
        #expect(rig.service.state(for: id(1)) == .downloaded)
        #expect(rig.service.collectionState(for: one) == .downloaded(done: 2, total: 2))
    }

    @Test("removing a song only the store knows a collection lists leaves the file and clears the song's own flag")
    func removeAfterRelaunchBeforeTheRecordIsLoaded() async throws {
        let first = DownloadServiceRig(backend: FakeMusicBackend())
        await first.script(one, tracks: DownloadSamples.tracks(1...2))
        first.download(id(1))
        #expect(await first.settles(id(1), as: .downloaded))
        first.service.downloadCollection(first.request(one))
        await first.service.waitUntilIdle()
        let second = DownloadServiceRig(folder: first.folder, backend: FakeMusicBackend())
        defer { second.cleanUp() }

        // Before the index has loaded the service knows of no collection at all.
        second.service.remove(videoId: id(1))
        await second.service.waitUntilIdle()

        #expect(second.folder.audioFiles == [file(1), file(2)])
        #expect(await second.store.entries[id(1)]?.standalone == false)
        #expect(second.service.state(for: id(1)) == .downloaded)
        #expect(second.service.isCollectionOnly(id(1)))
    }

    @Test("a collection song whose file is damaged loses the file, stays listed, and the next sync fetches it again")
    func damagedCollectionSong() async throws {
        let rig = DownloadServiceRig(backend: FakeMusicBackend())
        defer { rig.cleanUp() }
        await rig.script(one, tracks: DownloadSamples.tracks(1...2))
        rig.service.downloadCollection(rig.request(one))
        await rig.service.waitUntilIdle()
        try DownloadSamples.payload(20).write(to: rig.folder.audioURL(id(1)))

        #expect(rig.service.localStream(for: id(1)) == nil)
        #expect(rig.service.state(for: id(1)) == .none)
        await rig.service.waitUntilIdle()
        #expect(rig.folder.audioFiles == [file(2)])
        #expect(await rig.store.collectionList()[one]?.videoIds == [id(1), id(2)])

        rig.service.sync(one)
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == [file(1), file(2)])
        #expect(rig.service.state(for: id(1)) == .downloaded)
    }
}
