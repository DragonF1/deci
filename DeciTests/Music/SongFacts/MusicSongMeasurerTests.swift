// DeciTests/Music/SongFacts/MusicSongMeasurerTests.swift
// Measuring what the services lacked: the analysis through the coordinator, the tempo through a decode and a beat
// finder (both fakes here), the pinned file released after, and nothing recorded on a cancel.

import Foundation
import Testing
@testable import Deci

private actor FakeAnalysis: MusicAnalysisProviding {
    var ensureOutcome: MusicAnalysisCoordinator.Outcome = .alreadyFresh
    var fileOutcome: MusicSongFileOutcome = .failed
    private(set) var ensured: [(videoId: String, wantsFile: Bool)] = []
    private(set) var pinnedAsked: [String] = []
    private(set) var released: [String] = []
    var playerPins: Set<String> = []

    func setEnsure(_ outcome: MusicAnalysisCoordinator.Outcome) { ensureOutcome = outcome }
    func setFile(_ outcome: MusicSongFileOutcome) { fileOutcome = outcome }
    func setPlayerPin(_ id: String) { playerPins.insert(id) }

    func isPinned(videoId: String) async -> Bool { playerPins.contains(videoId) }

    func ensure(stream: ResolvedStream, wantsFile: Bool) async -> MusicAnalysisCoordinator.Outcome {
        ensured.append((stream.videoId, wantsFile))
        return ensureOutcome
    }

    func release(videoId: String) async { released.append(videoId) }
    func discard(videoId: String) async {}
    func cancel(videoId: String) async {}

    func pinnedFile(for stream: ResolvedStream) async -> MusicSongFileOutcome {
        pinnedAsked.append(stream.videoId)
        return fileOutcome
    }
}

@Suite("Music song measurer")
struct MusicSongMeasurerTests {
    private static let file = URL(fileURLWithPath: "/Volumes/Storage/_test/deci-songdata/pinned.m4a")

    private func stream(
        id: String = "a", url: String = "https://example.com/a", origin: ResolvedStream.Origin = .network
    ) -> ResolvedStream {
        ResolvedStream(
            videoId: id, url: URL(string: url)!, itag: 251, durationSeconds: 200, expiresAt: .distantFuture,
            playbackTrackingURL: nil, httpHeaders: [:], origin: origin
        )
    }

    private func store() -> MusicSongFactsStore {
        let dir = "/Volumes/Storage/_test/deci-songdata/measurer"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return MusicSongFactsStore(url: URL(fileURLWithPath: "\(dir)/\(UUID().uuidString).sqlite"))
    }

    private let steady = MusicBeatResult(bpm: 128.4, confidence: 0.82, beats: [0.5, 0.97, 1.44], intervalSpread: 0.01, downbeat: nil)

    private func measurer(
        _ analysis: FakeAnalysis, _ facts: MusicSongFactsStore, result: MusicBeatResult? = nil,
        decode: MusicSongMeasurer.Decode? = nil
    ) -> MusicSongMeasurer {
        let found = result ?? steady
        return MusicSongMeasurer(
            analysis: analysis, facts: facts,
            decode: decode ?? { _ in MusicBeatDecoder.Decoded(samples: [0, 0, 0], sampleRate: 22_050) },
            find: { _, _ in found }
        )
    }

    @Test("a tempo is measured from the pinned file, stored with the Deci source, and the file is released")
    func measuresTempo() async throws {
        let analysis = FakeAnalysis()
        await analysis.setFile(.file(Self.file))
        let facts = store()
        let result = await measurer(analysis, facts).measure(stream: stream(), needAnalysis: false, needBPM: true)
        #expect(result.problem == nil)
        let record = try #require(await facts.record(for: "a"))
        #expect(record.facts.bpm == 128.4)
        #expect(record.facts.bpmConfidence == 0.82)
        #expect(record.facts.source(of: .bpm) == .deci)
        #expect(await analysis.released == ["a"])
        #expect(await analysis.ensured.isEmpty)
    }

    @Test("the analysis and the tempo share one download when both are missing")
    func oneDownload() async throws {
        let analysis = FakeAnalysis()
        await analysis.setEnsure(.analysed(file: Self.file))
        let facts = store()
        let result = await measurer(analysis, facts).measure(stream: stream(), needAnalysis: true, needBPM: true)
        #expect(result.problem == nil)
        let asked = await analysis.ensured
        #expect(asked.count == 1)
        #expect(asked.first?.wantsFile == true)
        #expect(await analysis.pinnedAsked.isEmpty)
        #expect(await facts.record(for: "a")?.facts.bpm == 128.4)
        #expect(await analysis.released == ["a"])
    }

    @Test("an analysis alone asks for no file and measures no tempo")
    func analysisOnly() async {
        let analysis = FakeAnalysis()
        await analysis.setEnsure(.analysed(file: nil))
        let facts = store()
        let result = await measurer(analysis, facts).measure(stream: stream(), needAnalysis: true, needBPM: false)
        #expect(result.problem == nil)
        #expect(await analysis.ensured.first?.wantsFile == false)
        #expect(await facts.record(for: "a") == nil)
    }

    @Test("a song with an analysis but no tempo takes the pinned file route")
    func pinnedRoute() async {
        let analysis = FakeAnalysis()
        await analysis.setFile(.file(Self.file))
        let facts = store()
        _ = await measurer(analysis, facts).measure(stream: stream(), needAnalysis: false, needBPM: true)
        #expect(await analysis.pinnedAsked == ["a"])
    }

    @Test("a file on this Mac is read where it is and nothing is pinned or released")
    func fileStream() async {
        let analysis = FakeAnalysis()
        let facts = store()
        let local = stream(url: "file:///Volumes/Storage/_test/deci-songdata/a.m4a", origin: .download)
        _ = await measurer(analysis, facts).measure(stream: local, needAnalysis: false, needBPM: true)
        #expect(await analysis.pinnedAsked.isEmpty)
        #expect(await analysis.released.isEmpty)
        #expect(await facts.record(for: "a")?.facts.bpm == 128.4)
    }

    @Test("a beat finder with nothing usable stores no tempo but marks the song as measured")
    func noUsableTempo() async throws {
        let analysis = FakeAnalysis()
        await analysis.setFile(.file(Self.file))
        let facts = store()
        let result = await measurer(analysis, facts, result: .empty).measure(stream: stream(), needAnalysis: false, needBPM: true)
        #expect(result.problem == nil)
        let record = try #require(await facts.record(for: "a"))
        #expect(record.facts.bpm == nil)
        #expect(record.measuredAt != nil)
        #expect(await analysis.released == ["a"])
    }

    @Test("a rate limit while fetching is reported and nothing is stored")
    func rateLimited() async {
        let analysis = FakeAnalysis()
        await analysis.setFile(.rateLimited)
        let facts = store()
        let result = await measurer(analysis, facts).measure(stream: stream(), needAnalysis: false, needBPM: true)
        #expect(result.problem == .rateLimited)
        #expect(await facts.record(for: "a") == nil)
    }

    @Test("a failed fetch is reported and not retried for the tempo")
    func fetchFailed() async {
        let analysis = FakeAnalysis()
        await analysis.setEnsure(.failed)
        let facts = store()
        let result = await measurer(analysis, facts).measure(stream: stream(), needAnalysis: true, needBPM: true)
        #expect(result.problem == .failed)
        #expect(await analysis.pinnedAsked.isEmpty)
        let record = await facts.record(for: "a")
        #expect(record?.facts.measureFailedAt != nil)
        #expect(record?.measuredAt == nil)
    }

    @Test("a decode that throws is a quiet failure, the pin is released, and nothing is stored")
    func decodeFails() async {
        struct Boom: Error {}
        let analysis = FakeAnalysis()
        await analysis.setFile(.file(Self.file))
        let facts = store()
        let result = await measurer(analysis, facts, decode: { _ in throw Boom() })
            .measure(stream: stream(), needAnalysis: false, needBPM: true)
        #expect(result.problem == .failed)
        #expect(await analysis.released == ["a"])
        let record = await facts.record(for: "a")
        #expect(record?.facts.bpm == nil)
        #expect(record?.facts.measureFailedAt != nil)
        #expect(record?.measuredAt == nil)
    }

    @Test("a measured tempo outside 30 to 300 is not stored, but the song counts as measured")
    func absurdTempo() async throws {
        let analysis = FakeAnalysis()
        await analysis.setFile(.file(Self.file))
        let facts = store()
        let wild = MusicBeatResult(bpm: 1e300, confidence: 0.9, beats: [0.5, 0.97, 1.44], intervalSpread: 0.01, downbeat: nil)
        _ = await measurer(analysis, facts, result: wild).measure(stream: stream(), needAnalysis: false, needBPM: true)
        let record = try #require(await facts.record(for: "a"))
        #expect(record.facts.bpm == nil)
        #expect(record.measuredAt != nil)
    }

    @Test("a file the player already pinned is read but its pin and file are left alone")
    func playerPinKept() async {
        let analysis = FakeAnalysis()
        await analysis.setFile(.borrowed(Self.file))
        let facts = store()
        _ = await measurer(analysis, facts).measure(stream: stream(), needAnalysis: false, needBPM: true)
        #expect(await analysis.released.isEmpty)
        #expect(await facts.record(for: "a")?.facts.bpm == 128.4)
    }

    @Test("a download of the shared run the player pinned is not released either")
    func playerPinKeptThroughEnsure() async {
        let analysis = FakeAnalysis()
        await analysis.setPlayerPin("a")
        await analysis.setEnsure(.analysed(file: Self.file))
        let facts = store()
        _ = await measurer(analysis, facts).measure(stream: stream(), needAnalysis: true, needBPM: true)
        #expect(await analysis.released.isEmpty)
        #expect(await facts.record(for: "a")?.facts.bpm == 128.4)
    }

    @Test("a rate limit is not remembered as a failed attempt")
    func rateLimitNotRecorded() async {
        let analysis = FakeAnalysis()
        await analysis.setEnsure(.rateLimited)
        let facts = store()
        let result = await measurer(analysis, facts).measure(stream: stream(), needAnalysis: true, needBPM: true)
        #expect(result.problem == .rateLimited)
        #expect(await facts.record(for: "a") == nil)
    }

    @Test("a cancel during the decode records nothing")
    func cancelled() async {
        let analysis = FakeAnalysis()
        await analysis.setFile(.file(Self.file))
        let facts = store()
        let measurer = measurer(analysis, facts, decode: { _ in
            try await Task.sleep(for: .seconds(30))
            return MusicBeatDecoder.Decoded(samples: [], sampleRate: 22_050)
        })
        let task = Task { await measurer.measure(stream: stream(), needAnalysis: false, needBPM: true) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value
        #expect(await facts.record(for: "a") == nil)
        #expect(await analysis.released == ["a"])
    }

    @Test("a cached copy is not analysed again")
    func trackCacheSkipsAnalysis() async {
        let analysis = FakeAnalysis()
        let facts = store()
        let cached = stream(url: "file:///Volumes/Storage/_test/deci-songdata/c.m4a", origin: .trackCache)
        _ = await measurer(analysis, facts).measure(stream: cached, needAnalysis: true, needBPM: false)
        #expect(await analysis.ensured.isEmpty)
    }
}
