// DeciTests/Music/MusicBackendLiveTests.swift
// The assembled backend behind the MusicBackend contract, on a fake transport and fake solver.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicBackendLive")
struct MusicBackendLiveTests {

    private struct Harness {
        let backend: MusicBackendLive
        let youtube: FakeYouTube
        let store: MemorySecretStore
        let directory: URL
    }

    private func makeHarness(signedIn: Bool) -> Harness {
        let youtube = FakeYouTube()
        let store = signedIn ? MusicTestJar.signedInStore() : MemorySecretStore()
        let directory = makeTemporaryDirectory("deci-backend")
        let client = InnerTubeClient(transport: youtube, secretStore: store, now: { MusicTestJar.now })
        let cache = PlayerCache(directory: directory)
        let resolver = StreamResolver(client: client, solver: FakeChallengeSolver(), cache: cache, now: { MusicTestJar.now })
        return Harness(backend: MusicBackendLive(client: client, resolver: resolver), youtube: youtube, store: store, directory: directory)
    }

    @Test("Signed out until cookies arrive, then signed in, then signed out again")
    func signInAndOut() async throws {
        let harness = makeHarness(signedIn: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        #expect(await harness.backend.isSignedIn() == false)
        try await harness.backend.signIn(with: MusicTestJar.signedInCookies())
        #expect(await harness.backend.isSignedIn())
        #expect(harness.store.saveCount >= 1)
        await harness.backend.signOut()
        #expect(await harness.backend.isSignedIn() == false)
        #expect(harness.store.deleteCount == 1)
    }

    @Test("Signing in with cookies that lack the Google sign-in cookies is refused")
    func signInRefused() async {
        let harness = makeHarness(signedIn: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        await #expect(throws: MusicError.signedOut) {
            try await harness.backend.signIn(with: [MusicTestJar.cookie("PREF", "x")])
        }
        #expect(await harness.backend.isSignedIn() == false)
    }

    @Test("Search while signed out fails before any network request")
    func searchSignedOut() async {
        let harness = makeHarness(signedIn: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.search("daft punk") }
        #expect(harness.youtube.requests.isEmpty)
    }

    @Test("accountInfo returns the signed-in channel from the account menu")
    func accountInfo() async throws {
        let harness = makeHarness(signedIn: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let account = try await harness.backend.accountInfo()
        #expect(account?.name == "Test Listener")
        #expect(account?.handle == "@testlistener")
        #expect(account?.photoURL != nil)
        #expect(harness.youtube.requests(path: "/youtubei/v1/account/account_menu").count == 1)
    }

    @Test("accountInfo while signed out fails before any network request")
    func accountInfoSignedOut() async {
        let harness = makeHarness(signedIn: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.accountInfo() }
        #expect(harness.youtube.requests.isEmpty)
    }

    @Test("Search returns the parsed songs")
    func search() async throws {
        let harness = makeHarness(signedIn: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let tracks = try await harness.backend.search("daft punk")
        #expect(tracks.count == 6)
        #expect(tracks.allSatisfy { !$0.videoId.isEmpty && !$0.title.isEmpty })
    }

    @Test("Artist search returns the parsed artists")
    func searchArtists() async throws {
        let harness = makeHarness(signedIn: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.youtube.update { $0.searchBody = (try? MusicFixtures.data("search-artists.json")) ?? Data() }
        let artists = try await harness.backend.searchArtists("alpha")
        #expect(artists.map(\.title) == ["Artist Alpha", "Artist Beta", "Artist Delta", "Artist Zeta"])
        #expect(artists.allSatisfy { $0.kind == .artist })
        let body = FakeYouTube.jsonBody(try #require(harness.youtube.requests(path: "/youtubei/v1/search").first))
        #expect(body["params"] as? String == InnerTubeClient.artistsSearchParams)
    }

    @Test("Artist search while signed out fails before any network request")
    func searchArtistsSignedOut() async {
        let harness = makeHarness(signedIn: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.searchArtists("some band") }
        #expect(harness.youtube.requests.isEmpty)
    }

    @Test("Radio returns the first queue page, seed first, with its continuation")
    func radio() async throws {
        let harness = makeHarness(signedIn: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let page = try await harness.backend.radio(seedVideoId: "4D7u5KF7SP8")
        #expect(page.tracks.first?.videoId == "4D7u5KF7SP8")
        #expect(page.tracks.count == 4)
        #expect(page.continuation != nil)
        let body = FakeYouTube.jsonBody(try #require(harness.youtube.requests(path: "/youtubei/v1/next").first))
        #expect(body["playlistId"] as? String == "RDAMVM4D7u5KF7SP8")
    }

    @Test("moreRadio sends the continuation token and returns the next page")
    func moreRadio() async throws {
        let harness = makeHarness(signedIn: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let first = try await harness.backend.radio(seedVideoId: "4D7u5KF7SP8")
        let token = try #require(first.continuation)
        let next = try await harness.backend.moreRadio(seedVideoId: "4D7u5KF7SP8", continuation: token)
        #expect(next.tracks.count == 4)
        #expect(next.continuation == "SCRUBBED_RADIO_CONTINUATION_3")
        let sent = FakeYouTube.jsonBody(try #require(harness.youtube.requests(path: "/youtubei/v1/next").last))
        #expect(sent["continuation"] as? String == token)
        #expect(sent["videoId"] == nil)
    }

    @Test("Radio while signed out fails before any network request")
    func radioSignedOut() async {
        let harness = makeHarness(signedIn: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.radio(seedVideoId: "4D7u5KF7SP8") }
        await #expect(throws: MusicError.signedOut) {
            _ = try await harness.backend.moreRadio(seedVideoId: "4D7u5KF7SP8", continuation: "token")
        }
        #expect(harness.youtube.requests.isEmpty)
    }

    @Test("Radio errors map like search: 401 is signedOut, other statuses are http, bad bodies are parse")
    func radioErrors() async {
        let harness = makeHarness(signedIn: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.youtube.update { $0.nextStatus = 401 }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.radio(seedVideoId: "x") }
        harness.youtube.update { $0.nextStatus = 503 }
        await #expect(throws: MusicError.http(503)) { _ = try await harness.backend.radio(seedVideoId: "x") }
        await #expect(throws: MusicError.http(503)) { _ = try await harness.backend.moreRadio(seedVideoId: "x", continuation: "t") }
        harness.youtube.update {
            $0.nextStatus = 200
            $0.nextBody = Data("<html>blocked</html>".utf8)
        }
        await #expect(throws: MusicError.self) { _ = try await harness.backend.radio(seedVideoId: "x") }
    }

    // MARK: - Browse

    private func makeBrowseHarness(signedIn: Bool = true, _ configure: (inout FakeYouTube.Config) -> Void = { _ in }) -> Harness {
        let youtube = FakeYouTube { config in
            config.browseBodies = [
                "FEmusic_home": (try? MusicFixtures.data("browse-home.json")) ?? Data(),
                "FEmusic_history": (try? MusicFixtures.data("browse-history.json")) ?? Data(),
                "FEmusic_liked_playlists": (try? MusicFixtures.data("browse-library-playlists.json")) ?? Data(),
                "VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i": (try? MusicFixtures.data("browse-playlist.json")) ?? Data(),
            ]
            config.browseContinuationBody = (try? MusicFixtures.data("browse-tracks-continuation-old.json")) ?? Data()
            configure(&config)
        }
        let store = signedIn ? MusicTestJar.signedInStore() : MemorySecretStore()
        let directory = makeTemporaryDirectory("deci-backend")
        let client = InnerTubeClient(transport: youtube, secretStore: store, now: { MusicTestJar.now })
        let cache = PlayerCache(directory: directory)
        let resolver = StreamResolver(client: client, solver: FakeChallengeSolver(), cache: cache, now: { MusicTestJar.now })
        return Harness(backend: MusicBackendLive(client: client, resolver: resolver), youtube: youtube, store: store, directory: directory)
    }

    @Test("home, library and page forward to the client and return what it parsed")
    func browseForwards() async throws {
        let harness = makeBrowseHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let home = try await harness.backend.home()
        #expect(home.shelves.map(\.title) == ["Quick picks", "Trending community playlists"])

        let library = try await harness.backend.library(.playlists)
        #expect(library.items.map(\.browseId).contains("VLLM"))

        let page = try await harness.backend.page(browseId: "VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i")
        #expect(page.tracks.map(\.videoId) == ["fcnDmrtj6Sk", "xvT1jH8B9AM", "fRIhCiUVaKs"])

        let ids = harness.youtube.requests(path: "/youtubei/v1/browse").map { FakeYouTube.jsonBody($0)["browseId"] as? String }
        #expect(ids == ["FEmusic_home", "FEmusic_liked_playlists", "VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i"])
    }

    @Test("moreHome, moreLibrary and moreTracks send their continuation token")
    func moreBrowseForwards() async throws {
        let harness = makeBrowseHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let tracks = try await harness.backend.moreTracks(browseId: "VLPL1", continuation: "FIXTURE_TOKEN")
        #expect(tracks.tracks.map(\.videoId) == ["fixtureVid0001", "fixtureVid0002"])
        #expect(tracks.continuation == "q:FIXTURE_TRACKS_NEXT2%3D")

        // The stub answers every continuation with the same body: only the routing is under test here.
        _ = try? await harness.backend.moreHome(continuation: "FIXTURE_HOME")
        _ = try? await harness.backend.moreLibrary(.albums, continuation: "FIXTURE_LIBRARY")

        let bodies = harness.youtube.requests(path: "/youtubei/v1/browse").map { FakeYouTube.jsonBody($0) }
        #expect(bodies.count == 3)
        #expect(bodies.compactMap { $0["continuation"] as? String } == ["FIXTURE_TOKEN", "FIXTURE_HOME", "FIXTURE_LIBRARY"])
        #expect(bodies.allSatisfy { $0["browseId"] == nil })
    }

    @Test("history and moreHistory forward to the client: the history browse id, then the continuation token")
    func historyForwards() async throws {
        let harness = makeBrowseHarness { $0.browseContinuationBody = (try? MusicFixtures.data("browse-history-continuation.json")) ?? Data() }
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let first = try await harness.backend.history()
        #expect(first.shelves.map(\.title) == ["Today", "Yesterday"])
        #expect(first.continuation == "q:FIXTURE_HISTORY_NEXT%3D")

        let more = try await harness.backend.moreHistory(continuation: "q:FIXTURE_HISTORY_NEXT%3D")
        #expect(more.shelves.map(\.title) == ["This week", "Last week"])

        let bodies = harness.youtube.requests(path: "/youtubei/v1/browse").map { FakeYouTube.jsonBody($0) }
        #expect(bodies.compactMap { $0["browseId"] as? String } == ["FEmusic_history", "FEmusic_history"])
    }

    @Test("History calls while signed out fail before any network request; errors map like the rest of browse")
    func historyErrors() async {
        let signedOut = makeBrowseHarness(signedIn: false)
        defer { try? FileManager.default.removeItem(at: signedOut.directory) }
        await #expect(throws: MusicError.signedOut) { _ = try await signedOut.backend.history() }
        await #expect(throws: MusicError.signedOut) { _ = try await signedOut.backend.moreHistory(continuation: "t") }
        #expect(signedOut.youtube.requests.isEmpty)

        let harness = makeBrowseHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.youtube.update { $0.browseStatus = 401 }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.history() }
        harness.youtube.update { $0.browseStatus = 503 }
        await #expect(throws: MusicError.http(503)) { _ = try await harness.backend.history() }
        await #expect(throws: MusicError.http(503)) { _ = try await harness.backend.moreHistory(continuation: "t") }
    }

    @Test("Browse calls while signed out fail before any network request")
    func browseSignedOut() async {
        let harness = makeBrowseHarness(signedIn: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.home() }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.moreHome(continuation: "t") }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.library(.playlists) }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.moreLibrary(.playlists, continuation: "t") }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.page(browseId: "VLLM") }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.moreTracks(browseId: "VLLM", continuation: "t") }
        #expect(harness.youtube.requests.isEmpty)
    }

    @Test("Browse errors map like search: 401 is signedOut, other statuses are http, bad bodies are parse")
    func browseErrors() async {
        let harness = makeBrowseHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.youtube.update { $0.browseStatus = 401 }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.home() }
        harness.youtube.update { $0.browseStatus = 503 }
        await #expect(throws: MusicError.http(503)) { _ = try await harness.backend.library(.playlists) }
        await #expect(throws: MusicError.http(503)) { _ = try await harness.backend.moreTracks(browseId: "VLLM", continuation: "t") }
        harness.youtube.update {
            $0.browseStatus = 200
            $0.browseBodies = ["VLLM": Data("<html>blocked</html>".utf8)]
        }
        await #expect(throws: MusicError.self) { _ = try await harness.backend.page(browseId: "VLLM") }
    }

    @Test("Resolve returns a solved, expiring AAC stream")
    func resolve() async throws {
        let harness = makeHarness(signedIn: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let stream = try await harness.backend.resolve(videoId: "4D7u5KF7SP8")
        #expect(stream.itag == 140)
        #expect(stream.url.absoluteString.contains("n=N(K7mvvqmnpyMV8KYX)") || stream.url.absoluteString.contains("n=N%28K7mvvqmnpyMV8KYX%29"))
        #expect(stream.expiresAt == Date(timeIntervalSince1970: 1_792_305_256))
    }

    @Test("Resolve while signed out is signedOut")
    func resolveSignedOut() async {
        let harness = makeHarness(signedIn: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        await #expect(throws: MusicError.signedOut) { _ = try await harness.backend.resolve(videoId: "4D7u5KF7SP8") }
    }

    @Test("reportHistory sends one ping to music.youtube.com with the cpn and returns the status")
    func reportHistory() async throws {
        let harness = makeHarness(signedIn: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let tracking = try #require(URL(string: "https://s.youtube.com/api/stats/playback?docid=abc"))
        let status = try await harness.backend.reportHistory(
            HistoryPing(kind: .playback, url: tracking, cpn: "AbCd_-0123456789", mediaTime: 30)
        )
        #expect(status == 204)
        let pings = harness.youtube.requests.filter { $0.url.path == "/api/stats/playback" }
        #expect(pings.count == 1)
        #expect(pings.first?.url.host == "music.youtube.com")
        #expect(pings.first?.url.absoluteString.contains("cpn=AbCd_-0123456789") == true)
    }

    @Test("live() builds the production backend without touching the Keychain, network or solver")
    func liveSmoke() {
        let backend: any MusicBackend = MusicBackendLive.live()
        #expect(backend is MusicBackendLive)
    }
}
