import Foundation
import Testing
@testable import Deci

/// What a coordinator told its `report` closure, in order.
nonisolated final class ReportSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [(String, UUID, Bool)] = []

    var events: [(String, UUID, Bool)] { lock.withLock { _events } }

    var closure: MusicAnalysisCoordinator.Report {
        { [self] id, token, active in lock.withLock { _events.append((id, token, active)) } }
    }
}

struct MusicAnalysisActivityTests {
    private let id = DownloadSamples.idA
    private let payload = DownloadSamples.payload(12_000)

    @MainActor
    @Test("a song shows as analysing until every run of it has ended")
    func tokensPerRun() {
        let activity = MusicAnalysisActivity()
        let first = UUID(), second = UUID()
        #expect(!activity.isAnalysing("a"))

        activity.begin("a", token: first)
        activity.begin("a", token: second)
        activity.end("a", token: first)
        #expect(activity.isAnalysing("a"), "the second run is still going")

        activity.end("a", token: UUID())
        #expect(activity.isAnalysing("a"), "an unknown token clears nothing")

        activity.end("a", token: second)
        #expect(!activity.isAnalysing("a"))
    }

    @MainActor
    @Test("the finished hook fires once, when a song's last run ends")
    func finishedOnLastRun() {
        let activity = MusicAnalysisActivity()
        var finished: [String] = []
        activity.onFinished = { finished.append($0) }
        let first = UUID(), second = UUID()
        activity.begin("a", token: first)
        activity.begin("a", token: second)
        activity.end("a", token: first)
        #expect(finished.isEmpty, "the second run is still going")
        activity.end("a", token: UUID())
        #expect(finished.isEmpty, "an unknown token ends nothing")
        activity.end("a", token: second)
        #expect(finished == ["a"])
        activity.end("b", token: UUID())
        #expect(finished == ["a"], "a song that never began does not fire")
    }

    @Test("a run that analyses reports start then end with one token; a fresh entry reports only the end")
    func coordinatorReports() async throws {
        let folder = TrackCacheFolder()
        defer { folder.remove() }
        let transport = FakeDownloadTransport(serving: payload)
        let cache = MusicTrackCache(
            root: folder.root, transport: transport, chunkSize: 5_000, sleep: { _ in },
            freeBytes: { _ in Int64.max / 2 }
        )
        let spy = AnalyzeSpy()
        let reports = ReportSpy()
        let payloadCount = payload.count
        let coordinator = MusicAnalysisCoordinator(
            store: MusicAnalysisStore(url: nil), cache: cache,
            downloads: { _ in nil },
            resolve: { id in FakeDownloadResolver.stream(videoId: id, call: 1, query: "clen=\(payloadCount)") },
            analyze: spy.closure,
            report: reports.closure
        )
        let stream = ResolvedStream(
            videoId: id, url: URL(string: "https://media.example.test/\(id)/0.m4a?clen=12000")!, itag: 140,
            durationSeconds: 200, expiresAt: .distantFuture, playbackTrackingURL: nil, httpHeaders: [:],
            audioCodec: "mp4a.40.2", loudnessDb: -7.5, perceptualLoudnessDb: -5
        )

        #expect(await coordinator.ensure(stream: stream, wantsFile: false) == .analysed(file: nil))
        let first = reports.events
        #expect(first.map(\.2) == [true, false])
        #expect(first.allSatisfy { $0.0 == id })
        #expect(first.first?.1 == first.last?.1, "start and end carry the same run token")

        #expect(await coordinator.ensure(stream: stream, wantsFile: false) == .alreadyFresh)
        #expect(reports.events.dropFirst(2).map(\.2) == [false], "a fresh skip never starts a spinner")
    }
}
