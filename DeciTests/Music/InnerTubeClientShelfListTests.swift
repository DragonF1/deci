// DeciTests/Music/InnerTubeClientShelfListTests.swift
// The full list behind a shelf's "Show all" when it is a channel id with params (an artist's or creator's playlists):
// the request carries the params and the page's visitor id, the grid parses, and continuations are followed.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient shelf lists")
struct InnerTubeClientShelfListTests {
    private static let channel = "UCPC0L1d253x-KuMNwa05TpA"
    private static let params = "6gPgAUdxVUJXcFlCQ3BNQkNpUjVkRjl3WVdkbFgzTnVZWEJ6YUc5MFgyMTFjMmxqWDNCaFoyVmZjbVZuYVc5dVlXd1NI"

    private func makeClient(_ youtube: FakeYouTube) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: MusicTestJar.signedInStore(), now: { MusicTestJar.now })
    }

    private func gridWithContinuation(token: String) throws -> Data {
        var root = try #require(try JSONSerialization.jsonObject(with: MusicFixtures.data("browse-artist-playlists-grid.json")) as? [String: Any])
        func inject(_ value: Any) -> Any {
            if var dict = value as? [String: Any] {
                if var grid = dict["gridRenderer"] as? [String: Any], var items = grid["items"] as? [Any] {
                    items.append(["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": token]]]])
                    grid["items"] = items
                    dict["gridRenderer"] = grid
                    return dict
                }
                for (key, child) in dict { dict[key] = inject(child) }
                return dict
            }
            if let list = value as? [Any] { return list.map(inject) }
            return value
        }
        root = try #require(inject(root) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test("A channel's playlists list sends the channel id with its params and the visitor id, and returns every playlist")
    func playlistsRequestAndResult() async throws {
        let fake = FakeYouTube { $0.browseBodies[Self.channel] = (try? MusicFixtures.data("browse-artist-playlists-grid.json")) ?? Data() }
        let playlists = try await makeClient(fake).discography(browseId: Self.channel, params: Self.params)
        #expect(playlists.count == 3)
        #expect(playlists.allSatisfy { $0.kind == .playlist })

        let request = try #require(fake.requests(path: "/youtubei/v1/browse").first)
        let body = FakeYouTube.jsonBody(request)
        #expect(body["browseId"] as? String == Self.channel)
        #expect(body["params"] as? String == Self.params)
        // Without the visitor id YouTube answered this call with an empty tab.
        #expect(request.headers["X-Goog-Visitor-Id"] == "SCRUBBED_VISITOR_DATA")
        let context = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(context?["visitorData"] as? String == "SCRUBBED_VISITOR_DATA")
    }

    @Test("A list with a continuation token follows it and adds the next playlists")
    func playlistsFollowContinuation() async throws {
        let fake = FakeYouTube {
            $0.browseBodies[Self.channel] = (try? self.gridWithContinuation(token: "PLAYLISTS_NEXT")) ?? Data()
            $0.browseContinuationBody = (try? MusicFixtures.data("browse-library-continuation-new.json")) ?? Data()
        }
        let items = try await makeClient(fake).discography(browseId: Self.channel, params: Self.params)
        #expect(items.count > 3)
        #expect(Array(items.prefix(3)).allSatisfy { $0.browseId.hasPrefix("VLPL") })
        let requests = fake.requests(path: "/youtubei/v1/browse")
        #expect(requests.count >= 2)
        #expect(FakeYouTube.jsonBody(requests[1])["continuation"] as? String == "PLAYLISTS_NEXT")
    }

    @Test("A channel list that comes back empty is an empty list, not an error")
    func emptyTab() async throws {
        let empty = Data(#"{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{}}]}}}"#.utf8)
        let fake = FakeYouTube { $0.browseBodies[Self.channel] = empty }
        let items = try await makeClient(fake).discography(browseId: Self.channel, params: Self.params)
        #expect(items.isEmpty)
    }

    /// Every continuation hands back one new album and the token of the next page, for as long as asked.
    nonisolated private static func endlessChain(_ token: String) -> Data {
        let number = Int(token.dropFirst()) ?? 0
        let text = String(decoding: (try? MusicFixtures.data("browse-library-continuation-new.json")) ?? Data(), as: UTF8.self)
            .replacingOccurrences(of: "FIXTURE_LIB_ALBUMS_NEXT2", with: "T\(number + 1)")
            .replacingOccurrences(of: "MPREbFixtureHomework0000", with: "MPREbPage\(number)")
        return Data(text.utf8)
    }

    @Test("A full list rethrows a continuation that fails, so a partial list never passes for the whole one")
    func listRethrowsContinuationError() async throws {
        let fake = FakeYouTube {
            $0.browseBodies[Self.channel] = (try? self.gridWithContinuation(token: "T1")) ?? Data()
            $0.browseContinuationStatus = 503
        }
        await #expect(throws: MusicError.http(503)) {
            try await makeClient(fake).shelfList(browseId: Self.channel, params: Self.params)
        }
    }

    @Test("A full list rethrows a continuation that is cancelled")
    func listRethrowsCancellation() async throws {
        let fake = FakeYouTube {
            $0.browseBodies[Self.channel] = (try? self.gridWithContinuation(token: "T1")) ?? Data()
            $0.browseContinuationFactory = { Self.endlessChain($0) }
        }
        let client = makeClient(fake)
        let task = Task { try await client.shelfList(browseId: Self.channel, params: Self.params) }
        task.cancel()
        let outcome = await task.result
        switch outcome {
        case .success: Issue.record("a cancelled list load returned a list")
        case .failure(let error): #expect(error is CancellationError)
        }
    }

    @Test("The release-year path keeps what it has when a continuation fails, as before")
    func discographyStaysLenient() async throws {
        let fake = FakeYouTube {
            $0.browseBodies[Self.channel] = (try? self.gridWithContinuation(token: "T1")) ?? Data()
            $0.browseContinuationStatus = 503
        }
        let items = try await makeClient(fake).discography(browseId: Self.channel, params: Self.params)
        #expect(items.count == 3)
    }

    @Test("A full list reads up to twenty pages, where the release-year path stops at five")
    func listPageCap() async throws {
        func fake() -> FakeYouTube {
            FakeYouTube {
                $0.browseBodies[Self.channel] = (try? self.gridWithContinuation(token: "T1")) ?? Data()
                $0.browseContinuationFactory = { Self.endlessChain($0) }
            }
        }
        let list = fake()
        let items = try await makeClient(list).shelfList(browseId: Self.channel, params: Self.params)
        #expect(list.requests(path: "/youtubei/v1/browse").count == 20)
        #expect(items.count == 3 + 19)

        let years = fake()
        _ = try await makeClient(years).discography(browseId: Self.channel, params: Self.params)
        #expect(years.requests(path: "/youtubei/v1/browse").count == 5)
    }
}
