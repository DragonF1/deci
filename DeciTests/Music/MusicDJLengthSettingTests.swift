// DeciTests/Music/MusicDJLengthSettingTests.swift
// DJ exits and entries are always part of Mixing: the old DJ-length switch is gone and a settings file that has it still reads.
// The service hands them to the planner in Mixing only, parks in time for the exit, and withdraws an exit that no longer holds.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music DJ-length setting")
struct MusicDJLengthSettingTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("a file with the old switch in it, in any shape, reads as if it was not there")
    func oldKeyIsIgnored() throws {
        for value in ["true", "false", "\"yes\"", "null", "{}"] {
            let old = try decode(#"{"musicDJLength": \#(value), "musicTransitions": "mixing", "musicCrossfadeSeconds": 8, "musicVocalGuard": false}"#)
            #expect(old.musicTransitions == .mixing && old.musicCrossfadeSeconds == 8 && old.musicVocalGuard == false, "\(value)")
        }
    }

    @Test("it is not written any more")
    func notWritten() throws {
        let data = try JSONEncoder().encode(AppSettings())
        #expect(String(decoding: data, as: UTF8.self).contains("musicDJLength") == false)
    }
}

@MainActor
@Suite("MusicService DJ-length")
struct MusicServiceDJLengthTests {
    /// Rows for `ids`: every song is an "a"-shaped 240 s song with choruses in `high` phrases (16 s phrases) and the energy
    /// rating 0.8. The second chorus of the default ends at 112.2.
    private func rows(_ h: BeatHarness, ids: [String] = ["a", "b", "c", "d"], high: Set<Int> = [2, 6, 9]) async {
        for id in ids {
            var row = BeatHarness.row("a", period: 0.5)
            row.videoId = id
            row.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.8).encode()
            row.energy = SectionFixtures.envelope(seconds: 240, high: high)
            await h.reader.set(row)
        }
    }

    private func harness(mix: Bool = true, vocalGuard: Bool = false, live: (@MainActor () -> Bool)? = nil) -> BeatHarness {
        BeatHarness(preferences: MusicPlaybackPreferences(
            shuffleMode: mix ? .flow : .off, transitionMode: mix ? .mixing : .crossfade, crossfadeSeconds: 6, vocalGuard: vocalGuard
        ), djLength: live)
    }

    /// Plays the current song for `seconds` (a tick a second), long enough to count as played.
    private func listen(_ h: BeatHarness, seconds: Int = 35) {
        for s in 0...seconds { h.engine.tick(Double(s), playing: true) }
    }

    @Test("in Mixing the engine's plan mixes out at the second chorus and the next song is parked in time")
    func reachesPlanner() async throws {
        let h = harness()
        await rows(h)
        await h.startQueue(["a", "b", "c"])
        #expect(h.service.isDJLengthOn)
        listen(h)
        // The usual mix-out is about 192 (window opens near 166); the window for the exit at 112.2 opens near 86.
        await h.tick(40)
        await h.tick(70)
        #expect(h.engine.preloads.isEmpty, "not yet")
        await h.tick(90)
        #expect(h.engine.preloads.count == 1, "shuffle \(h.service.isShuffleOn) preloads \(h.engine.preloads.count) lines \(h.service.transitionLines) queue \(h.service.queue.tracks.map(\.videoId))")
        let plan = try #require(h.lastPlan, "lines: \(h.service.transitionLines)")
        #expect(plan.djSection == .chorus2, "plan \(plan) lines \(h.service.transitionLines)")
        #expect(abs((plan.mixOutSec ?? 0) - 112.2) < 0.001)
    }

    @Test("switched off (tests only) the plan stays at the usual mix-out")
    func offChangesNothing() async throws {
        let h = harness(live: { false })
        await rows(h)
        await h.startQueue(["a", "b", "c"])
        #expect(h.service.isDJLengthOn == false)
        listen(h)
        await h.tick(126)
        await h.tick(170)
        let plan = try #require(h.lastPlan)
        #expect(plan.djSection == nil)
        #expect((plan.mixOutSec ?? 200) > 150, "the usual mix-out, near the end of the song: \(plan)")
    }

    @Test("outside Mixing there are none")
    func needsMix() async {
        let h = harness(mix: false)
        #expect(h.service.isDJLengthOn == false)
    }

    // MARK: Parked plans

    /// A DJ plan parked for the first song (the exit at 112.2).
    private func parked(_ h: BeatHarness) async {
        await rows(h)
        await h.startQueue(["a", "b", "c"])
        listen(h)
        await h.tick(40)
        await h.tick(70)
        await h.tick(90)
    }

    @Test("a seek past every exit withdraws the parked DJ plan, and the song gets the usual plan at its end")
    func seekPastTheExits() async throws {
        let h = harness()
        await parked(h)
        #expect(h.lastPlan?.djSection == .chorus2)
        let cancels = h.engine.cancelPreloadCount
        // Past the second chorus and the third (160.2) with its spare bars.
        h.service.seek(to: 168)
        #expect(h.engine.cancelPreloadCount == cancels + 1, "withdrawn")
        await h.tick(169)
        await h.tick(172)
        let plan = try #require(h.lastPlan)
        #expect(plan.djSection == nil)
        #expect((plan.mixOutSec ?? 0) > 150, "the usual mix-out: \(plan)")
        #expect(!h.service.transitionLines.contains { $0.hasPrefix("transition_dj") }, "no false log")
    }

    @Test("turned off with a DJ plan parked: withdrawn, so the song plays out")
    func toggleOffMidSong() async throws {
        final class Flag { var on = true }
        let flag = Flag()
        let h = harness(live: { flag.on })
        await parked(h)
        #expect(h.lastPlan?.djSection == .chorus2)
        let cancels = h.engine.cancelPreloadCount
        flag.on = false
        await h.tick(91)
        #expect(h.engine.cancelPreloadCount == cancels + 1, "the cut is withdrawn")
        await h.tick(170)
        let plan = try #require(h.lastPlan)
        #expect(plan.djSection == nil)
        #expect((plan.mixOutSec ?? 0) > 150)
    }

    @Test("turned on with the usual plan parked and the exit still ahead: withdrawn")
    func toggleOnMidSong() async throws {
        final class Flag { var on = false }
        let flag = Flag()
        let h = harness(live: { flag.on })
        // The second chorus ends at 176.2: after the usual window opens (166), before the usual mix-out (192.2).
        await rows(h, high: [5, 10])
        await h.startQueue(["a", "b", "c"])
        listen(h)
        await h.tick(166)
        let first = try #require(h.lastPlan)
        #expect(first.djSection == nil)
        let cancels = h.engine.cancelPreloadCount
        flag.on = true
        await h.tick(167)
        #expect(h.engine.cancelPreloadCount == cancels + 1, "withdrawn to be planned again with the cut")
    }

    @Test("the transition_dj line follows a plan the engine ran on the grid, and not a fallback")
    func logOnlyOnTheGrid() async {
        for onGrid in [true, false] {
            let h = harness()
            await parked(h)
            #expect(h.lastPlan?.djSection == .chorus2)
            h.engine.lastTransitionOnGrid = onGrid
            h.engine.advance()
            let logged = h.service.transitionLines.contains { $0.hasPrefix("transition_dj from=a") }
            #expect(logged == onGrid, "onGrid \(onGrid): \(h.service.transitionLines)")
        }
    }
}
