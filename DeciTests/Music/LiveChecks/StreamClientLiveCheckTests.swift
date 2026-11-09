// DeciTests/Music/LiveChecks/StreamClientLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): the anonymous ANDROID_VR player call through Deci's real InnerTube request code, the
// URL built by the real StreamURLBuilder, then ranged GETs against googlevideo. The TV client needs the account's cookies,
// which tests never have, so it is not checked here.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite(.enabled(if: liveGate))
struct StreamClientLiveCheckTests {
    private static let videoId = "FXk4oLgkKL0"

    @Test("ANDROID_VR anonymous: the player call gives a URL googlevideo serves with a 206 to ranged GETs")
    func androidVRStreamServesRanges() async throws {
        let transport = URLSessionTransport()
        let client = InnerTubeClient(transport: transport, secretStore: MemorySecretStore())
        let response = try await client.streamPlayer(client: .androidVR, videoId: Self.videoId, signatureTimestamp: 0)
        #expect(response.status == "OK")
        let format = try #require(FormatPicker.pick(from: response.formats))
        let plan = try StreamURLBuilder.plan(for: format)
        #expect(!plan.needsSolving, "the VR URL needs the solver, which this check does not run")
        let built = try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: [:], n: [:]))
        print("LIVE stream_client android_vr itag \(format.itag) host \(built.url.host ?? "?")")

        for range in ["bytes=0-0", "bytes=1000000-1065535"] {
            let reply = try await transport.send(HTTPRequest(
                url: built.url, method: "GET", headers: ["User-Agent": StreamClient.vrUserAgent, "Range": range]
            ))
            print("LIVE probe \(range) -> HTTP \(reply.statusCode), \(reply.data.count) bytes")
            #expect(reply.statusCode == 206)
        }
        let viaClient = await client.probeStream(url: built.url, userAgent: StreamClient.vrUserAgent)
        #expect(viaClient == 206)
    }
}
