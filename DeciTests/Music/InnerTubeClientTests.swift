// DeciTests/Music/InnerTubeClientTests.swift
// The InnerTube client against a recording fake transport: request shape, auth headers,
// cookie rotation, session bootstrap and error mapping.

import Foundation
import os
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient")
struct InnerTubeClientTests {

    private func makeClient(
        _ youtube: FakeYouTube = FakeYouTube(),
        store: MemorySecretStore = MusicTestJar.signedInStore(),
        clock: MutableClock = MutableClock()
    ) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: store, now: { clock.now })
    }

    private static func clientObject(_ body: [String: Any]) -> [String: Any]? {
        (body["context"] as? [String: Any])?["client"] as? [String: Any]
    }

    // MARK: - Search

    @Test("Search sends a WEB_REMIX songs query with the auth headers and returns the rows")
    func searchRequestShape() async throws {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        let tracks = try await client.search("daft punk")
        #expect(tracks.count == 6)

        let request = try #require(youtube.requests(path: "/youtubei/v1/search").first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")
        let headers = request.headers
        #expect(headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(headers["Authorization"]?.contains("SAPISID1PHASH 1800000000_") == true)
        #expect(headers["Authorization"]?.contains("SAPISID3PHASH 1800000000_") == true)
        #expect(headers["X-Goog-AuthUser"] == "0")
        #expect(headers["X-YouTube-Client-Name"] == "67")
        #expect(headers["X-YouTube-Client-Version"] == "1.20261013.15.00")
        #expect(headers["X-Goog-Visitor-Id"] == "SCRUBBED_VISITOR_DATA")
        #expect(headers["Origin"] == "https://music.youtube.com")
        #expect(headers["X-Origin"] == "https://music.youtube.com")
        #expect(headers["Referer"] == "https://music.youtube.com/")
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["User-Agent"] == MusicAuthHeaders.userAgent)

        let body = FakeYouTube.jsonBody(request)
        let client0 = Self.clientObject(body)
        #expect(client0?["clientName"] as? String == "WEB_REMIX")
        #expect(client0?["clientVersion"] as? String == "1.20261013.15.00")
        #expect(client0?["visitorData"] as? String == "SCRUBBED_VISITOR_DATA")
        #expect(body["query"] as? String == "daft punk")
        #expect(body["params"] as? String == "EgWKAQIIAWoMEA4QChADEAQQCRAF")
    }

    @Test("Only the cookies that match the request host are sent")
    func searchSendsMatchingCookiesOnly() async throws {
        let youtube = FakeYouTube()
        _ = try await makeClient(youtube).search("x")
        let cookie = try #require(youtube.requests(path: "/youtubei/v1/search").first?.headers["Cookie"])
        #expect(cookie.contains("SAPISID=sapisid-secret"))
        #expect(cookie.contains("__Secure-3PAPISID=three-papisid-secret"))
        #expect(!cookie.contains("sid-google-only"))
    }

    @Test("A blank query returns nothing and makes no request")
    func searchBlankQuery() async throws {
        let youtube = FakeYouTube()
        #expect(try await makeClient(youtube).search("   \n").isEmpty)
        #expect(youtube.requests.isEmpty)
    }

    @Test("Special characters and emoji in the query reach the body intact")
    func searchUnicodeQuery() async throws {
        let youtube = FakeYouTube()
        _ = try await makeClient(youtube).search("夜に駆ける \"quoted\" 🎵 \\ ' --; DROP")
        let body = FakeYouTube.jsonBody(try #require(youtube.requests(path: "/youtubei/v1/search").first))
        #expect(body["query"] as? String == "夜に駆ける \"quoted\" 🎵 \\ ' --; DROP")
    }

    // MARK: - Sign-in state

    @Test("Signed out: search fails with signedOut and touches no network")
    func searchSignedOut() async {
        let youtube = FakeYouTube()
        let client = makeClient(youtube, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.search("x") }
        #expect(youtube.requests.isEmpty)
    }

    @Test("Garbage in the secret store reads as signed out")
    func corruptStoreIsSignedOut() async {
        let client = makeClient(store: MemorySecretStore(data: Data("not a jar".utf8)))
        #expect(await client.isSignedIn() == false)
    }

    @Test("A stored jar with the sign-in cookies reads as signed in")
    func storedJarIsSignedIn() async {
        #expect(await makeClient().isSignedIn())
    }

    @Test("Expired cookies in the store do not count")
    func expiredCookiesAreSignedOut() async throws {
        let expired = MusicTestJar.cookie("SAPISID", "old", expires: Date(timeIntervalSince1970: 1_000_000_000))
        let data = try JSONEncoder().encode(MusicCookieJar(cookies: [expired]))
        let client = makeClient(store: MemorySecretStore(data: data))
        #expect(await client.isSignedIn() == false)
    }

    @Test("signIn stores only the YouTube cookies: no Google ones, nothing unrelated")
    func signInStoresYouTubeCookiesOnly() async throws {
        let store = MemorySecretStore()
        let client = makeClient(store: store)
        let cookies = MusicTestJar.signedInCookies() + [
            MusicTestJar.cookie("tracker", "x", domain: ".example.com"),
            MusicTestJar.cookie("NID", "g", domain: "accounts.google.com"),
        ]
        try await client.signIn(with: cookies)

        #expect(await client.isSignedIn())
        #expect(store.saveCount == 1)
        let saved = try JSONDecoder().decode(MusicCookieJar.self, from: try #require(store.load()))
        #expect(saved.value(named: "SAPISID") == "sapisid-secret")
        #expect(Set(saved.cookies.map(\.name)) == ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"])
        #expect(saved.cookies.allSatisfy { $0.domain == ".youtube.com" })
    }

    @Test("signIn starts the bootstrap but returns once the cookies are saved")
    func signInDoesNotWaitForBootstrap() async throws {
        let gate = MusicTestGate()
        let youtube = FakeYouTube { $0.gate = gate }
        let store = MemorySecretStore()
        let client = makeClient(youtube, store: store)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let signIn = Task {
            try await client.signIn(with: MusicTestJar.signedInCookies())
            returned.withLock { $0 = true }
        }

        let finished = await eventually { returned.withLock { $0 } }
        await gate.open()
        try await signIn.value

        #expect(finished)
        #expect(store.saveCount == 1)
        _ = try await client.session()
        #expect(youtube.requests(path: "/").count == 1)
    }

    @Test("signIn without a SAPISID cookie is refused and stores nothing")
    func signInWithoutSapisid() async {
        let store = MemorySecretStore()
        let client = makeClient(store: store)
        await #expect(throws: MusicError.signedOut) {
            try await client.signIn(with: [MusicTestJar.cookie("SID", "x", domain: ".google.com")])
        }
        #expect(store.saveCount == 0)
        #expect(await client.isSignedIn() == false)
    }

    @Test("signIn refuses a SAPISID that only exists on google.com")
    func signInGoogleOnlySapisid() async {
        let store = MemorySecretStore()
        let client = makeClient(store: store)
        await #expect(throws: MusicError.signedOut) {
            try await client.signIn(with: [
                MusicTestJar.cookie("SAPISID", "g", domain: ".google.com"),
                MusicTestJar.cookie("__Secure-3PAPISID", "g3", domain: "accounts.google.com"),
            ])
        }
        #expect(store.saveCount == 0)
        #expect(await client.isSignedIn() == false)
    }

    @Test("signIn accepts __Secure-3PAPISID alone")
    func signInWith3PAPISIDOnly() async throws {
        let client = makeClient(store: MemorySecretStore())
        try await client.signIn(with: [MusicTestJar.cookie("__Secure-3PAPISID", "three")])
        #expect(await client.isSignedIn())
    }

    @Test("A Keychain write failure fails signIn and leaves the client signed out")
    func signInKeychainFailure() async {
        let store = MemorySecretStore()
        store.failSaves = true
        let client = makeClient(store: store)
        await #expect(throws: KeychainSecretStore.KeychainError.self) {
            try await client.signIn(with: MusicTestJar.signedInCookies())
        }
        #expect(await client.isSignedIn() == false)
    }

    @Test("signOut deletes the Keychain item and every later call is signedOut")
    func signOutWipes() async {
        let youtube = FakeYouTube()
        let store = MusicTestJar.signedInStore()
        let client = makeClient(youtube, store: store)
        #expect(await client.isSignedIn())
        await client.signOut()
        #expect(store.deleteCount == 1)
        #expect(store.load() == nil)
        #expect(await client.isSignedIn() == false)
        await #expect(throws: MusicError.signedOut) { try await client.search("x") }
    }

    // MARK: - Bootstrap

    @Test("The home page is fetched once and reused for later calls")
    func bootstrapOnce() async throws {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        _ = try await client.search("a")
        _ = try await client.search("b")
        #expect(youtube.requests(path: "/").count == 1)
    }

    @Test("Concurrent first calls share one bootstrap")
    func bootstrapCoalesced() async throws {
        let youtube = FakeYouTube { $0.delay = .milliseconds(40) }
        let client = makeClient(youtube)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<6 { group.addTask { try await client.search("q\(index)").count } }
            for try await _ in group {}
        }
        #expect(youtube.requests(path: "/").count == 1)
    }

    @Test("The session is refreshed after six hours")
    func bootstrapExpires() async throws {
        let youtube = FakeYouTube()
        let clock = MutableClock()
        let client = makeClient(youtube, clock: clock)
        _ = try await client.search("a")
        clock.advance(by: 5 * 3600)
        _ = try await client.search("b")
        #expect(youtube.requests(path: "/").count == 1)
        clock.advance(by: 2 * 3600)
        _ = try await client.search("c")
        #expect(youtube.requests(path: "/").count == 2)
    }

    @Test("The bootstrap request carries the matching cookies")
    func bootstrapSendsCookies() async throws {
        let youtube = FakeYouTube()
        _ = try await makeClient(youtube).search("a")
        let home = try #require(youtube.requests(path: "/").first)
        #expect(home.method == "GET")
        #expect(home.headers["Cookie"]?.contains("SAPISID=") == true)
        #expect(home.headers["User-Agent"] == MusicAuthHeaders.userAgent)
    }

    @Test("A home page without ytcfg falls back to the built-in client version")
    func bootstrapFallbackVersion() async throws {
        let youtube = FakeYouTube { $0.bootstrapHTML = "<html>consent wall</html>" }
        _ = try await makeClient(youtube).search("a")
        let request = try #require(youtube.requests(path: "/youtubei/v1/search").first)
        #expect(request.headers["X-YouTube-Client-Version"] == InnerTubeClient.fallbackClientVersion)
        #expect(request.headers["X-Goog-Visitor-Id"] == nil)
    }

    @Test("A failing home page does not fail search, and is retried next time")
    func bootstrapFailureIsNotFatal() async throws {
        let youtube = FakeYouTube { $0.bootstrapStatus = 503 }
        let client = makeClient(youtube)
        let tracks = try await client.search("a")
        #expect(tracks.count == 6)
        _ = try await client.search("b")
        #expect(youtube.requests(path: "/").count == 2)
    }

    @Test("session() exposes the version, visitor id and player JS from the page")
    func sessionContents() async throws {
        let session = try await makeClient().session()
        #expect(session.clientVersion == "1.20261013.15.00")
        #expect(session.visitorData == "SCRUBBED_VISITOR_DATA")
        #expect(session.playerHash == "0229cd64")
    }

    @Test("session() surfaces a bootstrap HTTP error")
    func sessionHTTPError() async {
        let client = makeClient(FakeYouTube { $0.bootstrapStatus = 500 })
        await #expect(throws: MusicError.http(500)) { try await client.session() }
    }

    @Test("A bootstrap that finishes after a sign-out is not cached")
    func staleBootstrapIsNotCached() async throws {
        let gate = MusicTestGate()
        let youtube = FakeYouTube { $0.gate = gate }
        let client = makeClient(youtube)
        let stale = Task { try await client.session() }
        #expect(await eventually { youtube.requests(path: "/").count == 1 })

        await client.signOut()
        await gate.open()
        _ = try? await stale.value
        youtube.update { $0.gate = nil }
        _ = try await client.session()

        #expect(youtube.requests(path: "/").count == 2)
    }

    @Test("A stale bootstrap finishing does not hide a newer one in flight")
    func staleBootstrapKeepsTheNewerTask() async throws {
        let staleGate = MusicTestGate()
        let freshGate = MusicTestGate()
        let youtube = FakeYouTube { $0.gate = staleGate }
        let client = makeClient(youtube)
        let stale = Task { try await client.session() }
        #expect(await eventually { youtube.requests(path: "/").count == 1 })

        await client.signOut()
        youtube.update { $0.gate = freshGate }
        let fresh = Task { try await client.session() }
        #expect(await eventually { youtube.requests(path: "/").count == 2 })

        await staleGate.open()
        _ = try? await stale.value
        let joiner = Task { try await client.session() }
        try await Task.sleep(for: .milliseconds(50))
        await freshGate.open()
        _ = try await fresh.value
        _ = try await joiner.value

        #expect(youtube.requests(path: "/").count == 2)
    }

    // MARK: - Cookie rotation

    @Test("Set-Cookie on a response replaces the stored cookie and is persisted")
    func setCookiePersisted() async throws {
        let youtube = FakeYouTube {
            $0.searchHeaders = ["Set-Cookie": "SAPISID=rotated-value; Domain=.youtube.com; Path=/; Secure; Expires=Wed, 01 Jan 2031 00:00:00 GMT"]
        }
        let store = MusicTestJar.signedInStore()
        let client = makeClient(youtube, store: store)
        _ = try await client.search("a")

        #expect(store.saveCount == 1)
        let saved = try JSONDecoder().decode(MusicCookieJar.self, from: try #require(store.load()))
        #expect(saved.value(named: "SAPISID") == "rotated-value")
        #expect(saved.value(named: "__Secure-3PAPISID") == "three-papisid-secret")

        youtube.update { $0.searchHeaders = [:] }
        _ = try await client.search("b")
        let second = try #require(youtube.requests(path: "/youtubei/v1/search").last)
        #expect(second.headers["Cookie"]?.contains("SAPISID=rotated-value") == true)
        #expect(second.headers["Cookie"]?.contains("sapisid-secret") == false)
        #expect(store.saveCount == 1)
    }

    @Test("Set-Cookie on the bootstrap response is persisted too")
    func setCookieOnBootstrap() async throws {
        let youtube = FakeYouTube {
            $0.bootstrapHeaders = ["Set-Cookie": "__Secure-1PSIDTS=fresh; Domain=.youtube.com; Path=/; Secure; Expires=Wed, 01 Jan 2031 00:00:00 GMT"]
        }
        let store = MusicTestJar.signedInStore()
        _ = try await makeClient(youtube, store: store).search("a")
        let saved = try JSONDecoder().decode(MusicCookieJar.self, from: try #require(store.load()))
        #expect(saved.value(named: "__Secure-1PSIDTS") == "fresh")
    }

    @Test("A response that changes no cookie does not rewrite the Keychain")
    func noRewriteWithoutChange() async throws {
        let store = MusicTestJar.signedInStore()
        _ = try await makeClient(store: store).search("a")
        #expect(store.saveCount == 0)
    }

    @Test("A Keychain write failure while rotating cookies does not fail the request")
    func rotationSurvivesKeychainFailure() async throws {
        let youtube = FakeYouTube {
            $0.searchHeaders = ["Set-Cookie": "SAPISID=rotated; Domain=.youtube.com; Path=/; Secure"]
        }
        let store = MusicTestJar.signedInStore()
        store.failSaves = true
        #expect(try await makeClient(youtube, store: store).search("a").count == 6)
    }

    private static let rotation = "Domain=.youtube.com; Path=/; Secure; Expires=Wed, 01 Jan 2031 00:00:00 GMT"

    @Test("A response that lands after signOut neither merges its cookies nor persists them")
    func lateResponseAfterSignOut() async throws {
        let gate = MusicTestGate()
        let youtube = FakeYouTube()
        let store = MusicTestJar.signedInStore()
        let client = makeClient(youtube, store: store)
        _ = try await client.session()
        youtube.update {
            $0.gate = gate
            $0.searchHeaders = ["Set-Cookie": "SAPISID=late-rotation; \(Self.rotation)"]
        }
        let search = Task { try await client.search("a") }
        #expect(await eventually { youtube.requests(path: "/youtubei/v1/search").count == 1 })

        await client.signOut()
        await gate.open()
        _ = try? await search.value

        #expect(store.load() == nil)
        #expect(store.saveCount == 0)
        #expect(await client.isSignedIn() == false)
    }

    @Test("A response from the previous session cannot overwrite a newer sign-in")
    func lateResponseAfterSignIn() async throws {
        let gate = MusicTestGate()
        let youtube = FakeYouTube()
        let store = MusicTestJar.signedInStore()
        let client = makeClient(youtube, store: store)
        _ = try await client.session()
        youtube.update {
            $0.gate = gate
            $0.searchHeaders = ["Set-Cookie": "SAPISID=old-rotation; \(Self.rotation)"]
        }
        let search = Task { try await client.search("a") }
        #expect(await eventually { youtube.requests(path: "/youtubei/v1/search").count == 1 })

        try await client.signIn(with: [MusicTestJar.cookie("SAPISID", "new-sapisid")])
        await gate.open()
        _ = try? await search.value

        let saved = try JSONDecoder().decode(MusicCookieJar.self, from: try #require(store.load()))
        #expect(saved.value(named: "SAPISID") == "new-sapisid")
        #expect(store.saveCount == 1)
    }

    @Test("A jar left without SAPISID or __Secure-3PAPISID is never persisted")
    func jarWithoutSapisidIsNotPersisted() async throws {
        let deleted = "Domain=.youtube.com; Path=/; Max-Age=0; Secure"
        let youtube = FakeYouTube {
            $0.searchHeaders = ["Set-Cookie": "SAPISID=; \(deleted), __Secure-3PAPISID=; \(deleted)"]
        }
        let store = MusicTestJar.signedInStore()
        _ = try await makeClient(youtube, store: store).search("a")

        #expect(store.saveCount == 0)
        let stored = try JSONDecoder().decode(MusicCookieJar.self, from: try #require(store.load()))
        #expect(stored.hasSignInCookies)
    }

    // MARK: - Errors

    @Test("HTTP 401 means the session is gone")
    func unauthorized() async {
        let client = makeClient(FakeYouTube { $0.searchStatus = 401 })
        await #expect(throws: MusicError.signedOut) { try await client.search("a") }
    }

    @Test("Other HTTP failures carry their status")
    func httpFailures() async {
        for status in [403, 429, 500, 503] {
            let client = makeClient(FakeYouTube { $0.searchStatus = status })
            await #expect(throws: MusicError.http(status)) { try await client.search("a") }
        }
    }

    @Test("A body that is not JSON is a parse error")
    func parseFailure() async {
        let client = makeClient(FakeYouTube { $0.searchBody = Data("<html>blocked</html>".utf8) })
        await #expect(throws: MusicError.self) { try await client.search("a") }
    }

    // MARK: - Radio

    private static let nextPath = "/youtubei/v1/next"

    @Test("radio POSTs the seed's RDAMVM playlist to next with the auth headers and returns the queue")
    func radioRequestShape() async throws {
        let youtube = FakeYouTube()
        let page = try await makeClient(youtube).radio(seedVideoId: "4D7u5KF7SP8")
        #expect(page.tracks.count == 4)
        #expect(page.tracks.first?.videoId == "4D7u5KF7SP8")
        #expect(page.continuation == "SCRUBBED_RADIO_CONTINUATION_2")

        let request = try #require(youtube.requests(path: Self.nextPath).first)
        #expect(youtube.requests(path: Self.nextPath).count == 1)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/next?prettyPrint=false")
        let headers = request.headers
        #expect(headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(headers["X-Goog-AuthUser"] == "0")
        #expect(headers["X-YouTube-Client-Name"] == "67")
        #expect(headers["X-YouTube-Client-Version"] == "1.20261013.15.00")
        #expect(headers["X-Goog-Visitor-Id"] == "SCRUBBED_VISITOR_DATA")
        #expect(headers["Origin"] == "https://music.youtube.com")
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)

        let body = FakeYouTube.jsonBody(request)
        #expect(body["videoId"] as? String == "4D7u5KF7SP8")
        #expect(body["playlistId"] as? String == "RDAMVM4D7u5KF7SP8")
        #expect(body["isAudioOnly"] as? Bool == true)
        #expect(body["enablePersistentPlaylistPanel"] as? Bool == true)
        #expect(body["tunerSettingValue"] as? String == "AUTOMIX_SETTING_NORMAL")
        #expect(body["continuation"] == nil)
        let client0 = Self.clientObject(body)
        #expect(client0?["clientName"] as? String == "WEB_REMIX")
        #expect(client0?["clientVersion"] as? String == "1.20261013.15.00")
        #expect(client0?["visitorData"] as? String == "SCRUBBED_VISITOR_DATA")
    }

    @Test("moreRadio sends only the token: a stale one must not be able to restart the radio")
    func moreRadioRequestShape() async throws {
        let youtube = FakeYouTube()
        let page = try await makeClient(youtube).moreRadio(continuation: "TOKEN%3D")
        #expect(page.tracks.map(\.videoId) == ["noiy7ajORtA", "vP709vKwkD0", "JWxoRY7AFSw", "2pzs39z2VMk"])
        #expect(page.continuation == "SCRUBBED_RADIO_CONTINUATION_3")

        let request = try #require(youtube.requests(path: Self.nextPath).first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/next?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
        #expect(request.headers["X-YouTube-Client-Name"] == "67")
        #expect(request.headers["Cookie"]?.contains("SAPISID=") == true)

        let body = FakeYouTube.jsonBody(request)
        #expect(body["continuation"] as? String == "TOKEN%3D")
        #expect(body["videoId"] == nil)
        #expect(body["playlistId"] == nil)
        #expect(Self.clientObject(body)?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("A continuation answer that is the first page again is refused, not replayed")
    func moreRadioRejectedTokenIsAnError() async throws {
        let first = try MusicFixtures.data("next-radio-first.json")
        let client = makeClient(FakeYouTube { $0.nextContinuationBody = first })
        await #expect(throws: MusicError.self) { try await client.moreRadio(continuation: "expired") }
    }

    @Test("A blank seed or continuation returns an empty page and makes no request")
    func radioBlankInputs() async throws {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        #expect(try await client.radio(seedVideoId: " \n").tracks.isEmpty)
        #expect(try await client.radio(seedVideoId: "").continuation == nil)
        #expect(try await client.moreRadio(continuation: "").tracks.isEmpty)
        #expect(try await client.moreRadio(continuation: "  ").continuation == nil)
        #expect(youtube.requests.isEmpty)
    }

    @Test("The seed reaches the body intact, special characters included")
    func radioSeedIsJSONEncoded() async throws {
        let youtube = FakeYouTube()
        _ = try await makeClient(youtube).radio(seedVideoId: "a-b_\"\\ 🎵")
        let body = FakeYouTube.jsonBody(try #require(youtube.requests(path: Self.nextPath).first))
        #expect(body["videoId"] as? String == "a-b_\"\\ 🎵")
        #expect(body["playlistId"] as? String == "RDAMVMa-b_\"\\ 🎵")
    }

    @Test("Signed out: radio and moreRadio fail with signedOut and touch no network")
    func radioSignedOut() async {
        let youtube = FakeYouTube()
        let client = makeClient(youtube, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.radio(seedVideoId: "4D7u5KF7SP8") }
        await #expect(throws: MusicError.signedOut) { try await client.moreRadio(continuation: "token") }
        #expect(youtube.requests.isEmpty)
    }

    @Test("Radio shares the home page bootstrap with search")
    func radioSharesBootstrap() async throws {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        _ = try await client.search("a")
        _ = try await client.radio(seedVideoId: "4D7u5KF7SP8")
        _ = try await client.moreRadio(continuation: "token")
        #expect(youtube.requests(path: "/").count == 1)
    }

    @Test("A failing home page does not fail radio")
    func radioSurvivesBootstrapFailure() async throws {
        let youtube = FakeYouTube { $0.bootstrapStatus = 503 }
        #expect(try await makeClient(youtube).radio(seedVideoId: "4D7u5KF7SP8").tracks.count == 4)
        let request = try #require(youtube.requests(path: Self.nextPath).first)
        #expect(request.headers["X-YouTube-Client-Version"] == InnerTubeClient.fallbackClientVersion)
    }

    @Test("Radio HTTP 401 means the session is gone, other failures carry their status")
    func radioHTTPErrors() async {
        let expired = makeClient(FakeYouTube { $0.nextStatus = 401 })
        await #expect(throws: MusicError.signedOut) { try await expired.radio(seedVideoId: "x") }
        await #expect(throws: MusicError.signedOut) { try await expired.moreRadio(continuation: "x") }
        for status in [400, 403, 429, 500, 503] {
            let client = makeClient(FakeYouTube { $0.nextStatus = status })
            await #expect(throws: MusicError.http(status)) { try await client.radio(seedVideoId: "x") }
            await #expect(throws: MusicError.http(status)) { try await client.moreRadio(continuation: "x") }
        }
    }

    @Test("A radio body that is not JSON is a parse error")
    func radioParseFailure() async {
        let client = makeClient(FakeYouTube {
            $0.nextBody = Data("<html>blocked</html>".utf8)
            $0.nextContinuationBody = Data("<html>blocked</html>".utf8)
        })
        await #expect(throws: MusicError.self) { try await client.radio(seedVideoId: "x") }
        await #expect(throws: MusicError.self) { try await client.moreRadio(continuation: "x") }
    }

    @Test("Set-Cookie on a radio response replaces the stored cookie and is persisted")
    func radioSetCookiePersisted() async throws {
        let youtube = FakeYouTube {
            $0.nextHeaders = ["Set-Cookie": "SAPISID=rotated-by-radio; \(Self.rotation)"]
        }
        let store = MusicTestJar.signedInStore()
        let client = makeClient(youtube, store: store)
        _ = try await client.radio(seedVideoId: "4D7u5KF7SP8")

        #expect(store.saveCount == 1)
        let saved = try JSONDecoder().decode(MusicCookieJar.self, from: try #require(store.load()))
        #expect(saved.value(named: "SAPISID") == "rotated-by-radio")
        #expect(saved.value(named: "__Secure-3PAPISID") == "three-papisid-secret")

        youtube.update { $0.nextHeaders = [:] }
        _ = try await client.moreRadio(continuation: "token")
        let second = try #require(youtube.requests(path: Self.nextPath).last)
        #expect(second.headers["Cookie"]?.contains("SAPISID=rotated-by-radio") == true)
        #expect(second.headers["Cookie"]?.contains("sapisid-secret") == false)
        #expect(store.saveCount == 1)
    }

    @Test("A radio response that lands after signOut neither merges its cookies nor persists them")
    func radioLateResponseAfterSignOut() async throws {
        let gate = MusicTestGate()
        let youtube = FakeYouTube()
        let store = MusicTestJar.signedInStore()
        let client = makeClient(youtube, store: store)
        _ = try await client.session()
        youtube.update {
            $0.gate = gate
            $0.nextHeaders = ["Set-Cookie": "SAPISID=late-radio; \(Self.rotation)"]
        }
        let radio = Task { try await client.radio(seedVideoId: "4D7u5KF7SP8") }
        #expect(await eventually { youtube.requests(path: Self.nextPath).count == 1 })

        await client.signOut()
        await gate.open()
        _ = try? await radio.value

        #expect(store.load() == nil)
        #expect(store.saveCount == 0)
        #expect(await client.isSignedIn() == false)
    }

    @Test("A moreRadio response from the previous session cannot overwrite a newer sign-in")
    func moreRadioLateResponseAfterSignIn() async throws {
        let gate = MusicTestGate()
        let youtube = FakeYouTube()
        let store = MusicTestJar.signedInStore()
        let client = makeClient(youtube, store: store)
        _ = try await client.session()
        youtube.update {
            $0.gate = gate
            $0.nextHeaders = ["Set-Cookie": "SAPISID=old-radio-rotation; \(Self.rotation)"]
        }
        let more = Task { try await client.moreRadio(continuation: "token") }
        #expect(await eventually { youtube.requests(path: Self.nextPath).count == 1 })

        try await client.signIn(with: [MusicTestJar.cookie("SAPISID", "new-sapisid")])
        await gate.open()
        _ = try? await more.value

        let saved = try JSONDecoder().decode(MusicCookieJar.self, from: try #require(store.load()))
        #expect(saved.value(named: "SAPISID") == "new-sapisid")
        #expect(store.saveCount == 1)
    }

    // MARK: - Player

    @Test("The player call carries the signatureTimestamp and the content-check flags")
    func playerRequestShape() async throws {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        let response = try await client.player(videoId: "4D7u5KF7SP8", signatureTimestamp: 20739)
        #expect(response.status == "OK")

        let request = try #require(youtube.requests(path: "/youtubei/v1/player").first)
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/player?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
        #expect(request.headers["X-YouTube-Client-Name"] == "67")
        let body = FakeYouTube.jsonBody(request)
        #expect(body["videoId"] as? String == "4D7u5KF7SP8")
        #expect(body["racyCheckOk"] as? Bool == true)
        #expect(body["contentCheckOk"] as? Bool == true)
        let playback = (body["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any]
        #expect(playback?["signatureTimestamp"] as? Int == 20739)
        #expect(Self.clientObject(body)?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("The player call is refused when signed out")
    func playerSignedOut() async {
        let youtube = FakeYouTube()
        let client = makeClient(youtube, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.player(videoId: "x", signatureTimestamp: 1) }
        #expect(youtube.requests.isEmpty)
    }

    @Test("The player JS is fetched without any credentials")
    func playerJSHasNoCredentials() async throws {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        let url = URL(string: "https://music.youtube.com/s/player/0229cd64/player_es6.vflset/en_US/base.js")!
        let js = try await client.playerJS(at: url)
        #expect(js.contains("signatureTimestamp:20739"))
        let request = try #require(youtube.requests.last)
        #expect(request.method == "GET")
        #expect(request.headers["Cookie"] == nil)
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["X-Goog-AuthUser"] == nil)
    }

    @Test("A player JS download failure carries its status")
    func playerJSFailure() async {
        let client = makeClient(FakeYouTube { $0.playerJSStatus = 404 })
        let url = URL(string: "https://music.youtube.com/s/player/0229cd64/player_es6.vflset/en_US/base.js")!
        await #expect(throws: MusicError.http(404)) { try await client.playerJS(at: url) }
    }

    @Test("The player JS is only fetched from a YouTube host over https")
    func playerJSHostGuard() async {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        await #expect(throws: MusicError.self) { try await client.playerJS(at: URL(string: "https://evil.example/base.js")!) }
        await #expect(throws: MusicError.self) { try await client.playerJS(at: URL(string: "http://music.youtube.com/base.js")!) }
        #expect(youtube.requests.isEmpty)
    }

    // MARK: - History ping

    private static let trackingURL = URL(string: "https://s.youtube.com/api/stats/playback?cl=1&docid=abc&ei=E&len=370")!
    private static let watchtimeURL = URL(string: "https://s.youtube.com/api/stats/watchtime?cl=1&docid=abc&ei=E&len=370")!

    private static func ping(
        _ kind: HistoryPing.Kind = .playback,
        url: URL? = nil,
        mediaTime: TimeInterval = 30
    ) -> HistoryPing {
        HistoryPing(
            kind: kind,
            url: url ?? (kind == .playback ? trackingURL : watchtimeURL),
            cpn: "AbCd_-0123456789",
            mediaTime: mediaTime
        )
    }

    @Test("The playback ping GETs music.youtube.com with the client parameters and auth headers")
    func playbackPingShape() async throws {
        let youtube = FakeYouTube()
        let status = try await makeClient(youtube).reportHistory(Self.ping(.playback, mediaTime: 30.5))
        #expect(status == 204)
        let request = try #require(youtube.requests.last)
        #expect(request.method == "GET")
        #expect(request.body == nil)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "music.youtube.com")
        #expect(components.path == "/api/stats/playback")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["docid"] == "abc")
        #expect(items["ver"] == "2")
        #expect(items["c"] == "WEB_REMIX")
        #expect(items["cpn"] == "AbCd_-0123456789")
        #expect(items["cver"] == "1.20261013.15.00")
        #expect(items["cmt"] == "30.500")
        #expect(items["el"] == "detailpage")
        #expect(items["st"] == nil)
        #expect(items["et"] == nil)
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
        #expect(request.headers["Cookie"]?.contains("SAPISID=") == true)
        #expect(request.headers["Origin"] == "https://music.youtube.com")
        #expect(request.headers["Content-Type"] == nil)
    }

    @Test("The watchtime ping GETs music.youtube.com with st, et, cmt and the same auth headers")
    func reportWatchtimeShape() async throws {
        let youtube = FakeYouTube()
        let status = try await makeClient(youtube).reportHistory(Self.ping(.watchtime, mediaTime: 30.5))
        #expect(status == 204)
        let request = try #require(youtube.requests.last)
        #expect(request.method == "GET")
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "music.youtube.com")
        #expect(components.path == "/api/stats/watchtime")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["docid"] == "abc")
        #expect(items["cpn"] == "AbCd_-0123456789")
        #expect(items["cmt"] == "30.500")
        #expect(items["st"] == "0")
        #expect(items["et"] == "30.500")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
        #expect(request.headers["Cookie"]?.contains("SAPISID=") == true)
    }

    @Test("Both pings of a session reach music.youtube.com and never s.youtube.com")
    func pingsNeverUseTheOldHost() async throws {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        _ = try await client.reportHistory(Self.ping(.playback))
        _ = try await client.reportHistory(Self.ping(.watchtime))
        let stats = youtube.requests.filter { $0.url.path.hasPrefix("/api/stats/") }
        #expect(stats.map(\.url.path) == ["/api/stats/playback", "/api/stats/watchtime"])
        #expect(stats.allSatisfy { $0.url.host == "music.youtube.com" })
        #expect(youtube.requests.contains { $0.url.host == "s.youtube.com" } == false)
    }

    @Test("A www.youtube.com tracking URL is sent to music.youtube.com as well")
    func wwwHostRewritten() async throws {
        let youtube = FakeYouTube()
        let url = try #require(URL(string: "https://www.youtube.com/api/stats/playback?docid=abc"))
        _ = try await makeClient(youtube).reportHistory(Self.ping(.playback, url: url))
        #expect(youtube.requests.last?.url.host == "music.youtube.com")
    }

    @Test("Both 200 and 204 count as a recorded play and are returned")
    func pingSuccessCodes() async throws {
        for status in [200, 204] {
            let youtube = FakeYouTube { $0.statsStatus = status }
            let returned = try await makeClient(youtube).reportHistory(Self.ping())
            #expect(returned == status)
        }
    }

    @Test("A failing history ping reports its status")
    func pingFailureStatus() async {
        let client = makeClient(FakeYouTube { $0.statsStatus = 500 })
        await #expect(throws: MusicError.http(500)) { try await client.reportHistory(Self.ping(.playback)) }
        await #expect(throws: MusicError.http(500)) { try await client.reportHistory(Self.ping(.watchtime)) }
    }

    @Test("A 401 from the stats host means the session is dead")
    func pingUnauthorized() async {
        let client = makeClient(FakeYouTube { $0.statsStatus = 401 })
        await #expect(throws: MusicError.signedOut) { try await client.reportHistory(Self.ping()) }
    }

    @Test("The history ping is refused when signed out")
    func pingSignedOut() async {
        let youtube = FakeYouTube()
        let client = makeClient(youtube, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.reportHistory(Self.ping()) }
        await #expect(throws: MusicError.signedOut) { try await client.reportHistory(Self.ping(.watchtime)) }
        #expect(youtube.requests.isEmpty)
    }

    @Test("Credentials are never sent to a tracking URL outside YouTube")
    func pingHostGuard() async throws {
        let youtube = FakeYouTube()
        let client = makeClient(youtube)
        let evil = try #require(URL(string: "https://evil.example/api/stats/playback"))
        let insecure = try #require(URL(string: "http://s.youtube.com/api/stats/playback"))
        let lookalike = try #require(URL(string: "https://notyoutube.com/api/stats/playback"))
        for kind in [HistoryPing.Kind.playback, .watchtime] {
            for url in [evil, insecure, lookalike] {
                await #expect(throws: MusicError.self) { try await client.reportHistory(Self.ping(kind, url: url)) }
            }
        }
        #expect(youtube.requests.isEmpty)
    }
}
