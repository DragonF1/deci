// DeciTests/Music/LiveChecks/QueueDurationLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): the anonymous music/get_queue call through Deci's real InnerTube request code, for
// three well-known public songs. Each must come back with a positive length. No account is involved.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite(.enabled(if: liveGate))
struct QueueDurationLiveCheckTests {
    private static let ids = ["FXk4oLgkKL0", "kJQP7kiw5Fk", "JGwWNGJdvx8"]

    @Test("music/get_queue answers a positive length for each of three public songs, signed out")
    func lengthsForPublicSongs() async throws {
        let client = InnerTubeClient(transport: URLSessionTransport(), secretStore: MemorySecretStore())
        let lengths = try await client.queueDurations(videoIds: Self.ids)
        print("LIVE queue_durations \(lengths.count) of \(Self.ids.count) ids had a length: \(lengths.values.sorted())")
        for id in Self.ids { #expect((lengths[id] ?? 0) > 0, "no length for one of the ids") }
    }
}
