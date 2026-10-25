// DeciTests/Music/MusicDownloadServiceTests.swift
// What the rest of the app sees of downloads: a song's state from none through queued and downloading to downloaded
// (or failed), one song at a time in the order asked, progress that reaches a row a few times a second at most, the
// local stream that exists only while the file does, and removal at every stage. The real downloader and store run
// against a fake transport and a folder under /Volumes/Storage/_test; nothing touches the network.

import Foundation
import Observation
import os
import Testing
@testable import Deci

/// A service on a folder of its own, fed by a fake transport. Chunks are 10 bytes, so the default 35-byte song takes
/// four requests.
@MainActor
struct DownloadServiceRig {
    let folder: DownloadTestFolder
    let clock: MutableClock
    let transport: FakeDownloadTransport
    let store: MusicDownloadStore
    let service: MusicDownloadService
    /// The backend collection pages come from; nil on a rig that downloads single songs only (or reads from a source built
    /// by hand).
    let backend: FakeMusicBackend?
    /// Every wait the service made (gaps between songs, back-offs). None of them really waits.
    let pause: RecordingPause

    init(
        folder: DownloadTestFolder = DownloadTestFolder(),
        clock: MutableClock = MutableClock(),
        payload: Data = DownloadSamples.payload(35),
        handler: FakeDownloadTransport.Handler? = nil,
        storeNow: @escaping @Sendable () -> Date = { DownloadSamples.fixedDate },
        backend: FakeMusicBackend? = nil,
        source: MusicCollectionSource? = nil,
        covers: (any MusicCoverFetching)? = nil,
        resolver: FakeDownloadResolver = FakeDownloadResolver(),
        pause: RecordingPause = RecordingPause(),
        beforeCollectionChange: (@Sendable (String) -> Void)? = nil
    ) {
        self.folder = folder
        self.clock = clock
        self.backend = backend
        self.pause = pause
        store = MusicDownloadStore(root: folder.root, now: storeNow, beforeCollectionChange: beforeCollectionChange)
        transport = FakeDownloadTransport(handler: handler ?? FakeDownloadTransport.serving(payload))
        let downloader = MusicDownloader(
            store: store, transport: transport, resolve: resolver.closure, chunkSize: 10,
            now: { clock.now }
        )
        service = MusicDownloadService(
            store: store,
            downloader: downloader,
            source: source ?? backend.map { MusicCollectionSource(backend: $0) },
            covers: covers,
            pause: pause.closure,
            now: { clock.now }
        )
    }

    /// Removes the folder once the service has nothing left to write. A removal answers at once and the disk follows, so
    /// deleting the folder right away could be followed by a write that puts it back.
    func cleanUp() {
        let service = service, folder = folder
        Task { @MainActor in
            await service.waitUntilIdle()
            folder.remove()
        }
    }

    func download(_ id: String) {
        service.download(DownloadSamples.track(id))
    }

    /// True when, once everything asked for has run to its end (the queue empty, the disk caught up), the song is in
    /// `state`. Only for states a song stays in: downloaded, failed, none.
    func settles(_ id: String, as state: MusicDownloadState) async -> Bool {
        await service.waitUntilIdle()
        return service.state(for: id) == state
    }

    /// The video id of every request so far, in the order they went out.
    var requestedIDs: [String] {
        get async { await transport.requests.map(\.videoId) }
    }
}

/// Reads a song's state from inside the transport, which is the state a row would show at that moment.
@MainActor
private final class StateProbe {
    var service: MusicDownloadService?
    private(set) var samples: [MusicDownloadState] = []

    func sample(_ id: String) {
        if let service { samples.append(service.state(for: id)) }
    }
}

/// Removes a song through the service the first time the store reads its clock, which a commit does between renaming
/// the finished file into place and listing the song: the moment a removal can still arrive after the last check for
/// cancelling.
@MainActor
private final class CommitHook {
    var service: MusicDownloadService?
    var videoId: String?

    func fire() {
        guard let videoId, let service else { return }
        self.videoId = nil
        service.remove(videoId: videoId)
    }
}

/// Watches two songs' states the way two rows do and says which of them would have been redrawn.
@MainActor
private final class RedrawProbe {
    var service: MusicDownloadService?
    private let firstFired = OSAllocatedUnfairLock(initialState: false)
    private let secondFired = OSAllocatedUnfairLock(initialState: false)
    private(set) var seen: (first: Bool, second: Bool)?

    func watch(first: String, second: String) {
        guard let service else { return }
        let firstFired = firstFired, secondFired = secondFired
        withObservationTracking { _ = service.state(for: first) } onChange: { firstFired.withLock { $0 = true } }
        withObservationTracking { _ = service.state(for: second) } onChange: { secondFired.withLock { $0 = true } }
    }

    func capture() {
        seen = (firstFired.withLock { $0 }, secondFired.withLock { $0 })
    }
}

@MainActor
@Suite("MusicDownloadService")
struct MusicDownloadServiceTests {
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB
    private let idC = DownloadSamples.idC

    // MARK: - States

    @Test("a song goes none, queued, downloading, downloaded")
    func stateTransitions() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let rig = DownloadServiceRig { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }
        #expect(rig.service.state(for: idA) == .none)

        rig.download(idA)

        // Queued at once, before any work has had a turn.
        #expect(rig.service.state(for: idA) == .queued)
        await rig.transport.waitForRequests(1)
        #expect(rig.service.state(for: idA) == .downloading(fraction: 0))
        #expect(rig.service.localStream(for: idA) == nil)
        await gate.open()
        #expect(await rig.settles(idA, as: .downloaded))
        #expect(rig.service.localStream(for: idA) != nil)
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
    }

    @Test("a download that fails shows failed, leaves nothing behind, and can be asked for again")
    func failureThenRetry() async throws {
        let payload = DownloadSamples.payload(35)
        let failing = OSAllocatedUnfairLock(initialState: true)
        let rig = DownloadServiceRig { request, index in
            if failing.withLock({ $0 }), index >= 1 { throw URLError(.timedOut) }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }

        rig.download(idA)
        #expect(await rig.settles(idA, as: .failed))
        #expect(rig.service.localStream(for: idA) == nil)
        #expect(rig.folder.audioFiles.isEmpty)

        failing.withLock { $0 = false }
        rig.download(idA)

        #expect(rig.service.state(for: idA) == .queued)
        #expect(await rig.settles(idA, as: .downloaded))
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
    }

    @Test("an id that cannot be a video id fails at once and goes nowhere near the disk or the network")
    func invalidIdFails() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }

        rig.service.download(DownloadSamples.track("../../etc/passwd"))

        #expect(await rig.settles("../../etc/passwd", as: .failed))
        #expect(await rig.transport.requestCount == 0)
        #expect(!rig.folder.exists(rig.folder.root))
        #expect(rig.service.localStream(for: "../../etc/passwd") == nil)
    }

    @Test("asking again for a song that is queued, downloading or downloaded changes nothing")
    func duplicateIgnored() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let rig = DownloadServiceRig { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }

        rig.download(idA)
        rig.download(idA)
        await rig.transport.waitForRequests(1)
        #expect(rig.service.state(for: idA) == .downloading(fraction: 0))
        rig.download(idA)
        await gate.open()
        #expect(await rig.settles(idA, as: .downloaded))
        rig.download(idA)
        #expect(rig.service.state(for: idA) == .downloaded)

        // One song, four requests: nothing was fetched twice.
        #expect(await rig.requestedIDs == Array(repeating: idA, count: 4))
    }

    // MARK: - The queue

    @Test("songs download one at a time, in the order they were asked for")
    func serialQueue() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let rig = DownloadServiceRig { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }

        rig.download(idA)
        rig.download(idB)
        rig.download(idC)
        #expect([idA, idB, idC].map(rig.service.state(for:)) == [.queued, .queued, .queued])

        // The first song is held at its first request: the others wait and have asked for nothing.
        await rig.transport.waitForRequests(1)
        #expect(rig.service.state(for: idA) == .downloading(fraction: 0))
        #expect(rig.service.state(for: idB) == .queued)
        #expect(rig.service.state(for: idC) == .queued)
        await gate.open()
        #expect(await rig.settles(idC, as: .downloaded))

        #expect(rig.service.state(for: idA) == .downloaded)
        #expect(rig.service.state(for: idB) == .downloaded)
        let expected = [idA, idB, idC].flatMap { Array(repeating: $0, count: 4) }
        #expect(await rig.requestedIDs == expected)
    }

    @Test("a song that fails does not stop the ones queued behind it")
    func failureFreesTheQueue() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloadServiceRig { request, _ in
            if request.videoId == DownloadSamples.idA { throw URLError(.timedOut) }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }

        rig.download(idA)
        rig.download(idB)

        #expect(await rig.settles(idB, as: .downloaded))
        #expect(rig.service.state(for: idA) == .failed)
        #expect(rig.folder.audioFiles == ["\(idB).m4a"])
    }

    // MARK: - Progress

    @Test("progress reaches the row about four times a second at most, however fast the chunks come")
    func progressThrottled() async throws {
        let payload = DownloadSamples.payload(100)
        let clock = MutableClock()
        let probe = StateProbe()
        let rig = DownloadServiceRig(clock: clock, payload: payload) { request, _ in
            await probe.sample(request.videoId)
            // Each chunk takes a tenth of a second.
            clock.advance(by: 0.1)
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }
        probe.service = rig.service

        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))

        // What the row showed when each of the ten requests went out: one new value every 0.25 s or more.
        let fractions: [Double] = [0, 0, 0, 0.3, 0.3, 0.3, 0.6, 0.6, 0.6, 0.9]
        #expect(probe.samples == fractions.map { .downloading(fraction: $0) })
    }

    @Test("with the clock standing still the row shows the start and then the finished song")
    func progressHeldBack() async throws {
        let payload = DownloadSamples.payload(100)
        let probe = StateProbe()
        let rig = DownloadServiceRig(payload: payload) { request, _ in
            await probe.sample(request.videoId)
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }
        probe.service = rig.service

        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))

        #expect(probe.samples == Array(repeating: .downloading(fraction: 0), count: 10))
    }

    @Test("a progress update redraws the row being downloaded and no other row")
    func progressRedrawsOnlyItsRow() async throws {
        let payload = DownloadSamples.payload(60)
        let clock = MutableClock()
        let probe = RedrawProbe()
        let rig = DownloadServiceRig(clock: clock, payload: payload) { request, index in
            clock.advance(by: 1)
            // Two rows start watching as the first song's second chunk is asked for, and are read three chunks on.
            if index == 1 { await probe.watch(first: DownloadSamples.idA, second: DownloadSamples.idB) }
            if index == 4 { await probe.capture() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }
        probe.service = rig.service

        rig.download(idA)
        rig.download(idB)
        #expect(await rig.settles(idB, as: .downloaded))

        let seen = try #require(probe.seen)
        #expect(seen.first, "The row being downloaded was not redrawn by its progress")
        #expect(!seen.second, "A queued row was redrawn by another song's progress")
    }

    // MARK: - The local stream

    @Test("the local stream is the file on disk: never expiring, with no headers and no tracking")
    func localStreamShape() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))

        let stream = try #require(rig.service.localStream(for: idA))

        #expect(stream.videoId == idA)
        #expect(stream.url.isFileURL)
        #expect(stream.url.path == rig.folder.audioURL(idA).path)
        #expect(stream.expiresAt == .distantFuture)
        #expect(stream.httpHeaders.isEmpty)
        #expect(stream.durationSeconds == 200)
        #expect(stream.playbackTrackingURL == nil)
        #expect(stream.watchtimeTrackingURL == nil)
    }

    @Test("a song nothing was downloaded for has no local stream")
    func localStreamNeedsDownload() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))

        #expect(rig.service.localStream(for: idB) == nil)
        #expect(rig.service.localStream(for: "") == nil)
        #expect(rig.service.localStream(for: "../../etc/passwd") == nil)
    }

    @Test("a half-written part is never offered as a stream")
    func partIsNotOffered() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let rig = DownloadServiceRig { request, index in
            if index == 2 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }

        rig.download(idA)
        await rig.transport.waitForRequests(3)

        #expect(rig.folder.exists(rig.folder.partURL(idA)))
        #expect(rig.service.localStream(for: idA) == nil)
        await gate.open()
        #expect(await rig.settles(idA, as: .downloaded))
        #expect(rig.service.localStream(for: idA) != nil)
    }

    @Test("a file that vanished from disk is not offered, and the song stops showing as downloaded")
    func vanishedFile() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))

        try FileManager.default.removeItem(at: rig.folder.audioURL(idA))

        #expect(rig.service.localStream(for: idA) == nil)
        #expect(rig.service.state(for: idA) == .none)
        await rig.service.waitUntilIdle()
        #expect(await rig.store.entries.isEmpty)
    }

    @Test("downloads from an earlier launch are offered once the index has loaded, and not before")
    func earlierLaunch() async throws {
        let first = DownloadServiceRig()
        defer { first.cleanUp() }
        first.download(idA)
        #expect(await first.settles(idA, as: .downloaded))

        // A second service on the same folder, as after a relaunch.
        let second = DownloadServiceRig(folder: first.folder)
        #expect(second.service.state(for: idA) == .none)
        #expect(second.service.localStream(for: idA) == nil)
        await second.service.waitUntilLoaded()

        #expect(second.service.state(for: idA) == .downloaded)
        #expect(second.service.localStream(for: idA)?.url.path == first.folder.audioURL(idA).path)
        #expect(await second.transport.requestCount == 0)
    }

    // MARK: - Removing

    @Test("removing a downloaded song deletes its file and entry, and a later launch agrees")
    func removeDownloaded() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idA)
        rig.download(idB)
        #expect(await rig.settles(idB, as: .downloaded))

        rig.service.remove(videoId: idA)

        // Gone from the app at once; the disk follows.
        #expect(rig.service.state(for: idA) == .none)
        #expect(rig.service.localStream(for: idA) == nil)
        await rig.service.waitUntilIdle()
        #expect(rig.folder.audioFiles == ["\(DownloadSamples.idB).m4a"])
        #expect(rig.service.state(for: idB) == .downloaded)
        let later = MusicDownloadStore(root: rig.folder.root, now: { DownloadSamples.fixedDate })
        #expect(await later.load().keys.sorted() == [idB])
    }

    @Test("removing a song while it downloads stops it, deletes the part, and the queue carries on")
    func removeRunning() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let rig = DownloadServiceRig { request, index in
            if index == 2 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }
        rig.download(idA)
        rig.download(idB)
        await rig.transport.waitForRequests(3)

        rig.service.remove(videoId: idA)

        #expect(rig.service.state(for: idA) == .none)
        #expect(rig.service.state(for: idB) == .queued)
        await gate.open()
        #expect(await rig.settles(idB, as: .downloaded))
        #expect(rig.service.state(for: idA) == .none)
        #expect(rig.service.localStream(for: idA) == nil)
        #expect(rig.folder.audioFiles == ["\(idB).m4a"])
        // Three requests for the song that was cut off, four for the next.
        #expect(await rig.requestedIDs == [idA, idA, idA, idB, idB, idB, idB])
    }

    @Test("removing a song that is only queued means it is never fetched")
    func removeQueued() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let rig = DownloadServiceRig { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }
        rig.download(idA)
        rig.download(idB)
        await rig.transport.waitForRequests(1)

        rig.service.remove(videoId: idB)

        #expect(rig.service.state(for: idB) == .none)
        await gate.open()
        #expect(await rig.settles(idA, as: .downloaded))
        #expect(await rig.requestedIDs == Array(repeating: idA, count: 4))
        #expect(rig.folder.audioFiles == ["\(idA).m4a"])
    }

    @Test("removing a failed song clears the failure")
    func removeFailed() async throws {
        let rig = DownloadServiceRig { _, _ in throw URLError(.timedOut) }
        defer { rig.cleanUp() }
        rig.download(idA)
        #expect(await rig.settles(idA, as: .failed))

        rig.service.remove(videoId: idA)

        #expect(rig.service.state(for: idA) == .none)
    }

    @Test("removing a song nothing was downloaded for does no harm")
    func removeUnknown() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))

        rig.service.remove(videoId: idB)
        rig.service.remove(videoId: "../../etc/passwd")

        #expect(rig.service.state(for: idA) == .downloaded)
        #expect(rig.service.state(for: idB) == .none)
        #expect(rig.folder.audioFiles == ["\(idA).m4a"])
    }

    @Test("a song removed and asked for again is fetched again from the start")
    func removeThenDownloadAgain() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloadServiceRig(payload: payload)
        defer { rig.cleanUp() }
        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))

        rig.service.remove(videoId: idA)
        rig.download(idA)

        #expect(rig.service.state(for: idA) == .queued)
        #expect(await rig.settles(idA, as: .downloaded))
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
        #expect(await rig.requestedIDs == Array(repeating: idA, count: 8))
        #expect(rig.service.localStream(for: idA) != nil)
    }

    @Test("a song removed just as its file is committed ends up removed: not downloaded, no file, no entry")
    func removedAsItFinishes() async throws {
        let hook = CommitHook()
        let rig = DownloadServiceRig(
            payload: DownloadSamples.payload(10),
            storeNow: {
                // On the store's own thread, with the main actor free: the test is waiting on the service.
                DispatchQueue.main.sync { MainActor.assumeIsolated { hook.fire() } }
                return DownloadSamples.fixedDate
            }
        )
        defer { rig.cleanUp() }
        hook.service = rig.service
        hook.videoId = idA

        rig.download(idA)
        #expect(await rig.settles(idA, as: .none))

        #expect(rig.service.localStream(for: idA) == nil)
        #expect(rig.folder.audioFiles.isEmpty)
        #expect(await rig.store.entries.isEmpty)
        let later = MusicDownloadStore(root: rig.folder.root, now: { DownloadSamples.fixedDate })
        #expect(await later.load().isEmpty)
    }

    @Test("a running song removed and asked for again at once downloads cleanly; the old run's cleanup spares the new")
    func removeRunningThenDownloadAgain() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let rig = DownloadServiceRig { request, index in
            if index == 2 {
                await gate.wait()
                try Task.checkCancellation()
            }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }
        rig.download(idA)
        await rig.transport.waitForRequests(3)

        rig.service.remove(videoId: idA)
        rig.download(idA)
        #expect(rig.service.state(for: idA) == .queued)
        await gate.open()

        #expect(await rig.settles(idA, as: .downloaded))
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
        #expect(rig.folder.audioFiles == ["\(idA).m4a"])
        #expect(await rig.store.isDownloaded(idA))
        // Three requests for the run that was cut off and four for the new one, all from the start.
        #expect(await rig.transport.requests.map(\.range) == [0...9, 10...19, 20...29, 0...9, 10...19, 20...29, 30...34])
        let later = MusicDownloadStore(root: rig.folder.root, now: { DownloadSamples.fixedDate })
        #expect(await later.load().keys.sorted() == [idA])
    }

    @Test("removing the song that is playing from its file drops it at once and deletes the file when playback leaves it")
    func removePlayingSong() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idA)
        rig.download(idB)
        #expect(await rig.settles(idB, as: .downloaded))
        rig.service.noteLocalPlayback(of: idA)

        rig.service.remove(videoId: idA)

        #expect(rig.service.state(for: idA) == .none)
        #expect(rig.service.localStream(for: idA) == nil)
        await rig.service.waitUntilIdle()
        // The file is still under the player, and the index no longer lists the song.
        #expect(rig.folder.audioFiles == ["\(idA).m4a", "\(idB).m4a"])
        let index = try #require(rig.folder.read(rig.folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
        #expect(index.entries.keys.sorted() == [idB])

        rig.service.noteLocalPlayback(of: idB)
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == ["\(idB).m4a"])
    }

    @Test("the kept file goes when playback stops altogether too")
    func removePlayingSongThenStop() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))
        rig.service.noteLocalPlayback(of: idA)
        rig.service.remove(videoId: idA)
        await rig.service.waitUntilIdle()
        #expect(rig.folder.audioFiles == ["\(idA).m4a"])

        rig.service.noteLocalPlayback(of: nil)
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles.isEmpty)
    }

    @Test("a song downloaded again while its old file was kept for playback keeps its new file")
    func redownloadWhileKept() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloadServiceRig(payload: payload)
        defer { rig.cleanUp() }
        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))
        rig.service.noteLocalPlayback(of: idA)
        rig.service.remove(videoId: idA)
        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))

        rig.service.noteLocalPlayback(of: nil)
        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: idA) == .downloaded)
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
        #expect(rig.service.localStream(for: idA) != nil)
    }

    @Test("removing a song that is not the one playing deletes its file at once")
    func removeOtherThanPlaying() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idA)
        rig.download(idB)
        #expect(await rig.settles(idB, as: .downloaded))
        rig.service.noteLocalPlayback(of: idB)

        rig.service.remove(videoId: idA)
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == ["\(idB).m4a"])
    }

    // MARK: - Disk trouble

    @Test("a folder the disk refuses shows failed, and the next try after it is fixed works")
    func diskRefusesThenRecovers() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        await rig.service.waitUntilLoaded()
        try FileManager.default.createDirectory(at: rig.folder.audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.folder.audioDirectory.path)

        rig.download(idA)

        #expect(await rig.settles(idA, as: .failed))
        #expect(await rig.transport.requestCount == 0)
        #expect(rig.service.localStream(for: idA) == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.folder.audioDirectory.path)
        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))
    }

    @Test("a file that is not the size the index says is not offered, and the song and its file go")
    func truncatedFile() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idA)
        #expect(await rig.settles(idA, as: .downloaded))
        try DownloadSamples.payload(20).write(to: rig.folder.audioURL(idA))

        #expect(rig.service.localStream(for: idA) == nil)
        #expect(rig.service.state(for: idA) == .none)
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles.isEmpty)
        #expect(await rig.store.entries.isEmpty)
    }

    @Test("downloads of an earlier launch whose file is the wrong size are dropped as the index loads")
    func truncatedFileAtLaunch() async throws {
        let first = DownloadServiceRig()
        defer { first.cleanUp() }
        first.download(idA)
        #expect(await first.settles(idA, as: .downloaded))
        try DownloadSamples.payload(20).write(to: first.folder.audioURL(idA))

        let second = DownloadServiceRig(folder: first.folder)
        await second.service.waitUntilLoaded()

        #expect(second.service.state(for: idA) == .none)
        #expect(second.service.localStream(for: idA) == nil)
        #expect(first.folder.audioFiles.isEmpty)
    }

    // MARK: - The failure log line

    @Test("the failure log line gives the error's domain and code or the download error case, and nothing else")
    func failureLogLine() {
        #expect(MusicDownloadService.failureLogLine(for: MusicDownloadError.badStatus(404), removed: false)
            == "MusicDownloadError.badStatus(404)")
        #expect(MusicDownloadService.failureLogLine(for: MusicDownloadError.lengthMismatch, removed: false)
            == "MusicDownloadError.lengthMismatch")
        #expect(MusicDownloadService.failureLogLine(for: URLError(.timedOut), removed: false)
            == "NSURLErrorDomain -1001")
        #expect(MusicDownloadService.failureLogLine(for: URLError(.cancelled), removed: false)
            == "NSURLErrorDomain -999")
    }

    @Test("the failure log line carries no path or id from the error")
    func failureLogLineLeaksNothing() throws {
        let error = CocoaError(
            .fileWriteNoPermission,
            userInfo: [NSFilePathErrorKey: "/Users/someone/Library/\(idA).m4a", NSLocalizedDescriptionKey: idA]
        )

        let line = try #require(MusicDownloadService.failureLogLine(for: error, removed: false))

        #expect(line == "NSCocoaErrorDomain 513")
        #expect(!line.contains(idA))
        #expect(!line.contains("Users"))
    }

    @Test("nothing is logged for a download that was cancelled or removed, whatever error it ended with")
    func failureLogLineSkipsRemoval() {
        #expect(MusicDownloadService.failureLogLine(for: CancellationError(), removed: false) == nil)
        #expect(MusicDownloadService.failureLogLine(for: CancellationError(), removed: true) == nil)
        #expect(MusicDownloadService.failureLogLine(for: URLError(.cancelled), removed: true) == nil)
        #expect(MusicDownloadService.failureLogLine(for: URLError(.timedOut), removed: true) == nil)
    }

    @Test("a song removed while its transport fails with URLError cancelled does not show failed")
    func removedThenURLCancelledIsNotAFailure() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let rig = DownloadServiceRig { request, index in
            if index == 1 {
                await gate.wait()
                throw URLError(.cancelled)
            }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }
        rig.download(idA)
        await rig.transport.waitForRequests(2)

        rig.service.remove(videoId: idA)
        await gate.open()

        #expect(await rig.settles(idA, as: .none))
        #expect(rig.folder.audioFiles.isEmpty)
    }

    // MARK: - Idle

    @Test("waiting for idle returns once the queue is empty and a removal has reached the disk")
    func waitUntilIdle() async throws {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }
        rig.download(idA)
        rig.download(idB)
        await rig.service.waitUntilIdle()
        #expect(rig.service.state(for: idA) == .downloaded)
        #expect(rig.service.state(for: idB) == .downloaded)

        rig.service.remove(videoId: idA)
        await rig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == ["\(idB).m4a"])
        let later = MusicDownloadStore(root: rig.folder.root, now: { DownloadSamples.fixedDate })
        #expect(await later.load().keys.sorted() == [idB])
    }

    @Test("waiting for idle with nothing to do returns at once")
    func waitUntilIdleWithNothing() async {
        let rig = DownloadServiceRig()
        defer { rig.cleanUp() }

        await rig.service.waitUntilIdle()

        #expect(rig.service.state(for: idA) == .none)
    }
}
