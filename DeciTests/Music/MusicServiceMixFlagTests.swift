// DeciTests/Music/MusicServiceMixFlagTests.swift
// Tier 2b P4: the service reads the no-mix flags into every transition plan. A flagged song, or a flagged pair, gets the
// clean plan (no overlap, trims kept); a skip into it still quick fades; unflagging restores mixing, also while a preload
// is parked; the menu helpers list and flip the flags.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct MixHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let connectivity = MusicConnectivity(isOnline: true)
    let provider = FakeAnalysisProvider()
    let reader = FakeAnalysisReader()
    let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/mixflags-service", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let flags: MusicMixFlagStore
    let player: MusicPlayer
    let service: MusicService

    init() {
        let engine = self.engine
        let clock = self.clock
        flags = MusicMixFlagStore(
            fileURL: directory.appendingPathComponent("MusicMixFlags.json"), now: { clock.now },
            scheduler: ManualWriteScheduler(clock: clock)
        )
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
            preferences: MusicPlaybackPreferences(crossfade: true, crossfadeSeconds: 6),
            queueRetryDelay: .seconds(60),
            connectivity: connectivity,
            refreshOnCreate: false,
            analysis: provider,
            analysisReader: reader,
            mixFlags: flags
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func standardRows(bLufs: Double = -14) async {
        await reader.set(MusicTransitionPlannerTests.analysis("a", duration: 200, silenceEnd: 197, outroStart: 185))
        await reader.set(
            MusicTransitionPlannerTests.analysis("b", duration: 200, silenceStart: 0.5, introEnd: 8, lufs: bLufs)
        )
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

    func startQueue(_ ids: [String]) async {
        for id in ids { await backend.setStream(MusicSamples.stream(videoId: id, duration: 200)) }
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

    /// Plays a to the offer of b.
    func offerB() async {
        await standardRows()
        await startQueue(["a", "b", "c"])
        await tick(126)
        await tick(160)
    }

    var lastPlan: TransitionPlan? { engine.plans.last ?? nil }
}

@MainActor
@Suite("MusicService no-mix flags")
struct MusicServiceMixFlagTests {
    @Test("no flags: the plan is smart, as before")
    func unflaggedIsSmart() async {
        let h = MixHarness()
        defer { h.cleanUp() }
        await h.offerB()
        #expect(h.lastPlan?.mode == .smart)
    }

    @Test("a song flagged Always start clean gets the clean plan: no overlap, trims kept")
    func flaggedSongIsClean() async throws {
        let h = MixHarness()
        defer { h.cleanUp() }
        h.flags.setStartsClean(true, videoId: "b")
        await h.offerB()

        let plan = try #require(h.lastPlan)
        #expect(plan.mode == .clean)
        #expect(plan.reason == .noMix)
        #expect(plan.fadeSeconds == 0)
        #expect(plan.fadeStartSec == nil)
        #expect(plan.incomingStartSec == 0.5)
        #expect(plan.outgoingEndSec == 197)
        #expect(plan.incomingGainDb == 0)
        #expect(plan.outgoingGainDb == 0)
        #expect(h.service.transitionLines.first?.contains("mode=clean") == true)
    }

    @Test("a flagged pair a into b gets the clean plan")
    func flaggedPairIsClean() async throws {
        let h = MixHarness()
        defer { h.cleanUp() }
        h.flags.setPairClean(true, from: "a", to: "b")
        await h.offerB()
        let plan = try #require(h.lastPlan)
        #expect(plan.mode == .clean)
        #expect(plan.reason == .noMix)
        #expect(plan.incomingStartSec == 0.5)
    }

    @Test("the pair is ordered: b into a flagged does not clean a into b")
    func reversedPairDoesNotMatch() async {
        let h = MixHarness()
        defer { h.cleanUp() }
        h.flags.setPairClean(true, from: "b", to: "a")
        await h.offerB()
        #expect(h.lastPlan?.mode == .smart)
    }

    @Test("flagging a different song leaves this transition mixing")
    func otherSongFlagDoesNotMatch() async {
        let h = MixHarness()
        defer { h.cleanUp() }
        h.flags.setStartsClean(true, videoId: "c")
        await h.offerB()
        #expect(h.lastPlan?.mode == .smart)
    }

    @Test("a manual skip into a flagged song still gets the 0.3 s quick fade")
    func skipIntoFlaggedSongStillQuickFades() async throws {
        let h = MixHarness()
        defer { h.cleanUp() }
        h.flags.setStartsClean(true, videoId: "b")
        await h.offerB()
        #expect(h.lastPlan?.mode == .clean)

        h.service.next()
        await h.settle()

        #expect(h.engine.manualCrossfades == [0.3])
        let skip = try #require(h.engine.updatedPlans.last ?? nil)
        #expect(skip.mode == .fixed)
        #expect(skip.fadeSeconds == 0.3)
        #expect(skip.incomingStartSec == 0.5)
    }

    @Test("flagging while a preload is parked re-plans through updateTransitionPlan, same park offset, no re-preload")
    func flaggingReplans() async throws {
        let h = MixHarness()
        defer { h.cleanUp() }
        await h.offerB()
        #expect(h.lastPlan?.mode == .smart)
        let cancels = h.engine.cancelPreloadCount

        h.service.performMix(.startClean(on: false), for: MusicSamples.track("b", title: "Song b"))

        let plan = try #require(h.engine.updatedPlans.last ?? nil)
        #expect(plan.mode == .clean)
        #expect(plan.incomingStartSec == 0.5)
        #expect(plan.outgoingEndSec == 197)
        #expect(h.engine.preloads.count == 1)
        #expect(h.engine.cancelPreloadCount == cancels)
    }

    @Test("unflagging while a preload is parked restores mixing")
    func unflaggingRestoresMixing() async throws {
        let h = MixHarness()
        defer { h.cleanUp() }
        h.flags.setStartsClean(true, videoId: "b")
        await h.offerB()
        #expect(h.lastPlan?.mode == .clean)

        h.service.performMix(.startClean(on: true), for: MusicSamples.track("b", title: "Song b"))

        let plan = try #require(h.engine.updatedPlans.last ?? nil)
        #expect(plan.mode == .smart)
        #expect(plan.fadeStartSec == 185)
        #expect(!h.flags.startsClean("b"))
    }

    @Test("a flag set after the transition is past changes nothing and sends no update")
    func flagWithoutPreloadSendsNothing() async {
        let h = MixHarness()
        defer { h.cleanUp() }
        await h.standardRows()
        await h.startQueue(["a", "b", "c"])
        h.service.performMix(.startClean(on: false), for: MusicSamples.track("b", title: "Song b"))
        #expect(h.engine.updatedPlans.isEmpty)
        #expect(h.flags.startsClean("b"))
    }

    // MARK: - Menu helpers

    @Test("a song that is not playing lists one entry, worded for its flag")
    func rowList() async {
        let h = MixHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c"])
        let c = MusicSamples.track("c", title: "Song c")
        #expect(h.service.mixItems(for: c, includingPrevious: true) == [.startClean(on: false)])
        h.flags.setStartsClean(true, videoId: "c")
        #expect(h.service.mixItems(for: c, includingPrevious: true) == [.startClean(on: true)])
    }

    @Test("the first song playing lists one entry, the second lists two")
    func nowPlayingList() async {
        let h = MixHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c"])
        let a = MusicSamples.track("a", title: "Song a")
        #expect(h.service.mixItems(for: a, includingPrevious: true) == [.startClean(on: false)])

        h.service.next()
        await h.settle()
        let b = MusicSamples.track("b", title: "Song b")
        #expect(h.service.mixItems(for: b, includingPrevious: true) == [.startClean(on: false), .cleanAfterPrevious(on: false)])
        #expect(h.service.mixItems(for: b, includingPrevious: false) == [.startClean(on: false)])
    }

    @Test("picking the pair entry flags previous into this song, and picking it again clears it")
    func pairPick() async {
        let h = MixHarness()
        defer { h.cleanUp() }
        await h.startQueue(["a", "b", "c"])
        h.service.next()
        await h.settle()
        let b = MusicSamples.track("b", title: "Song b")

        h.service.performMix(.cleanAfterPrevious(on: false), for: b)
        #expect(h.flags.pairIsClean(from: "a", to: "b"))
        #expect(!h.flags.pairIsClean(from: "b", to: "a"))
        #expect(h.service.mixItems(for: b, includingPrevious: true).last == .cleanAfterPrevious(on: true))

        h.service.performMix(.cleanAfterPrevious(on: true), for: b)
        #expect(!h.flags.pairIsClean(from: "a", to: "b"))
    }

    @Test("a service with no flag store lists nothing and flips nothing")
    func noStoreNoItems() async {
        let backend = FakeMusicBackend()
        let service = MusicService(
            backend: backend, player: MusicPlayer(engine: FakePlaybackEngine()), presentSignIn: { _ in },
            presentChannelPicker: { _, _ in }, closeSignInWindow: {}, raiseSignInWindow: {},
            refreshOnCreate: false
        )
        let track = MusicSamples.track("a", title: "Song a")
        #expect(service.mixItems(for: track, includingPrevious: true).isEmpty)
        service.performMix(.startClean(on: false), for: track)
    }
}
