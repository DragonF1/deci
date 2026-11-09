// DeciTests/Music/MusicDJLengthSettingTests.swift
// Tier 4b P3: the DJ-length songs switch is off by default, an old settings file reads it as off, a stored true survives a
// round trip, it rides in the playback preferences, and the service hands it (and the run's energy) to the planner.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music DJ-length setting")
struct MusicDJLengthSettingTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("a fresh install has it off, in the settings and in the preferences")
    func defaultIsOff() {
        #expect(AppSettings().musicDJLength == false)
        #expect(MusicPlaybackPreferences().djLength == false)
        #expect(AppSettings().musicPlayback.djLength == false)
    }

    @Test("an old file, an empty file and a wrong type read it as off")
    func oldFilesDecode() throws {
        #expect(try decode("{}").musicDJLength == false)
        #expect(try decode(#"{"musicBeatMix": false, "musicVocalGuard": false}"#).musicDJLength == false)
        #expect(try decode(#"{"musicDJLength": "yes"}"#).musicDJLength == false)
        #expect(try decode(#"{"musicDJLength": true}"#).musicDJLength)
        // The rest of an old file still decodes.
        let old = try decode(#"{"musicCrossfadeEnabled": true, "musicCrossfadeSeconds": 8}"#)
        #expect(old.musicCrossfadeEnabled && old.musicCrossfadeSeconds == 8 && old.musicBeatMix)
    }

    @Test("a stored true survives an encode and decode")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.musicDJLength = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).musicDJLength)
    }

    @Test("the playback preferences carry it both ways")
    func preferencesCarryIt() {
        var settings = AppSettings()
        settings.musicDJLength = true
        #expect(settings.musicPlayback.djLength)
        var other = AppSettings()
        other.musicPlayback = MusicPlaybackPreferences(djLength: true)
        #expect(other.musicDJLength)
        other.musicPlayback = MusicPlaybackPreferences()
        #expect(other.musicDJLength == false)
    }
}

@MainActor
@Suite("MusicService DJ-length")
struct MusicServiceDJLengthTests {
    /// Rows for `ids`: every song is an "a"-shaped 240 s song with choruses in `high` phrases (16 s phrases) and the energy
    /// rating in `energies` (0.8 when not named).
    private func rows(_ h: BeatHarness, ids: [String] = ["a", "b", "c", "d"], energies: [String: Float] = [:], high: Set<Int> = [2, 5, 8]) async {
        for id in ids {
            var row = BeatHarness.row("a", period: 0.5)
            row.videoId = id
            row.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: energies[id] ?? 0.8).encode()
            row.energy = SectionFixtures.envelope(seconds: 240, high: high)
            await h.reader.set(row)
        }
    }

    private func harness(djLength: Bool, mix: Bool, vocalGuard: Bool = false, live: (@MainActor () -> Bool)? = nil) -> BeatHarness {
        BeatHarness(preferences: MusicPlaybackPreferences(
            shuffle: mix, crossfade: true, crossfadeSeconds: 6, beatMix: true, vocalGuard: vocalGuard, mixShuffle: mix, djLength: djLength
        ), djLength: live)
    }

    /// Plays the current song for `seconds` (a tick a second), long enough to count as played.
    private func listen(_ h: BeatHarness, seconds: Int = 35) {
        for s in 0...seconds { h.engine.tick(Double(s), playing: true) }
    }

    private func skip(_ h: BeatHarness) async {
        h.service.next()
        await h.settle()
        h.engine.emit(.playingChanged(true))
    }

    /// Ticks the third song up to where an energetic run's cut would have been offered (72 s) and says whether it was.
    private func offeredEarly(_ h: BeatHarness) async -> TransitionPlan? {
        await h.tick(40)
        await h.tick(60)
        await h.tick(72)
        return h.engine.preloads.isEmpty ? nil : h.lastPlan
    }

    @Test("Mix with the setting on: the engine's plan mixes out at the second chorus and the next song is parked in time")
    func settingReachesPlanner() async throws {
        let h = harness(djLength: true, mix: true)
        await rows(h)
        await h.startQueue(["a", "b", "c"])
        #expect(h.service.isDJLengthOn)
        listen(h)
        #expect(h.service.runEnergy == 0.8, "run energy \(String(describing: h.service.runEnergy))")
        // The usual mix-out is about 192 (window opens near 166); the window for the cut at 96.2 opens at 70.
        await h.tick(40)
        await h.tick(60)
        await h.tick(72)
        #expect(h.engine.preloads.count == 1, "mix \(h.service.isMixOn) preloads \(h.engine.preloads.count) lines \(h.service.transitionLines) queue \(h.service.queue.tracks.map(\.videoId))")
        let plan = try #require(h.lastPlan, "lines: \(h.service.transitionLines)")
        #expect(plan.djSection == .chorus2, "plan \(plan) lines \(h.service.transitionLines)")
        #expect(abs((plan.mixOutSec ?? 0) - 96.2) < 0.001)
    }

    @Test("the vocal guard on and no lyric timings for the song: no cut, the usual window")
    func guardWithoutLyricsKeepsUsualPlan() async {
        let h = harness(djLength: true, mix: true, vocalGuard: true)
        await rows(h)
        await h.startQueue(["a", "b", "c"])
        listen(h)
        let early = await offeredEarly(h)
        #expect(early == nil, "plan \(String(describing: early))")
    }

    @Test("the setting off leaves the plan at the usual mix-out")
    func settingOffChangesNothing() async throws {
        let h = harness(djLength: false, mix: true)
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

    @Test("outside Mix the setting does nothing")
    func needsMix() async {
        let h = harness(djLength: true, mix: false)
        #expect(h.service.isDJLengthOn == false)
    }

    // MARK: Run energy

    @Test("the run is the songs that played: a calm start (0.40 then loud songs) keeps a loud third song from cutting")
    func runEnergyIsTheRun() async {
        // Third song 0.70 alone is high, but with 0.40 and two 0.70 songs the run is 0.60, under the threshold.
        let h = harness(djLength: true, mix: true)
        await rows(h, energies: ["a": 0.40, "b": 0.70, "c": 0.70, "d": 0.70])
        await h.startQueue(["a", "b", "c", "d"])
        listen(h)
        await skip(h)
        listen(h)
        await skip(h)
        listen(h)
        let early = await offeredEarly(h)
        #expect(early == nil, "calm run: no early window, plan \(String(describing: early))")
        await h.tick(170)
        let plan = h.lastPlan
        #expect(plan?.djSection == nil)
        #expect((plan?.mixOutSec ?? 0) > 150)
    }

    @Test("an energetic run of three played songs cuts")
    func energeticRunCuts() async {
        let h = harness(djLength: true, mix: true)
        await rows(h, energies: ["a": 0.70, "b": 0.70, "c": 0.70, "d": 0.70])
        await h.startQueue(["a", "b", "c", "d"])
        listen(h)
        await skip(h)
        listen(h)
        await skip(h)
        listen(h)
        let early = await offeredEarly(h)
        #expect(early?.djSection == .chorus2, "plan \(String(describing: early))")
    }

    @Test("a song skipped before the play-count point is not in the run")
    func skippedSongDoesNotCount() async {
        // Counted: 0.70 and 0.56 give 0.63 (high). A skipped 0.56 song counted too would pull it to 0.607 (calm).
        let h = harness(djLength: true, mix: true)
        await rows(h, energies: ["a": 0.70, "b": 0.56, "c": 0.56, "d": 0.56])
        await h.startQueue(["a", "b", "c", "d"])
        listen(h)
        await skip(h)
        listen(h, seconds: 5)
        await skip(h)
        listen(h)
        let early = await offeredEarly(h)
        #expect(early?.djSection == .chorus2, "plan \(String(describing: early))")
    }

    @Test("a new queue starts a new run")
    func newQueueResetsRun() async {
        let h = harness(djLength: true, mix: true)
        await rows(h, ids: ["a", "b", "c", "d", "e", "f"], energies: ["a": 0.30, "b": 0.30, "c": 0.30, "d": 0.30, "e": 0.80, "f": 0.80])
        await h.startQueue(["a", "b", "c", "d"])
        listen(h)
        await skip(h)
        listen(h)
        // A tapped song of another queue: the 0.30 songs before it are not its run.
        for id in ["e", "f"] { await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
        let tracks = ["e", "f"].map { MusicSamples.track($0, title: "Song \($0)") }
        await h.backend.setRadio(seed: "e", tracks: tracks, continuation: nil)
        h.service.play(tracks[0])
        await h.settle()
        h.engine.emit(.playingChanged(true))
        listen(h)
        let early = await offeredEarly(h)
        #expect(early?.djSection == .chorus2, "plan \(String(describing: early))")
    }

    // MARK: Parked plans

    /// A DJ plan parked for the first song of an energetic run (the cut at 96.2).
    private func parked(_ h: BeatHarness) async {
        await rows(h)
        await h.startQueue(["a", "b", "c"])
        listen(h)
        await h.tick(40)
        await h.tick(60)
        await h.tick(72)
    }

    @Test("a seek past the cut withdraws the parked DJ plan, and the song gets the usual plan at its end")
    func seekPastTheCut() async throws {
        let h = harness(djLength: true, mix: true)
        await parked(h)
        #expect(h.lastPlan?.djSection == .chorus2)
        let cancels = h.engine.cancelPreloadCount
        h.service.seek(to: 100)
        #expect(h.engine.cancelPreloadCount == cancels + 1, "withdrawn")
        await h.tick(120)
        await h.tick(170)
        let plan = try #require(h.lastPlan)
        #expect(plan.djSection == nil)
        #expect((plan.mixOutSec ?? 0) > 150, "the usual mix-out: \(plan)")
        #expect(!h.service.transitionLines.contains { $0.hasPrefix("transition_dj") }, "no false log")
    }

    @Test("turning the setting off with a DJ plan parked withdraws it, so the song plays out")
    func toggleOffMidSong() async throws {
        final class Flag { var on = true }
        let flag = Flag()
        let h = harness(djLength: true, mix: true, live: { flag.on })
        await parked(h)
        #expect(h.lastPlan?.djSection == .chorus2)
        let cancels = h.engine.cancelPreloadCount
        flag.on = false
        await h.tick(64)
        #expect(h.engine.cancelPreloadCount == cancels + 1, "the cut is withdrawn")
        await h.tick(170)
        let plan = try #require(h.lastPlan)
        #expect(plan.djSection == nil)
        #expect((plan.mixOutSec ?? 0) > 150)
    }

    @Test("turning the setting on with the usual plan parked and the cut still ahead withdraws it")
    func toggleOnMidSong() async throws {
        final class Flag { var on = false }
        let flag = Flag()
        let h = harness(djLength: false, mix: true, live: { flag.on })
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
            let h = harness(djLength: true, mix: true)
            await parked(h)
            #expect(h.lastPlan?.djSection == .chorus2)
            h.engine.lastTransitionOnGrid = onGrid
            h.engine.advance()
            let logged = h.service.transitionLines.contains { $0.hasPrefix("transition_dj from=a") }
            #expect(logged == onGrid, "onGrid \(onGrid): \(h.service.transitionLines)")
        }
    }
}
