// DeciTests/Music/InnerTubeClientAlbumsTests.swift
// The search made with the albums filter: its params, the same guards and errors as the other searches, and the albums
// the response holds.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient albums")
struct InnerTubeClientAlbumsTests {

    private func makeClient(_ youtube: FakeYouTube, store: MemorySecretStore = MusicTestJar.signedInStore()) -> InnerTubeClient {
        let clock = MutableClock()
        return InnerTubeClient(transport: youtube, secretStore: store, now: { clock.now })
    }

    private func youtube(serving fixture: String) -> FakeYouTube {
        FakeYouTube { $0.searchBody = (try? MusicFixtures.data(fixture)) ?? Data() }
    }

    @Test("The albums filter params are the albums tab of YouTube Music search")
    func paramsConstant() {
        #expect(InnerTubeClient.albumsSearchParams == "EgWKAQIYAWoMEA4QChADEAQQCRAF")
        #expect(InnerTubeClient.albumsSearchParams != InnerTubeClient.songsSearchParams)
        #expect(InnerTubeClient.albumsSearchParams != InnerTubeClient.artistsSearchParams)
    }

    @Test("The request has the query and the albums params, with the same auth headers as the other searches")
    func requestShape() async throws {
        let youtube = youtube(serving: "search-albums.json")
        let albums = try await makeClient(youtube).searchAlbums("alpha")
        #expect(albums.map(\.browseId) == ["MPREb_albumA", "MPREb_singleB", "MPREb_epD", "MPREb_albumZ"])

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
        #expect(body["query"] as? String == "alpha")
        #expect(body["params"] as? String == InnerTubeClient.albumsSearchParams)
    }

    @Test("The query is trimmed, and a blank one returns nothing and makes no request")
    func blankAndTrimmed() async throws {
        let youtube = youtube(serving: "search-albums.json")
        let client = makeClient(youtube)
        #expect(try await client.searchAlbums("  \n ").isEmpty)
        #expect(youtube.requests.isEmpty)

        _ = try await client.searchAlbums("  alpha \n")
        let body = FakeYouTube.jsonBody(try #require(youtube.requests(path: "/youtubei/v1/search").first))
        #expect(body["query"] as? String == "alpha")
    }

    @Test("A response with no albums gives an empty list")
    func noAlbums() async throws {
        let youtube = youtube(serving: "search-songs.json")
        #expect(try await makeClient(youtube).searchAlbums("alpha").isEmpty)
    }

    @Test("Signed out: it fails with signedOut and touches no network, even for a blank query")
    func signedOut() async {
        let youtube = FakeYouTube()
        let client = makeClient(youtube, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.searchAlbums("x") }
        await #expect(throws: MusicError.signedOut) { try await client.searchAlbums("  ") }
        #expect(youtube.requests.isEmpty)
    }

    @Test("Errors map like the other searches: other statuses are http, bad bodies are parse")
    func errors() async {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        youtube.update { $0.searchStatus = 503 }
        await #expect(throws: MusicError.http(503)) { try await client.searchAlbums("a") }
        youtube.update {
            $0.searchStatus = 200
            $0.searchBody = Data("<html>".utf8)
        }
        await #expect(throws: MusicError.self) { try await client.searchAlbums("a") }
    }

    @Test("Special characters and emoji in the query reach the body intact")
    func unicodeQuery() async throws {
        let youtube = youtube(serving: "search-albums.json")
        _ = try await makeClient(youtube).searchAlbums("夜に駆ける \"quoted\" 🎵 \\ ' --; DROP")
        let body = FakeYouTube.jsonBody(try #require(youtube.requests(path: "/youtubei/v1/search").first))
        #expect(body["query"] as? String == "夜に駆ける \"quoted\" 🎵 \\ ' --; DROP")
    }
}
