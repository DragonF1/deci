// DeciTests/Music/LyricsTestSupport.swift
// Shared fakes and made-up fixtures for the lyrics tests. Every lyric line here is invented
// ("First test line"): real lyrics are copyrighted and never go into the repo, the tests or the logs.

import Foundation
import os
@testable import Deci

nonisolated enum LyricsSamples {
    /// A small synced file with two metadata tags and four timed lines.
    static let synced = """
    [ar:Test Artist]
    [ti:Test Song]
    [00:01.00]First test line
    [00:05.50]Second test line
    [00:10.00]Third test line
    [00:15.25]Fourth test line
    """

    static let plain = "First test line\nSecond test line\nThird test line\nFourth test line"

    /// The parsed form of `synced`.
    static let syncedLines = [
        LyricLine(time: 1.0, text: "First test line"),
        LyricLine(time: 5.5, text: "Second test line"),
        LyricLine(time: 10.0, text: "Third test line"),
        LyricLine(time: 15.25, text: "Fourth test line"),
    ]

    /// One LRCLIB record as the API returns it. A nil field becomes JSON null.
    static func record(
        id: Int = 1,
        track: String = "Test Song",
        artist: String = "Test Artist",
        album: String? = "Test Album",
        duration: Double = 200,
        instrumental: Bool = false,
        plain: String? = LyricsSamples.plain,
        synced: String? = LyricsSamples.synced
    ) -> [String: Any] {
        [
            "id": id,
            "name": track,
            "trackName": track,
            "artistName": artist,
            "albumName": album ?? NSNull(),
            "duration": duration,
            "instrumental": instrumental,
            "plainLyrics": plain ?? NSNull(),
            "syncedLyrics": synced ?? NSNull(),
        ]
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// An LRC body of `count` lines, one every 2 s, for tests that need a long song.
    static func syncedBody(lines count: Int, prefix: String = "Made-up line") -> String {
        (0..<count).map { index in
            let seconds = index * 2
            return String(format: "[%02d:%02d.00]%@ %d", seconds / 60, seconds % 60, prefix, index)
        }.joined(separator: "\n")
    }

    static func query(
        videoId: String = "vid1",
        title: String = "Test Song",
        artist: String = "Test Artist",
        album: String? = "Test Album",
        duration: TimeInterval? = 200
    ) -> LyricsQuery {
        LyricsQuery(videoId: videoId, title: title, artist: artist, album: album, duration: duration)
    }
}

/// A scripted lrclib.net: answers `/api/get` and `/api/search` from queues of replies (the last one
/// repeats), records every request, and can hold requests at a gate.
nonisolated final class FakeLRCLib: HTTPTransport, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var failure: URLError?

        static func ok(_ body: Data) -> Reply { Reply(body: body) }
        static func record(_ record: [String: Any]) -> Reply { Reply(body: LyricsSamples.json(record)) }
        static func results(_ records: [[String: Any]]) -> Reply { Reply(body: LyricsSamples.json(records)) }
        static func status(_ code: Int, headers: [String: String] = [:], body: String = "") -> Reply {
            Reply(status: code, headers: headers, body: Data(body.utf8))
        }
        static func fail(_ code: URLError.Code) -> Reply { Reply(failure: URLError(code)) }

        static let notFound = Reply(
            status: 404,
            body: Data(#"{"message":"Failed to find specified track","name":"TrackNotFound","statusCode":404}"#.utf8)
        )
        static let empty = Reply(body: Data("[]".utf8))
    }

    private struct State {
        var getReplies: [Reply] = [.notFound]
        var searchReplies: [Reply] = [.empty]
        var requests: [HTTPRequest] = []
        var getCount = 0
        var searchCount = 0
        var gate: MusicTestGate?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(get: [Reply] = [.notFound], search: [Reply] = [.empty]) {
        state.withLockUnchecked {
            $0.getReplies = get
            $0.searchReplies = search
        }
    }

    func setGet(_ replies: Reply...) { state.withLockUnchecked { $0.getReplies = replies; $0.getCount = 0 } }
    func setSearch(_ replies: Reply...) { state.withLockUnchecked { $0.searchReplies = replies; $0.searchCount = 0 } }
    func setGate(_ gate: MusicTestGate?) { state.withLockUnchecked { $0.gate = gate } }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var getRequests: [HTTPRequest] { requests.filter { $0.url.path == "/api/get" } }
    var searchRequests: [HTTPRequest] { requests.filter { $0.url.path == "/api/search" } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (reply, gate) = state.withLockUnchecked { state -> (Reply, MusicTestGate?) in
            state.requests.append(request)
            switch request.url.path {
            case "/api/get":
                let reply = state.getReplies[min(state.getCount, state.getReplies.count - 1)]
                state.getCount += 1
                return (reply, state.gate)
            case "/api/search":
                let reply = state.searchReplies[min(state.searchCount, state.searchReplies.count - 1)]
                state.searchCount += 1
                return (reply, state.gate)
            default:
                return (.status(404), state.gate)
            }
        }
        if let gate { await gate.wait() }
        if let failure = reply.failure { throw failure }
        return HTTPResponse(statusCode: reply.status, headers: reply.headers, data: reply.body)
    }

    /// The query string of a request as a dictionary.
    static func query(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}

/// Stands in for a lyrics source (the chain's two legs, or the whole chain in store and service tests): records
/// queries, answers from a script, and can hold a query at a gate.
nonisolated final class FakeLyricsProvider: LyricsProviding, @unchecked Sendable {
    private struct State {
        var queries: [LyricsQuery] = []
        var results: [String: LyricsResult] = [:]
        var credits: [String: String] = [:]
        var lengthMatters: [String: Bool] = [:]
        var errors: [String: any Error] = [:]
        var gates: [String: MusicTestGate] = [:]
        var fallback: LyricsResult = .notFound
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var queries: [LyricsQuery] { state.withLock { $0.queries } }
    var videoIds: [String] { queries.map(\.videoId) }

    func setResult(_ result: LyricsResult, for videoId: String) {
        state.withLockUnchecked { $0.results[videoId] = result; $0.errors[videoId] = nil }
    }

    /// The credit that goes with the scripted result; none by default, like a provider that does not name itself.
    func setCredit(_ credit: String?, for videoId: String) {
        state.withLockUnchecked { $0.credits[videoId] = credit }
    }

    /// Whether the scripted answer is worth redoing once the length is known; true by default, like a guess.
    func setLengthMatters(_ matters: Bool, for videoId: String) {
        state.withLockUnchecked { $0.lengthMatters[videoId] = matters }
    }

    func setError(_ error: (any Error)?, for videoId: String) {
        state.withLockUnchecked { $0.errors[videoId] = error }
    }

    func setGate(_ gate: MusicTestGate?, for videoId: String) {
        state.withLockUnchecked { $0.gates[videoId] = gate }
    }

    func lyrics(for query: LyricsQuery) async throws -> LyricsResult {
        try await answer(for: query).result
    }

    func answer(for query: LyricsQuery) async throws -> LyricsAnswer {
        // Like the real client, the answer is what was scripted when the call was made, even if a gate holds it.
        let (answer, error, gate) = state.withLockUnchecked { state -> (LyricsAnswer, (any Error)?, MusicTestGate?) in
            state.queries.append(query)
            let answer = LyricsAnswer(
                result: state.results[query.videoId] ?? state.fallback,
                credit: state.credits[query.videoId],
                lengthMatters: state.lengthMatters[query.videoId] ?? true
            )
            return (answer, state.errors[query.videoId], state.gates[query.videoId])
        }
        // The gate ignores cancellation, like a slow server: a late answer must be dropped by the store, not by the task.
        if let gate { await gate.wait() }
        if let error { throw error }
        return answer
    }
}

/// A provider that only knows the older one-method seam, so it gets the default `answer(for:)` with no credit.
nonisolated struct ResultOnlyProvider: LyricsProviding {
    let result: LyricsResult
    func lyrics(for query: LyricsQuery) async throws -> LyricsResult { result }
}

/// Stands in for `Task.sleep` in the store: records how long it was asked to wait and, when gated, holds every
/// caller until `release()`. The gate ignores cancellation, like a stuck timer, so a test can prove that a
/// stale sleeper which wakes up late still sends nothing.
nonisolated final class FakeSleeper: @unchecked Sendable {
    private let asked = OSAllocatedUnfairLock(initialState: [Duration]())
    private let gate = MusicTestGate()
    private let gated: Bool

    init(gated: Bool = true) { self.gated = gated }

    var requested: [Duration] { asked.withLock { $0 } }

    func sleep(_ duration: Duration) async throws {
        asked.withLock { $0.append(duration) }
        if gated { await gate.wait() }
    }

    func release() async { await gate.open() }
}
