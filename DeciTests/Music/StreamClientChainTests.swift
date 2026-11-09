// DeciTests/Music/StreamClientChainTests.swift
// The stream client chain: VISIONOS anonymous, TV signed in, then WEB_REMIX, each probed before it is used. A fake
// transport and a fake solver: no network.

import CryptoKit
import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("StreamClientChain")
struct StreamClientChainTests {

    private static let videoId = "4D7u5KF7SP8"
    private static let visionHost = "vision-fixture.googlevideo.com"
    private static let tvHost = "tv-fixture.googlevideo.com"
    private static let webHost = "rr1---sn-fixture.googlevideo.com"

    private static func body(host: String, itag: Int = 140) -> Data {
        Data(#"""
        {"playabilityStatus":{"status":"OK"},"streamingData":{"expiresInSeconds":"21540","adaptiveFormats":[
          {"itag":\#(itag),"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,"contentLength":"3000000",
           "url":"https://\#(host)/videoplayback?itag=\#(itag)&expire=1792305256&sig=abc"}]},
         "videoDetails":{"lengthSeconds":"215"}}
        """#.utf8)
    }

    private struct Harness {
        let youtube: FakeYouTube
        let solver: FakeChallengeSolver
        let clock: MutableClock
        let resolver: StreamResolver
        let directory: URL
    }

    /// A transport where VISIONOS and TV each answer with their own host, unless a test says otherwise.
    private func makeHarness(
        candidateTimeout: Duration = .seconds(5),
        _ configure: (inout FakeYouTube.Config) -> Void = { _ in }
    ) -> Harness {
        let youtube = FakeYouTube {
            $0.visionPlayerStatus = 200
            $0.visionPlayerBody = Self.body(host: Self.visionHost)
            $0.tvPlayerStatus = 200
            $0.tvPlayerBody = Self.body(host: Self.tvHost)
            configure(&$0)
        }
        let solver = FakeChallengeSolver()
        let clock = MutableClock()
        let directory = makeTemporaryDirectory()
        let client = InnerTubeClient(transport: youtube, secretStore: MusicTestJar.signedInStore(), now: { clock.now })
        let resolver = StreamResolver(
            client: client, solver: solver, cache: PlayerCache(directory: directory), now: { clock.now },
            candidateTimeout: candidateTimeout, probeTimeout: candidateTimeout
        )
        return Harness(youtube: youtube, solver: solver, clock: clock, resolver: resolver, directory: directory)
    }

    private func finish(_ harness: Harness) {
        try? FileManager.default.removeItem(at: harness.directory)
    }

    private func playerRequests(_ youtube: FakeYouTube, host: String) -> [HTTPRequest] {
        youtube.requests(host: host, path: "/youtubei/v1/player")
    }

    private func probes(_ youtube: FakeYouTube) -> [HTTPRequest] {
        youtube.requests.filter { $0.url.host?.hasSuffix(".googlevideo.com") == true }
    }

    // MARK: - Request shapes

    @Test("The VISIONOS call is anonymous: exact headers and context, no cookie, no authorization, no playbackContext")
    func visionRequestShape() async throws {
        let h = makeHarness()
        defer { finish(h) }
        _ = try await h.resolver.resolve(videoId: Self.videoId)

        let request = try #require(playerRequests(h.youtube, host: "www.youtube.com").first { FakeYouTube.jsonBody($0).clientName == "VISIONOS" })
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
        #expect(request.headers["Cookie"] == nil)
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["X-Goog-AuthUser"] == nil)
        #expect(request.headers["X-YouTube-Client-Name"] == "101")
        #expect(request.headers["X-YouTube-Client-Version"] == "1.02")
        #expect(request.headers["User-Agent"] == ua)
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Origin"] == "https://www.youtube.com")
        #expect(Set(request.headers.keys) == [
            "X-YouTube-Client-Name", "X-YouTube-Client-Version", "User-Agent", "Content-Type", "Origin", "X-Goog-Visitor-Id",
        ])
        let body = FakeYouTube.jsonBody(request)
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "VISIONOS")
        #expect(client?["clientVersion"] as? String == "1.02")
        #expect(client?["deviceMake"] as? String == "Apple")
        #expect(client?["deviceModel"] as? String == "RealityDevice17,1")
        #expect(client?["osName"] as? String == "visionOS")
        #expect(client?["osVersion"] as? String == "26.5.23O471")
        #expect(client?["userAgent"] as? String == ua)
        #expect(client?["hl"] as? String == "en")
        #expect(client?["gl"] as? String == "US")
        #expect(body["videoId"] as? String == Self.videoId)
        #expect(body["contentCheckOk"] as? Bool == true)
        #expect(body["racyCheckOk"] as? Bool == true)
        #expect(body["playbackContext"] == nil)
        #expect((body["context"] as? [String: Any])?["user"] == nil)
        let visitor = try #require(client?["visitorData"] as? String)
        #expect(!visitor.isEmpty)
        #expect(request.headers["X-Goog-Visitor-Id"] == visitor)
    }

    @Test("The TV call is the tv_samsung client, signed in, with the www origin hash and the cookies")
    func tvRequestShape() async throws {
        let h = makeHarness { $0.visionPlayerStatus = 403 }
        defer { finish(h) }
        _ = try await h.resolver.resolve(videoId: Self.videoId)

        let request = try #require(playerRequests(h.youtube, host: "www.youtube.com").first { FakeYouTube.jsonBody($0).clientName == "TVHTML5" })
        let ua = "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1"
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
        #expect(request.headers["X-YouTube-Client-Name"] == "7")
        #expect(request.headers["X-YouTube-Client-Version"] == "5.20260707")
        #expect(request.headers["User-Agent"] == ua)
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Origin"] == "https://www.youtube.com")
        #expect(request.headers["X-Origin"] == "https://www.youtube.com")
        #expect(request.headers["X-Goog-AuthUser"] == "0")
        #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)

        let timestamp = Int(MusicTestJar.now.timeIntervalSince1970.rounded(.down))
        let expected = MusicAuthHeaders.authorization(
            sapisid: "sapisid-secret", secure1PAPISID: "one-papisid-secret", secure3PAPISID: "three-papisid-secret",
            timestamp: timestamp, origin: "https://www.youtube.com"
        )
        #expect(request.headers["Authorization"] == expected)
        let musicHash = MusicAuthHeaders.authorization(
            sapisid: "sapisid-secret", secure1PAPISID: "one-papisid-secret", secure3PAPISID: "three-papisid-secret", timestamp: timestamp
        )
        #expect(request.headers["Authorization"] != musicHash)

        let body = FakeYouTube.jsonBody(request)
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "TVHTML5")
        #expect(client?["clientVersion"] as? String == "5.20260707")
        #expect(client?["deviceMake"] as? String == "Samsung")
        #expect(client?["deviceModel"] as? String == "UKS9800")
        #expect(client?["osName"] as? String == "Tizen")
        #expect(client?["osVersion"] as? String == "2.4.0")
        #expect(client?["userAgent"] as? String == ua)
        #expect(client?["hl"] as? String == "en")
        #expect(client?["gl"] as? String == "US")
        #expect((body["context"] as? [String: Any])?["user"] == nil)
        #expect(body["videoId"] as? String == Self.videoId)
        #expect(body["contentCheckOk"] as? Bool == true)
        #expect(body["racyCheckOk"] as? Bool == true)
        let playback = (body["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any]
        #expect(playback?["signatureTimestamp"] as? Int == 20739)
        #expect(playback?["html5Preference"] as? String == "HTML5_PREF_WANTS")
    }

    @Test("Every probe is a one-byte ranged GET with only the winning client's User-Agent: no cookie, no authorization")
    func probeCarriesNoAccount() async throws {
        let h = makeHarness()
        defer { finish(h) }
        _ = try await h.resolver.resolve(videoId: Self.videoId)
        let sent = probes(h.youtube)
        #expect(sent.count == 2)
        #expect(Set(sent.compactMap { $0.headers["Range"] }) == ["bytes=0-0", "bytes=2999999-2999999"])
        #expect(sent.allSatisfy { $0.method == "GET" })
        #expect(sent.allSatisfy { $0.headers["User-Agent"] == StreamClient.visionUserAgent })
        #expect(sent.allSatisfy { Set($0.headers.keys) == ["Range", "User-Agent"] })
    }

    // MARK: - Chain

    @Test("VISIONOS wins first, and the stream carries its host, itag and User-Agent")
    func visionWins() async throws {
        let h = makeHarness()
        defer { finish(h) }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.visionHost)
        #expect(stream.httpHeaders == ["User-Agent": StreamClient.visionUserAgent])
        #expect(stream.itag == 140)
        #expect(playerRequests(h.youtube, host: "www.youtube.com").count == 1)
    }

    @Test("A VISIONOS player failure falls to TV, whose User-Agent lands in httpHeaders")
    func tvWinsWhenVisionFails() async throws {
        let h = makeHarness { $0.visionPlayerStatus = 403 }
        defer { finish(h) }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.tvHost)
        #expect(stream.httpHeaders == ["User-Agent": StreamClient.tvUserAgent])
    }

    @Test("A probe 403 on VISIONOS falls through to TV, then to WEB_REMIX, in that order")
    func probeFallsThrough() async throws {
        let h = makeHarness {
            $0.probeStatuses = [Self.visionHost: 403, Self.tvHost: 403]
        }
        defer { finish(h) }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.webHost)
        #expect(stream.httpHeaders == ["User-Agent": MusicAuthHeaders.userAgent])
        // Two probes per client, none for the last resort.
        var hosts: [String] = []
        for host in probes(h.youtube).compactMap(\.url.host) where hosts.last != host { hosts.append(host) }
        #expect(hosts == [Self.visionHost, Self.tvHost])
        #expect(probes(h.youtube).count == 4)
    }

    @Test("When every probe fails the last built URL is still returned, from WEB_REMIX")
    func everyProbeFails() async throws {
        let h = makeHarness { $0.probeStatus = 403 }
        defer { finish(h) }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.webHost)
        #expect(probes(h.youtube).count == 4)
    }

    @Test("A probe answer that is neither 200 nor 206 counts as a failure")
    func probeOddStatus() async throws {
        let h = makeHarness { $0.probeStatuses = [Self.visionHost: 416] }
        defer { finish(h) }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.tvHost)
    }

    @Test("A client with no audio format is skipped")
    func noFormatSkips() async throws {
        let h = makeHarness {
            $0.visionPlayerBody = Data(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[]}}"#.utf8)
        }
        defer { finish(h) }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.tvHost)
    }

    @Test("A TV URL that needs solving is solved by the existing solver path")
    func tvCipherIsSolved() async throws {
        let h = makeHarness {
            $0.visionPlayerStatus = 403
            $0.tvPlayerBody = Data(#"""
            {"playabilityStatus":{"status":"OK"},"streamingData":{"expiresInSeconds":"21540","adaptiveFormats":[
              {"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,
               "url":"https://tv-fixture.googlevideo.com/videoplayback?itag=140&n=ABCDEFGH&sig=abc"}]}}
            """#.utf8)
        }
        defer { finish(h) }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.tvHost)
        #expect(h.solver.requests.first?.nInputs == ["ABCDEFGH"])
        #expect(stream.url.absoluteString.contains("n=N%28ABCDEFGH%29"))
    }

    @Test("A VISIONOS answer with only a signatureCipher format counts as no format and is never solved")
    func visionCipherOnlyIsNoFormat() async throws {
        let h = makeHarness {
            $0.visionPlayerBody = Data(#"""
            {"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[
              {"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,
               "signatureCipher":"s=abc&sp=sig&url=https%3A%2F%2Fvision-fixture.googlevideo.com%2Fvideoplayback%3Fitag%3D140"}]}}
            """#.utf8)
        }
        defer { finish(h) }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.tvHost)
        #expect(h.solver.requests.isEmpty)
        #expect(await !h.resolver.isSkipped(.visionOS))
    }

    // MARK: - WEB_REMIX stays the source of metadata

    @Test("Tracking URLs, loudness and view count come from WEB_REMIX even when another client wins")
    func metadataFromWebRemix() async throws {
        let web = Data(#"""
        {"playabilityStatus":{"status":"OK"},"playerConfig":{"audioConfig":{"loudnessDb":-6.3,"perceptualLoudnessDb":-4.1}},
         "streamingData":{"expiresInSeconds":"21540","adaptiveFormats":[
          {"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,
           "url":"https://rr1---sn-fixture.googlevideo.com/videoplayback?itag=140&expire=1792305256&sig=abc"}]},
         "videoDetails":{"lengthSeconds":"215","viewCount":"42"},
         "playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/api/stats/playback?docid=x"},
                             "videostatsWatchtimeUrl":{"baseUrl":"https://s.youtube.com/api/stats/watchtime?docid=x"}}}
        """#.utf8)
        let h = makeHarness { $0.playerBody = web }
        defer { finish(h) }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.visionHost)
        #expect(stream.loudnessDb == -6.3)
        #expect(stream.perceptualLoudnessDb == -4.1)
        #expect(stream.viewCount == 42)
        #expect(stream.playbackTrackingURL?.host == "s.youtube.com")
        #expect(stream.watchtimeTrackingURL?.path == "/api/stats/watchtime")
        #expect(playerRequests(h.youtube, host: "music.youtube.com").count == 1)
    }

    @Test("A WEB_REMIX status that is not OK still throws, whatever the other clients say")
    func webStatusStillThrows() async {
        let json = #"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"Video unavailable"}}"#
        let h = makeHarness { $0.playerBody = Data(json.utf8) }
        defer { finish(h) }
        await #expect(throws: MusicError.unplayable("Video unavailable")) {
            try await h.resolver.resolve(videoId: Self.videoId)
        }
    }

    // MARK: - Sticky preference and skip window

    @Test("The client that last passed is tried first next time")
    func stickyPreference() async throws {
        let h = makeHarness { $0.visionPlayerStatus = 403 }
        defer { finish(h) }
        _ = try await h.resolver.resolve(videoId: Self.videoId)
        // VISIONOS is now skipped, so a second resolve asks TV only.
        h.youtube.update { $0.visionPlayerStatus = 200 }
        let before = playerRequests(h.youtube, host: "www.youtube.com").count
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.tvHost)
        let calls = playerRequests(h.youtube, host: "www.youtube.com").dropFirst(before)
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { FakeYouTube.jsonBody($0).clientName == "TVHTML5" })
    }

    @Test("A failed client is skipped for 30 minutes and tried again after")
    func skipWindow() async throws {
        let h = makeHarness { $0.visionPlayerStatus = 403 }
        defer { finish(h) }
        _ = try await h.resolver.resolve(videoId: Self.videoId)
        h.youtube.update { $0.visionPlayerStatus = 200 }

        h.clock.advance(by: 29 * 60)
        #expect(try await h.resolver.resolve(videoId: Self.videoId).url.host == Self.tvHost)

        // Past the window VISIONOS is back in the chain, behind the sticky TV: it is reached once that fails.
        h.clock.advance(by: 2 * 60)
        h.youtube.update { $0.tvPlayerStatus = 403 }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.visionHost)
    }

    @Test("A probe failure also starts the skip window")
    func probeFailureSkips() async throws {
        let h = makeHarness { $0.probeStatuses = [Self.visionHost: 403] }
        defer { finish(h) }
        #expect(try await h.resolver.resolve(videoId: Self.videoId).url.host == Self.tvHost)
        #expect(await h.resolver.isSkipped(.visionOS))
        h.youtube.update { $0.probeStatuses = [:] }
        #expect(try await h.resolver.resolve(videoId: Self.videoId).url.host == Self.tvHost)
        h.clock.advance(by: 31 * 60)
        h.youtube.update { $0.tvPlayerStatus = 403 }
        #expect(try await h.resolver.resolve(videoId: Self.videoId).url.host == Self.visionHost)
    }

    @Test("The client that passes goes first even when it is the second in the default order")
    func passingClientMovesFirst() async throws {
        let h = makeHarness { $0.probeStatuses = [Self.visionHost: 403] }
        defer { finish(h) }
        _ = try await h.resolver.resolve(videoId: Self.videoId)
        // After the window TV is back in the chain, but TV passed last, so it is asked first.
        h.clock.advance(by: 31 * 60)
        h.youtube.update { $0.probeStatuses = [:] }
        let before = playerRequests(h.youtube, host: "www.youtube.com").count
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.tvHost)
        let calls = playerRequests(h.youtube, host: "www.youtube.com").dropFirst(before)
        #expect(calls.count == 1)
    }

    // MARK: - What starts the skip window

    @Test("With every client in its window the chain is still tried, soonest window first")
    func bothSkippedStillTried() async throws {
        let h = makeHarness { $0.visionPlayerStatus = 403 }
        defer { finish(h) }
        _ = try await h.resolver.resolve(videoId: Self.videoId)
        h.clock.advance(by: 60)
        h.youtube.update { $0.tvPlayerStatus = 403 }
        #expect(try await h.resolver.resolve(videoId: Self.videoId).url.host == Self.webHost)
        #expect(await h.resolver.isSkipped(.visionOS))
        #expect(await h.resolver.isSkipped(.tv))

        // TV's window ends first, so TV is asked first even though both are still inside theirs.
        h.youtube.update { $0.visionPlayerStatus = 200; $0.tvPlayerStatus = 200 }
        let before = playerRequests(h.youtube, host: "www.youtube.com").count
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.visionHost)
        let calls = playerRequests(h.youtube, host: "www.youtube.com").dropFirst(before)
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { FakeYouTube.jsonBody($0).clientName == "VISIONOS" })
    }

    @Test("A probe transport error does not start the skip window")
    func transportErrorNoSkip() async throws {
        let h = makeHarness { $0.throwingHosts = [Self.visionHost] }
        defer { finish(h) }
        #expect(try await h.resolver.resolve(videoId: Self.videoId).url.host == Self.tvHost)
        #expect(await !h.resolver.isSkipped(.visionOS))
    }

    @Test("A player call that times out does not start the skip window")
    func timeoutNoSkip() async throws {
        let h = makeHarness(candidateTimeout: .milliseconds(150)) { $0.visionPlayerDelay = .seconds(30) }
        defer { finish(h) }
        #expect(try await h.resolver.resolve(videoId: Self.videoId).url.host == Self.tvHost)
        #expect(await !h.resolver.isSkipped(.visionOS))
    }

    @Test("A per-video playability status does not start the skip window")
    func perVideoStatusNoSkip() async throws {
        let reasons = [
            #"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"Video unavailable"}}"#,
            #"{"playabilityStatus":{"status":"ERROR","reason":"This video is gone"}}"#,
            #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm your age"}}"#,
            #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"This video is private"}}"#,
        ]
        for json in reasons {
            let h = makeHarness { $0.visionPlayerBody = Data(json.utf8) }
            defer { finish(h) }
            #expect(try await h.resolver.resolve(videoId: Self.videoId).url.host == Self.tvHost)
            #expect(await !h.resolver.isSkipped(.visionOS))
        }
    }

    @Test("A LOGIN_REQUIRED that is not about the song, and a player HTTP error, do start the skip window")
    func wholeClientSignalsSkip() async throws {
        let login = makeHarness {
            $0.visionPlayerBody = Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you're not a bot"}}"#.utf8)
        }
        defer { finish(login) }
        _ = try await login.resolver.resolve(videoId: Self.videoId)
        #expect(await login.resolver.isSkipped(.visionOS))

        let http = makeHarness { $0.visionPlayerStatus = 500 }
        defer { finish(http) }
        _ = try await http.resolver.resolve(videoId: Self.videoId)
        #expect(await http.resolver.isSkipped(.visionOS))
    }

    @Test("A probe 401 or 403 starts the skip window; a 416 does not")
    func probeStatusSkip() async throws {
        let forbidden = makeHarness { $0.probeStatuses = [Self.visionHost: 403] }
        defer { finish(forbidden) }
        _ = try await forbidden.resolver.resolve(videoId: Self.videoId)
        #expect(await forbidden.resolver.isSkipped(.visionOS))

        let range = makeHarness { $0.probeStatuses = [Self.visionHost: 416] }
        defer { finish(range) }
        _ = try await range.resolver.resolve(videoId: Self.videoId)
        #expect(await !range.resolver.isSkipped(.visionOS))
    }

    // MARK: - Deeper probe

    @Test("A URL that serves the first byte but refuses the last byte fails the probe")
    func tailProbeFails() async throws {
        let h = makeHarness { $0.tailProbeStatuses = [Self.visionHost: 403] }
        defer { finish(h) }
        #expect(try await h.resolver.resolve(videoId: Self.videoId).url.host == Self.tvHost)
        #expect(await h.resolver.isSkipped(.visionOS))
    }

    private func visionBody(format: String) -> Data {
        Data(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[\#(format)]}}"#.utf8)
    }

    @Test("The second probe asks the last byte from the format's contentLength")
    func tailProbeLastByte() async throws {
        let h = makeHarness {
            $0.visionPlayerBody = self.visionBody(format: #"""
            {"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,"contentLength":"5000",
             "url":"https://vision-fixture.googlevideo.com/videoplayback?itag=140&clen=9999&sig=abc"}
            """#)
        }
        defer { finish(h) }
        _ = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(Set(probes(h.youtube).compactMap { $0.headers["Range"] }) == ["bytes=0-0", "bytes=4999-4999"])
    }

    @Test("With no contentLength the URL's clen gives the last byte")
    func tailProbeUsesClen() async throws {
        let h = makeHarness {
            $0.visionPlayerBody = self.visionBody(format: #"""
            {"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,
             "url":"https://vision-fixture.googlevideo.com/videoplayback?itag=140&clen=7000&sig=abc"}
            """#)
        }
        defer { finish(h) }
        _ = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(Set(probes(h.youtube).compactMap { $0.headers["Range"] }) == ["bytes=0-0", "bytes=6999-6999"])
    }

    @Test("An unknown size or a file of one byte gets the first-byte probe only")
    func tailProbeSkipped() async throws {
        for tail in [#""contentLength":"1","#, #""contentLength":"0","#, ""] {
            let h = makeHarness {
                $0.visionPlayerBody = self.visionBody(format: #"""
                {"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,\#(tail)
                 "url":"https://vision-fixture.googlevideo.com/videoplayback?itag=140&sig=abc"}
                """#)
            }
            defer { finish(h) }
            let stream = try await h.resolver.resolve(videoId: Self.videoId)
            #expect(stream.url.host == Self.visionHost)
            #expect(probes(h.youtube).compactMap { $0.headers["Range"] } == ["bytes=0-0"])
        }
    }

    // MARK: - Last built URL, cookies, cancellation

    @Test("When WEB_REMIX has no usable format and TV's probe is refused, the TV URL is still returned")
    func lastBuiltIsReturned() async throws {
        let webm = Data(#"""
        {"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[
          {"itag":251,"mimeType":"audio/webm; codecs=\"opus\"","bitrate":146460,"url":"https://rr1---sn-fixture.googlevideo.com/videoplayback?itag=251"}]}}
        """#.utf8)
        let h = makeHarness {
            $0.playerBody = webm
            $0.tvPlayerStatus = 403
            $0.probeStatuses = [Self.visionHost: 403]
        }
        defer { finish(h) }
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.visionHost)
        #expect(stream.httpHeaders == ["User-Agent": StreamClient.visionUserAgent])
    }

    @Test("A Set-Cookie on the VISIONOS answer or the probe never reaches the jar")
    func foreignCookiesAreNotAbsorbed() async throws {
        let evil = ["Set-Cookie": "SID=evil; Domain=.youtube.com; Path=/"]
        let h = makeHarness {
            $0.visionPlayerHeaders = evil
            $0.probeHeaders = evil
        }
        defer { finish(h) }
        _ = try await h.resolver.resolve(videoId: Self.videoId)
        _ = try await h.resolver.resolve(videoId: Self.videoId)
        let cookies = h.youtube.requests(host: "music.youtube.com", path: "/youtubei/v1/player").compactMap { $0.headers["Cookie"] }
        #expect(cookies.count == 2)
        #expect(Set(cookies).count == 1)
        #expect(cookies.allSatisfy { !$0.contains("evil") })
    }

    @Test("A resolve cancelled during the VISIONOS call marks nothing failed: the next one asks VISIONOS first")
    func cancellationLeavesNoMark() async throws {
        let h = makeHarness { $0.visionPlayerDelay = .seconds(30) }
        defer { finish(h) }
        let resolver = h.resolver
        let task = Task { try await resolver.resolve(videoId: Self.videoId) }
        for _ in 0..<400 {
            if h.youtube.requests.contains(where: { $0.url.host == "www.youtube.com" && FakeYouTube.jsonBody($0).clientName == "VISIONOS" }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        _ = await task.result
        #expect(await !h.resolver.isSkipped(.visionOS))

        h.youtube.update { $0.visionPlayerDelay = nil }
        let before = playerRequests(h.youtube, host: "www.youtube.com").count
        let stream = try await h.resolver.resolve(videoId: Self.videoId)
        #expect(stream.url.host == Self.visionHost)
        let calls = playerRequests(h.youtube, host: "www.youtube.com").dropFirst(before)
        #expect(calls.count == 1)
    }
}

private extension Dictionary where Key == String, Value == Any {
    var clientName: String? {
        ((self["context"] as? [String: Any])?["client"] as? [String: Any])?["clientName"] as? String
    }
}
