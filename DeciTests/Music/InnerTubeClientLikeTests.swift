// DeciTests/Music/InnerTubeClientLikeTests.swift
// The like calls of the InnerTube client against the recording fake transport: reading a song's like state from `next`,
// and rating it with like/like, like/dislike and like/removelike. Request bodies, auth headers, and how each failure maps.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient likes")
struct InnerTubeClientLikeTests {
    private static let nextPath = "/youtubei/v1/next"
    private static let likePath = "/youtubei/v1/like/like"
    private static let dislikePath = "/youtubei/v1/like/dislike"
    private static let removePath = "/youtubei/v1/like/removelike"

    private func makeClient(
        _ youtube: FakeYouTube,
        store: MemorySecretStore = MusicTestJar.signedInStore()
    ) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: store, now: { MusicTestJar.now })
    }

    private func onlyRequest(_ youtube: FakeYouTube, _ path: String) throws -> HTTPRequest {
        let requests = youtube.requests(path: path)
        #expect(requests.count == 1)
        return try #require(requests.first)
    }

    private static func nextBody(_ videoId: String, _ status: String) -> Data {
        let renderer = #"{"likeButtonRenderer":{"target":{"videoId":"\#(videoId)"},"likeStatus":"\#(status)"}}"#
        return Data(#"{"playerOverlays":{"playerOverlayRenderer":{"actions":[\#(renderer)]}}}"#.utf8)
    }

    // MARK: - Reading the state

    @Test("The like state posts the video id with isAudioOnly to next, with the WEB_REMIX context and the auth headers")
    func stateRequestShape() async throws {
        let fake = FakeYouTube { $0.nextBody = Self.nextBody("vid-1", "LIKE") }
        let status = try await makeClient(fake).likeStatus(videoId: "vid-1")
        #expect(status == .like)

        let request = try onlyRequest(fake, Self.nextPath)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/next?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
        let body = FakeYouTube.jsonBody(request)
        #expect(body["videoId"] as? String == "vid-1")
        #expect(body["isAudioOnly"] as? Bool == true)
        // No radio playlist: the answer is one song's overlay, not a queue.
        #expect(body["playlistId"] == nil)
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("Each status comes back as the matching value")
    func stateValues() async throws {
        let cases: [(String, MusicLikeStatus)] = [("LIKE", .like), ("DISLIKE", .dislike), ("INDIFFERENT", .indifferent)]
        for (raw, expected) in cases {
            let fake = FakeYouTube { $0.nextBody = Self.nextBody("vid-1", raw) }
            #expect(try await makeClient(fake).likeStatus(videoId: "vid-1") == expected, "status \(raw)")
        }
    }

    @Test("An answer with no like button for the song is unknown, not an error")
    func stateMissing() async throws {
        let fake = FakeYouTube { $0.nextBody = Self.nextBody("vid-other", "LIKE") }
        #expect(try await makeClient(fake).likeStatus(videoId: "vid-1") == nil)
    }

    @Test("A blank video id asks for nothing and knows nothing")
    func stateBlankId() async throws {
        let fake = FakeYouTube()
        let client = makeClient(fake)
        #expect(try await client.likeStatus(videoId: "") == nil)
        #expect(try await client.likeStatus(videoId: "  \n") == nil)
        #expect(fake.requests(path: Self.nextPath).isEmpty)
    }

    @Test("A like state answer that is not JSON is a parse error")
    func stateNotJSON() async {
        let fake = FakeYouTube { $0.nextBody = Data("<html>".utf8) }
        await #expect(throws: MusicError.self) { try await makeClient(fake).likeStatus(videoId: "vid-1") }
    }

    // MARK: - Rating

    @Test("Each rating posts the video id as the target to its own endpoint, with the auth headers")
    func rateRequestShapes() async throws {
        let cases: [(MusicLikeStatus, String)] = [
            (.like, Self.likePath), (.dislike, Self.dislikePath), (.indifferent, Self.removePath),
        ]
        for (status, path) in cases {
            let fake = FakeYouTube()
            try await makeClient(fake).rate(videoId: "vid-1", status: status)

            let request = try onlyRequest(fake, path)
            #expect(request.method == "POST")
            #expect(request.url.absoluteString == "https://music.youtube.com\(path)?prettyPrint=false")
            #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
            #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
            let body = FakeYouTube.jsonBody(request)
            #expect((body["target"] as? [String: Any])?["videoId"] as? String == "vid-1", "status \(status)")
            let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
            #expect(client?["clientName"] as? String == "WEB_REMIX")
            // Nothing went to the other two endpoints.
            let others = [Self.likePath, Self.dislikePath, Self.removePath].filter { $0 != path }
            #expect(others.allSatisfy { fake.requests(path: $0).isEmpty })
        }
    }

    @Test("Any 2xx answer is success, whatever the body")
    func rateSuccessBodies() async throws {
        let fake = FakeYouTube {
            $0.rateBody = Data()
            $0.rateStatus = 200
        }
        try await makeClient(fake).rate(videoId: "vid-1", status: .like)
        let created = FakeYouTube { $0.rateStatus = 204 }
        try await makeClient(created).rate(videoId: "vid-1", status: .dislike)
    }

    @Test("A blank video id is refused before any request")
    func rateBlankId() async {
        let fake = FakeYouTube()
        let client = makeClient(fake)
        await #expect(throws: MusicError.self) { try await client.rate(videoId: "", status: .like) }
        await #expect(throws: MusicError.self) { try await client.rate(videoId: " \n", status: .indifferent) }
        #expect(fake.requests.isEmpty)
    }

    // MARK: - Signed out and HTTP errors

    @Test("Signed out: both calls fail with signedOut and touch no network")
    func signedOut() async {
        let fake = FakeYouTube()
        let client = makeClient(fake, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.likeStatus(videoId: "vid-1") }
        await #expect(throws: MusicError.signedOut) { try await client.rate(videoId: "vid-1", status: .like) }
        #expect(fake.requests.isEmpty)
    }

    @Test("HTTP 401 means the session is gone, other statuses carry their code")
    func httpErrors() async {
        let expired = makeClient(FakeYouTube {
            $0.nextStatus = 401
            $0.rateStatus = 401
        })
        await #expect(throws: MusicError.signedOut) { try await expired.likeStatus(videoId: "vid-1") }
        await #expect(throws: MusicError.signedOut) { try await expired.rate(videoId: "vid-1", status: .like) }

        let broken = makeClient(FakeYouTube {
            $0.nextStatus = 500
            $0.rateStatus = 503
        })
        await #expect(throws: MusicError.http(500)) { try await broken.likeStatus(videoId: "vid-1") }
        await #expect(throws: MusicError.http(503)) { try await broken.rate(videoId: "vid-1", status: .dislike) }
        await #expect(throws: MusicError.http(503)) { try await broken.rate(videoId: "vid-1", status: .indifferent) }
    }
}
