// DeciTests/Music/InnerTubeClientMixTests.swift
// The mix call of the InnerTube client against the recording fake transport: one `next` for the mix's playlist and the
// song to continue it after, with no params. Request body, the page that comes back, and the answers that are thrown:
// unlike the playlist automix this never falls back to the radio, because the service decides what a refused mix means.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient mix")
struct InnerTubeClientMixTests {
    private static let nextPath = "/youtubei/v1/next"
    private static let playlistId = "RDTMAK5uy_handBuiltMix01"
    private static let afterVideoId = "hbMixSong001"
    private static let mixVideoIds = ["hbMixSong001", "hbMixSong002", "hbMixSong003", "hbMixSong004"]

    private func makeClient(
        _ youtube: FakeYouTube,
        store: MemorySecretStore = MusicTestJar.signedInStore()
    ) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: store, now: { MusicTestJar.now })
    }

    /// A fake music.youtube.com whose mix answers with the hand-built first page. Any other playlist id gets the radio capture.
    private func mixYouTube(_ configure: (inout FakeYouTube.Config) -> Void = { _ in }) throws -> FakeYouTube {
        let mix = try MusicFixtures.data("next-mix-first.json")
        return FakeYouTube {
            $0.nextBodies = [Self.playlistId: mix]
            configure(&$0)
        }
    }

    private func nextBodies(_ youtube: FakeYouTube) -> [[String: Any]] {
        youtube.requests(path: Self.nextPath).map(FakeYouTube.jsonBody)
    }

    private func mix(_ client: InnerTubeClient) async throws -> MusicQueuePage {
        try await client.mix(playlistId: Self.playlistId, afterVideoId: Self.afterVideoId)
    }

    // MARK: - The request

    @Test("The mix is one next call, and its first page comes back with the continuation")
    func onePage() async throws {
        let youtube = try mixYouTube()
        let page = try await mix(makeClient(youtube))
        #expect(page.tracks.map(\.videoId) == Self.mixVideoIds)
        #expect(page.continuation == "HANDBUILT_MIX_CONTINUATION_2")
        #expect(youtube.requests(path: Self.nextPath).count == 1)
    }

    @Test("It posts the song and the mix's playlist with the radio's base fields and no params")
    func requestBody() async throws {
        let youtube = try mixYouTube()
        _ = try await mix(makeClient(youtube))

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

    @Test("It goes to next with the auth headers")
    func requestShape() async throws {
        let youtube = try mixYouTube()
        _ = try await mix(makeClient(youtube))

        let request = try #require(youtube.requests(path: Self.nextPath).first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/next?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["X-YouTube-Client-Name"] == "67")
        #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
    }

    @Test("The ids are trimmed before they are asked for")
    func idsAreTrimmed() async throws {
        let youtube = try mixYouTube()
        let page = try await makeClient(youtube).mix(playlistId: " \(Self.playlistId)\n", afterVideoId: "  \(Self.afterVideoId) ")
        #expect(page.tracks.map(\.videoId) == Self.mixVideoIds)
        let body = try #require(nextBodies(youtube).first)
        #expect(body["videoId"] as? String == Self.afterVideoId)
        #expect(body["playlistId"] as? String == Self.playlistId)
    }

    @Test("The call shares the home page bootstrap with the other calls")
    func sharesBootstrap() async throws {
        let youtube = try mixYouTube()
        let client = makeClient(youtube)
        _ = try await client.search("a")
        _ = try await mix(client)
        #expect(youtube.requests(path: "/").count == 1)
    }

    @Test("A mix page with no songs is returned as it is, not replaced by the radio")
    func emptyMixPage() async throws {
        let youtube = try mixYouTube { $0.nextBodies[Self.playlistId] = Self.panelJSON(items: []) }
        let page = try await mix(makeClient(youtube))
        #expect(page.tracks.isEmpty)
        #expect(page.continuation == nil)
        #expect(youtube.requests(path: Self.nextPath).count == 1)
    }

    @Test("A page with no continuation is the end of the mix")
    func lastPage() async throws {
        let youtube = try mixYouTube {
            $0.nextBodies[Self.playlistId] = Self.panelJSON(items: [Self.row("hbMixSong009", playlistId: Self.playlistId)])
        }
        let page = try await mix(makeClient(youtube))
        #expect(page.tracks.map(\.videoId) == ["hbMixSong009"])
        #expect(page.continuation == nil)
    }

    // MARK: - Errors that are thrown

    @Test("A rejected request or an unreadable answer is thrown, and the radio is not tried")
    func refusedThrows() async throws {
        for status in [400, 403, 404] {
            let youtube = try mixYouTube { $0.nextStatuses[Self.playlistId] = status }
            await #expect(throws: MusicError.http(status)) { try await mix(makeClient(youtube)) }
            #expect(youtube.requests(path: Self.nextPath).count == 1, "status \(status)")
        }
        for garbage in ["<html>blocked</html>", "{}"] {
            let youtube = try mixYouTube { $0.nextBodies[Self.playlistId] = Data(garbage.utf8) }
            do {
                _ = try await mix(makeClient(youtube))
                Issue.record("\(garbage) should not parse")
            } catch {
                #expect(MusicError.endsPaging(error), "\(garbage)")
            }
            #expect(youtube.requests(path: Self.nextPath).count == 1, "\(garbage)")
        }
    }

    @Test("Server errors, timeouts and rate limits are thrown as they are, so the service can retry them")
    func retryableThrows() async throws {
        for status in [408, 429, 500, 502, 503] {
            let youtube = try mixYouTube { $0.nextStatuses[Self.playlistId] = status }
            await #expect(throws: MusicError.http(status)) { try await mix(makeClient(youtube)) }
            #expect(youtube.requests(path: Self.nextPath).count == 1, "status \(status)")
        }
    }

    @Test("HTTP 401 means the session is gone")
    func sessionGone() async throws {
        let youtube = try mixYouTube { $0.nextStatuses[Self.playlistId] = 401 }
        await #expect(throws: MusicError.signedOut) { try await mix(makeClient(youtube)) }
        #expect(youtube.requests(path: Self.nextPath).count == 1)
    }

    @Test("A failure of the network itself is thrown")
    func networkErrorsThrow() async throws {
        let failing = InnerTubeClient(transport: FailingTransport(), secretStore: MusicTestJar.signedInStore(), now: { MusicTestJar.now })
        await #expect(throws: URLError.self) { try await failing.mix(playlistId: Self.playlistId, afterVideoId: Self.afterVideoId) }
    }

    @Test("Signed out: the call fails with signedOut and touches no network")
    func signedOut() async throws {
        let youtube = try mixYouTube()
        let client = makeClient(youtube, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await mix(client) }
        #expect(youtube.requests.isEmpty)
    }

    // MARK: - Blanks

    @Test("A blank video id or playlist id returns an empty page and makes no request")
    func blankIds() async throws {
        let youtube = try mixYouTube()
        let client = makeClient(youtube)
        for blank in ["", " ", "\n\t"] {
            let noSong = try await client.mix(playlistId: Self.playlistId, afterVideoId: blank)
            #expect(noSong.tracks.isEmpty)
            #expect(noSong.continuation == nil)
            let noPlaylist = try await client.mix(playlistId: blank, afterVideoId: Self.afterVideoId)
            #expect(noPlaylist.tracks.isEmpty)
            #expect(noPlaylist.continuation == nil)
        }
        #expect(youtube.requests.isEmpty)
    }

    // MARK: - Builders

    /// One row of a queue panel: a song and its playlist.
    private static func row(_ videoId: String, playlistId: String) -> [String: Any] {
        [
            "playlistPanelVideoRenderer": [
                "videoId": videoId,
                "title": ["runs": [["text": "Song \(videoId)"]]],
                "longBylineText": ["runs": [["text": "Artist"]]],
                "lengthText": ["runs": [["text": "3:20"]]],
                "navigationEndpoint": ["watchEndpoint": ["videoId": videoId, "playlistId": playlistId]],
            ] as [String: Any],
        ]
    }

    /// A queue panel of `items` and nothing else: no continuation, and with no items a valid page that lists nothing.
    private static func panelJSON(items: [[String: Any]]) -> Data {
        let panel: [String: Any] = ["contents": items]
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
