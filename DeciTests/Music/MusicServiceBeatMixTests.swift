// DeciTests/Music/MusicServiceBeatMixTests.swift
// Tier 3b P3: the service offers the engine a beat plan when both songs have a grid and the setting is on, gives up the
// pair for the smart plan when the next song is not parked in time or the mix point is too near, and never changes the
// standby's park offset on a replan. A fake engine, provider and row reader stand in for the real ones.

import Foundation
import Testing
@testable import Deci

@MainActor
struct BeatHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let connectivity = MusicConnectivity(isOnline: true)
    let provider = FakeAnalysisProvider()
    let reader = FakeAnalysisReader()
    let player: MusicPlayer
    let service: MusicService

    init(
        crossfade: Bool = true, beatMix: Bool = true, preferences: MusicPlaybackPreferences? = nil,
        djLength: (@MainActor () -> Bool)? = nil
    ) {
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
            preferences: preferences ?? MusicPlaybackPreferences(crossfade: crossfade, crossfadeSeconds: 6, beatMix: beatMix),
            djLength: djLength,
            queueRetryDelay: .seconds(60),
            connectivity: connectivity,
            refreshOnCreate: false,
            analysis: provider,
            analysisReader: reader
        )
    }

    /// Row of a 240 s song ending at 236 with the outro at 200, carrying a beat grid.
    static func row(_ id: String, period: Double, grid: Bool = true, introEnd: Double = 8) -> MusicAnalysis {
        var row = MusicTransitionPlannerTests.analysis(
            id, duration: 240, silenceStart: id == "a" ? 0 : 0.1, silenceEnd: id == "a" ? 236 : nil,
            introEnd: id == "a" ? nil : introEnd, outroStart: id == "a" ? 200 : nil
        )
        if grid {
            row.beatGrid = MusicBeatPlannerTests.grid(
                period: period, anchor: id == "a" ? 0.2 : 0.1, phase: id == "a" ? 0 : 1,
                span: (id == "a" ? 0.2 : 0.1)...236
            ).encode()
        }
        return row
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

    func startQueue(_ ids: [String], duration: Double = 240) async {
        for id in ids { await backend.setStream(MusicSamples.stream(videoId: id, duration: duration)) }
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)") }
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
    }

    func tick(_ position: TimeInterval) async {
        engine.tick(position, playing: true)
        await service.prefetchTask?.value
        await service.analysisTask?.value
        engine.tick(position + 0.5, playing: true)
    }

    var lastPlan: TransitionPlan? { engine.plans.last ?? nil }

    /// What the planner makes of the two standard rows, for the mix point to aim ticks at.
    static func expectedBeatPlan(aPeriod: Double = 0.5, bPeriod: Double = 0.48, bassSwap: Bool = true) -> TransitionPlan {
        var inputs = MusicBeatPlannerTests.inputs(
            a: MusicBeatPlannerTests.grid(period: aPeriod, anchor: 0.2, phase: 0),
            b: MusicBeatPlannerTests.grid(period: bPeriod, anchor: 0.1, phase: 1, span: 0.1...236)
        )
        inputs.beatMixEnabled = true
        inputs.bassSwapAvailable = bassSwap
        return MusicBeatPlannerTests.plan(inputs)
    }
}

@MainActor
@Suite("MusicService beat mix")
struct MusicServiceBeatMixTests {
    private func start(_ h: BeatHarness, bGrid: Bool = true) async {
        await h.reader.set(BeatHarness.row("a", period: 0.5))
        await h.reader.set(BeatHarness.row("b", period: 0.48, grid: bGrid))
        await h.startQueue(["a", "b", "c"])
    }

    @Test("both grids present and the setting on: the engine gets a beat plan, and the log says so")
    func beatPlanAtOffer() async throws {
        let h = BeatHarness()
        await start(h)
        await h.tick(126)
        await h.tick(170)
        #expect(h.engine.preloads.count == 1)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode == .beat, "plan: \(plan) lines: \(h.service.transitionLines)")
        #expect(plan.incomingRate < 1 && abs(plan.incomingRate - 0.96) < 0.001)
        #expect(plan.mixOutSec != nil && plan.mixInSec != nil)
        #expect(plan.fadeStartSec == plan.mixOutSec)
        #expect(plan.incomingStartSec == plan.mixInSec)
        #expect(plan.fadeSeconds == plan.overlapSec)
        #expect(plan.bassSwapAtSec != nil && plan.bassHandoverSec > 0, "the service offers the bass swap")
        #expect(h.service.transitionLines.contains { $0.hasPrefix("transition_beat_plan from=a to=b") })
    }

    @Test("the setting off gives the smart plan and no beat line")
    func settingOffGivesSmart() async throws {
        let h = BeatHarness(beatMix: false)
        await start(h)
        await h.tick(126)
        await h.tick(205)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode != .beat)
        #expect(plan.incomingRate == 1)
        #expect(!h.service.transitionLines.contains { $0.hasPrefix("transition_beat") })
    }

    @Test("Crossfade off gives no beat plan whatever the beat setting says")
    func crossfadeOffGivesNoBeat() async throws {
        let h = BeatHarness(crossfade: false, beatMix: true)
        await start(h)
        await h.tick(126)
        await h.tick(222)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode != .beat)
        #expect(plan.incomingRate == 1)
    }

    @Test("a next song without a grid gives the smart plan and a beat_fallback line with the reason")
    func missingGridFallsBack() async throws {
        let h = BeatHarness()
        await start(h, bGrid: false)
        await h.tick(126)
        await h.tick(205)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode != .beat)
        #expect(h.service.transitionLines.contains { $0.hasPrefix("transition_beat_fallback from=a to=b reason=") })
    }

    @Test("a beat plan opens its window at 70 s before the trimmed end, not before")
    func beatWindow() async {
        let h = BeatHarness()
        await start(h)
        await h.tick(126)
        await h.tick(164)
        #expect(h.engine.preloads.isEmpty, "236 - 70 = 166: not yet at 164.5")
        await h.tick(166)
        #expect(h.engine.preloads.count == 1)
    }

    @Test("the next song not parked 8 s before the mix point gives the pair up: smart plan, preload offered again")
    func notReadyFallsBackToSmart() async throws {
        let h = BeatHarness()
        await start(h)
        await h.tick(126)
        h.engine.preloadReady = false
        await h.tick(170)
        let first = try #require(h.lastPlan)
        #expect(first.mode == .beat)
        let mixOut = try #require(first.mixOutSec)
        let cancels = h.engine.cancelPreloadCount
        await h.tick(mixOut - 9)
        #expect(h.engine.cancelPreloadCount == cancels, "still time to park")
        await h.tick(mixOut - 7.9)
        #expect(h.engine.cancelPreloadCount == cancels + 1)
        #expect(h.service.transitionLines.contains { $0.hasPrefix("transition_beat_fallback from=a to=b reason=notReady") })
        // The smart lead (37 s from the end) opens the window again later than the beat lead did.
        await h.tick(max(mixOut - 6, 210))
        #expect(h.engine.preloads.count == 2, "offered again")
        let second = try #require(h.lastPlan)
        #expect(second.mode != .beat)
        #expect(second.incomingRate == 1)
    }

    @Test("a mix point nearer than the preroll gives smart (tooLate) instead of a beat plan the engine cannot meet")
    func earliestMixOutGivesSmart() async throws {
        let h = BeatHarness()
        await start(h)
        // The 8-bar plan (the later mix point): a 16-bar one no longer fits, so the planner drops to 8.
        let expected = BeatHarness.expectedBeatPlan(bassSwap: false)
        let mixOut = try #require(expected.mixOutSec)
        await h.tick(126)
        // The first offer comes when the playhead is already within the preroll of the mix point.
        await h.tick(mixOut - 4)
        let plan = try #require(h.lastPlan)
        #expect(plan.mode != .beat)
        #expect(plan.incomingRate == 1)
        #expect(h.service.transitionLines.contains { $0.contains("reason=tooLate") })
    }

    @Test("a late row replan keeps the park offset: the plan the engine already holds is never moved")
    func lateRowKeepsParkOffset() async throws {
        let h = BeatHarness()
        await h.reader.set(BeatHarness.row("a", period: 0.5))
        await h.startQueue(["a", "b"])
        let gate = MusicTestGate()
        await h.provider.hold("b", gate)
        await h.engine.tickNoGate(h.service, at: 126)
        await h.engine.tickNoGate(h.service, at: 232)
        let before = try #require(h.lastPlan)
        await h.reader.set(BeatHarness.row("b", period: 0.48))
        await gate.open()
        await h.service.analysisTask?.value
        #expect(h.lastPlan == before)
        #expect(h.engine.updatedPlans.isEmpty)
        h.service.setCrossfade(false)
        if let updated = h.engine.updatedPlans.last ?? nil {
            #expect(updated.incomingStartSec == before.incomingStartSec)
            #expect(updated.incomingRate == 1)
        }
    }

    @Test("toggling Crossfade off under a beat plan whose preload is still loading withdraws it")
    func toggleUnderBeatPlanNotReadyRepreloads() async throws {
        let h = BeatHarness()
        await start(h)
        await h.tick(126)
        await h.tick(170)
        #expect(h.lastPlan?.mode == .beat)
        h.engine.preloadReady = false
        let cancels = h.engine.cancelPreloadCount
        h.service.setCrossfade(false)
        #expect(h.engine.cancelPreloadCount == cancels + 1)
        #expect(h.engine.updatedPlans.isEmpty)
    }

    @Test("a replan inside the last seconds keeps a ready preload: the plan goes non-beat at the same park offset")
    func lateReplanKeepsReadyPreload() async throws {
        let h = BeatHarness()
        await start(h)
        await h.tick(126)
        await h.tick(170)
        let beat = try #require(h.lastPlan)
        #expect(beat.mode == .beat)
        let mixOut = try #require(beat.mixOutSec)
        await h.tick(mixOut - 7.5)
        let cancels = h.engine.cancelPreloadCount
        h.service.setCrossfade(false)
        #expect(h.engine.cancelPreloadCount == cancels, "the ready preload stays")
        let updated = try #require(h.engine.updatedPlans.last ?? nil)
        #expect(updated.mode != .beat)
        #expect(updated.incomingRate == 1)
        #expect(updated.incomingStartSec == beat.incomingStartSec)
    }

    @Test("a manual skip on a beat preload hands the engine the skip plan, at the beat plan's park offset")
    func manualSkipOnBeatPreload() async throws {
        let h = BeatHarness()
        await start(h)
        await h.tick(126)
        await h.tick(170)
        let beat = try #require(h.lastPlan)
        #expect(beat.mode == .beat)
        h.service.next()
        let updated = try #require(h.engine.updatedPlans.last ?? nil)
        #expect(updated.mode == .fixed)
        #expect(updated.incomingRate == 1)
        #expect(updated.incomingStartSec == beat.incomingStartSec)
        #expect(h.engine.transitionPlan?.mode == .fixed)
    }
}

@MainActor
@Suite("MusicService drop swap skip", .serialized)
struct MusicServiceDropSwapSkipTests {
    /// A drop swap offered for a to b: b has a loud step at 40 s on a bar line, so its standby parks deep in the song.
    private func offered(_ h: BeatHarness) async -> TransitionPlan? {
        var a = BeatHarness.row("a", period: 0.5)
        a.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.4).encode()
        var b = BeatHarness.row("b", period: 0.48)
        b.energy = DropFixtures.envelope(seconds: 240, steps: [40])
        b.keyInfo = MusicKeyInfo(tonic: 0, isMinor: false, confidence: 0.5, energy: 0.7).encode()
        await h.reader.set(a)
        await h.reader.set(b)
        await h.startQueue(["a", "b", "c"])
        // Scoped to this task: a plan test running beside this one never sees the forced style.
        await MusicTransitionStylePicker.$debugScopedStyle.withValue(.dropSwap) {
            await h.tick(126)
            await h.tick(170)
        }
        return h.lastPlan
    }

    @Test("Next on a pending drop swap takes the ordinary load: no crossfade into a song parked deep at its drop lead")
    func nextOnDropSwapDoesNotCrossfade() async throws {
        let h = BeatHarness()
        let plan = try #require(await offered(h))
        #expect(plan.style == .dropSwap, "plan: \(plan) lines: \(h.service.transitionLines)")
        #expect((plan.mixInSec ?? 0) > 10, "the standby is parked deep: \(plan.mixInSec ?? -1)")
        #expect(MusicService.parksDeepForDropSwap(plan))
        h.service.next()
        #expect(h.engine.manualCrossfades.isEmpty, "a skip must not start the song at its drop lead")
    }

    @Test("only a drop swap parked more than a bar from the normal start counts as deep")
    func deepRule() {
        var plan = TransitionPlan(
            mode: .beat, incomingStartSec: 30, outgoingEndSec: nil, fadeStartSec: 100,
            fadeSeconds: 8, incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok
        )
        plan.mixInSec = 30
        plan.barSec = 2
        plan.fallbackIncomingStartSec = 1
        plan.style = .dropSwap
        #expect(MusicService.parksDeepForDropSwap(plan))
        plan.mixInSec = 2.5
        #expect(!MusicService.parksDeepForDropSwap(plan))
        plan.mixInSec = 30
        plan.style = .longBlend
        #expect(!MusicService.parksDeepForDropSwap(plan))
    }
}

@MainActor
private extension FakePlaybackEngine {
    /// A tick that does not wait for the held analysis job.
    func tickNoGate(_ service: MusicService, at position: TimeInterval) async {
        tick(position, playing: true)
        await service.prefetchTask?.value
        tick(position + 0.5, playing: true)
    }
}
