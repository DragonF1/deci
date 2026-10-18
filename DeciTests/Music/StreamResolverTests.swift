// DeciTests/Music/StreamResolverTests.swift
// The whole resolve path with a fake transport and a fake solver: no network, no JavaScript.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("StreamResolver")
struct StreamResolverTests {

    private struct Harness {
        let youtube: FakeYouTube
        let solver: FakeChallengeSolver
        let cache: PlayerCache
        let store: MemorySecretStore
        let resolver: StreamResolver
        let directory: URL
    }

    private func makeHarness(
        youtube: FakeYouTube = FakeYouTube(),
        solver: FakeChallengeSolver = FakeChallengeSolver(),
        store: MemorySecretStore = MusicTestJar.signedInStore(),
        directory: URL = makeTemporaryDirectory()
    ) -> Harness {
        let client = InnerTubeClient(transport: youtube, secretStore: store, now: { MusicTestJar.now })
        let cache = PlayerCache(directory: directory)
        let resolver = StreamResolver(client: client, solver: solver, cache: cache, now: { MusicTestJar.now })
        return Harness(youtube: youtube, solver: solver, cache: cache, store: store, resolver: resolver, directory: directory)
    }

    private func finish(_ harness: Harness) {
        try? FileManager.default.removeItem(at: harness.directory)
    }

    private static let videoId = "4D7u5KF7SP8"

    // MARK: - Happy path

    @Test("Resolve returns the AAC 128k stream with solved signature and n, expiry and tracking URL")
    func resolvesFixture() async throws {
        let harness = makeHarness()
        defer { finish(harness) }
        let stream = try await harness.resolver.resolve(videoId: Self.videoId)

        #expect(stream.videoId == Self.videoId)
        #expect(stream.itag == 140)
        #expect(stream.url.host == "rr1---sn-fixture.googlevideo.com")
        #expect(stream.url.path == "/videoplayback")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["n"] == "N(K7mvvqmnpyMV8KYX)")
        #expect(items["sig"]?.hasPrefix("SOLVED(==QQV") == true)
        #expect(items["itag"] == "140")
        #expect(stream.expiresAt == Date(timeIntervalSince1970: 1_792_305_256))
        #expect(stream.playbackTrackingURL?.host == "s.youtube.com")
        #expect(stream.httpHeaders == ["User-Agent": MusicAuthHeaders.userAgent])
        let duration = try #require(stream.durationSeconds)
        #expect(abs(duration - 369.626) < 0.001)
    }

    @Test("The solver is asked for exactly this format's signature and n, against this player hash")
    func solverRequest() async throws {
        let harness = makeHarness()
        defer { finish(harness) }
        _ = try await harness.resolver.resolve(videoId: Self.videoId)
        let request = try #require(harness.solver.requests.first)
        #expect(request.playerHash == "0229cd64")
        #expect(request.nInputs == ["K7mvvqmnpyMV8KYX"])
        #expect(request.sigInputs.count == 1)
        #expect(request.sigInputs.first?.hasPrefix("==QQV") == true)
        #expect(harness.solver.requests.count == 1)
    }

    @Test("The player request carries the signatureTimestamp read from the player JS")
    func playerRequestCarriesSTS() async throws {
        let harness = makeHarness()
        defer { finish(harness) }
        _ = try await harness.resolver.resolve(videoId: Self.videoId)
        let request = try #require(harness.youtube.requests(path: "/youtubei/v1/player").first)
        let playback = (FakeYouTube.jsonBody(request)["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any]
        #expect(playback?["signatureTimestamp"] as? Int == 20739)
        #expect(harness.cache.sts(forHash: "0229cd64") == 20739)
    }

    @Test("The raw player JS reaches the solver without a second download")
    func rawPlayerReusedFromTheStsFetch() async throws {
        let harness = makeHarness()
        defer { finish(harness) }
        _ = try await harness.resolver.resolve(videoId: Self.videoId)
        #expect(harness.solver.rawPlayers.count == 1)
        #expect(harness.solver.rawPlayers[0].contains("signatureTimestamp:20739"))
        let downloads = harness.youtube.requests.filter { $0.url.path.hasSuffix("/base.js") }
        #expect(downloads.count == 1)
    }

    @Test("A second resolve of a known player build downloads nothing")
    func warmResolveSkipsTheDownload() async throws {
        let harness = makeHarness(solver: FakeChallengeSolver(needsRawPlayer: false))
        defer { finish(harness) }
        _ = try await harness.resolver.resolve(videoId: Self.videoId)
        _ = try await harness.resolver.resolve(videoId: Self.videoId)
        let downloads = harness.youtube.requests.filter { $0.url.path.hasSuffix("/base.js") }
        #expect(downloads.count == 1)
        let players = harness.youtube.requests(path: "/youtubei/v1/player")
        #expect(players.count == 2)
    }

    @Test("A fresh resolver on the same cache directory also skips the download")
    func warmAcrossLaunches() async throws {
        let first = makeHarness(solver: FakeChallengeSolver(needsRawPlayer: false))
        defer { finish(first) }
        _ = try await first.resolver.resolve(videoId: Self.videoId)

        let second = makeHarness(solver: FakeChallengeSolver(needsRawPlayer: false), directory: first.directory)
        _ = try await second.resolver.resolve(videoId: Self.videoId)
        #expect(second.youtube.requests.filter { $0.url.path.hasSuffix("/base.js") }.isEmpty)
        let request = try #require(second.youtube.requests(path: "/youtubei/v1/player").first)
        let playback = (FakeYouTube.jsonBody(request)["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any]
        #expect(playback?["signatureTimestamp"] as? Int == 20739)
    }

    @Test("A cached player the solver no longer has is downloaded on demand")
    func solverFetchesRawPlayerOnDemand() async throws {
        let first = makeHarness()
        defer { finish(first) }
        _ = try await first.resolver.resolve(videoId: Self.videoId)

        let second = makeHarness(solver: FakeChallengeSolver(needsRawPlayer: true), directory: first.directory)
        _ = try await second.resolver.resolve(videoId: Self.videoId)
        #expect(second.solver.rawPlayers.count == 1)
        #expect(second.youtube.requests.filter { $0.url.path.hasSuffix("/base.js") }.count == 1)
    }

    @Test("A direct URL with no n parameter never calls the solver")
    func directURLNeedsNoSolver() async throws {
        let json = #"""
        {"playabilityStatus":{"status":"OK"},"streamingData":{"expiresInSeconds":"21540","adaptiveFormats":[
          {"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,
           "url":"https://rr1---sn-fixture.googlevideo.com/videoplayback?itag=140&expire=1792305256&sig=abc"}]},
         "videoDetails":{"lengthSeconds":"215"}}
        """#
        let harness = makeHarness(youtube: FakeYouTube { $0.playerBody = Data(json.utf8) })
        defer { finish(harness) }
        let stream = try await harness.resolver.resolve(videoId: Self.videoId)
        #expect(harness.solver.requests.isEmpty)
        #expect(stream.url.absoluteString == "https://rr1---sn-fixture.googlevideo.com/videoplayback?itag=140&expire=1792305256&sig=abc")
        #expect(stream.durationSeconds == 215)
    }

    @Test("Without an expire parameter the expiry comes from expiresInSeconds")
    func expiryFallback() async throws {
        let json = #"""
        {"playabilityStatus":{"status":"OK"},"streamingData":{"expiresInSeconds":"600","adaptiveFormats":[
          {"itag":140,"mimeType":"audio/mp4","bitrate":128000,"url":"https://rr1---sn-fixture.googlevideo.com/videoplayback?itag=140"}]}}
        """#
        let harness = makeHarness(youtube: FakeYouTube { $0.playerBody = Data(json.utf8) })
        defer { finish(harness) }
        let stream = try await harness.resolver.resolve(videoId: Self.videoId)
        #expect(stream.expiresAt == MusicTestJar.now.addingTimeInterval(600))
    }

    // MARK: - Failures

    @Test("A non-OK playability status is unplayable with YouTube's reason")
    func unplayable() async {
        let json = #"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"Video unavailable"}}"#
        let harness = makeHarness(youtube: FakeYouTube { $0.playerBody = Data(json.utf8) })
        defer { finish(harness) }
        await #expect(throws: MusicError.unplayable("Video unavailable")) {
            try await harness.resolver.resolve(videoId: Self.videoId)
        }
        #expect(harness.solver.requests.isEmpty)
    }

    @Test("LOGIN_REQUIRED means the session is dead")
    func loginRequiredIsSignedOut() async {
        let body = (try? MusicFixtures.data("player-login-required.json")) ?? Data()
        let harness = makeHarness(youtube: FakeYouTube { $0.playerBody = body })
        defer { finish(harness) }
        await #expect(throws: MusicError.signedOut) {
            try await harness.resolver.resolve(videoId: Self.videoId)
        }
        #expect(harness.solver.requests.isEmpty)
    }

    @Test("LOGIN_REQUIRED without a reason is still a dead session")
    func loginRequiredWithoutReason() async {
        let json = #"{"playabilityStatus":{"status":"LOGIN_REQUIRED"}}"#
        let harness = makeHarness(youtube: FakeYouTube { $0.playerBody = Data(json.utf8) })
        defer { finish(harness) }
        await #expect(throws: MusicError.signedOut) { try await harness.resolver.resolve(videoId: Self.videoId) }
    }

    @Test("An age gate stays unplayable: signing in again would not help")
    func ageGateIsUnplayable() async {
        for reason in ["Sign in to confirm your age", "This video is age-restricted", "Confirm your AGE to continue"] {
            let json = #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"\#(reason)"}}"#
            let harness = makeHarness(youtube: FakeYouTube { $0.playerBody = Data(json.utf8) })
            defer { finish(harness) }
            await #expect(throws: MusicError.unplayable(reason)) {
                try await harness.resolver.resolve(videoId: Self.videoId)
            }
        }
    }

    @Test("A private video stays unplayable: signing in again would not help")
    func privateVideoIsUnplayable() async {
        let reason = "This video is private"
        let json = #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"\#(reason)"}}"#
        let harness = makeHarness(youtube: FakeYouTube { $0.playerBody = Data(json.utf8) })
        defer { finish(harness) }
        await #expect(throws: MusicError.unplayable(reason)) { try await harness.resolver.resolve(videoId: Self.videoId) }
    }

    @Test("Only the word age marks an age gate")
    func ageInsideAnotherWordIsNotAnAgeGate() async {
        let json = #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to manage this page"}}"#
        let harness = makeHarness(youtube: FakeYouTube { $0.playerBody = Data(json.utf8) })
        defer { finish(harness) }
        await #expect(throws: MusicError.signedOut) { try await harness.resolver.resolve(videoId: Self.videoId) }
    }

    @Test("A response with only WebM audio has no audio format")
    func onlyWebM() async {
        let json = #"""
        {"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[
          {"itag":251,"mimeType":"audio/webm; codecs=\"opus\"","bitrate":146460,"url":"https://rr1---sn-fixture.googlevideo.com/videoplayback?itag=251"}]}}
        """#
        let harness = makeHarness(youtube: FakeYouTube { $0.playerBody = Data(json.utf8) })
        defer { finish(harness) }
        await #expect(throws: MusicError.noAudioFormat) { try await harness.resolver.resolve(videoId: Self.videoId) }
    }

    @Test("A solver failure surfaces as the solver error")
    func solverFailure() async {
        let solver = FakeChallengeSolver()
        solver.fail(with: .solver("boom"))
        let harness = makeHarness(solver: solver)
        defer { finish(harness) }
        await #expect(throws: MusicError.solver("boom")) { try await harness.resolver.resolve(videoId: Self.videoId) }
    }

    @Test("Signed out: nothing is requested")
    func signedOut() async {
        let harness = makeHarness(store: MemorySecretStore())
        defer { finish(harness) }
        await #expect(throws: MusicError.signedOut) { try await harness.resolver.resolve(videoId: Self.videoId) }
        #expect(harness.youtube.requests.isEmpty)
    }

    @Test("A home page that names no player is a parse error")
    func noPlayerOnThePage() async {
        let harness = makeHarness(youtube: FakeYouTube { $0.bootstrapHTML = "<html></html>" })
        defer { finish(harness) }
        await #expect(throws: MusicError.self) { try await harness.resolver.resolve(videoId: Self.videoId) }
    }

    @Test("A player JS without a signatureTimestamp fails instead of guessing one")
    func playerWithoutSTS() async {
        let harness = makeHarness(youtube: FakeYouTube { $0.playerJS = "var nothing = 1;" })
        defer { finish(harness) }
        await #expect(throws: MusicError.self) { try await harness.resolver.resolve(videoId: Self.videoId) }
        #expect(harness.youtube.requests(path: "/youtubei/v1/player").isEmpty)
    }

    @Test("A failed player JS download with nothing cached fails with its status")
    func downloadFailureNothingCached() async {
        let harness = makeHarness(youtube: FakeYouTube { $0.playerJSStatus = 500 })
        defer { finish(harness) }
        await #expect(throws: MusicError.http(500)) { try await harness.resolver.resolve(videoId: Self.videoId) }
    }

    @Test("A failed player JS download falls back to the last player that worked")
    func downloadFailureUsesLastGood() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PlayerCache(directory: directory)
        cache.saveSTS(20111, forHash: "oldhash1", now: MusicTestJar.now.addingTimeInterval(-86_400))
        cache.savePreprocessed("PRE", forHash: "oldhash1")

        // The cached preprocessed player answers the solve, so the fake must not ask for the raw one.
        let harness = makeHarness(youtube: FakeYouTube { $0.playerJSStatus = 500 }, solver: FakeChallengeSolver(needsRawPlayer: false), directory: directory)
        let stream = try await harness.resolver.resolve(videoId: Self.videoId)
        #expect(stream.itag == 140)
        let request = try #require(harness.youtube.requests(path: "/youtubei/v1/player").first)
        let playback = (FakeYouTube.jsonBody(request)["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any]
        #expect(playback?["signatureTimestamp"] as? Int == 20111)
        #expect(harness.solver.requests.first?.playerHash == "oldhash1")
    }

    @Test("Old player builds are pruned to the newest two")
    func cachePruned() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PlayerCache(directory: directory)
        for (index, hash) in ["hash0001", "hash0002", "hash0003"].enumerated() {
            cache.saveSTS(100 + index, forHash: hash, now: MusicTestJar.now.addingTimeInterval(Double(index - 10) * 3600))
            cache.savePreprocessed("PRE\(index)", forHash: hash)
        }
        let harness = makeHarness(directory: directory)
        _ = try await harness.resolver.resolve(videoId: Self.videoId)
        #expect(cache.sts(forHash: "0229cd64") == 20739)
        #expect(cache.sts(forHash: "hash0003") == 102)
        #expect(cache.sts(forHash: "hash0001") == nil)
        #expect(cache.sts(forHash: "hash0002") == nil)
    }
}
