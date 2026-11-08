// DeciTests/Music/LiveChecks/MixLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): Deci's Mix shuffle against 54 real songs, with the real MusicService, queue, analysis
// (beat_this), transition planner, vocal guard and the two-deck AVPlaybackEngine. Only the network is faked. The engine
// plays into a muted process tap, so nothing is heard. One test runs the ten checks in order and writes report.md.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MixLiveCheckTests", .serialized, .enabled(if: liveGate))
struct MixLiveCheckTests {
    @Test("Mix with real songs and the real engine: ten checks")
    func tenChecks() async throws {
        let world = try await LiveWorld.shared()
        LiveReport.note("Songs: \(world.songs.count). Analysis rows: \(world.rows.count). Analysed this run: \(world.analysedNow) in \(Int(world.analysisSeconds)) s.")
        let withLyrics = world.lyricLines.count
        LiveReport.note("Synced lyrics (LRCLIB): \(withLyrics) of \(world.songs.count) songs, instrumental: \(world.instrumentals.count). The others use the structural proxy.")
        let checks = LiveChecks(world: world)
        let results = await checks.runAll()
        for (number, pass) in results.sorted(by: { $0.key < $1.key }) {
            #expect(pass, "live check \(number) failed, see report.md")
        }
    }
}
