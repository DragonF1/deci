// DeciTests/Music/MusicDownloaderTests.swift
// One song's download through a fake transport: the ranged chunks and where they land, how the total length is found,
// a 403 that needs a fresh stream and resumes where it stopped, every way a download fails and what it leaves behind,
// and cancelling. Nothing here reaches the network.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct DownloaderRig {
    let folder = DownloadTestFolder()
    let clock = MutableClock()
    let store: MusicDownloadStore
    let transport: FakeDownloadTransport
    let resolver: FakeDownloadResolver
    let downloader: MusicDownloader
    let progress: DownloadProgressLog

    /// `payload` is the file the fake server holds; `chunkSize` is small so a short payload takes several requests.
    /// `steps` and `afterStep` shape how the bytes of an answer arrive (see `FakeDownloadTransport`).
    init(
        payload: Data = DownloadSamples.payload(35),
        chunkSize: Int = 10,
        handler: FakeDownloadTransport.Handler? = nil,
        resolver: FakeDownloadResolver = FakeDownloadResolver(),
        steps: @escaping FakeDownloadTransport.Steps = { [$0] },
        afterStep: FakeDownloadTransport.AfterStep? = nil,
        progress: DownloadProgressLog = DownloadProgressLog()
    ) {
        let clock = self.clock
        store = MusicDownloadStore(root: folder.root, now: { DownloadSamples.fixedDate })
        transport = FakeDownloadTransport(
            handler: handler ?? FakeDownloadTransport.serving(payload), steps: steps, afterStep: afterStep
        )
        self.progress = progress
        self.resolver = resolver
        downloader = MusicDownloader(
            store: store, transport: transport, resolve: resolver.closure, chunkSize: chunkSize, now: { clock.now }
        )
    }

    func cleanUp() { folder.remove() }

    @discardableResult
    func download(_ id: String = DownloadSamples.idA) async throws -> MusicDownloadStore.Entry {
        _ = await store.load()
        let log = progress
        return try await downloader.download(DownloadSamples.track(id)) { log.note($0) }
    }

    var ranges: [ClosedRange<Int64>] {
        get async { await transport.requests.map(\.range) }
    }

    /// True when nothing of the download is left: no part, no audio, no entry.
    func leftNothing(_ id: String = DownloadSamples.idA) async -> Bool {
        let listed = await store.entries
        let downloaded = await store.isDownloaded(id)
        return folder.audioFiles.isEmpty && listed.isEmpty && !downloaded
    }
}

@MainActor
@Suite("MusicDownloader")
struct MusicDownloaderTests {
    private let idA = DownloadSamples.idA

    // MARK: - Chunking

    @Test("a song is fetched in ranged chunks of the set size and lands byte for byte")
    func chunking() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10)
        defer { rig.cleanUp() }

        let entry = try await rig.download()

        #expect(await rig.ranges == [0...9, 10...19, 20...29, 30...34])
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
        #expect(entry.bytes == 35)
        #expect(entry.track == DownloadSamples.track(idA))
        #expect(entry.downloadedAt == DownloadSamples.fixedDate)
        #expect(await rig.store.entries == [idA: entry])
        #expect(!rig.folder.exists(rig.folder.partURL(idA)))
    }

    @Test("a song that fits one chunk takes one request")
    func singleChunk() async throws {
        let rig = DownloaderRig(payload: DownloadSamples.payload(8), chunkSize: 10)
        defer { rig.cleanUp() }

        try await rig.download()

        #expect(await rig.ranges == [0...9])
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == DownloadSamples.payload(8))
    }

    @Test("a song that is an exact number of chunks does not ask for one more")
    func exactMultiple() async throws {
        let rig = DownloaderRig(payload: DownloadSamples.payload(30), chunkSize: 10)
        defer { rig.cleanUp() }

        try await rig.download()

        #expect(await rig.ranges == [0...9, 10...19, 20...29])
    }

    @Test("progress is the fraction written after each chunk, ending at 1")
    func progressValues() async throws {
        let rig = DownloaderRig(payload: DownloadSamples.payload(40), chunkSize: 10)
        defer { rig.cleanUp() }

        try await rig.download()

        #expect(rig.progress.values == [0.25, 0.5, 0.75, 1.0])
    }

    @Test("every request carries the stream's headers and the address the stream was resolved to")
    func requestsCarryHeaders() async throws {
        let rig = DownloaderRig(payload: DownloadSamples.payload(15), chunkSize: 10)
        defer { rig.cleanUp() }

        try await rig.download()

        let requests = await rig.transport.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.headers == ["User-Agent": "test-agent"])
            #expect(request.url.absoluteString == "https://media.example.test/\(idA)/0.m4a")
        }
    }

    @Test("a server that answers with less than was asked is followed from the byte it reached")
    func shortAnswers() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(
            payload: payload, chunkSize: 10, handler: FakeDownloadTransport.serving(payload, limit: 4)
        )
        defer { rig.cleanUp() }

        try await rig.download()

        #expect(await rig.ranges == [0...9, 4...13, 8...17, 12...21, 16...25, 20...29, 24...33, 28...34, 32...34])
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
    }

    @Test("the entry keeps the exact length the stream stated, which playback needs")
    func entryKeepsDuration() async throws {
        let resolver = FakeDownloadResolver { id, call in
            FakeDownloadResolver.stream(videoId: id, call: call, duration: 201.37)
        }
        let rig = DownloaderRig(resolver: resolver)
        defer { rig.cleanUp() }

        let entry = try await rig.download()

        #expect(entry.durationSeconds == 201.37)
    }

    // MARK: - The total length

    @Test("the total comes from the first Content-Range")
    func totalFromContentRange() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10)
        defer { rig.cleanUp() }

        try await rig.download()

        // The first request cannot be cut to the file yet; the last one is.
        #expect(await rig.ranges.last == 30...34)
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
    }

    @Test("without a Content-Range total the clen on the stream's address gives it")
    func totalFromClen() async throws {
        let payload = DownloadSamples.payload(35)
        let resolver = FakeDownloadResolver { id, call in
            FakeDownloadResolver.stream(videoId: id, call: call, query: "itag=140&clen=35&expire=1")
        }
        let rig = DownloaderRig(
            payload: payload, chunkSize: 10, handler: FakeDownloadTransport.serving(payload, reportsTotal: false),
            resolver: resolver
        )
        defer { rig.cleanUp() }

        let entry = try await rig.download()

        #expect(await rig.ranges == [0...9, 10...19, 20...29, 30...34])
        #expect(entry.bytes == 35)
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
    }

    @Test("the Content-Range total wins over a clen that disagrees")
    func contentRangeBeatsClen() async throws {
        let payload = DownloadSamples.payload(35)
        let resolver = FakeDownloadResolver { id, call in
            FakeDownloadResolver.stream(videoId: id, call: call, query: "clen=999")
        }
        let rig = DownloaderRig(payload: payload, chunkSize: 10, resolver: resolver)
        defer { rig.cleanUp() }

        let entry = try await rig.download()

        #expect(entry.bytes == 35)
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
    }

    @Test("with no total anywhere the download fails and leaves nothing")
    func noTotalFails() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: FakeDownloadTransport.serving(payload, reportsTotal: false))
        defer { rig.cleanUp() }

        await #expect(throws: MusicDownloadError.unknownLength) { try await rig.download() }

        #expect(await rig.leftNothing())
    }

    @Test("the Content-Range header is read for its total, and an unknown total is no total")
    func contentRangeParsing() {
        #expect(MusicDownloadChunk.totalLength(inContentRange: "bytes 0-9/100") == 100)
        #expect(MusicDownloadChunk.totalLength(inContentRange: "bytes 10-19/3456789") == 3_456_789)
        #expect(MusicDownloadChunk.totalLength(inContentRange: "bytes 0-9/*") == nil)
        #expect(MusicDownloadChunk.totalLength(inContentRange: "bytes */100") == 100)
        #expect(MusicDownloadChunk.totalLength(inContentRange: "") == nil)
        #expect(MusicDownloadChunk.totalLength(inContentRange: "garbage") == nil)
        #expect(MusicDownloadChunk.totalLength(inContentRange: "bytes 0-9/abc") == nil)
        #expect(MusicDownloadChunk.totalLength(inContentRange: "bytes 0-9/-5") == nil)
        #expect(MusicDownloadChunk.totalLength(inContentRange: nil) == nil)
    }

    // MARK: - Fresh streams

    @Test("a 403 mid-file asks for a fresh stream and resumes at the byte it reached")
    func forbiddenResumes() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            index == 2 ? FakeDownloadTransport.status(403) : FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }

        try await rig.download()

        let requests = await rig.transport.requests
        #expect(requests.map(\.range) == [0...9, 10...19, 20...29, 20...29, 30...34])
        #expect(requests.map { $0.url.lastPathComponent } == ["0.m4a", "0.m4a", "0.m4a", "1.m4a", "1.m4a"])
        #expect(await rig.resolver.calls == [idA, idA])
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
    }

    @Test("a stream that has already expired is replaced before it is used")
    func expiredStreamReplaced() async throws {
        let payload = DownloadSamples.payload(25)
        let clock = MutableClock()
        let resolver = FakeDownloadResolver { id, call in
            // The first stream ran out a second ago; the second is good for hours.
            FakeDownloadResolver.stream(
                videoId: id, call: call, expiresAt: clock.now.addingTimeInterval(call == 0 ? -1 : 3600)
            )
        }
        let rig = DownloaderRigWithClock(clock: clock, payload: payload, resolver: resolver)
        defer { rig.cleanUp() }

        try await rig.download()

        let requests = await rig.transport.requests
        #expect(requests.allSatisfy { $0.url.lastPathComponent == "1.m4a" })
        #expect(await rig.resolver.calls == [idA, idA])
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
    }

    @Test("a stream that runs out between two chunks is replaced and the download carries on")
    func streamExpiresMidFile() async throws {
        let payload = DownloadSamples.payload(35)
        let clock = MutableClock()
        let resolver = FakeDownloadResolver { id, call in
            FakeDownloadResolver.stream(videoId: id, call: call, expiresAt: clock.now.addingTimeInterval(call == 0 ? 30 : 3600))
        }
        let rig = DownloaderRigWithClock(clock: clock, payload: payload, resolver: resolver) { request, index in
            // The clock passes the first stream's end as the second chunk is answered.
            if index == 1 { clock.advance(by: 60) }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        }
        defer { rig.cleanUp() }

        try await rig.download()

        let requests = await rig.transport.requests
        #expect(requests.map(\.range) == [0...9, 10...19, 20...29, 30...34])
        #expect(requests.map { $0.url.lastPathComponent } == ["0.m4a", "0.m4a", "1.m4a", "1.m4a"])
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
    }

    @Test("the fourth fresh stream is refused: three re-resolves per song, then the download fails and cleans up")
    func reResolveLimit() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            index >= 1 ? FakeDownloadTransport.status(403) : FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }

        await #expect(throws: MusicDownloadError.reResolveLimit) { try await rig.download() }

        // The first resolve plus three re-resolves.
        #expect(await rig.resolver.calls.count == 4)
        #expect(await rig.transport.requestCount == 5)
        #expect(await rig.leftNothing())
    }

    @Test("the limit counts every re-resolve of the song, not only those in a row")
    func reResolveLimitIsPerSong() async throws {
        let payload = DownloadSamples.payload(60)
        // A 403 before each of chunks 2, 3, 4 and 5: four in all, each followed by a good answer.
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            [1, 3, 5, 7].contains(index) ? FakeDownloadTransport.status(403) : FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }

        await #expect(throws: MusicDownloadError.reResolveLimit) { try await rig.download() }

        #expect(await rig.resolver.calls.count == 4)
        #expect(await rig.leftNothing())
    }

    // MARK: - Failures

    @Test("any other status fails the song and removes the part")
    func otherStatusFails() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            index == 2 ? FakeDownloadTransport.status(404) : FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }

        await #expect(throws: MusicDownloadError.badStatus(404)) { try await rig.download() }

        #expect(await rig.resolver.calls.count == 1)
        #expect(await rig.leftNothing())
    }

    @Test("a transport error fails the song and removes the part")
    func transportErrorFails() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            if index == 1 { throw URLError(.notConnectedToInternet) }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }

        await #expect(throws: URLError(.notConnectedToInternet)) { try await rig.download() }

        #expect(await rig.leftNothing())
    }

    @Test("a stream that cannot be resolved fails the song before anything is written")
    func resolveFailureFails() async throws {
        let resolver = FakeDownloadResolver { _, _ in throw MusicError.unplayable("gone") }
        let rig = DownloaderRig(resolver: resolver)
        defer { rig.cleanUp() }

        await #expect(throws: MusicError.unplayable("gone")) { try await rig.download() }

        #expect(await rig.transport.requestCount == 0)
        #expect(await rig.leftNothing())
    }

    @Test("a fresh stream that cannot be resolved ends the download and removes the part")
    func reResolveFailureFails() async throws {
        let payload = DownloadSamples.payload(35)
        let resolver = FakeDownloadResolver { id, call in
            if call > 0 { throw MusicError.signedOut }
            return FakeDownloadResolver.stream(videoId: id, call: call)
        }
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            index == 1 ? FakeDownloadTransport.status(403) : FakeDownloadTransport.chunk(of: payload, request.range)
        }, resolver: resolver)
        defer { rig.cleanUp() }

        await #expect(throws: MusicError.signedOut) { try await rig.download() }

        #expect(await rig.leftNothing())
    }

    @Test("an empty answer fails the song instead of asking for the same bytes forever")
    func emptyAnswerFails() async throws {
        let rig = DownloaderRig(handler: { _, _ in
            MusicDownloadChunk(data: Data(), status: 206, totalLength: 35)
        })
        defer { rig.cleanUp() }

        await #expect(throws: MusicDownloadError.badResponse) { try await rig.download() }

        #expect(await rig.transport.requestCount == 1)
        #expect(await rig.leftNothing())
    }

    @Test("a length that does not add up fails the song and removes the part: more bytes than the total")
    func overshootFails() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            // The last answer carries more bytes than the file has left.
            if index == 3 {
                return MusicDownloadChunk(data: DownloadSamples.payload(9), status: 206, totalLength: 35, byteRange: 30...38)
            }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }

        await #expect(throws: MusicDownloadError.lengthMismatch) { try await rig.download() }

        #expect(await rig.leftNothing())
    }

    @Test("a total that changes between two answers fails the song and removes the part")
    func totalChangesFails() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            let chunk = FakeDownloadTransport.chunk(of: payload, request.range)
            return index == 1
                ? MusicDownloadChunk(data: chunk.data, status: 206, totalLength: 40, byteRange: chunk.byteRange)
                : chunk
        })
        defer { rig.cleanUp() }

        await #expect(throws: MusicDownloadError.lengthMismatch) { try await rig.download() }

        #expect(await rig.leftNothing())
    }

    @Test("a bad video id is refused before anything is resolved or fetched")
    func badIdRefused() async throws {
        let rig = DownloaderRig()
        defer { rig.cleanUp() }
        _ = await rig.store.load()

        await #expect(throws: MusicDownloadError.invalidVideoId) {
            _ = try await rig.downloader.download(DownloadSamples.track("../../etc/passwd")) { _ in }
        }

        #expect(await rig.resolver.calls.isEmpty)
        #expect(await rig.transport.requestCount == 0)
        #expect(!rig.folder.exists(rig.folder.root))
    }

    // MARK: - What an answer must be

    @Test("progress inside a chunk follows the bytes as they arrive, and the end of the chunk adds no repeat")
    func progressInsideChunk() async throws {
        let payload = DownloadSamples.payload(40)
        let log = DownloadProgressLog()
        let rig = DownloaderRig(
            payload: payload, chunkSize: 40, resolver: FakeDownloadResolver.knowingLength(40),
            steps: { size in [size / 4, size / 2, size] },
            afterStep: { number in await log.waitForCount(number + 1) },
            progress: log
        )
        defer { rig.cleanUp() }

        try await rig.download()

        #expect(log.values == [0.25, 0.5, 1.0])
    }

    @Test("progress inside a later chunk counts the bytes already written")
    func progressInsideLaterChunk() async throws {
        let payload = DownloadSamples.payload(40)
        let log = DownloadProgressLog()
        // Each chunk of 20 bytes arrives as 10, then 20; the second chunk's count of waits goes on from the first's.
        let steps = DownloadStepCounter()
        let rig = DownloaderRig(
            payload: payload, chunkSize: 20, resolver: FakeDownloadResolver.knowingLength(40),
            steps: { size in [size / 2, size] },
            afterStep: { _ in await log.waitForCount(steps.next()) },
            progress: log
        )
        defer { rig.cleanUp() }

        try await rig.download()

        #expect(log.values == [0.25, 0.5, 0.75, 1.0])
    }

    @Test("an answer that starts at another byte than the one asked for fails the song")
    func misalignedStartFails() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            // The second answer repeats the first range.
            index == 1 ? FakeDownloadTransport.chunk(of: payload, 0...9) : FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }

        await #expect(throws: MusicDownloadError.lengthMismatch) { try await rig.download() }

        #expect(await rig.leftNothing())
    }

    @Test("an answer whose Content-Range is longer or shorter than its body fails the song")
    func misalignedLengthFails() async throws {
        let payload = DownloadSamples.payload(35)
        for claimed in [10...20 as ClosedRange<Int64>, 10...17] {
            let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
                let chunk = FakeDownloadTransport.chunk(of: payload, request.range)
                return index == 1
                    ? MusicDownloadChunk(data: chunk.data, status: 206, totalLength: 35, byteRange: claimed)
                    : chunk
            })
            defer { rig.cleanUp() }

            await #expect(throws: MusicDownloadError.lengthMismatch, "\(claimed)") { try await rig.download() }

            #expect(await rig.leftNothing())
        }
    }

    @Test("a 206 with no usable Content-Range fails the song")
    func missingContentRangeFails() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, _ in
            let chunk = FakeDownloadTransport.chunk(of: payload, request.range)
            return MusicDownloadChunk(data: chunk.data, status: 206, totalLength: 35)
        })
        defer { rig.cleanUp() }

        await #expect(throws: MusicDownloadError.badResponse) { try await rig.download() }

        #expect(await rig.transport.requestCount == 1)
        #expect(await rig.leftNothing())
    }

    @Test("a 200 with the whole file, as a proxy that ignores Range sends, is refused and nothing is written")
    func fullBodyRefused() async throws {
        let payload = DownloadSamples.payload(35)
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { _, _ in
            MusicDownloadChunk(data: payload, status: 200, totalLength: nil)
        })
        defer { rig.cleanUp() }

        await #expect(throws: MusicDownloadError.badStatus(200)) { try await rig.download() }

        #expect(await rig.transport.requestCount == 1)
        #expect(await rig.leftNothing())
    }

    // MARK: - Disk and overlap

    @Test("a folder that cannot be written to fails the song with the disk's own error and leaves nothing")
    func diskErrorFails() async throws {
        let rig = DownloaderRig()
        defer { rig.cleanUp() }
        _ = await rig.store.load()
        try FileManager.default.createDirectory(at: rig.folder.audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.folder.audioDirectory.path)

        do {
            _ = try await rig.downloader.download(DownloadSamples.track(idA)) { _ in }
            Issue.record("The download should have failed")
        } catch {
            #expect((error as NSError).domain == NSCocoaErrorDomain)
        }

        #expect(await rig.transport.requestCount == 0)
        #expect(rig.folder.audioFiles.isEmpty)
        #expect(await rig.store.entries.isEmpty)
    }

    @Test("a second download of the id that is already running is refused, and the first is not harmed")
    func overlapRefused() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }
        _ = await rig.store.load()
        let downloader = rig.downloader
        let first = Task { try await downloader.download(DownloadSamples.track(idA)) { _ in } }
        await rig.transport.waitForRequests(1)

        await #expect(throws: MusicDownloadError.alreadyDownloading) {
            _ = try await downloader.download(DownloadSamples.track(idA)) { _ in }
        }
        await gate.open()
        let entry = try await first.value

        #expect(entry.bytes == 35)
        #expect(rig.folder.read(rig.folder.audioURL(idA)) == payload)
        #expect(await rig.transport.requestCount == 4)
        // Finished, the id can be downloaded again.
        let again = try await rig.download()
        #expect(again.bytes == 35)
    }

    @Test("two different songs may download at the same time")
    func differentIdsOverlap() async throws {
        let payload = DownloadSamples.payload(25)
        let gate = MusicTestGate()
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            if index == 0 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }
        _ = await rig.store.load()
        let downloader = rig.downloader
        let first = Task { try await downloader.download(DownloadSamples.track(DownloadSamples.idA)) { _ in } }
        await rig.transport.waitForRequests(1)

        let second = try await downloader.download(DownloadSamples.track(DownloadSamples.idB)) { _ in }
        await gate.open()
        _ = try await first.value

        #expect(second.bytes == 25)
        #expect(await rig.store.entries.keys.sorted() == [DownloadSamples.idA, DownloadSamples.idB])
    }

    // MARK: - Cancelling

    @Test("cancelling stops the download and deletes the part, leaving no entry")
    func cancelDeletesPart() async throws {
        let payload = DownloadSamples.payload(35)
        let gate = MusicTestGate()
        let rig = DownloaderRig(payload: payload, chunkSize: 10, handler: { request, index in
            if index == 2 { await gate.wait() }
            return FakeDownloadTransport.chunk(of: payload, request.range)
        })
        defer { rig.cleanUp() }
        _ = await rig.store.load()
        let downloader = rig.downloader
        let task = Task { try await downloader.download(DownloadSamples.track(idA)) { _ in } }

        // Two chunks are down and the third is held: the part has 20 bytes.
        await rig.transport.waitForRequests(3)
        #expect(rig.folder.read(rig.folder.partURL(idA))?.count == 20)
        task.cancel()
        await gate.open()
        let result = await task.result

        guard case .failure(let error) = result else {
            Issue.record("A cancelled download finished")
            return
        }
        #expect(error is CancellationError)
        #expect(await rig.transport.requestCount == 3)
        #expect(await rig.leftNothing())
    }

    @Test("a download cancelled before it starts fetches nothing")
    func cancelBeforeStart() async throws {
        let rig = DownloaderRig()
        defer { rig.cleanUp() }
        _ = await rig.store.load()
        let downloader = rig.downloader
        let task = Task {
            // Suspended once so the cancel lands first.
            await Task.yield()
            return try await downloader.download(DownloadSamples.track(idA)) { _ in }
        }
        task.cancel()

        let result = await task.result

        if case .success = result { Issue.record("A cancelled download finished") }
        #expect(await rig.transport.requestCount == 0)
        #expect(await rig.leftNothing())
    }
}

/// The rig for tests that move the clock: the downloader reads the same clock the resolver's streams were built on.
@MainActor
private struct DownloaderRigWithClock {
    let folder = DownloadTestFolder()
    let store: MusicDownloadStore
    let transport: FakeDownloadTransport
    let resolver: FakeDownloadResolver
    let downloader: MusicDownloader

    init(
        clock: MutableClock, payload: Data, resolver: FakeDownloadResolver,
        handler: FakeDownloadTransport.Handler? = nil
    ) {
        store = MusicDownloadStore(root: folder.root, now: { DownloadSamples.fixedDate })
        transport = FakeDownloadTransport(handler: handler ?? FakeDownloadTransport.serving(payload))
        self.resolver = resolver
        downloader = MusicDownloader(
            store: store, transport: transport, resolve: resolver.closure, chunkSize: 10, now: { clock.now }
        )
    }

    func cleanUp() { folder.remove() }

    @discardableResult
    func download() async throws -> MusicDownloadStore.Entry {
        _ = await store.load()
        return try await downloader.download(DownloadSamples.track(DownloadSamples.idA)) { _ in }
    }
}

