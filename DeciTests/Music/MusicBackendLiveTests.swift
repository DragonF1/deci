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

    @Test("Search returns the parsed songs")
    func search() async throws {
        let harness = makeHarness(signedIn: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let tracks = try await harness.backend.search("daft punk")
        #expect(tracks.count == 6)
        #expect(tracks.allSatisfy { !$0.videoId.isEmpty && !$0.title.isEmpty })
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

    @Test("reportPlayback sends one ping to the tracking host with the cpn")
    func reportPlayback() async throws {
        let harness = makeHarness(signedIn: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let tracking = try #require(URL(string: "https://s.youtube.com/api/stats/playback?docid=abc"))
        try await harness.backend.reportPlayback(trackingURL: tracking, cpn: "AbCd_-0123456789")
        let pings = harness.youtube.requests.filter { $0.url.host == "s.youtube.com" }
        #expect(pings.count == 1)
        #expect(pings.first?.url.absoluteString.contains("cpn=AbCd_-0123456789") == true)
    }

    @Test("live() builds the production backend without touching the Keychain, network or solver")
    func liveSmoke() {
        let backend: any MusicBackend = MusicBackendLive.live()
        #expect(backend is MusicBackendLive)
    }
}
