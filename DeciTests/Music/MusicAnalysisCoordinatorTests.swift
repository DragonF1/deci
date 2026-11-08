// DeciTests/Music/MusicAnalysisCoordinatorTests.swift
// Tier 2a P3: the coordinator's policy. A fresh entry costs nothing, a downloaded song is analysed from its own file with
// no fetch, a missing or stale one is fetched into the track cache, analysed and stored, and the file is kept or deleted
// as asked. The analyzer is a counting closure, the store is in memory, the transport serves bytes from memory.

import Foundation
import Testing
@testable import Deci

nonisolated final class AnalyzeSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL] = []
    private var durations: [Double?] = []
    var fails = false
    var gate: MusicTestGate?

    var count: Int { lock.withLock { files.count } }
    var calledFiles: [URL] { lock.withLock { files } }
    var calledDurations: [Double?] { lock.withLock { durations } }

    var closure: MusicAnalysisCoordinator.Analyze {
        { file, duration in
            self.lock.withLock { self.files.append(file); self.durations.append(duration) }
            if let gate = self.gate { await gate.wait() }
            if self.fails { throw MusicFileAnalyzer.Failure.unreadable }
            return Self.result(duration: duration ?? 200)
        }
    }

    static func result(duration: Double) -> MusicFileAnalyzer.Result {
        MusicFileAnalyzer.Result(
            measurement: MusicAnalysisMeasurement(
                silenceStart: 0.2, silenceEnd: duration - 0.3, introEnd: 4, outroStart: duration - 10,
                integratedLUFS: -14, samplePeakDb: -1, introLUFS: -20, outroLUFS: -18,
                energy: [100, 110, 120], duration: duration, isSilent: false
            ),
            format: MusicAnalysis.Format(codec: "mp4a.40.2", itag: 0, durationMs: Int(duration * 1000)),
            decodedSeconds: duration
        )
    }
}

@Suite("Analysis coordinator")
struct MusicAnalysisCoordinatorTests {
    private let id = DownloadSamples.idA
    private let payload = DownloadSamples.payload(12_000)

    private struct Rig {
        let folder = TrackCacheFolder()
        let store = MusicAnalysisStore(url: nil)
        let transport: FakeDownloadTransport
        let cache: MusicTrackCache
        let spy = AnalyzeSpy()
        let coordinator: MusicAnalysisCoordinator

        init(payload: Data, downloaded: MusicDownloadedFile? = nil) {
            let transport = FakeDownloadTransport(serving: payload)
            self.transport = transport
            let cache = MusicTrackCache(
                root: folder.root, transport: transport, chunkSize: 5_000, sleep: { _ in },
                freeBytes: { _ in Int64.max / 2 }
            )
            self.cache = cache
            let spy = self.spy
            coordinator = MusicAnalysisCoordinator(
                store: store, cache: cache,
                downloads: { _ in downloaded },
                resolve: { id in FakeDownloadResolver.stream(videoId: id, call: 1, query: "clen=\(payload.count)") },
                analyze: spy.closure
            )
        }

        func stream(
            _ id: String, duration: Double = 200, itag: Int = 140, loudness: Double? = -7.5, perceptual: Double? = -5
        ) -> ResolvedStream {
            ResolvedStream(
                videoId: id, url: URL(string: "https://media.example.test/\(id)/0.m4a?clen=\(transportLength)")!, itag: itag,
                durationSeconds: duration, expiresAt: .distantFuture, playbackTrackingURL: nil, httpHeaders: [:],
                audioCodec: "mp4a.40.2", loudnessDb: loudness, perceptualLoudnessDb: perceptual
            )
        }

        var transportLength = 12_000
        func cleanUp() { folder.remove() }
    }

    @Test("a fresh entry means no fetch and no analysis")
    func freshMeansNothing() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        let first = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)
        #expect(first == .analysed(file: nil))
        let requests = await rig.transport.requestCount

        let second = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: true)

        #expect(second == .alreadyFresh)
        #expect(rig.spy.count == 1)
        #expect(await rig.transport.requestCount == requests)
    }

    @Test("a downloaded song is analysed from the Downloads file, nothing is fetched, the source is download")
    func downloadedSong() async throws {
        let file = URL(fileURLWithPath: "/Volumes/Storage/_test/deci-2a/downloaded.m4a")
        let rig = Rig(payload: payload, downloaded: MusicDownloadedFile(url: file, durationSeconds: 199.5))
        defer { rig.cleanUp() }

        let outcome = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: true)

        #expect(outcome == .analysed(file: nil))
        #expect(rig.spy.calledFiles == [file])
        #expect(rig.spy.calledDurations == [199.5], "the exact duration the download stored")
        #expect(await rig.transport.requestCount == 0)
        #expect(await rig.store.entry(for: id)?.source == .download)
    }

    @Test("a missing entry fetches, analyses and stores; without wantsFile the file is deleted at once")
    func missingEntryDeletesFile() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }

        let outcome = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)

        #expect(outcome == .analysed(file: nil))
        #expect(rig.spy.calledFiles == [rig.folder.file(id)])
        #expect(!rig.folder.exists(rig.folder.file(id)))
        let entry = await rig.store.entry(for: id)
        #expect(entry?.source == .backgroundCache)
        #expect(entry?.format.itag == 140)
        #expect(entry?.format.durationMs == 200_000)
    }

    @Test("with wantsFile the cache file is kept and named in the outcome")
    func wantsFileKeepsIt() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }

        let outcome = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: true)

        #expect(outcome == .analysed(file: rig.folder.file(id)))
        #expect(rig.folder.exists(rig.folder.file(id)))
        #expect(await rig.store.entry(for: id)?.source == .playbackCache)
    }

    @Test("the stored row carries the stream's YouTube loudness")
    func storesYouTubeLoudness() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        _ = await rig.coordinator.ensure(stream: rig.stream(id, loudness: -7.5, perceptual: -5), wantsFile: false)

        let entry = await rig.coordinator.analysis(for: id)
        #expect(entry?.youtubeLoudnessDb == -7.5)
        #expect(entry?.youtubePerceptualLoudnessDb == -5)
    }

    @Test("a format change (the duration a second off) analyses again")
    func formatChangeReanalyses() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        _ = await rig.coordinator.ensure(stream: rig.stream(id, duration: 200), wantsFile: false)
        _ = await rig.coordinator.ensure(stream: rig.stream(id, duration: 201), wantsFile: false)

        #expect(rig.spy.count == 2)
        #expect(await rig.store.entry(for: id)?.format.durationMs == 201_000)
    }

    @Test("an entry from an older analysis version analyses again")
    func versionBumpReanalyses() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)
        var old = try #require(await rig.store.entry(for: id))
        old.version = MusicAnalysis.currentVersion - 1
        try await rig.store.put(old)

        let outcome = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)

        #expect(outcome == .analysed(file: nil))
        #expect(rig.spy.count == 2)
        #expect(await rig.store.entry(for: id)?.version == MusicAnalysis.currentVersion)
    }

    @Test("a version 1 row is re-analysed in the background and comes back as version 2")
    func versionOneBecomesTwo() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)
        var old = try #require(await rig.store.entry(for: id))
        old.version = 1
        old.beatGrid = nil
        try await rig.store.put(old)
        #expect(await rig.store.freshness(of: id, matching: nil) == .staleVersion)

        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)

        #expect(await rig.store.entry(for: id)?.version == MusicAnalysis.currentVersion)
        #expect(await rig.store.freshness(of: id, matching: nil) == .fresh)
    }

    @Test("a version 1 row whose file can never be analysed becomes a v2 row with its fades and no grid")
    func versionOneUnreadableIsUpgraded() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)
        var old = try #require(await rig.store.entry(for: id))
        old.version = 1
        old.beatGrid = nil
        try await rig.store.put(old)
        #expect(await rig.store.staleVideoIds(limit: 10).contains(id))

        rig.spy.fails = true
        let outcome = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)

        guard case .failed = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
        let row = try #require(await rig.store.entry(for: id))
        #expect(row.version == MusicAnalysis.currentVersion)
        #expect(row.beatGrid == nil)
        #expect(row.energy == old.energy && row.silenceEnd == old.silenceEnd && row.introEnd == old.introEnd)
        #expect(await rig.store.staleVideoIds(limit: 10).contains(id) == false)
    }

    @Test("a version 2 row with a grid is stale, and its grid survives when the file can never be re-analysed")
    func versionTwoGridSurvivesUnreadable() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)
        var old = try #require(await rig.store.entry(for: id))
        old.version = 2
        old.beatGrid = MusicBeatGrid(
            periodSec: 0.5, anchorSec: 1, downbeatPhase: nil, beatConfidence: 0.9, downbeatConfidence: 0,
            intervalSpread: 0.01, driftSec: 0, spanStartSec: 1, spanEndSec: 100
        ).encode()
        try await rig.store.put(old)
        #expect(await rig.store.freshness(of: id, matching: nil) == .staleVersion)

        rig.spy.fails = true
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)

        let row = try #require(await rig.store.entry(for: id))
        #expect(row.version == MusicAnalysis.currentVersion)
        #expect(row.usableGrid?.beatConfidence == 0.9)
    }

    @Test("a version 3 row with a grid is stale but its grid survives an unreadable file (downbeat step is new in 4)")
    func versionThreeGridSurvivesUnreadable() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)
        var old = try #require(await rig.store.entry(for: id))
        old.version = 3
        old.beatGrid = MusicBeatGrid(
            periodSec: 0.5, anchorSec: 1, downbeatPhase: 2, beatConfidence: 0.9, downbeatConfidence: 0.6,
            intervalSpread: 0.01, driftSec: 0, spanStartSec: 1, spanEndSec: 100
        ).encode()
        try await rig.store.put(old)
        #expect(await rig.store.freshness(of: id, matching: nil) == .staleVersion)
        #expect(MusicAnalysis.currentVersion >= 4)

        rig.spy.fails = true
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)

        let row = try #require(await rig.store.entry(for: id))
        #expect(row.version == MusicAnalysis.currentVersion)
        #expect(row.usableGrid?.beatConfidence == 0.9)
        // The old bass-only downbeat guess is cleared, not re-stamped as a version 4 one.
        #expect(row.usableGrid?.downbeatPhase == nil)
        #expect(row.usableGrid?.downbeatConfidence == 0)
    }

    @Test("a version 4 row whose file can never be re-analysed is stamped current with no key")
    func versionFourUnreadableHasNoKey() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)
        var old = try #require(await rig.store.entry(for: id))
        old.version = 4
        old.keyInfo = MusicKeyInfo(tonic: 3, isMinor: true, confidence: 0.5, energy: 0.5).encode()
        try await rig.store.put(old)
        #expect(await rig.store.freshness(of: id, matching: nil) == .staleVersion)

        rig.spy.fails = true
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)

        let row = try #require(await rig.store.entry(for: id))
        #expect(row.version == MusicAnalysis.currentVersion)
        #expect(row.keyInfo == nil && row.keyInfoValue == nil)
        #expect(await rig.store.staleVideoIds(limit: 10).contains(id) == false)
    }

    @Test("a cancelled analysis never replaces a stored row, so a kept grid survives")
    func cancelledRunKeepsOldRow() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false)
        var old = try #require(await rig.store.entry(for: id))
        old.version = 4
        old.beatGrid = MusicBeatGrid(
            periodSec: 0.5, anchorSec: 1, downbeatPhase: 2, beatConfidence: 0.9, downbeatConfidence: 0.6,
            intervalSpread: 0.01, driftSec: 0, spanStartSec: 1, spanEndSec: 100
        ).encode()
        try await rig.store.put(old)
        let gate = MusicTestGate()
        rig.spy.gate = gate
        let before = rig.spy.count

        // The spy returns a grid-less result even though the task was cancelled while it waited.
        let only = Task { await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false) }
        while rig.spy.count == before { await Task.yield() }
        only.cancel()
        for _ in 0..<20 { await Task.yield() }
        await gate.open()
        _ = await only.value

        let row = try #require(await rig.store.entry(for: id))
        #expect(row.version == 4)
        #expect(row.usableGrid?.beatConfidence == 0.9)
    }

    @Test("two ensure calls for one song at once share one fetch and one analysis")
    func coalesces() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        let gate = MusicTestGate()
        rig.spy.gate = gate
        let s = rig.stream(id)

        async let a = rig.coordinator.ensure(stream: s, wantsFile: false)
        async let b = rig.coordinator.ensure(stream: s, wantsFile: true)
        while rig.spy.count == 0 { await Task.yield() }
        await gate.open()
        let outcomes = await [a, b]

        #expect(rig.spy.count == 1)
        #expect(await rig.transport.requestCount == 3)
        // The file was wanted by one of the two callers, so it is kept for both.
        #expect(outcomes.allSatisfy { $0 == .analysed(file: rig.folder.file(id)) })
    }

    @Test("an analyzer failure stores nothing and deletes the file")
    func analyzerFailure() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        rig.spy.fails = true

        let outcome = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: true)

        #expect(outcome == .failed)
        #expect(await rig.store.entry(for: id) == nil)
        #expect(!rig.folder.exists(rig.folder.file(id)))
    }

    @Test("a fetch failure is a failed outcome with no row and no file")
    func fetchFailure() async throws {
        let bad = ResolvedStream(
            videoId: id, url: URL(string: "http://insecure.example.test/x")!, itag: 140, durationSeconds: 200,
            expiresAt: .distantFuture, playbackTrackingURL: nil, httpHeaders: [:]
        )
        // The fake transport answers 416 past the payload: a range it cannot serve is a failed fetch.
        let empty = Rig(payload: Data())
        defer { empty.cleanUp() }

        let outcome = await empty.coordinator.ensure(stream: bad, wantsFile: false)

        #expect(outcome == .failed)
        #expect(empty.spy.count == 0)
        #expect(await empty.store.entry(for: id) == nil)
    }

    @Test("one joiner cancelling (task and cancel call) leaves a file-wanting joiner its file")
    func cancelKeepsOtherJoiner() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        let gate = MusicTestGate()
        rig.spy.gate = gate
        let s = rig.stream(id)

        let service = Task { await rig.coordinator.ensure(stream: s, wantsFile: true) }
        while rig.spy.count == 0 { await Task.yield() }
        let background = Task { await rig.coordinator.ensure(stream: s, wantsFile: false) }
        for _ in 0..<20 { await Task.yield() }
        background.cancel()
        await rig.coordinator.cancel(videoId: id)
        await gate.open()

        #expect(await service.value == .analysed(file: rig.folder.file(id)))
        #expect(rig.folder.exists(rig.folder.file(id)))
        _ = await background.value
    }

    @Test("when every joiner has cancelled the run is cancelled and its file deleted")
    func lastJoinerCancels() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        let gate = MusicTestGate()
        rig.spy.gate = gate
        let s = rig.stream(id)

        let only = Task { await rig.coordinator.ensure(stream: s, wantsFile: false) }
        while rig.spy.count == 0 { await Task.yield() }
        only.cancel()
        for _ in 0..<20 { await Task.yield() }
        await gate.open()

        #expect(await only.value == .failed)
        #expect(!rig.folder.exists(rig.folder.file(id)))
    }

    @Test("an ensure that arrives as the run finishes never gets a stale outcome for a deleted file")
    func noStaleRunningEntry() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        for round in 0..<40 {
            await rig.store.invalidate(videoId: id)
            let first = Task { await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: false) }
            for _ in 0..<(round % 12) { await Task.yield() }
            let second = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: true)
            _ = await first.value

            if case .analysed(file: let file) = second {
                let kept = try #require(file, "round \(round): a file-wanting caller got no file")
                #expect(rig.folder.exists(kept), "round \(round)")
            }
            await rig.cache.discard(videoId: id)
        }
    }

    @Test("release unpins and deletes a kept file after the grace")
    func releaseDeletes() async throws {
        let rig = Rig(payload: payload)
        defer { rig.cleanUp() }
        _ = await rig.coordinator.ensure(stream: rig.stream(id), wantsFile: true)

        await rig.coordinator.release(videoId: id)
        await rig.cache.drainReleases()

        #expect(!rig.folder.exists(rig.folder.file(id)))
    }
}
