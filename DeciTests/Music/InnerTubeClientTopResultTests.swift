// DeciTests/Music/InnerTubeClientTopResultTests.swift
// The unfiltered search that finds the Top result: no filter in the body, the same guards and errors as the other
// searches, and a track only when the card names one.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient top result")
struct InnerTubeClientTopResultTests {

    private func makeClient(_ youtube: FakeYouTube, store: MemorySecretStore = MusicTestJar.signedInStore()) -> InnerTubeClient {
        let clock = MutableClock()
        return InnerTubeClient(transport: youtube, secretStore: store, now: { clock.now })
    }

    private func youtube(serving fixture: String) -> FakeYouTube {
        FakeYouTube { $0.searchBody = (try? MusicFixtures.data(fixture)) ?? Data() }
    }

    @Test("The request has the query and no params, with the same auth headers as the filtered searches")
    func requestShape() async throws {
        let youtube = youtube(serving: "search-unfiltered-top-video.json")
        let track = try await makeClient(youtube).searchTopResult("crab rave bass boosted")
        #expect(track?.videoId == "topVideo001")

        let request = try #require(youtube.requests(path: "/youtubei/v1/search").first)
        #expect(youtube.requests.filter { $0.url.path == "/youtubei/v1/search" }.count == 1)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["X-Goog-AuthUser"] == "0")
        #expect(request.headers["Origin"] == "https://music.youtube.com")
        let body = FakeYouTube.jsonBody(request)
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "WEB_REMIX")
        #expect(body["query"] as? String == "crab rave bass boosted")
        #expect(body["params"] == nil)
    }

    @Test("The query is trimmed, and a blank one returns nothing and makes no request")
    func blankAndTrimmed() async throws {
        let youtube = youtube(serving: "search-unfiltered-top-video.json")
        let client = makeClient(youtube)
        #expect(try await client.searchTopResult("  \n ") == nil)
        #expect(youtube.requests.isEmpty)

        _ = try await client.searchTopResult("  crab \n")
        let body = FakeYouTube.jsonBody(try #require(youtube.requests(path: "/youtubei/v1/search").first))
        #expect(body["query"] as? String == "crab")
    }

    @Test("A top artist card returns no track")
    func artistCard() async throws {
        let youtube = youtube(serving: "search-unfiltered-top-artist.json")
        #expect(try await makeClient(youtube).searchTopResult("alpha") == nil)
    }

    @Test("Signed out: it fails with signedOut and touches no network, even for a blank query")
    func signedOut() async {
        let youtube = FakeYouTube()
        let client = makeClient(youtube, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.searchTopResult("x") }
        await #expect(throws: MusicError.signedOut) { try await client.searchTopResult("  ") }
        #expect(youtube.requests.isEmpty)
    }

    @Test("Errors map like the other searches: other statuses are http, bad bodies are parse")
    func errors() async {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        youtube.update { $0.searchStatus = 503 }
        await #expect(throws: MusicError.http(503)) { try await client.searchTopResult("a") }
        youtube.update {
            $0.searchStatus = 200
            $0.searchBody = Data("<html>".utf8)
        }
        await #expect(throws: MusicError.self) { try await client.searchTopResult("a") }
    }

    @Test("Special characters and emoji in the query reach the body intact")
    func unicodeQuery() async throws {
        let youtube = youtube(serving: "search-unfiltered-top-video.json")
        _ = try await makeClient(youtube).searchTopResult("夜に駆ける \"quoted\" 🎵 \\ ' --; DROP")
        let body = FakeYouTube.jsonBody(try #require(youtube.requests(path: "/youtubei/v1/search").first))
        #expect(body["query"] as? String == "夜に駆ける \"quoted\" 🎵 \\ ' --; DROP")
    }
}
