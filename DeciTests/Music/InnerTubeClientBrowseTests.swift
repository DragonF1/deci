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
                "FEmusic_history": (try? MusicFixtures.data("browse-history.json")) ?? Data(),
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
        let ids = browseRequests(fake).map { FakeYouTube.jsonBody($0)["browseId"] as? String }
        #expect(ids == ["FEmusic_liked_playlists", "FEmusic_liked_albums"])
    }

    @Test("library parses the rows and the grid it gets back")
    func libraryParses() async throws {
        let client = makeClient(youtube())
        let playlists = try await client.library(.playlists)
        #expect(playlists.items.count == 3)
        #expect(playlists.continuation == "q:FIXTURE_LIB_PLAYLISTS_NEXT%3D")
        let albums = try await client.library(.albums)
        #expect(albums.items.count == 2)
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

    // MARK: - Discography

    private func discographyYoutube() -> FakeYouTube {
        youtube { $0.browseBodies["MPADdisc"] = (try? MusicFixtures.data("browse-library-albums.json")) ?? Data() }
    }

    @Test("home leaves params out of its body")
    func homeSendsNoParams() async throws {
        let fake = youtube()
        _ = try await makeClient(fake).home()
        #expect(FakeYouTube.jsonBody(try onlyRequest(fake))["params"] == nil)
    }

    @Test("discography sends the browse id with its params, and keeps the first page when the next one fails to parse")
    func discographyRequestShape() async throws {
        let fake = discographyYoutube()
        let albums = try await makeClient(fake).discography(browseId: "MPADdisc", params: "ggMIegYIARoCAQI%3D")
        #expect(albums.map(\.browseId) == ["MPREbFixtureRam0000", "MPREbFixtureDiscovery"])
        #expect(albums.allSatisfy { $0.kind == .album })

        let request = try #require(browseRequests(fake).first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        let body = FakeYouTube.jsonBody(request)
        #expect(body["browseId"] as? String == "MPADdisc")
        #expect(body["params"] as? String == "ggMIegYIARoCAQI%3D")
        #expect(body["continuation"] == nil)
    }

    @Test("discography with no params sends the browse id alone, and trims the id")
    func discographyWithoutParams() async throws {
        let fake = discographyYoutube()
        _ = try await makeClient(fake).discography(browseId: "  MPADdisc \n", params: nil)
        let body = FakeYouTube.jsonBody(try #require(browseRequests(fake).first))
        #expect(body["browseId"] as? String == "MPADdisc")
        #expect(body["params"] == nil)
    }

    @Test("discography follows its continuations and stops when a page hands back a token it already followed")
    func discographyFollowsContinuations() async throws {
        let fake = youtube {
            $0.browseBodies["MPADdisc"] = (try? MusicFixtures.data("browse-library-albums.json")) ?? Data()
            $0.browseContinuationBody = (try? MusicFixtures.data("browse-library-continuation-new.json")) ?? Data()
        }
        let albums = try await makeClient(fake).discography(browseId: "MPADdisc", params: "P")
        // The first page, then FIXTURE_LIB_ALBUMS_NEXT, then FIXTURE_LIB_ALBUMS_NEXT2, which answers NEXT2 again.
        #expect(albums.map(\.browseId) == ["MPREbFixtureRam0000", "MPREbFixtureDiscovery", "MPREbFixtureHomework0000", "MPREbFixtureHomework0000"])
        let requests = browseRequests(fake)
        #expect(requests.count == 3)
        #expect(requests.dropFirst().map { FakeYouTube.jsonBody($0)["continuation"] as? String } == ["FIXTURE_LIB_ALBUMS_NEXT", "FIXTURE_LIB_ALBUMS_NEXT2"])
    }

    @Test("discography with a blank browse id fails to parse and sends nothing")
    func discographyBlankBrowseId() async {
        let fake = discographyYoutube()
        let client = makeClient(fake)
        await #expect(throws: MusicError.self) { try await client.discography(browseId: " ", params: "P") }
        await #expect(throws: MusicError.self) { try await client.discography(browseId: "", params: nil) }
        #expect(fake.requests.isEmpty)
    }

    @Test("discography errors map as the other browse calls do, and keep the cookies out of the URL")
    func discographyErrors() async throws {
        let signedOut = discographyYoutube()
        let signedOutClient = makeClient(signedOut, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await signedOutClient.discography(browseId: "MPADdisc", params: "P") }
        #expect(signedOut.requests.isEmpty)

        let expired = makeClient(youtube { $0.browseStatus = 401 })
        await #expect(throws: MusicError.signedOut) { try await expired.discography(browseId: "MPADdisc", params: "P") }
        let broken = makeClient(youtube { $0.browseStatus = 503 })
        await #expect(throws: MusicError.http(503)) { try await broken.discography(browseId: "MPADdisc", params: "P") }

        let fake = discographyYoutube()
        _ = try await makeClient(fake).discography(browseId: "MPADdisc", params: "P")
        let urls = browseRequests(fake).map(\.url.absoluteString)
        #expect(!urls.isEmpty)
        for url in urls {
            for cookie in MusicTestJar.signedInCookies() {
                #expect(!url.contains(cookie.value))
            }
        }
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
        _ = try await makeClient(fake).moreLibrary(.albums, continuation: "q:a+b/c d&e=f%3D")
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

    // MARK: - History

    @Test("history posts the FEmusic_history browse id with the auth headers and parses the day shelves")
    func historyRequestShape() async throws {
        let fake = youtube()
        let page = try await makeClient(fake).history()
        #expect(page.shelves.map(\.title) == ["Today", "Yesterday"])
        #expect(page.continuation == "q:FIXTURE_HISTORY_NEXT%3D")

        let request = try onlyRequest(fake)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["X-Goog-AuthUser"] == "0")
        let body = FakeYouTube.jsonBody(request)
        #expect(body["browseId"] as? String == "FEmusic_history")
        #expect(body["continuation"] == nil)
        let context = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(context?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("The history browse id is the one ytmusicapi uses")
    func historyBrowseId() {
        #expect(InnerTubeClient.historyBrowseId == "FEmusic_history")
    }

    @Test("moreHistory sends an old-style token as ctoken and continuation next to the history browse id")
    func historyOldStyleContinuation() async throws {
        let fake = youtube { $0.browseContinuationBody = (try? MusicFixtures.data("browse-history-continuation.json")) ?? Data() }
        let page = try await makeClient(fake).moreHistory(continuation: "q:FIXTURE_HISTORY_NEXT%3D")
        #expect(page.shelves.map(\.title) == ["This week", "Last week"])
        #expect(page.continuation == "q:FIXTURE_HISTORY_NEXT2%3D")

        let request = try onlyRequest(fake)
        let query = queryItems(request)
        #expect(query["ctoken"] == "FIXTURE_HISTORY_NEXT=")
        #expect(query["continuation"] == "FIXTURE_HISTORY_NEXT=")
        #expect(request.url.absoluteString.hasSuffix("&ctoken=FIXTURE_HISTORY_NEXT%3D&continuation=FIXTURE_HISTORY_NEXT%3D"))
        let body = FakeYouTube.jsonBody(request)
        #expect(body["browseId"] as? String == "FEmusic_history")
        #expect(body["continuation"] == nil)
    }

    @Test("moreHistory sends a new-style token alone in the body")
    func historyNewStyleContinuation() async throws {
        let fake = youtube { $0.browseContinuationBody = (try? MusicFixtures.data("browse-home-continuation-new.json")) ?? Data() }
        _ = try await makeClient(fake).moreHistory(continuation: "NEWTOKEN")
        let request = try onlyRequest(fake)
        let body = FakeYouTube.jsonBody(request)
        #expect(body["continuation"] as? String == "NEWTOKEN")
        #expect(body["browseId"] == nil)
        #expect(queryItems(request)["ctoken"] == nil)
    }

    @Test("A blank history continuation makes no request and returns an empty page")
    func historyBlankContinuation() async throws {
        let fake = youtube()
        let client = makeClient(fake)
        #expect(try await client.moreHistory(continuation: " ") == MusicHomePage(shelves: [], continuation: nil))
        #expect(try await client.moreHistory(continuation: "q:") == MusicHomePage(shelves: [], continuation: nil))
        #expect(browseRequests(fake).isEmpty)
    }

    @Test("Paused history comes back as an empty page, not an error")
    func historyPaused() async throws {
        let fake = youtube { $0.browseBodies["FEmusic_history"] = (try? MusicFixtures.data("browse-history-paused.json")) ?? Data() }
        let page = try await makeClient(fake).history()
        #expect(page == MusicHomePage(shelves: [], continuation: nil))
    }

    @Test("History: signed out fails with signedOut and touches no network; 401 is signed out, other statuses carry their code")
    func historyErrors() async {
        let signedOutFake = youtube()
        let signedOut = makeClient(signedOutFake, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await signedOut.history() }
        await #expect(throws: MusicError.signedOut) { try await signedOut.moreHistory(continuation: "q:a") }
        #expect(signedOutFake.requests.isEmpty)

        let expired = makeClient(youtube { $0.browseStatus = 401 })
        await #expect(throws: MusicError.signedOut) { try await expired.history() }
        await #expect(throws: MusicError.signedOut) { try await expired.moreHistory(continuation: "q:a") }

        for status in [400, 403, 429, 500, 503] {
            let client = makeClient(youtube { $0.browseStatus = status })
            await #expect(throws: MusicError.httpAnswer(status)) { try await client.history() }
        }
    }

    @Test("A history response that is not a browse page is a parse error")
    func historyUnexpectedResponse() async {
        let client = makeClient(youtube {
            $0.browseBodies = [:]
            $0.browseDefaultBody = Data("<html>captcha</html>".utf8)
        })
        await #expect(throws: MusicError.self) { try await client.history() }
    }

    @Test("History calls keep the cookie values out of the request URL")
    func historyUrlHoldsNoCookies() async throws {
        let fake = youtube { $0.browseContinuationBody = (try? MusicFixtures.data("browse-history-continuation.json")) ?? Data() }
        _ = try await makeClient(fake).moreHistory(continuation: "q:abc")
        let url = try onlyRequest(fake).url.absoluteString
        for cookie in MusicTestJar.signedInCookies() {
            #expect(!url.contains(cookie.value))
        }
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
            await #expect(throws: MusicError.httpAnswer(status)) { try await client.home() }
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
        #expect(try await client.library(.albums) == MusicCollectionList(items: [], continuation: nil))
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
