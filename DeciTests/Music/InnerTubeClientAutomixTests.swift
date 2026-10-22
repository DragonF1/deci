// DeciTests/Music/InnerTubeClientAutomixTests.swift
// The playlist automix call of the InnerTube client against the recording fake transport: a `next` for the playlist
// and the song to read the automix preview from, then a `next` for the automix itself, and the fall back to the plain
// radio when the playlist has no automix. Request bodies, the answers that fall back, and the ones that throw.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient playlist automix")
struct InnerTubeClientAutomixTests {
    private static let nextPath = "/youtubei/v1/next"
    private static let playlistId = "PLhandBuiltAutomix01"
    private static let automixId = "RDAMPLPLhandBuiltAutomix01"
    private static let params = "wAEB8gECeAE%3D"
    private static let afterVideoId = "hbPlSong003"
    private static let automixVideoIds = ["hbPlSong003", "hbAmxSong01", "hbAmxSong02", "hbAmxSong03"]
    private static let radioVideoIds = ["4D7u5KF7SP8", "wU26xVT_vBU", "dJqxQzxLbHM", "tOaWhRATZqk"]

    private func makeClient(
        _ youtube: FakeYouTube,
        store: MemorySecretStore = MusicTestJar.signedInStore()
    ) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: store, now: { MusicTestJar.now })
    }

    /// A fake music.youtube.com whose playlist answers with the preview and whose automix answers with its first
    /// page. Any other playlist id (the plain radio's) gets the radio capture.
    private func automixYouTube(_ configure: (inout FakeYouTube.Config) -> Void = { _ in }) throws -> FakeYouTube {
        let playlist = try MusicFixtures.data("next-playlist-automix.json")
        let automix = try MusicFixtures.data("next-automix-first.json")
        return FakeYouTube {
            $0.nextBodies = [Self.playlistId: playlist, Self.automixId: automix]
            configure(&$0)
        }
    }

    private func nextBodies(_ youtube: FakeYouTube) -> [[String: Any]] {
        youtube.requests(path: Self.nextPath).map(FakeYouTube.jsonBody)
    }

    private func autoplay(_ client: InnerTubeClient) async throws -> MusicQueuePage {
        try await client.autoplay(afterVideoId: Self.afterVideoId, playlistId: Self.playlistId)
    }

    // MARK: - The two requests

    @Test("The playlist is asked about first, then the automix: two next calls, and the automix's page comes back")
    func twoRequests() async throws {
        let youtube = try automixYouTube()
        let page = try await autoplay(makeClient(youtube))
        #expect(page.tracks.map(\.videoId) == Self.automixVideoIds)
        #expect(page.continuation == "HANDBUILT_AUTOMIX_CONTINUATION_2")
        #expect(youtube.requests(path: Self.nextPath).count == 2)
    }

    @Test("Step one posts the song and the playlist with the radio's base fields and no params")
    func stepOneBody() async throws {
        let youtube = try automixYouTube()
        _ = try await autoplay(makeClient(youtube))

        let body = try #require(nextBodies(youtube).first)
        #expect(body["videoId"] as? String == Self.afterVideoId)
        #expect(body["playlistId"] as? String == Self.playlistId)
        #expect(body["params"] == nil)
        #expect(body["continuation"] == nil)
        #expect(body["isAudioOnly"] as? Bool == true)
        #expect(body["enablePersistentPlaylistPanel"] as? Bool == true)
        #expect(body["tunerSettingValue"] as? String == "AUTOMIX_SETTING_NORMAL")
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("Step two posts the automix's playlist and params, with no video id")
    func stepTwoBody() async throws {
        let youtube = try automixYouTube()
        _ = try await autoplay(makeClient(youtube))

        let body = try #require(nextBodies(youtube).last)
        #expect(body["playlistId"] as? String == Self.automixId)
        #expect(body["params"] as? String == Self.params)
        #expect(body["videoId"] == nil)
        #expect(body["continuation"] == nil)
        #expect(body["isAudioOnly"] as? Bool == true)
        #expect(body["enablePersistentPlaylistPanel"] as? Bool == true)
        #expect(body["tunerSettingValue"] as? String == "AUTOMIX_SETTING_NORMAL")
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("The params go out exactly as the preview carried them: still percent-encoded, never decoded or encoded twice")
    func paramsStayVerbatim() async throws {
        let youtube = try automixYouTube()
        _ = try await autoplay(makeClient(youtube))
        let raw = try #require(youtube.requests(path: Self.nextPath).last?.body)
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.contains(#""params":"wAEB8gECeAE%3D""#) || text.contains(#""params" : "wAEB8gECeAE%3D""#))
        #expect(text.contains("wAEB8gECeAE=") == false)
        #expect(text.contains("%253D") == false)
    }

    @Test("Both calls go to next with the auth headers")
    func requestShape() async throws {
        let youtube = try automixYouTube()
        _ = try await autoplay(makeClient(youtube))

        for request in youtube.requests(path: Self.nextPath) {
            #expect(request.method == "POST")
            #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/next?prettyPrint=false")
            #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
            #expect(request.headers["X-YouTube-Client-Name"] == "67")
            #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
        }
    }

    @Test("The ids are trimmed before they are asked for")
    func idsAreTrimmed() async throws {
        let youtube = try automixYouTube()
        let page = try await makeClient(youtube).autoplay(afterVideoId: "  \(Self.afterVideoId)\n", playlistId: " \(Self.playlistId) ")
        #expect(page.tracks.map(\.videoId) == Self.automixVideoIds)
        let first = try #require(nextBodies(youtube).first)
        #expect(first["videoId"] as? String == Self.afterVideoId)
        #expect(first["playlistId"] as? String == Self.playlistId)
    }

    @Test("The call shares the home page bootstrap with the other calls")
    func sharesBootstrap() async throws {
        let youtube = try automixYouTube()
        let client = makeClient(youtube)
        _ = try await client.search("a")
        _ = try await autoplay(client)
        #expect(youtube.requests(path: "/").count == 1)
    }

    @Test("An automix that answers with no songs and no continuation is no automix: the call falls back to the radio")
    func emptyAutomixPageFallsBack() async throws {
        let youtube = try automixYouTube { $0.nextBodies[Self.automixId] = Self.panelJSON(items: []) }
        let page = try await autoplay(makeClient(youtube))

        #expect(page.tracks.map(\.videoId) == Self.radioVideoIds)
        #expect(page.continuation == "SCRUBBED_RADIO_CONTINUATION_2")
        let bodies = nextBodies(youtube)
        #expect(bodies.count == 3)
        #expect(bodies.last?["videoId"] as? String == Self.afterVideoId)
        #expect(bodies.last?["playlistId"] as? String == "RDAMVM" + Self.afterVideoId)
        #expect(bodies.last?["params"] == nil)
    }

    @Test("An automix with no songs but a continuation is kept: the continuation may still lead to songs")
    func emptyAutomixPageWithContinuationIsKept() async throws {
        let youtube = try automixYouTube { $0.nextBodies[Self.automixId] = Self.panelJSON(items: [], continuation: "AMX_NEXT") }
        let page = try await autoplay(makeClient(youtube))

        #expect(page.tracks.isEmpty)
        #expect(page.continuation == "AMX_NEXT")
        #expect(youtube.requests(path: Self.nextPath).count == 2)
    }

    // MARK: - Falling back to the radio

    @Test("A playlist with no preview falls back to the radio of the song: the second call is the plain radio request")
    func noPreviewFallsBack() async throws {
        let radio = try MusicFixtures.data("next-radio-first.json")
        let youtube = try automixYouTube { $0.nextBodies[Self.playlistId] = radio }
        let page = try await autoplay(makeClient(youtube))

        #expect(page.tracks.map(\.videoId) == Self.radioVideoIds)
        #expect(page.continuation == "SCRUBBED_RADIO_CONTINUATION_2")
        let bodies = nextBodies(youtube)
        #expect(bodies.count == 2)
        #expect(bodies.last?["videoId"] as? String == Self.afterVideoId)
        #expect(bodies.last?["playlistId"] as? String == "RDAMVM" + Self.afterVideoId)
        #expect(bodies.last?["params"] == nil)
    }

    @Test("A preview with no playlist id falls back to the radio")
    func brokenPreviewFallsBack() async throws {
        let playlist = Self.panelJSON(items: [["automixPreviewVideoRenderer": ["content": [:]]]])
        let youtube = try automixYouTube { $0.nextBodies[Self.playlistId] = playlist }
        let page = try await autoplay(makeClient(youtube))
        #expect(page.tracks.map(\.videoId) == Self.radioVideoIds)
        #expect(nextBodies(youtube).last?["playlistId"] as? String == "RDAMVM" + Self.afterVideoId)
    }

    @Test("A rejected request or an unreadable answer to step one falls back to the radio")
    func stepOneEndsPagingFallsBack() async throws {
        for status in [400, 403, 404] {
            let youtube = try automixYouTube { $0.nextStatuses[Self.playlistId] = status }
            let page = try await autoplay(makeClient(youtube))
            #expect(page.tracks.map(\.videoId) == Self.radioVideoIds, "status \(status)")
            #expect(youtube.requests(path: Self.nextPath).count == 2, "status \(status)")
        }
        let garbage = try automixYouTube { $0.nextBodies[Self.playlistId] = Data("<html>blocked</html>".utf8) }
        let page = try await autoplay(makeClient(garbage))
        #expect(page.tracks.map(\.videoId) == Self.radioVideoIds)
        #expect(garbage.requests(path: Self.nextPath).count == 2)
    }

    @Test("A rejected request or an unreadable answer to step two falls back to the radio")
    func stepTwoEndsPagingFallsBack() async throws {
        for status in [400, 403, 404] {
            let youtube = try automixYouTube { $0.nextStatuses[Self.automixId] = status }
            let page = try await autoplay(makeClient(youtube))
            #expect(page.tracks.map(\.videoId) == Self.radioVideoIds, "status \(status)")
            let bodies = nextBodies(youtube)
            #expect(bodies.count == 3, "status \(status)")
            #expect(bodies.last?["playlistId"] as? String == "RDAMVM" + Self.afterVideoId, "status \(status)")
        }
        for garbage in ["<html>blocked</html>", "{}"] {
            let youtube = try automixYouTube { $0.nextBodies[Self.automixId] = Data(garbage.utf8) }
            let page = try await autoplay(makeClient(youtube))
            #expect(page.tracks.map(\.videoId) == Self.radioVideoIds, "\(garbage)")
            #expect(youtube.requests(path: Self.nextPath).count == 3, "\(garbage)")
        }
    }

    @Test("If the radio the call falls back to fails too, that failure is the one thrown")
    func fallbackFailureThrows() async throws {
        let youtube = try automixYouTube {
            $0.nextStatuses[Self.playlistId] = 404
            $0.nextStatuses["RDAMVM" + Self.afterVideoId] = 503
        }
        await #expect(throws: MusicError.http(503)) { try await autoplay(makeClient(youtube)) }
    }

    @Test("A blank playlist id has no automix to ask for: it goes straight to the radio of the song")
    func blankPlaylistId() async throws {
        let youtube = try automixYouTube()
        for blank in ["", "  \n"] {
            let page = try await makeClient(youtube).autoplay(afterVideoId: Self.afterVideoId, playlistId: blank)
            #expect(page.tracks.map(\.videoId) == Self.radioVideoIds)
        }
        let bodies = nextBodies(youtube)
        #expect(bodies.count == 2)
        for body in bodies {
            #expect(body["playlistId"] as? String == "RDAMVM" + Self.afterVideoId)
            #expect(body["videoId"] as? String == Self.afterVideoId)
        }
    }

    // MARK: - Errors that are thrown

    @Test("Server errors, timeouts and rate limits on step one throw, and the radio is not tried")
    func stepOneRetryableThrows() async throws {
        for status in [408, 429, 500, 502, 503] {
            let youtube = try automixYouTube { $0.nextStatuses[Self.playlistId] = status }
            await #expect(throws: MusicError.http(status)) { try await autoplay(makeClient(youtube)) }
            #expect(youtube.requests(path: Self.nextPath).count == 1, "status \(status)")
        }
    }

    @Test("Server errors, timeouts and rate limits on step two throw, and the radio is not tried")
    func stepTwoRetryableThrows() async throws {
        for status in [408, 429, 500, 502, 503] {
            let youtube = try automixYouTube { $0.nextStatuses[Self.automixId] = status }
            await #expect(throws: MusicError.http(status)) { try await autoplay(makeClient(youtube)) }
            #expect(youtube.requests(path: Self.nextPath).count == 2, "status \(status)")
        }
    }

    @Test("HTTP 401 on either step means the session is gone, and the radio is not tried")
    func sessionGone() async throws {
        let first = try automixYouTube { $0.nextStatuses[Self.playlistId] = 401 }
        await #expect(throws: MusicError.signedOut) { try await autoplay(makeClient(first)) }
        #expect(first.requests(path: Self.nextPath).count == 1)

        let second = try automixYouTube { $0.nextStatuses[Self.automixId] = 401 }
        await #expect(throws: MusicError.signedOut) { try await autoplay(makeClient(second)) }
        #expect(second.requests(path: Self.nextPath).count == 2)
    }

    @Test("A failure of the network itself is thrown, not mistaken for a playlist without an automix")
    func networkErrorsThrow() async throws {
        let failing = InnerTubeClient(transport: FailingTransport(), secretStore: MusicTestJar.signedInStore(), now: { MusicTestJar.now })
        await #expect(throws: URLError.self) { try await failing.autoplay(afterVideoId: Self.afterVideoId, playlistId: Self.playlistId) }
    }

    @Test("Signed out: the call fails with signedOut and touches no network")
    func signedOut() async throws {
        let youtube = try automixYouTube()
        let client = makeClient(youtube, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await autoplay(client) }
        #expect(youtube.requests.isEmpty)
    }

    // MARK: - Blanks

    @Test("A blank video id returns an empty page and makes no request")
    func blankVideoId() async throws {
        let youtube = try automixYouTube()
        let client = makeClient(youtube)
        for blank in ["", " ", "\n\t"] {
            let page = try await client.autoplay(afterVideoId: blank, playlistId: Self.playlistId)
            #expect(page.tracks.isEmpty)
            #expect(page.continuation == nil)
        }
        #expect(youtube.requests.isEmpty)
    }

    // MARK: - Builders

    /// A queue panel of `items` and nothing else: no continuation unless one is given, and with no items a valid page
    /// that lists nothing.
    private static func panelJSON(items: [[String: Any]], continuation: String? = nil) -> Data {
        var panel: [String: Any] = ["contents": items]
        if let continuation { panel["continuations"] = [["nextRadioContinuationData": ["continuation": continuation]]] }
        let root: [String: Any] = [
            "contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": ["watchNextTabbedResultsRenderer": ["tabs": [
                ["tabRenderer": ["content": ["musicQueueRenderer": ["content": ["playlistPanelRenderer": panel]]]]],
            ]]]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
}

/// A transport that cannot reach the network.
private struct FailingTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
