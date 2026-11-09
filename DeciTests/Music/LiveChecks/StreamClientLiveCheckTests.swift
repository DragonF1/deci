// DeciTests/Music/LiveChecks/StreamClientLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): the anonymous VISIONOS player call through Deci's real InnerTube request code, the
// URL built by the real StreamURLBuilder, then ranged and full GETs against googlevideo. The visitor id comes from an
// anonymous bootstrap on an empty secret store. The TV client needs the account's cookies, which tests never have, so
// it is not checked here.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite(.enabled(if: liveGate))
struct StreamClientLiveCheckTests {
    private static let videoId = "FXk4oLgkKL0"

    @Test("VISIONOS anonymous: itag 140 with a direct URL, 206 for the first and last byte, and the full body matches clen")
    func visionOSStreamServesRanges() async throws {
        let transport = URLSessionTransport()
        let client = InnerTubeClient(transport: transport, secretStore: MemorySecretStore())
        let response = try await client.streamPlayer(client: .visionOS, videoId: Self.videoId, signatureTimestamp: 0)
        #expect(response.status == "OK")
        let format = try #require(response.formats.first { $0.itag == 140 })
        #expect(format.url != nil, "itag 140 must come with a direct URL")
        let plan = try StreamURLBuilder.plan(for: format)
        #expect(!plan.needsSolving)
        let built = try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: [:], n: [:]))
        let clen = try #require(format.contentLength ?? Self.clen(in: built.url))
        print("LIVE stream_client visionos itag \(format.itag) host \(built.url.host ?? "?") clen \(clen)")

        for range in ["bytes=0-0", "bytes=\(clen - 1)-\(clen - 1)"] {
            let reply = try await transport.send(HTTPRequest(
                url: built.url, method: "GET", headers: ["User-Agent": StreamClient.visionUserAgent, "Range": range]
            ))
            print("LIVE probe \(range) -> HTTP \(reply.statusCode), \(reply.data.count) bytes")
            #expect(reply.statusCode == 206)
        }
        #expect(await client.probeStream(url: built.url, userAgent: StreamClient.visionUserAgent) == 206)
        #expect(await client.probeStream(url: built.url, userAgent: StreamClient.visionUserAgent, range: "bytes=\(clen - 1)-\(clen - 1)") == 206)

        // The whole file, straight from URLSession so no cap trims it: no cookies, only the User-Agent and an open range.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        var request = URLRequest(url: built.url)
        request.setValue(StreamClient.visionUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let (data, reply) = try await URLSession(configuration: configuration).data(for: request)
        let status = (reply as? HTTPURLResponse)?.statusCode
        print("LIVE full bytes=0- -> HTTP \(status ?? -1), \(data.count) of \(clen) bytes")
        #expect(status == 206)
        #expect(data.count == clen)
    }

    private static func clen(in url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "clen" }?.value.flatMap(Int.init)
    }
}
