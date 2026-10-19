// DeciTests/Music/YTMusicLyricsTestSupport.swift
// Made-up YouTube Music responses and a scripted music.youtube.com for the lyrics tests. Nothing here is a real
// title, id or lyric: "Line one", "vid00000001" and "MPLYt_fake" stand in for all of it.

import Foundation
import os
@testable import Deci

nonisolated enum YTSamples {
    static let videoId = "vid00000001"
    static let browseId = "MPLYt_fake"
    static let source = "Source: Test Provider"

    /// One timed line as the Android browse answer carries it: both times are strings of milliseconds (a test may use
    /// numbers or junk instead, hence `Any`; a cue is only ever built and read, never shared while it changes).
    struct Cue: @unchecked Sendable {
        var text: String
        var start: Any
        var end: Any
    }

    static func cue(_ text: String, _ start: Any, _ end: Any) -> Cue { Cue(text: text, start: start, end: end) }

    /// Four sung lines, one every two seconds, in order.
    static let fourCues = [
        cue("Line one", "1000", "3000"),
        cue("Line two", "3000", "5000"),
        cue("Line three", "5000", "7000"),
        cue("Line four", "7000", "9000"),
    ]

    static func json(_ object: Any) -> Data { LyricsSamples.json(object) }

    static func query(duration: TimeInterval? = 200) -> LyricsQuery {
        LyricsSamples.query(videoId: videoId, duration: duration)
    }

    // MARK: - /next

    /// A watch-next answer with an "Up next" tab, a lyrics tab (left out when `browseId` is nil) and a related tab.
    /// The lyrics tab is found by its browse id, so `title` can be anything.
    static func next(browseId: String? = browseId, unselectable: Bool = false, title: String = "Lyrics") -> Data {
        var tabs: [[String: Any]] = [
            ["tabRenderer": ["title": "Up next", "content": ["musicQueueRenderer": [String: Any]()]]],
        ]
        if let browseId {
            var tab: [String: Any] = [
                "title": title,
                "endpoint": [
                    "browseEndpoint": [
                        "browseId": browseId,
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_TRACK_LYRICS"],
                        ],
                    ],
                ],
            ]
            if unselectable { tab["unselectable"] = true }
            tabs.append(["tabRenderer": tab])
        }
        tabs.append([
            "tabRenderer": [
                "title": "Related",
                "endpoint": ["browseEndpoint": ["browseId": "MPREt_fake"]],
            ],
        ])
        return json([
            "contents": [
                "singleColumnMusicWatchNextResultsRenderer": [
                    "tabbedRenderer": ["watchNextTabbedResultsRenderer": ["tabs": tabs]],
                ],
            ],
        ])
    }

    // MARK: - /browse

    /// The Android answer with timed lyrics. `nested` buries the model deeper, inside lists, to show the search does
    /// not depend on the exact path. A nil `source` leaves `sourceMessage` out.
    static func timedBrowse(_ cues: [Cue], source: String? = source, nested: Bool = false) -> Data {
        let lines: [[String: Any]] = cues.map { cue in
            [
                "lyricLine": cue.text,
                "cueRange": [
                    "startTimeMilliseconds": cue.start,
                    "endTimeMilliseconds": cue.end,
                    "metadata": ["id": "cue"],
                ] as [String: Any],
            ]
        }
        var data: [String: Any] = ["timedLyricsData": lines]
        if let source { data["sourceMessage"] = source }
        let model: [String: Any] = ["timedLyricsModel": ["lyricsData": data]]
        let element: [String: Any] = ["newElement": ["type": ["componentType": ["model": model]]]]
        if nested {
            return json([
                "contents": ["sectionListRenderer": ["contents": [["wrapperRenderer": ["items": [["elementRenderer": element]]]]]]],
            ])
        }
        return json(["contents": ["elementRenderer": element]])
    }

    /// A browse answer with a description shelf: the plain lyrics are the runs joined, the credit is the footer's runs.
    static func plainBrowse(_ runs: [String], footer: [String]? = [source]) -> Data {
        var shelf: [String: Any] = ["description": ["runs": runs.map { ["text": $0] }]]
        if let footer { shelf["footer"] = ["runs": footer.map { ["text": $0] }] }
        return json(["contents": ["sectionListRenderer": ["contents": [["musicDescriptionShelfRenderer": shelf]]]]])
    }

    static func plainBrowse(_ text: String, footer: String? = source) -> Data {
        plainBrowse([text], footer: footer.map { [$0] })
    }

    static let plainText = "Line one\nLine two\nLine three\nLine four"

    /// A lyrics page for a song that has the tab but no lyrics (an instrumental, a lofi mix): neither model nor shelf.
    static let emptyBrowse = json(["contents": ["sectionListRenderer": ["contents": [[String: Any]]()]]])
}

/// A scripted music.youtube.com: `/next`, the Android-client `/browse` and the web-client `/browse` each answer from
/// a queue of replies (the last one repeats), every request is recorded, and requests can be held at a gate.
nonisolated final class FakeYTMusic: HTTPTransport, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var failure: URLError?

        static func ok(_ body: Data) -> Reply { Reply(body: body) }
        static func status(_ code: Int, headers: [String: String] = [:]) -> Reply { Reply(status: code, headers: headers) }
        static func fail(_ code: URLError.Code) -> Reply { Reply(failure: URLError(code)) }
    }

    enum Route: Hashable, Sendable { case next, android, web, other }

    private struct State {
        var replies: [Route: [Reply]] = [:]
        var counts: [Route: Int] = [:]
        var requests: [HTTPRequest] = []
        var gate: MusicTestGate?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// What is not scripted answers like a song with a lyrics tab and a page with no lyrics on it.
    init(next: [Reply]? = nil, android: [Reply]? = nil, web: [Reply]? = nil) {
        state.withLockUnchecked {
            $0.replies[.next] = next ?? [.ok(YTSamples.next())]
            $0.replies[.android] = android ?? [.ok(YTSamples.emptyBrowse)]
            $0.replies[.web] = web ?? [.ok(YTSamples.emptyBrowse)]
        }
    }

    func setGate(_ gate: MusicTestGate?) { state.withLockUnchecked { $0.gate = gate } }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var nextRequests: [HTTPRequest] { requests.filter { Self.route(of: $0) == .next } }
    var androidRequests: [HTTPRequest] { requests.filter { Self.route(of: $0) == .android } }
    var webRequests: [HTTPRequest] { requests.filter { Self.route(of: $0) == .web } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let route = Self.route(of: request)
        let (reply, gate) = state.withLockUnchecked { state -> (Reply, MusicTestGate?) in
            state.requests.append(request)
            guard let queue = state.replies[route], !queue.isEmpty else { return (.status(404), state.gate) }
            let count = state.counts[route, default: 0]
            state.counts[route] = count + 1
            return (queue[min(count, queue.count - 1)], state.gate)
        }
        if let gate { await gate.wait() }
        if let failure = reply.failure { throw failure }
        return HTTPResponse(statusCode: reply.status, headers: reply.headers, data: reply.body)
    }

    /// Which endpoint a request is for; a browse is told apart by the client it names.
    static func route(of request: HTTPRequest) -> Route {
        if request.url.path.hasSuffix("/next") { return .next }
        guard request.url.path.hasSuffix("/browse") else { return .other }
        return clientName(of: request) == "ANDROID_MUSIC" ? .android : .web
    }

    /// The JSON body of a request.
    static func body(_ request: HTTPRequest) -> [String: Any] {
        guard let data = request.body,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// The `context.client` object of a request body.
    static func client(of request: HTTPRequest) -> [String: Any] {
        ((body(request)["context"] as? [String: Any])?["client"] as? [String: Any]) ?? [:]
    }

    static func clientName(of request: HTTPRequest) -> String? { client(of: request)["clientName"] as? String }
}
