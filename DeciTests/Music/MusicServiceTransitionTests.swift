// DeciTests/Music/MusicServiceTransitionTests.swift
// Tier 2b P3: the service plans each transition from song analysis. One plan per offer (trims, smart fade numbers), the
// preload window measured to the trimmed end, a wait for the next song's analysis until 10 s remain, a late row that
// changes nothing, a mid-song Crossfade toggle that re-plans without re-preloading, and a manual skip that starts the
// song at its trim offset. A fake engine, a fake analysis provider and a fake row reader stand in for the real ones.

import Foundation
import Testing
@testable import Deci

actor FakeAnalysisReader: MusicAnalysisReading {
    private var rows: [String: MusicAnalysis] = [:]
    private(set) var reads: [String] = []

    func set(_ row: MusicAnalysis) { rows[row.videoId] = row }

    func analysis(for videoId: String) async -> MusicAnalysis? {
        reads.append(videoId)
        return rows[videoId]
    }
}

@MainActor
private struct TransitionHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let connectivity = MusicConnectivity(isOnline: true)
    let provider = FakeAnalysisProvider()
    let reader = FakeAnalysisReader()
    let player: MusicPlayer
    let service: MusicService

    /// Crossfade on means Mix on here: the smart plans these tests check belong to Mix. `mix` false is Crossfade alone.
    init(crossfade: Bool = true, seconds: Double = 6, mix: Bool? = nil) {
        let mix = mix ?? crossfade
        let engine = self.engine
        let clock = self.clock
        let player = MusicPlayer(engine: engine)
        self.player = player
        service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: MusicPlaybackPreferences(shuffle: mix, crossfade: crossfade, crossfadeSeconds: seconds, mixShuffle: mix),
            shuffleSeed: 1,
            queueRetryDelay: .seconds(60),
            connectivity: connectivity,
            refreshOnCreate: false,
            analysis: provider,
            analysisReader: reader
        )
    }

    /// A row: song of `duration` s, dead air to `silenceStart` and after `silenceEnd`, outro from `outroStart`.
    static func row(
        _ id: String, duration: Double = 200, silenceStart: Double = 0, silenceEnd: Double? = nil,
        introEnd: Double? = nil, outroStart: Double? = nil, lufs: Double = -14
    ) -> MusicAnalysis {
        MusicTransitionPlannerTests.analysis(
            id, duration: duration, silenceStart: silenceStart, silenceEnd: silenceEnd, introEnd: introEnd,
            outroStart: outroStart, lufs: lufs
        )
    }

    /// The first worked example: A ends at 197 with a 12 s outro, B opens at 0.5 s with an 8 s intro.
    func standardRows(bLufs: Double = -14) async {
        await reader.set(Self.row("a", silenceEnd: 197, outroStart: 185))
        await reader.set(Self.row("b", silenceStart: 0.5, introEnd: 8, lufs: bLufs))
    }

    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            await play?.value
            await radio?.value
            await service.currentAnalysisTask?.value
            await service.analysisCleanupTask?.value
            await service.transitionReadTask?.value
            if service.playTask == play, service.radioTask == radio { break }
        }
    }

    func startQueue(_ ids: [String], duration: Double = 200) async {
        for id in ids { await backend.setStream(MusicSamples.stream(videoId: id, duration: duration)) }
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)") }
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
    }

    func startPage(_ browseId: String, _ ids: [String], duration: Double = 200) async {
        for id in ids { await backend.setStream(MusicSamples.stream(videoId: id, duration: duration)) }
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)") }
        service.play(tracks[0], in: MusicSamples.page(browseId, tracks: tracks))
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Ticks to `position`, lets the prefetch and its analysis job finish, then ticks half a second on.
    func tick(_ position: TimeInterval) async {
        engine.tick(position, playing: true)
        // The next song is resolved once it has settled as next, so the clock moves between two ticks.
        clock.advance(by: MusicService.analysisSettle + 0.1)
        engine.tick(position + 0.25, playing: true)
        await service.prefetchTask?.value
        await service.analysisTask?.value
        engine.tick(position + 0.5, playing: true)
    }

    /// Like `tick`, without waiting for the analysis job (it is held).
    func tickNoWait(_ position: TimeInterval) async {
        engine.tick(position, playing: true)
        // The next song is resolved once it has settled as next, so the clock moves between two ticks.
        clock.advance(by: MusicService.analysisSettle + 0.1)
        engine.tick(position + 0.25, playing: true)
        await service.prefetchTask?.value
        engine.tick(position + 0.5, playing: true)
    }

    var lastPlan: TransitionPlan? { engine.plans.last ?? nil }
}

@MainActor
@Suite("MusicService transitions")
struct MusicServiceTransitionTests {
    // MARK: - The plan handed in at offer

    @Test("both rows fresh: the engine gets one floor blend with the trims and the smart start")
    func smartPlanAtOffer() async throws {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b", "c"])
        await h.tick(126)
        await h.tick(160)

        #expect(h.engine.preloads.count == 1)
        let plan = try #require(h.lastPlan)
        // Tier 4c: Mix never falls back to the plain smart fade; with no grids this is a gridless 8 s floor blend from the smart start.
        #expect(plan.mode == .beat)
        #expect(plan.incomingStartSec == 0.5)
        #expect(plan.fadeSeconds == 8)
        #expect(plan.fadeStartSec == 185)
        #expect(plan.incomingRate == 1)
        // The radio scan may log its own line first (Mix on a radio queue): the plan line is the one looked at.
        let line = try #require(h.service.transitionLines.first { $0.hasPrefix("transition_plan") })
        #expect(line.hasPrefix("transition_plan from=a to=b mode=beat"))
        #expect(!line.contains("http"))
    }

    @Test("the plan is offered once, however many ticks follow")
    func offeredOnce() async {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b"])
        await h.tick(126)
        for position in stride(from: 160.0, to: 190, by: 3) { await h.tick(position) }
        #expect(h.engine.preloads.count == 1)
        #expect(h.engine.plans.count == 1)
        #expect(h.service.transitionLines.filter { $0.hasPrefix("transition_plan") }.count == 1)
    }

    // MARK: - The preload window

    @Test("a smart-capable pair opens the window 37 s before the trimmed end, not before")
    func smartWindowIsMeasuredToTheTrimmedEnd() async {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(158)
        #expect(h.engine.preloads.isEmpty, "197 - 37 = 160: not yet at 158.5")
        await h.tick(160)
        #expect(h.engine.preloads.count == 1)
    }

    @Test("without rows the window is 15 s plus the fade before the duration, as in tier 1")
    func windowWithoutRowsIsTierOne() async {
        let h = TransitionHarness()
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(170)
        #expect(h.engine.preloads.isEmpty)
        await h.tick(179)
        #expect(h.engine.preloads.count == 1)
    }

    @Test("with Crossfade off the window is 15 s before the trimmed end")
    func crossfadeOffWindow() async throws {
        let h = TransitionHarness(crossfade: false)
        await h.standardRows()
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(170)
        #expect(h.engine.preloads.isEmpty)
        await h.tick(182)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode == .gapless)
        #expect(plan.reason == .off)
        #expect(plan.incomingStartSec == 0.5, "the trim stays with Crossfade off")
        #expect(plan.outgoingEndSec == 197)
        #expect(plan.fadeSeconds == 0)
    }

    // MARK: - Waiting for the next song's analysis

    @Test("the offer waits while the next song's job runs and goes out at 10 s left with a tier-1 fade")
    func waitsThenFallsBackAtTheDeadline() async throws {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b"])
        let gate = MusicTestGate()
        await h.provider.hold("b", gate)

        await h.tickNoWait(126)
        await h.tickNoWait(165)
        #expect(h.engine.preloads.isEmpty, "inside the window but waiting for b's analysis")
        await h.tickNoWait(186)
        #expect(h.engine.preloads.isEmpty, "10.5 s left to 197")
        await h.tickNoWait(187.5)

        #expect(h.engine.preloads.count == 1)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode == .fixed)
        #expect(plan.reason == .partialAnalysis)
        #expect(plan.fadeSeconds == 6)
        #expect(plan.fadeStartSec == nil)
        #expect(plan.incomingStartSec == 0, "b has no row yet")
        #expect(plan.outgoingEndSec == 197, "a's own trim still applies")
        await gate.open()
        await h.service.analysisTask?.value
    }

    @Test("a held job releases the offer the moment its row is read")
    func heldJobReleasedByItsRow() async throws {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b"])
        let gate = MusicTestGate()
        await h.provider.hold("b", gate)
        await h.tickNoWait(126)
        await h.tickNoWait(165)
        #expect(h.engine.preloads.isEmpty)

        await gate.open()
        await h.service.analysisTask?.value
        #expect(h.engine.preloads.count == 1)
        #expect(h.lastPlan?.mode == .beat)
        #expect(h.lastPlan?.incomingStartSec == 0.5)
    }

    @Test("a short current song: the next song is analysed early too, and the offer comes at its window once the job is done")
    func shortSongAnalysesNextToo() async throws {
        let h = TransitionHarness()
        await h.reader.set(TransitionHarness.row("a", duration: 120, silenceEnd: 118, outroStart: 108))
        await h.startQueue(["a", "b"], duration: 120)
        await h.tickNoWait(95)
        #expect(h.engine.preloads.isEmpty)
        await h.tick(100)
        #expect(h.engine.preloads.count == 1)
        #expect(Set(await h.provider.ensuredIDs) == ["a", "b"], "the next song is analysed from the start, not only for long songs")
        #expect(h.lastPlan?.mode == .fixed)
    }

    // MARK: - A late row

    @Test("a row that lands after the offer is logged as late and changes nothing")
    func lateRowChangesNothing() async throws {
        let h = TransitionHarness()
        await h.reader.set(TransitionHarness.row("a", silenceEnd: 197, outroStart: 185))
        await h.startQueue(["a", "b"])
        let gate = MusicTestGate()
        await h.provider.hold("b", gate)
        await h.tickNoWait(126)
        await h.tickNoWait(187.5)
        #expect(h.engine.plans.count == 1)
        let before = try #require(h.lastPlan)

        await h.reader.set(TransitionHarness.row("b", silenceStart: 0.5, introEnd: 8))
        await gate.open()
        await h.service.analysisTask?.value

        #expect(h.engine.preloads.count == 1)
        #expect(h.engine.plans.count == 1)
        #expect(h.lastPlan == before)
        #expect(h.engine.updatedPlans.isEmpty)
        #expect(h.service.transitionLines.last { $0.hasPrefix("transition_") }?.contains("reason=late") == true)
        // A toggle after that still re-plans from the frozen inputs: b stays unanalysed for this transition.
        h.service.setCrossfade(false)
        h.service.setShuffleMode(.off)
        #expect(h.engine.updatedPlans.last??.incomingStartSec == 0)
    }

    // MARK: - Crossfade toggled mid-song

    @Test("toggling Crossfade re-plans through updateTransitionPlan with the same park offset and no re-preload")
    func toggleReplans() async throws {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(160)
        #expect(h.lastPlan?.mode == .beat)
        let cancelsBefore = h.engine.cancelPreloadCount

        // Tier 4c: Mix's floor blend is a beat-mode plan; a ready beat preload still ahead is kept and re-planned in place.
        h.service.setCrossfade(false)
        h.service.setShuffleMode(.off)
        let off = try #require(h.engine.updatedPlans.last ?? nil)
        #expect(off.mode == .gapless)
        #expect(off.incomingStartSec == 0.5)
        #expect(h.engine.preloads.count == 1)
        #expect(h.engine.cancelPreloadCount == cancelsBefore)
    }

    @Test("ticks after an unchanged plan send no further updates")
    func noUpdateWithoutAChange() async {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(160)
        await h.tick(165)
        await h.tick(170)
        #expect(h.engine.updatedPlans.isEmpty)
    }

    // MARK: - Manual skip and the hand-over

    @Test("a manual skip keeps the 0.3 s fade, starts the song at its trim offset and matches the loudness")
    func manualSkipStartsAtTheOffset() async throws {
        let h = TransitionHarness()
        await h.standardRows(bLufs: -8)
        await h.startQueue(["a", "b", "c"])
        await h.tick(126)
        await h.tick(160)
        #expect(h.engine.preloads.count == 1)

        h.service.next()
        await h.settle()

        #expect(h.engine.manualCrossfades == [0.3])
        #expect(h.player.nowPlaying?.videoId == "b")
        #expect(h.player.currentTime == 0.5)
        let skip = try #require(h.engine.updatedPlans.last ?? nil)
        #expect(skip.mode == .fixed)
        #expect(skip.fadeSeconds == 0.3)
        #expect(skip.incomingStartSec == 0.5)
        #expect(skip.incomingGainDb == -6)
        #expect(skip.outgoingGainDb == 0)
    }

    @Test("an automatic hand-over starts the song at the offset the plan parked it at")
    func advanceStartsAtTheOffset() async {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b", "c"])
        await h.tick(126)
        await h.tick(160)

        h.engine.advance()
        await h.settle()

        #expect(h.player.nowPlaying?.videoId == "b")
        #expect(h.player.currentTime == 0.5)
    }

    @Test("a hand-over without a plan still starts at 0")
    func advanceWithoutAPlanStartsAtZero() async {
        let h = TransitionHarness()
        await h.startQueue(["a", "b", "c"])
        await h.tick(126)
        await h.tick(180)
        h.engine.advance()
        await h.settle()
        #expect(h.player.currentTime == 0)
    }

    // MARK: - Gates

    @Test("an album played in order is untrimmed and gapless, and its window is the tier-1 one")
    func albumInOrder() async throws {
        let h = TransitionHarness(crossfade: true, mix: false)
        await h.standardRows()
        await h.startPage("MPREb_album", ["a", "b", "c"])
        await h.tick(126)
        await h.tick(165)
        #expect(h.engine.preloads.isEmpty, "no early window and no trimmed end")
        await h.tick(186)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode == .gapless)
        #expect(plan.reason == .albumInOrder)
        #expect(plan.incomingStartSec == 0)
        #expect(plan.outgoingEndSec == nil)
        #expect(plan.fadeSeconds == 0)
    }

    @Test("Loop song gives no trims and no fade")
    func loopSong() async throws {
        let h = TransitionHarness()
        await h.reader.set(TransitionHarness.row("a", silenceStart: 0.5, silenceEnd: 197, outroStart: 185))
        await h.startQueue(["a", "b"])
        h.service.setLoopMode(.song)
        await h.tick(186)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode == .gapless)
        #expect(plan.reason == .loopSong)
        #expect(plan.incomingStartSec == 0)
        #expect(plan.outgoingEndSec == nil)
    }

    @Test("with no analysis at all the plan is the tier-1 fade: Settings length, natural end, no offset, no gains")
    func noAnalysisEqualsTierOne() async throws {
        let h = TransitionHarness()
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(179)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode == .fixed)
        #expect(plan.reason == .noAnalysis)
        #expect(plan.fadeSeconds == 6)
        #expect(plan.fadeStartSec == nil)
        #expect(plan.outgoingEndSec == nil)
        #expect(plan.incomingStartSec == 0)
        #expect(plan.incomingGainDb == 0)
        #expect(plan.outgoingGainDb == 0)
        #expect(h.engine.crossfadeSeconds == 6)
    }

    @Test("a row whose format does not match the stream is ignored")
    func staleRowIgnored() async throws {
        let h = TransitionHarness()
        await h.reader.set(TransitionHarness.row("a", silenceEnd: 197, outroStart: 185))
        // b was analysed from a 180 s file; its stream is 200 s.
        await h.reader.set(TransitionHarness.row("b", duration: 180, silenceStart: 0.5, introEnd: 8))
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(187.5)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode == .fixed)
        #expect(plan.incomingStartSec == 0)
    }

    // MARK: - The mirror

    @Test("the mirror holds the playing song and the next one, and drops older songs")
    func mirrorEvicts() async {
        let h = TransitionHarness()
        await h.standardRows()
        await h.reader.set(TransitionHarness.row("c"))
        await h.startQueue(["a", "b", "c"])
        #expect(Set(h.service.transitionAnalyses.keys) == ["a"])
        await h.tick(126)
        #expect(Set(h.service.transitionAnalyses.keys) == ["a", "b"])
        await h.tick(160)

        h.engine.advance()
        await h.settle()
        #expect(Set(h.service.transitionAnalyses.keys) == ["b"], "a is gone, c is not next yet")
    }

    @Test("the plan line carries ids only")
    func planLineIsIdsOnly() async throws {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(160)
        for line in h.service.transitionLines {
            #expect(!line.contains("://"))
            #expect(!line.contains("Song "))
        }
    }

    // MARK: - Review fixes

    @Test("Previous measures the 3 s restart rule from the song's trim offset, not from item time 0")
    func previousCountsFromTheStartOffset() async throws {
        let h = TransitionHarness()
        await h.reader.set(TransitionHarness.row("a", silenceEnd: 197, outroStart: 185))
        await h.reader.set(TransitionHarness.row("b", silenceStart: 5, introEnd: 12))
        await h.startQueue(["a", "b", "c"])
        await h.tick(126)
        await h.tick(160)
        let offset = try #require(h.lastPlan?.incomingStartSec)
        #expect(offset > 3)
        h.engine.advance()
        await h.settle()
        #expect(h.player.nowPlaying?.videoId == "b")
        #expect(h.player.currentTime == offset)
        #expect(h.player.playbackStartOffset == offset)

        // One second into the song (item time offset + 1): Previous goes back one song, it does not restart.
        h.engine.tick(offset + 1, playing: true)
        h.service.previous()
        await h.settle()
        #expect(h.player.nowPlaying?.videoId == "a")
        #expect(h.player.playbackStartOffset == 0, "a fresh load starts at 0")
    }

    @Test("Previous restarts a song that has played more than 3 s past its offset")
    func previousRestartsPastThreeSeconds() async throws {
        let h = TransitionHarness()
        await h.reader.set(TransitionHarness.row("a", silenceEnd: 197, outroStart: 185))
        await h.reader.set(TransitionHarness.row("b", silenceStart: 5, introEnd: 12))
        await h.startQueue(["a", "b", "c"])
        await h.tick(126)
        await h.tick(160)
        let offset = try #require(h.lastPlan?.incomingStartSec)
        h.engine.advance()
        await h.settle()
        h.engine.tick(offset + 4, playing: true)
        h.service.previous()
        await h.settle()
        #expect(h.player.nowPlaying?.videoId == "b")
    }

    private func finalPingMediaTime(restoringNaturalEnd: Bool) async throws -> Double {
        let h = TransitionHarness()
        await h.reader.set(TransitionHarness.row("a", silenceEnd: 197, outroStart: 185))
        await h.reader.set(TransitionHarness.row("b", silenceStart: 0.5, introEnd: 8))
        for id in ["a", "b"] {
            await h.backend.setStream(MusicSamples.stream(
                videoId: id,
                trackingURL: URL(string: "https://music.example.test/stats/playback?ev=\(id)"),
                watchtimeURL: URL(string: "https://music.example.test/stats/watchtime?ev=\(id)"),
                duration: 200
            ))
        }
        let tracks = ["a", "b"].map { MusicSamples.track($0, title: "Song \($0)") }
        await h.backend.setRadio(seed: "a", tracks: tracks, continuation: nil)
        h.service.play(tracks[0])
        await h.settle()
        h.engine.emit(.playingChanged(true))
        var position = 0.0
        while position < 160 {
            h.engine.tick(position, playing: true)
            position += 0.5
        }
        await h.tick(160)
        if restoringNaturalEnd {
            // A scrub near the trimmed end: the engine brings the natural end back and its plan loses the trimmed end.
            h.engine.debugRestoreNaturalEnd()
            h.engine.tick(190, playing: true)
        }
        h.engine.advance()
        await h.settle()
        let finals = await h.backend.reportAttempts.filter { $0.details?.isFinal == true }
        return try #require(finals.first, "a final ping went out").mediaTime
    }

    @Test("a final ping after a trimmed end carries the trimmed end, not the song's length")
    func finalPingIsCappedAtTheTrimmedEnd() async throws {
        let time = try await finalPingMediaTime(restoringNaturalEnd: false)
        #expect(time <= 197, "capped at the trimmed end: \(time)")
    }

    @Test("after a seek brought the natural end back the final ping is not capped")
    func finalPingIsNotCappedAfterASeekRestoredTheEnd() async throws {
        let time = try await finalPingMediaTime(restoringNaturalEnd: true)
        #expect(time > 197, "the song played to its natural end: \(time)")
    }

    @Test("Loop song turned on while a trimmed preload is parked withdraws it, and the next offer starts at 0")
    func loopSongWithdrawsATrimmedPreload() async throws {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b", "c"])
        await h.tick(126)
        await h.tick(160)
        #expect(h.lastPlan?.incomingStartSec == 0.5)
        let cancels = h.engine.cancelPreloadCount
        let updates = h.engine.updatedPlans.count

        h.service.setLoopMode(.song)

        #expect(h.engine.cancelPreloadCount == cancels + 1, "the parked standby is dropped")
        #expect(h.engine.updatedPlans.count == updates, "no plan is pushed at the old offset")
        await h.tick(186)
        let plan = try #require(h.lastPlan)
        #expect(plan.reason == .loopSong)
        #expect(plan.incomingStartSec == 0)
    }

    @Test("a setting change re-plans a parked preload once, and ticks after it add no update")
    func replanOnlyOnChange() async {
        let h = TransitionHarness()
        await h.standardRows()
        await h.startQueue(["a", "b"])
        await h.tick(126)
        await h.tick(160)
        h.service.setCrossfade(false)
        h.service.setShuffleMode(.off)
        #expect(h.engine.updatedPlans.count == 1)
        for position in stride(from: 165.0, to: 185, by: 5) { await h.tick(position) }
        #expect(h.engine.updatedPlans.count == 1)
        h.service.setCrossfade(true)
        #expect(h.engine.updatedPlans.count == 2)
    }
}
