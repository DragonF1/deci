// DeciTests/Music/InnerTubeClientBrowseTests.swift
// The browse calls of the InnerTube client against the recording fake transport: which browse id
// each call sends, how both continuation styles go out, the auth headers and the error mapping.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient browse")
struct InnerTubeClientBrowseTests {
    private static let path = "/youtubei/v1/browse"

    private func makeClient(
        _ youtube: FakeYouTube,
        store: MemorySecretStore = MusicTestJar.signedInStore()
    ) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: store, now: { MusicTestJar.now })
    }

    private func youtube(_ configure: (inout FakeYouTube.Config) -> Void = { _ in }) -> FakeYouTube {
        FakeYouTube { config in
            config.browseBodies = [
                "FEmusic_home": (try? MusicFixtures.data("browse-home.json")) ?? Data(),
                "VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i": (try? MusicFixtures.data("browse-playlist.json")) ?? Data(),
                "FEmusic_liked_playlists": (try? MusicFixtures.data("browse-library-playlists.json")) ?? Data(),
                "FEmusic_liked_albums": (try? MusicFixtures.data("browse-library-albums.json")) ?? Data(),
                "FEmusic_library_corpus_track_artists": (try? MusicFixtures.data("browse-library-artists.json")) ?? Data(),
            ]
            configure(&config)
        }
    }

    private func browseRequests(_ youtube: FakeYouTube) -> [HTTPRequest] {
        youtube.requests(path: Self.path)
    }

    private func onlyRequest(_ youtube: FakeYouTube) throws -> HTTPRequest {
        let requests = browseRequests(youtube)
        #expect(requests.count == 1)
        return try #require(requests.first)
    }

    private func queryItems(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - First pages

    @Test("home posts the FEmusic_home browse id with the WEB_REMIX context and the auth headers")
    func homeRequestShape() async throws {
        let fake = youtube()
        let page = try await makeClient(fake).home()
        #expect(page.shelves.map(\.title) == ["Quick picks", "Trending community playlists"])

        let request = try onlyRequest(fake)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["X-Goog-AuthUser"] == "0")
        #expect(request.headers["X-YouTube-Client-Name"] == "67")
        #expect(request.headers["Origin"] == "https://music.youtube.com")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
        #expect(request.headers["Cookie"]?.contains("sid-google-only") == false)

        let body = FakeYouTube.jsonBody(request)
        #expect(body["browseId"] as? String == "FEmusic_home")
        #expect(body["continuation"] == nil)
        let context = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(context?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("Each library section sends its own browse id")
    func libraryBrowseIds() async throws {
        let fake = youtube()
        let client = makeClient(fake)
        _ = try await client.library(.playlists)
        _ = try await client.library(.albums)
        _ = try await client.library(.artists)
        let ids = browseRequests(fake).map { FakeYouTube.jsonBody($0)["browseId"] as? String }
        #expect(ids == ["FEmusic_liked_playlists", "FEmusic_liked_albums", "FEmusic_library_corpus_track_artists"])
    }

    @Test("library parses the grid and the artist rows it gets back")
    func libraryParses() async throws {
        let client = makeClient(youtube())
        let playlists = try await client.library(.playlists)
        #expect(playlists.items.count == 3)
        #expect(playlists.continuation == "q:FIXTURE_LIB_PLAYLISTS_NEXT%3D")
        let albums = try await client.library(.albums)
        #expect(albums.items.count == 2)
        let artists = try await client.library(.artists)
        #expect(artists.items.map(\.kind) == [.artist, .artist])
    }

    @Test("page sends the browse id it was given, trimmed, for playlists, albums and artists")
    func pageBrowseId() async throws {
        let fake = youtube()
        let client = makeClient(fake)
        let page = try await client.page(browseId: "  VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i \n")
        #expect(page.title == "Top 100 Songs Global")
        #expect(page.tracks.count == 3)
        _ = try? await client.page(browseId: "MPREbSomething")
        _ = try? await client.page(browseId: "UCsomeone")
        let ids = browseRequests(fake).map { FakeYouTube.jsonBody($0)["browseId"] as? String }
        #expect(ids == ["VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i", "MPREbSomething", "UCsomeone"])
    }

    @Test("page with a blank browse id fails to parse and sends nothing")
    func pageBlankBrowseId() async {
        let fake = youtube()
        let client = makeClient(fake)
        await #expect(throws: MusicError.self) { try await client.page(browseId: "  ") }
        await #expect(throws: MusicError.self) { try await client.page(browseId: "") }
        #expect(fake.requests.isEmpty)
    }

    // MARK: - Continuations

    @Test("An old-style token goes in the query as ctoken and continuation, next to the browse id in the body")
    func oldStyleContinuation() async throws {
        let fake = youtube { $0.browseContinuationBody = (try? MusicFixtures.data("browse-sectionlist-continuation.json")) ?? Data() }
        let page = try await makeClient(fake).moreHome(continuation: "q:abc123%3D")
        #expect(page.shelves.map(\.title) == ["Related playlists"])

        let request = try onlyRequest(fake)
        let query = queryItems(request)
        #expect(query["ctoken"] == "abc123=")
        #expect(query["continuation"] == "abc123=")
        #expect(query["prettyPrint"] == "false")
        // Already-encoded characters are sent as they are, not encoded a second time.
        #expect(request.url.absoluteString.hasSuffix("&ctoken=abc123%3D&continuation=abc123%3D"))
        let body = FakeYouTube.jsonBody(request)
        #expect(body["browseId"] as? String == "FEmusic_home")
        #expect(body["continuation"] == nil)
    }

    @Test("A new-style token goes alone in the body, with no browse id and no query parameters")
    func newStyleContinuation() async throws {
        let fake = youtube { $0.browseContinuationBody = (try? MusicFixtures.data("browse-home-continuation-new.json")) ?? Data() }
        let page = try await makeClient(fake).moreHome(continuation: "NEWTOKEN")
        #expect(page.shelves.map(\.title) == ["Albums for you"])

        let request = try onlyRequest(fake)
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        let body = FakeYouTube.jsonBody(request)
        #expect(body["continuation"] as? String == "NEWTOKEN")
        #expect(body["browseId"] == nil)
    }

    @Test("Characters a URL cannot hold are escaped once in an old-style token")
    func oldStyleTokenEscaping() async throws {
        let fake = youtube { $0.browseContinuationBody = (try? MusicFixtures.data("browse-library-continuation-shelf.json")) ?? Data() }
        _ = try await makeClient(fake).moreLibrary(.artists, continuation: "q:a+b/c d&e=f%3D")
        let request = try onlyRequest(fake)
        #expect(request.url.absoluteString.hasSuffix("&ctoken=a%2Bb%2Fc%20d%26e%3Df%3D&continuation=a%2Bb%2Fc%20d%26e%3Df%3D"))
        #expect(queryItems(request)["ctoken"] == "a+b/c d&e=f=")
    }

    @Test("moreLibrary sends the section's browse id with an old-style token and parses the page")
    func moreLibraryOldStyle() async throws {
        let fake = youtube { $0.browseContinuationBody = (try? MusicFixtures.data("browse-library-continuation-grid.json")) ?? Data() }
        let list = try await makeClient(fake).moreLibrary(.playlists, continuation: "q:tok%3D")
        #expect(list.items.count == 2)
        #expect(list.continuation == "q:FIXTURE_LIB_PLAYLISTS_NEXT2%3D")
        #expect(FakeYouTube.jsonBody(try onlyRequest(fake))["browseId"] as? String == "FEmusic_liked_playlists")
    }

    @Test("moreLibrary with a new-style token parses the appended items")
    func moreLibraryNewStyle() async throws {
        let fake = youtube { $0.browseContinuationBody = (try? MusicFixtures.data("browse-library-continuation-new.json")) ?? Data() }
        let list = try await makeClient(fake).moreLibrary(.albums, continuation: "FIXTURE_LIB_ALBUMS_NEXT")
        #expect(list.items.map(\.browseId) == ["MPREbFixtureHomework0000"])
        #expect(list.continuation == "FIXTURE_LIB_ALBUMS_NEXT2")
        #expect(FakeYouTube.jsonBody(try onlyRequest(fake))["continuation"] as? String == "FIXTURE_LIB_ALBUMS_NEXT")
    }

    @Test("moreTracks sends the page's browse id with an old-style token and a bare token alone")
    func moreTracksBothStyles() async throws {
        let fake = youtube { $0.browseContinuationBody = (try? MusicFixtures.data("browse-playlist-continuation.json")) ?? Data() }
        let client = makeClient(fake)
        let old = try await client.moreTracks(browseId: "VLPLlong", continuation: "q:oldtoken%3D")
        let new = try await client.moreTracks(browseId: "VLPLlong", continuation: "newtoken")
        #expect(old.tracks.count == 4)
        #expect(new.tracks.count == 4)

        let requests = browseRequests(fake)
        #expect(requests.count == 2)
        let first = FakeYouTube.jsonBody(requests[0])
        #expect(first["browseId"] as? String == "VLPLlong")
        #expect(queryItems(requests[0])["ctoken"] == "oldtoken=")
        let second = FakeYouTube.jsonBody(requests[1])
        #expect(second["continuation"] as? String == "newtoken")
        #expect(second["browseId"] == nil)
        #expect(queryItems(requests[1])["ctoken"] == nil)
    }

    @Test("A blank continuation makes no request and returns an empty result")
    func blankContinuation() async throws {
        let fake = youtube()
        let client = makeClient(fake)
        #expect(try await client.moreHome(continuation: " ") == MusicHomePage(shelves: [], continuation: nil))
        #expect(try await client.moreLibrary(.albums, continuation: "") == MusicCollectionList(items: [], continuation: nil))
        #expect(try await client.moreLibrary(.albums, continuation: "q:") == MusicCollectionList(items: [], continuation: nil))
        #expect(try await client.moreTracks(browseId: "VLx", continuation: "\n") == MusicQueuePage(tracks: [], continuation: nil))
        #expect(browseRequests(fake).isEmpty)
    }

    // MARK: - Signed out and errors

    @Test("Signed out: every browse call fails with signedOut and touches no network")
    func signedOut() async {
        let fake = youtube()
        let client = makeClient(fake, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.home() }
        await #expect(throws: MusicError.signedOut) { try await client.moreHome(continuation: "q:a") }
        await #expect(throws: MusicError.signedOut) { try await client.library(.playlists) }
        await #expect(throws: MusicError.signedOut) { try await client.moreLibrary(.playlists, continuation: "a") }
        await #expect(throws: MusicError.signedOut) { try await client.page(browseId: "VLx") }
        await #expect(throws: MusicError.signedOut) { try await client.moreTracks(browseId: "VLx", continuation: "a") }
        #expect(fake.requests.isEmpty)
    }

    @Test("HTTP 401 means the session is gone, other statuses carry their code")
    func httpStatuses() async {
        let expired = makeClient(youtube { $0.browseStatus = 401 })
        await #expect(throws: MusicError.signedOut) { try await expired.home() }
        await #expect(throws: MusicError.signedOut) { try await expired.library(.albums) }
        await #expect(throws: MusicError.signedOut) { try await expired.page(browseId: "VLx") }
        await #expect(throws: MusicError.signedOut) { try await expired.moreTracks(browseId: "VLx", continuation: "a") }

        for status in [400, 403, 429, 500, 503] {
            let client = makeClient(youtube { $0.browseStatus = status })
            await #expect(throws: MusicError.http(status)) { try await client.home() }
        }
    }

    @Test("A response that is not what the parser expects is a parse error, not an empty page")
    func unexpectedResponse() async {
        let client = makeClient(youtube {
            $0.browseBodies = [:]
            $0.browseDefaultBody = Data("<html>captcha</html>".utf8)
        })
        await #expect(throws: MusicError.self) { try await client.home() }
        await #expect(throws: MusicError.self) { try await client.page(browseId: "VLunknown") }
    }

    @Test("A library response with no list is an empty list")
    func emptyLibrary() async throws {
        let client = makeClient(youtube {
            $0.browseBodies = [:]
            $0.browseDefaultBody = Data(#"{"contents":{}}"#.utf8)
        })
        #expect(try await client.library(.artists) == MusicCollectionList(items: [], continuation: nil))
    }

    @Test("Browse calls keep the cookie values out of the request URL")
    func urlHoldsNoCookies() async throws {
        let fake = youtube { $0.browseContinuationBody = (try? MusicFixtures.data("browse-sectionlist-continuation.json")) ?? Data() }
        _ = try await makeClient(fake).moreHome(continuation: "q:abc")
        let url = try onlyRequest(fake).url.absoluteString
        for cookie in MusicTestJar.signedInCookies() {
            #expect(!url.contains(cookie.value))
        }
    }
}
