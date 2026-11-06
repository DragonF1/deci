// DeciTests/Music/MusicTrackCacheTests.swift
// Tier 2a P3: the track cache downloads a whole song into its own folder (never the Downloads store), reuses a finished
// file, re-resolves on a 403, cleans up its part file on every failure, and deletes files after release, over its limits
// and at launch. The transport is the in-memory fake; nothing touches the network.

import Foundation
import Testing
@testable import Deci

nonisolated struct TrackCacheFolder {
    let root: URL

    init() {
        root = URL(fileURLWithPath: "/Volumes/Storage/_test/deci-2a/trackcache", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func file(_ id: String) -> URL { root.appendingPathComponent("\(id).m4a") }
    func part(_ id: String) -> URL { root.appendingPathComponent("\(id).m4a.part") }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }
}

/// A `sleep` the test opens by hand, remembering how long each wait was asked for.
nonisolated final class TrackCacheSleep: @unchecked Sendable {
    private let gate = MusicTestGate()
    private let lock = NSLock()
    private var asked: [TimeInterval] = []

    var requested: [TimeInterval] { lock.withLock { asked } }
    func open() async { await gate.open() }

    var closure: @Sendable (TimeInterval) async throws -> Void {
        { seconds in
            self.lock.withLock { self.asked.append(seconds) }
            await self.gate.wait()
        }
    }
}

@Suite("Track cache")
struct MusicTrackCacheTests {
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB
    private let idC = DownloadSamples.idC
    private let payload = DownloadSamples.payload(25_000)

    private func cache(
        _ folder: TrackCacheFolder, transport: FakeDownloadTransport, limits: MusicTrackCache.Limits = .init(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
        free: @escaping @Sendable (URL) -> Int64? = { _ in Int64.max / 2 }
    ) -> MusicTrackCache {
        MusicTrackCache(
            root: folder.root, transport: transport, limits: limits, chunkSize: 10_000, sleep: sleep, freeBytes: free
        )
    }

    private func stream(_ id: String, length: Int? = nil) -> ResolvedStream {
        FakeDownloadResolver.stream(videoId: id, call: 0, query: "clen=\(length ?? payload.count)")
    }

    private func resolver(length: Int? = nil) -> FakeDownloadResolver {
        FakeDownloadResolver.knowingLength(length ?? payload.count)
    }

    @Test("a 25 KB song comes down in 10 KB chunks into <id>.m4a, byte for byte")
    func downloadsInChunks() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let transport = FakeDownloadTransport(serving: payload)
        let cache = cache(folder, transport: transport)

        let url = try await cache.fetch(stream(idA), resolve: resolver().closure)

        #expect(url == folder.file(idA))
        #expect(try Data(contentsOf: url) == payload)
        #expect(await transport.requestCount == 3)
        #expect(await cache.totalBytes() == 25_000)
        #expect(!folder.names.contains { $0.hasSuffix(".part") })
    }

    @Test("readyFile is nil while the part file is being written and set once it is renamed")
    func readyAfterRename() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let gate = MusicTestGate()
        let payload = self.payload
        let transport = FakeDownloadTransport(handler: { request, index in
            if index == 1 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        })
        let cache = cache(folder, transport: transport)
        let s = stream(idA), r = resolver().closure

        let task = Task { try await cache.fetch(s, resolve: r) }
        await transport.waitForRequests(2)
        #expect(await cache.readyFile(for: idA) == nil)
        #expect(folder.exists(folder.part(idA)))
        await gate.open()
        _ = try await task.value
        #expect(await cache.readyFile(for: idA) == folder.file(idA))
        #expect(!folder.exists(folder.part(idA)))
    }

    @Test("a 403 mid-way asks for a fresh stream once and finishes")
    func reResolvesOn403() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let payload = self.payload
        let transport = FakeDownloadTransport(handler: { request, index in
            index == 1 ? FakeDownloadTransport.status(403) : FakeDownloadTransport.chunk(of: payload, request.range)
        })
        let cache = cache(folder, transport: transport)
        let resolver = resolver()

        let url = try await cache.fetch(stream(idA), resolve: resolver.closure)

        #expect(try Data(contentsOf: url) == payload)
        #expect(await resolver.calls == [idA])
    }

    @Test("four 403s fail with the re-resolve limit and leave no part file")
    func reResolveLimit() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let payload = self.payload
        let transport = FakeDownloadTransport(handler: { request, index in
            index >= 1 ? FakeDownloadTransport.status(403) : FakeDownloadTransport.chunk(of: payload, request.range)
        })
        let cache = cache(folder, transport: transport)

        await #expect(throws: MusicDownloadError.reResolveLimit) {
            try await cache.fetch(stream(idA), resolve: resolver().closure)
        }
        #expect(!folder.names.contains { $0.contains(idA) })
        #expect(await cache.readyFile(for: idA) == nil)
    }

    @Test("a cancel removes the part file")
    func cancelRemovesPart() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let gate = MusicTestGate()
        let payload = self.payload
        let transport = FakeDownloadTransport(handler: { request, index in
            if index == 1 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        })
        let cache = cache(folder, transport: transport)
        let s = stream(idA), r = resolver().closure

        let task = Task { try await cache.fetch(s, resolve: r) }
        await transport.waitForRequests(2)
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!folder.names.contains { $0.contains(idA) })
    }

    @Test("a second fetch of a finished file returns it with no request")
    func reusesFinishedFile() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let transport = FakeDownloadTransport(serving: payload)
        let cache = cache(folder, transport: transport)
        let r = resolver().closure

        let first = try await cache.fetch(stream(idA), resolve: r)
        let count = await transport.requestCount
        let second = try await cache.fetch(stream(idA), resolve: r)

        #expect(first == second)
        #expect(await transport.requestCount == count)
    }

    @Test("release deletes the file only after the grace has passed")
    func releaseAfterGrace() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let sleep = TrackCacheSleep()
        let cache = cache(folder, transport: FakeDownloadTransport(serving: payload), sleep: sleep.closure)
        _ = try await cache.fetch(stream(idA), resolve: resolver().closure)

        await cache.release(videoId: idA)
        #expect(folder.exists(folder.file(idA)), "a draining deck may still hold the file")
        await sleep.open()
        await cache.drainReleases()

        #expect(!folder.exists(folder.file(idA)))
        #expect(sleep.requested == [MusicTrackCache.Limits().graceAfterRelease])
    }

    @Test("a pinned file survives release until it is unpinned")
    func pinSurvivesRelease() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let cache = cache(folder, transport: FakeDownloadTransport(serving: payload))
        _ = try await cache.fetch(stream(idA), resolve: resolver().closure)

        await cache.pin(idA)
        await cache.release(videoId: idA)
        await cache.drainReleases()
        #expect(folder.exists(folder.file(idA)))

        await cache.unpin(idA)
        #expect(!folder.exists(folder.file(idA)))
    }

    @Test("fetching a released file again keeps it")
    func refetchCancelsRelease() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let sleep = TrackCacheSleep()
        let cache = cache(folder, transport: FakeDownloadTransport(serving: payload), sleep: sleep.closure)
        let r = resolver().closure
        _ = try await cache.fetch(stream(idA), resolve: r)
        await cache.release(videoId: idA)

        _ = try await cache.fetch(stream(idA), resolve: r)
        await sleep.open()
        await cache.drainReleases()

        #expect(folder.exists(folder.file(idA)))
    }

    @Test("over maxFiles the oldest unpinned file goes, a pinned one stays")
    func evictsOldestUnpinned() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        var limits = MusicTrackCache.Limits()
        limits.maxFiles = 2
        let cache = cache(folder, transport: FakeDownloadTransport(serving: payload), limits: limits)
        let r = resolver().closure

        _ = try await cache.fetch(stream(idA), resolve: r)
        await cache.pin(idA)
        _ = try await cache.fetch(stream(idB), resolve: r)
        _ = try await cache.fetch(stream(idC), resolve: r)

        #expect(folder.exists(folder.file(idA)), "pinned")
        #expect(!folder.exists(folder.file(idB)), "oldest unpinned")
        #expect(folder.exists(folder.file(idC)))
    }

    @Test("over maxBytes the oldest file is evicted")
    func evictsOverBytes() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        var limits = MusicTrackCache.Limits()
        limits.maxBytes = 30_000
        let cache = cache(folder, transport: FakeDownloadTransport(serving: payload), limits: limits)
        let r = resolver().closure

        _ = try await cache.fetch(stream(idA), resolve: r)
        _ = try await cache.fetch(stream(idB), resolve: r)

        #expect(!folder.exists(folder.file(idA)))
        #expect(folder.exists(folder.file(idB)))
        #expect(await cache.totalBytes() <= 30_000)
    }

    @Test("a song bigger than the whole budget is refused before any request")
    func tooLarge() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        var limits = MusicTrackCache.Limits()
        limits.maxBytes = 10_000
        let transport = FakeDownloadTransport(serving: payload)
        let cache = cache(folder, transport: transport, limits: limits)

        await #expect(throws: MusicTrackCache.Failure.tooLarge) {
            try await cache.fetch(stream(idA), resolve: resolver().closure)
        }
        #expect(await transport.requestCount == 0)
    }

    @Test("free space under minFreeBytes throws diskFull with nothing written")
    func diskFull() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let transport = FakeDownloadTransport(serving: payload)
        let cache = cache(folder, transport: transport, free: { _ in 500 })

        await #expect(throws: MusicTrackCache.Failure.diskFull) {
            try await cache.fetch(stream(idA), resolve: resolver().closure)
        }
        #expect(await transport.requestCount == 0)
        #expect(!folder.names.contains { $0.contains(idA) })
    }

    @Test("an id that is not a video id never reaches the disk")
    func invalidId() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let transport = FakeDownloadTransport(serving: payload)
        let cache = cache(folder, transport: transport)
        let evil = FakeDownloadResolver.stream(videoId: "../../etc/pw", call: 0, query: "clen=100")

        await #expect(throws: MusicTrackCache.Failure.invalidVideoId) {
            try await cache.fetch(evil, resolve: resolver().closure)
        }
        #expect(await transport.requestCount == 0)
        #expect(await cache.readyFile(for: "../../etc/pw") == nil)
        #expect(!folder.exists(folder.root))
    }

    @Test("sweepAtLaunch empties a folder the cache made, and leaves a folder that is not its own alone")
    func sweepAtLaunch() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let cache = cache(folder, transport: FakeDownloadTransport(serving: payload))
        let r = resolver().closure
        _ = try await cache.fetch(stream(idA), resolve: r)
        _ = try await cache.fetch(stream(idB), resolve: r)

        await cache.sweepAtLaunch()
        #expect(folder.names == [MusicTrackCache.sentinelName])

        // A folder with files and no sentinel is somebody else's: nothing is deleted.
        let stray = TrackCacheFolder()
        defer { stray.remove() }
        try FileManager.default.createDirectory(at: stray.root, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: stray.root.appendingPathComponent("mine.txt"))
        let strayCache = self.cache(stray, transport: FakeDownloadTransport(serving: payload))
        await strayCache.sweepAtLaunch()
        #expect(stray.names == ["mine.txt"])
    }

    @Test("the live root is under Caches, apart from the Downloads folder")
    func liveRootIsNotDownloads() {
        let root = MusicTrackCache.liveRoot().path
        #expect(root.hasSuffix("/Deci/TrackCache"))
        #expect(root.contains("/Caches/"))
        #expect(!MusicDownloadStore.liveRoot().path.hasPrefix(root))
    }
}
