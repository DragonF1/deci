// DeciTests/Music/InnerTubeClientRelatedTests.swift
// The related songs call of the InnerTube client against the recording fake transport: a `next` call for the Related
// tab's browse id, then a `browse` of that id. Request bodies, auth headers, the empty answers, and how each failure
// maps.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient related songs")
struct InnerTubeClientRelatedTests {
    private static let nextPath = "/youtubei/v1/next"
    private static let browsePath = "/youtubei/v1/browse"

    private func makeClient(
        _ youtube: FakeYouTube,
        store: MemorySecretStore = MusicTestJar.signedInStore()
    ) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: store, now: { MusicTestJar.now })
    }

    /// A fake music.youtube.com that answers the real watch-next tabs and the real Related browse answer.
    private func relatedYouTube(_ configure: (inout FakeYouTube.Config) -> Void = { _ in }) -> FakeYouTube {
        FakeYouTube {
            $0.nextBody = YTRelatedSamples.next
            $0.browseBodies[YTRelatedSamples.relatedBrowseId] = YTRelatedSamples.browse
            configure(&$0)
        }
    }

    private func onlyRequest(_ youtube: FakeYouTube, _ path: String) throws -> HTTPRequest {
        let requests = youtube.requests(path: path)
        #expect(requests.count == 1)
        return try #require(requests.first)
    }

    // MARK: - The two calls

    @Test("Related songs ask next for the song, then browse the Related tab's id, and return the first shelf's songs")
    func relatedSongs() async throws {
        let fake = relatedYouTube()
        let tracks = try await makeClient(fake).related(videoId: YTRelatedSamples.seedVideoId)
        #expect(tracks.map(\.videoId) == YTRelatedSamples.songShelfVideoIds)
        // The page bootstrap, if it comes at all, is not one of the two calls.
        #expect(fake.requests.map(\.url.path).filter { $0 != "/" } == [Self.nextPath, Self.browsePath])
    }

    @Test("The next call posts the video id with isAudioOnly, the WEB_REMIX context and the auth headers")
    func nextRequestShape() async throws {
        let fake = relatedYouTube()
        _ = try await makeClient(fake).related(videoId: YTRelatedSamples.seedVideoId)

        let request = try onlyRequest(fake, Self.nextPath)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/next?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
        let body = FakeYouTube.jsonBody(request)
        #expect(body["videoId"] as? String == YTRelatedSamples.seedVideoId)
        #expect(body["isAudioOnly"] as? Bool == true)
        // No radio playlist: the answer is the tabs of one song.
        #expect(body["playlistId"] == nil)
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("The browse call posts the Related tab's id with the auth headers")
    func browseRequestShape() async throws {
        let fake = relatedYouTube()
        _ = try await makeClient(fake).related(videoId: YTRelatedSamples.seedVideoId)

        let request = try onlyRequest(fake, Self.browsePath)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        let body = FakeYouTube.jsonBody(request)
        #expect(body["browseId"] as? String == YTRelatedSamples.relatedBrowseId)
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("The video id is trimmed before it is asked for")
    func idIsTrimmed() async throws {
        let fake = relatedYouTube()
        _ = try await makeClient(fake).related(videoId: "  \(YTRelatedSamples.seedVideoId)\n")
        let body = FakeYouTube.jsonBody(try onlyRequest(fake, Self.nextPath))
        #expect(body["videoId"] as? String == YTRelatedSamples.seedVideoId)
    }

    @Test("A blank video id asks for nothing and returns nothing")
    func blankId() async throws {
        let fake = relatedYouTube()
        let client = makeClient(fake)
        #expect(try await client.related(videoId: "").isEmpty)
        #expect(try await client.related(videoId: "  \n").isEmpty)
        #expect(fake.requests.isEmpty)
    }

    // MARK: - Nothing related

    @Test("A song with no Related tab returns nothing and browses nothing")
    func noRelatedTab() async throws {
        let fake = relatedYouTube { $0.nextBody = YTRelatedSamples.nextWithoutRelatedTab }
        #expect(try await makeClient(fake).related(videoId: YTRelatedSamples.seedVideoId).isEmpty)
        #expect(fake.requests(path: Self.browsePath).isEmpty)
    }

    @Test("A Related tab YouTube greys out returns nothing and browses nothing")
    func unselectableRelatedTab() async throws {
        let fake = relatedYouTube { $0.nextBody = YTRelatedSamples.nextWithUnselectableRelatedTab }
        #expect(try await makeClient(fake).related(videoId: YTRelatedSamples.seedVideoId).isEmpty)
        #expect(fake.requests(path: Self.browsePath).isEmpty)
    }

    @Test("A next answer with no tabs at all returns nothing, browses nothing and does not throw, so Retry is never offered")
    func nextWithoutTabs() async throws {
        let fake = relatedYouTube { $0.nextBody = Data("{}".utf8) }
        #expect(try await makeClient(fake).related(videoId: YTRelatedSamples.seedVideoId).isEmpty)
        #expect(fake.requests(path: Self.browsePath).isEmpty)
    }

    @Test("A browse answer with no song shelf returns nothing")
    func noSongShelf() async throws {
        let fake = relatedYouTube { $0.browseBodies[YTRelatedSamples.relatedBrowseId] = YTRelatedSamples.browse(shelves: [1]) }
        #expect(try await makeClient(fake).related(videoId: YTRelatedSamples.seedVideoId).isEmpty)
    }

    // MARK: - Failures

    @Test("Signed out: the call fails with signedOut and touches no network")
    func signedOut() async {
        let fake = relatedYouTube()
        let client = makeClient(fake, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.related(videoId: YTRelatedSamples.seedVideoId) }
        #expect(fake.requests.isEmpty)
    }

    @Test("HTTP 401 on either call means the session is gone, other statuses carry their code")
    func httpErrors() async {
        let nextExpired = makeClient(relatedYouTube { $0.nextStatus = 401 })
        await #expect(throws: MusicError.signedOut) { try await nextExpired.related(videoId: YTRelatedSamples.seedVideoId) }
        let browseExpired = makeClient(relatedYouTube { $0.browseStatus = 401 })
        await #expect(throws: MusicError.signedOut) { try await browseExpired.related(videoId: YTRelatedSamples.seedVideoId) }

        let nextBroken = makeClient(relatedYouTube { $0.nextStatus = 500 })
        await #expect(throws: MusicError.http(500)) { try await nextBroken.related(videoId: YTRelatedSamples.seedVideoId) }
        let browseBroken = makeClient(relatedYouTube { $0.browseStatus = 503 })
        await #expect(throws: MusicError.http(503)) { try await browseBroken.related(videoId: YTRelatedSamples.seedVideoId) }
    }

    @Test("A next answer or a browse answer that is not JSON is a parse error")
    func notJSON() async {
        let badNext = makeClient(relatedYouTube { $0.nextBody = Data("<html>".utf8) })
        await #expect(throws: MusicError.self) { try await badNext.related(videoId: YTRelatedSamples.seedVideoId) }
        let badBrowse = makeClient(relatedYouTube { $0.browseBodies[YTRelatedSamples.relatedBrowseId] = Data("<html>".utf8) })
        await #expect(throws: MusicError.self) { try await badBrowse.related(videoId: YTRelatedSamples.seedVideoId) }
    }

    @Test("A browse answer with no section list is a parse error")
    func browseWithoutShelves() async {
        let fake = relatedYouTube { $0.browseBodies = [:] }
        await #expect(throws: MusicError.self) { try await makeClient(fake).related(videoId: YTRelatedSamples.seedVideoId) }
    }
}
