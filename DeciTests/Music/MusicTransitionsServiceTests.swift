// DeciTests/Music/MusicTransitionsServiceTests.swift
// Shuffle only decides the order and Transitions only decides how songs hand over: Mixing works in playlist order, and
// Systematic shuffle with Crossfade orders the queue without a beat mix.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicService Transitions")
struct MusicTransitionsServiceTests {
    private func prefs(_ shuffle: MusicShuffleMode, _ transitions: MusicTransitionMode) -> MusicPlaybackPreferences {
        MusicPlaybackPreferences(shuffleMode: shuffle, transitionMode: transitions, crossfadeSeconds: 6)
    }

    private func start(_ h: BeatHarness) async {
        await h.reader.set(BeatHarness.row("a", period: 0.5))
        await h.reader.set(BeatHarness.row("b", period: BeatHarness.bPeriod))
        await h.startQueue(["a", "b"])
    }

    @Test("Mixing in playlist order: the planner is offered a beat mix though nothing is shuffled")
    func mixingInPlaylistOrder() async throws {
        let h = BeatHarness(preferences: prefs(.off, .mixing))
        #expect(!h.service.isShuffleOn)
        #expect(h.service.isBeatMixOn && h.service.mixesTransitions)
        await start(h)
        await h.tick(126)
        await h.tick(170)
        let plan = try #require(h.lastPlan, "lines: \(h.service.transitionLines)")
        #expect(plan.mode == .beat, "plan: \(plan)")
        #expect(h.service.queue.tracks.map(\.videoId) == ["a", "b"], "the order is the playlist's")
    }

    @Test("Systematic shuffle with Crossfade orders the queue but never mixes beats")
    func systematicWithCrossfade() async throws {
        let h = BeatHarness(preferences: prefs(.systematic, .crossfade))
        #expect(h.service.isShuffleOn)
        #expect(!h.service.isBeatMixOn)
        #expect(!h.service.isDJLengthOn)
        #expect(h.service.mixesTransitions)
        await start(h)
        await h.tick(126)
        await h.tick(220)
        let plan = try #require(h.lastPlan, "lines: \(h.service.transitionLines)")
        #expect(plan.mode == .fixed)
        #expect(plan.fadeSeconds == 6)
        #expect(!h.service.transitionLines.contains { $0.hasPrefix("transition_beat") })
    }

    @Test("Transitions Off is gapless, with or without Systematic shuffle")
    func transitionsOffIsGapless() {
        for shuffle in MusicShuffleMode.allCases {
            let h = BeatHarness(preferences: prefs(shuffle, .off))
            #expect(h.service.effectiveCrossfadeSeconds == 0)
            #expect(!h.service.mixesTransitions && !h.service.isBeatMixOn)
        }
        let on = BeatHarness(preferences: prefs(.off, .crossfade))
        #expect(on.service.effectiveCrossfadeSeconds == 6)
    }

    @Test("DJ length needs Mixing, whatever the order")
    func djLengthNeedsMixing() {
        let on = BeatHarness(
            preferences: MusicPlaybackPreferences(shuffleMode: .off, transitionMode: .mixing, crossfadeSeconds: 6, djLength: true)
        )
        #expect(on.service.isDJLengthOn)
        let crossfade = BeatHarness(
            preferences: MusicPlaybackPreferences(shuffleMode: .systematic, transitionMode: .crossfade, crossfadeSeconds: 6, djLength: true)
        )
        #expect(!crossfade.service.isDJLengthOn)
    }

    @Test("Up next tempo and key texts show in Systematic shuffle or in Mixing, not otherwise")
    func infoShows() {
        #expect(BeatHarness(preferences: prefs(.systematic, .off)).service.showsMixInfo)
        #expect(BeatHarness(preferences: prefs(.off, .mixing)).service.showsMixInfo)
        #expect(!BeatHarness(preferences: prefs(.off, .crossfade)).service.showsMixInfo)
        #expect(!BeatHarness(preferences: prefs(.off, .off)).service.showsMixInfo)
    }

    @Test("changing Transitions cycles Off, Crossfade, Mixing and leaves the order alone")
    func changeLeavesOrder() async {
        let h = BeatHarness(preferences: prefs(.systematic, .mixing))
        h.service.setTransitionMode(.crossfade)
        #expect(h.service.transitionMode == .crossfade)
        #expect(h.service.isShuffleOn, "the order is Shuffle's business")
        #expect(!h.service.isBeatMixOn)
        h.service.cycleTransitionMode()
        #expect(h.service.transitionMode == .mixing)
        h.service.cycleTransitionMode()
        #expect(h.service.transitionMode == .off)
    }

    @Test("the favourite slot's raw crossfade still decodes, and its button cycles Transitions")
    func favouriteSlot() {
        let slots = MusicFavoriteSlots(leftRaw: "crossfade", rightRaw: "like")
        #expect(slots.left == .transitions)
        #expect(slots.leftRaw == "crossfade")
        let h = BeatHarness(preferences: prefs(.off, .off))
        h.service.perform(.transitions)
        #expect(h.service.transitionMode == .crossfade)
        h.service.perform(.transitions)
        #expect(h.service.transitionMode == .mixing)
        h.service.perform(.transitions)
        #expect(h.service.transitionMode == .off)
    }

    @Test("a manual Next under Crossfade leaves no applied style, so Mixing later avoids nothing")
    func manualNextUnderCrossfadeLeavesNoStyle() async {
        let h = BeatHarness(preferences: prefs(.off, .crossfade))
        await start(h)
        await h.tick(126)
        await h.tick(170)
        h.service.next()
        #expect(h.service.lastAppliedStyle == nil)
    }
}

@MainActor
@Suite("MusicService Transitions and Up next info")
struct MusicTransitionsInfoTests {
    @Test("leaving Mixing drops the Up next pairs with shuffle Off and keeps them with Systematic shuffle on")
    func pairsFollowTheOrderAndMixing() async {
        let kept = MixShuffleHarness(preferences: MusicPlaybackPreferences(
            shuffleMode: .systematic, transitionMode: .mixing, crossfadeSeconds: 6))
        await kept.storeRows()
        await kept.startQueue()
        await kept.settle()
        #expect(!kept.service.mixPairs.isEmpty)
        kept.service.setTransitionMode(.crossfade)
        #expect(!kept.service.mixPairs.isEmpty, "Systematic shuffle still shows them")

        let dropped = MixShuffleHarness()
        await dropped.storeRows()
        await dropped.startQueue()
        dropped.service.setTransitionMode(.mixing)
        await dropped.settle()
        #expect(!dropped.service.mixPairs.isEmpty, "Mixing alone shows them")
        dropped.service.setTransitionMode(.crossfade)
        #expect(dropped.service.mixPairs.isEmpty)
    }
}
