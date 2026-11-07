// DeciTests/Music/SongFacts/MusicSongFactsLiveTests.swift
// One opt-in test against the real services. Run with TEST_RUNNER_DECI_SONGFACTS_LIVE=1. Never part of a normal run.

import Foundation
import Testing
@testable import Deci

@Suite("Music song facts live")
struct MusicSongFactsLiveTests {
    @Test(
        "Blinding Lights by The Weeknd is found with a tempo near 171",
        .enabled(if: ProcessInfo.processInfo.environment["DECI_SONGFACTS_LIVE"] == "1")
    )
    func blindingLights() async throws {
        let client = MusicSongFactsClient.live()
        let query = MusicSongFactsQuery(artist: "The Weeknd", title: "Blinding Lights", durationSeconds: 200)
        let result = await client.lookup(query)
        let facts: MusicSongFacts
        switch result {
        case .found(let value), .partial(let value): facts = value
        default:
            Issue.record("expected facts, got \(result)")
            return
        }
        print("SONGFACTS_LIVE \(facts)")
        let bpm = try #require(facts.bpm)
        #expect(abs(bpm - 171) <= 3)
        #expect(facts.isrc == "USUG11904206")
    }
}
