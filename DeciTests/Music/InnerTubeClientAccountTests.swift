// DeciTests/Music/InnerTubeClientAccountTests.swift
// The account menu call of the InnerTube client against the recording fake transport: the request
// shape, the auth headers, the parsed account and the error mapping.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient account")
struct InnerTubeClientAccountTests {
    private static let path = "/youtubei/v1/account/account_menu"

    private func makeClient(
        _ youtube: FakeYouTube,
        store: MemorySecretStore = MusicTestJar.signedInStore()
    ) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: store, now: { MusicTestJar.now })
    }

    @Test("accountInfo posts account/account_menu with the WEB_REMIX context and the auth headers")
    func requestShape() async throws {
        let fake = FakeYouTube()
        let account = try await makeClient(fake).accountInfo()
        #expect(account == MusicAccount(
            name: "Test Listener",
            handle: "@testlistener",
            photoURL: URL(string: "https://photos.example.test/avatar=s512-c-k-c0x00ffffff-no-rj")
        ))

        let requests = fake.requests(path: Self.path)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/account/account_menu?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["X-Goog-AuthUser"] == "0")
        #expect(request.headers["X-YouTube-Client-Name"] == "67")
        #expect(request.headers["Origin"] == "https://music.youtube.com")
        #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
        #expect(request.headers["Cookie"]?.contains("sid-google-only") == false)

        let body = FakeYouTube.jsonBody(request)
        let context = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(context?["clientName"] as? String == "WEB_REMIX")
        #expect(body["browseId"] == nil)
    }

    @Test("a menu without the account header gives nil")
    func headerMissing() async throws {
        let fake = FakeYouTube { $0.accountMenuBody = Data(#"{"actions":[]}"#.utf8) }
        #expect(try await makeClient(fake).accountInfo() == nil)
    }

    @Test("signed out fails with signedOut and touches no network")
    func signedOut() async {
        let fake = FakeYouTube()
        let client = makeClient(fake, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.accountInfo() }
        #expect(fake.requests.isEmpty)
    }

    @Test("HTTP 401 is signedOut, other statuses carry their code")
    func httpStatuses() async {
        let expired = makeClient(FakeYouTube { $0.accountMenuStatus = 401 })
        await #expect(throws: MusicError.signedOut) { try await expired.accountInfo() }
        for status in [400, 403, 429, 500, 503] {
            let client = makeClient(FakeYouTube { $0.accountMenuStatus = status })
            await #expect(throws: MusicError.http(status)) { try await client.accountInfo() }
        }
    }

    @Test("a body that is not JSON is a parse error")
    func notJSON() async {
        let client = makeClient(FakeYouTube { $0.accountMenuBody = Data("<html>blocked</html>".utf8) })
        await #expect(throws: MusicError.self) { try await client.accountInfo() }
    }

    @Test("an unreachable home page falls back to the built-in client version and still answers")
    func bootstrapFailure() async throws {
        let fake = FakeYouTube { $0.bootstrapStatus = 503 }
        let account = try await makeClient(fake).accountInfo()
        #expect(account?.name == "Test Listener")
        let body = FakeYouTube.jsonBody(try #require(fake.requests(path: Self.path).first))
        let context = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(context?["clientVersion"] as? String == InnerTubeClient.fallbackClientVersion)
    }
}
