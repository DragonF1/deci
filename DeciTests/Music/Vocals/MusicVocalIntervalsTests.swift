// DeciTests/Music/Vocals/MusicVocalIntervalsTests.swift
// Tier 3d-4: sung intervals from synced lyrics, the interval collision maths, and both planners using them.

import Foundation
import Testing
@testable import Deci

@Suite("MusicVocalIntervals")
struct MusicVocalIntervalsTests {
    typealias I = MusicVocalIntervals

    @Test("a line is padded 0.3 s each side and adjacent lines merge")
    func padAndMerge() {
        let l = [LyricLine(time: 10, text: "a", end: 12), LyricLine(time: 12.4, text: "b", end: 14)]
        #expect(I.from(lines: l, duration: 100) == [9.7...14.3])
    }

    @Test("a gap between lines stays a gap")
    func gapKept() {
        let l = [LyricLine(time: 10, text: "a", end: 12), LyricLine(time: 30, text: "b", end: 31)]
        #expect(I.from(lines: l, duration: 100) == [9.7...12.3, 29.7...31.3])
    }

    @Test("a line without an end runs to the next line, capped at 8 s")
    func capEightSeconds() {
        let l = [LyricLine(time: 10, text: "a"), LyricLine(time: 60, text: "b", end: 61)]
        #expect(I.from(lines: l, duration: 100)[0] == 9.7...18.3)
        let short = [LyricLine(time: 10, text: "a"), LyricLine(time: 13, text: "b", end: 14)]
        #expect(I.from(lines: short, duration: 100) == [9.7...14.3])
    }

    @Test("empty text is an instrumental gap, and no lines or no duration is no singing")
    func emptyAndInstrumental() {
        let l = [LyricLine(time: 10, text: "a", end: 11), LyricLine(time: 11, text: " "), LyricLine(time: 40, text: "b", end: 41)]
        #expect(I.from(lines: l, duration: 100).count == 2)
        #expect(I.from(lines: [], duration: 100).isEmpty)
        #expect(I.from(lines: l, duration: 0).isEmpty)
        #expect(I.from(lines: l, duration: .nan).isEmpty)
    }

    @Test("clamped to the song, unsorted and non finite lines tolerated")
    func clampAndOrder() {
        let l = [LyricLine(time: 98, text: "b", end: 120), LyricLine(time: .nan, text: "x"), LyricLine(time: 0.1, text: "a", end: 2)]
        let r = I.from(lines: l, duration: 100)
        #expect(r.first?.lowerBound == 0 && r.last?.upperBound == 100 && r.count == 2)
    }

    @Test("a last line with no end runs to the 8 s cap, so a late overlap against vocals collides")
    func openLastLine() {
        let r = I.from(lines: [LyricLine(time: 100, text: "a", end: 101), LyricLine(time: 200, text: "last")], duration: 240)
        #expect(r.last == 199.7...208.3)
        let capped = I.from(lines: [LyricLine(time: 238, text: "last")], duration: 240)
        #expect(capped == [237.7...240])
        // A 16 bar (32 s) overlap from 196 against incoming vocals from the start.
        let wall = MusicVocalGuardIntervals.collisionSec(
            a: r, b: [0...100], outroStartA: 0, introEndB: 0, outStart: 196, inStart: 0, length: 32)
        #expect(wall > MusicVocalGuard.budgetSec)
    }

    // MARK: Collision

    private func c(_ a: [ClosedRange<Double>]?, _ b: [ClosedRange<Double>]?, rate: Double = 1) -> Double {
        MusicVocalGuardIntervals.collisionSec(
            a: a, b: b, outroStartA: 100, introEndB: 20, outStart: 90, inStart: 0, rate: rate, length: 16
        )
    }

    @Test("intervals on one side use the proxy span on the other")
    func oneSide() {
        #expect(c(nil, nil) == 0)
        #expect(c([50...92], [6...60]) == 0)
        #expect(c(nil, [6...60]) == 4)
        #expect(c([90...95], nil) == 0)
    }

    @Test("both sides: overlapping wall time is summed, instrumental is empty")
    func bothSides() {
        #expect(c([90...95], [2...5]) == 3)
        // A wall 0...3 and 6...10, B wall 1...3 and 6...8: 2 + 2.
        #expect(c([90...93, 96...100], [1...3, 6...8]) == 4)
        #expect(c([], [0...100]) == 0 && c([90...100], []) == 0)
    }

    @Test("the incoming intervals map through the rate")
    func rateMapping() {
        // B song 4 is wall 2 at rate 2; A sings wall 0...10: overlap 2...10.
        #expect(abs(c([90...100], [4...100], rate: 2) - 8) < 1e-9)
    }

    @Test("the guard wrapper: nil intervals equal the proxy, intervals work without analysis")
    func wrapper() {
        let a = MusicTransitionPlannerTests.analysis("a", outroStart: 100)
        let b = MusicTransitionPlannerTests.analysis("b", introEnd: 4)
        let proxy = MusicVocalGuard.collisionSec(outgoing: a, incoming: b, outStart: 90, inStart: 0, length: 16)
        #expect(proxy == MusicVocalGuard.collisionSec(
            outroStartA: 100, introEndB: 4, outStart: 90, inStart: 0, length: 16))
        #expect(MusicVocalGuard.collisionSec(
            outgoing: nil, incoming: nil, outStart: 90, inStart: 0, length: 16,
            outgoingIntervals: [90...95], incomingIntervals: [2...5]) == 3)
        #expect(MusicVocalGuard.collisionSec(
            outgoing: nil, incoming: nil, outStart: 90, inStart: 0, length: 16, incomingIntervals: [2...5]) == nil)
    }

    // MARK: Planners

    @Test("beat planner: lyrics show a gap the proxy refuses, so the 16 bar overlap is kept")
    func beatPicksLongerOverlap() {
        let proxyPlan = MusicBeatPlannerTests.plan(MusicBeatPlannerTests.guardedInputs(outro: 208, swap: true))
        #expect(proxyPlan.overlapBars == 8)
        var i = MusicBeatPlannerTests.guardedInputs(outro: 208, swap: true)
        i.outgoing.vocalIntervals = [20...150]
        i.incoming.vocalIntervals = [30...200]
        let lyricsPlan = MusicBeatPlannerTests.plan(i)
        #expect(lyricsPlan.mode == .beat && lyricsPlan.overlapBars == 16 && lyricsPlan.vocalAction == nil)
    }

    @Test("beat planner: lyrics show a clash the proxy missed, so a shorter overlap is picked")
    func beatAvoidsHiddenClash() {
        let off = MusicBeatPlannerTests.plan(MusicBeatPlannerTests.guardedInputs(outro: 150, swap: true))
        #expect(off.overlapBars == 16)
        var i = MusicBeatPlannerTests.guardedInputs(outro: 150, swap: true)
        i.outgoing.vocalIntervals = [0...240]
        i.incoming.vocalIntervals = [0...240]
        let plan = MusicBeatPlannerTests.plan(i)
        #expect(plan.mode == .smart && plan.fallbackReason == "vocalClash" && (plan.vocalBeforeSec ?? 0) > MusicVocalGuard.budgetSec)
    }

    @Test("smart planner: lyrics clean a fade the proxy would shorten, and a hidden clash shortens it")
    func smartUsesIntervals() {
        let (proxyInputs, plan) = MusicTransitionPlannerTests.collidingSmart(outro: 195, bIntroEnd: 4)
        #expect(MusicTransitionPlanner.vocalGuarded(plan, proxyInputs).vocalAction == "shorten")
        var quiet = proxyInputs
        quiet.outgoing.vocalIntervals = [20...170]
        quiet.incoming.vocalIntervals = [30...200]
        #expect(MusicTransitionPlanner.vocalGuarded(plan, quiet) == plan)
        var hidden = MusicTransitionPlannerTests.collidingSmart(outro: 150, bIntroEnd: 30).0
        hidden.outgoing.vocalIntervals = [0...197]
        hidden.incoming.vocalIntervals = [0...200]
        let guarded = MusicTransitionPlanner.vocalGuarded(plan, hidden)
        #expect(guarded.vocalAction != nil && guarded.fadeSeconds < plan.fadeSeconds)
    }

    @Test("the plan log carries vocal=lyrics|proxy per side")
    func logField() {
        let plan = TransitionPlan.tier1Gapless
        let line = MusicTransitionLog.planLine(from: "a", to: "b", plan: plan, outgoingDuration: 200, vocal: (true, false))
        #expect(line.hasSuffix(" vocal=lyrics/proxy"))
        #expect(!MusicTransitionLog.planLine(from: "a", to: "b", plan: plan, outgoingDuration: 200).contains("vocal="))
    }
}

@MainActor
@Suite("MusicVocalLookahead")
struct MusicVocalLookaheadTests {
    private struct Boom: Error {}
    private actor Calls {
        var cache = 0, youtube = 0, stored = 0
        func hitCache() { cache += 1 }
        func hitYouTube() { youtube += 1 }
        func hitStore() { stored += 1 }
    }
    private nonisolated static let query = LyricsQuery(videoId: "vid", title: "t", artist: "a", album: nil, duration: 200)
    private nonisolated static let synced = LyricsAnswer(
        result: .synced([LyricLine(time: 10, text: "a", end: 12)]), credit: "yt", lengthMatters: false)

    private func make(
        cached: LyricsAnswer? = nil, remote: @escaping @Sendable () async throws -> LyricsAnswer,
        timeout: Double = 3, calls: Calls = Calls()
    ) -> (MusicVocalLookahead, Calls) {
        (MusicVocalLookahead(
            readCache: { _ in await calls.hitCache(); return cached },
            youtube: { _ in await calls.hitYouTube(); return try await remote() },
            store: { _, _, _ in await calls.hitStore() }, timeoutSec: timeout), calls)
    }

    @Test("a cache hit makes no network request")
    func cacheFirst() async {
        let (l, calls) = make(cached: Self.synced, remote: { throw Boom() })
        await l.prepare(Self.query, duration: 200, allowNetwork: true)
        #expect(l.intervals(for: "vid") == [9.7...12.3])
        let yt = await calls.youtube
        #expect(yt == 0)
    }

    @Test("a miss asks YouTube Music once, stores the answer, and a cached instrumental is empty")
    func missFetches() async {
        let (l, calls) = make(remote: { Self.synced })
        await l.prepare(Self.query, duration: 200, allowNetwork: true)
        await l.prepare(Self.query, duration: 200, allowNetwork: true)
        #expect(l.intervals(for: "vid") == [9.7...12.3])
        let (yt, st) = (await calls.youtube, await calls.stored)
        #expect(yt == 1 && st == 1)
        let (inst, _) = make(cached: LyricsAnswer(result: .instrumental, credit: nil), remote: { throw Boom() })
        await inst.prepare(Self.query, duration: 200, allowNetwork: true)
        #expect(inst.intervals(for: "vid") == [])
    }

    @Test("offline or network not allowed: cache only, nothing sent")
    func noNetwork() async {
        let (l, calls) = make(remote: { Self.synced })
        await l.prepare(Self.query, duration: 200, allowNetwork: false)
        let yt = await calls.youtube
        #expect(l.intervals(for: "vid") == nil && l.hasRequested("vid") == false)
        #expect(yt == 0)
    }

    @Test("failure, plain, not found and a cached plain answer leave the proxy")
    func unknownStaysNil() async {
        for remote in [LyricsAnswer(result: .plain("x"), credit: nil), LyricsAnswer(result: .notFound, credit: nil)] {
            let (l, calls) = make(remote: { remote })
            await l.prepare(Self.query, duration: 200, allowNetwork: true)
            let stored = await calls.stored
            #expect(l.intervals(for: "vid") == nil)
            #expect(stored == 0, "plain and not found are never written to the cache")
        }
        let (failing, _) = make(remote: { throw Boom() })
        await failing.prepare(Self.query, duration: 200, allowNetwork: true)
        #expect(failing.intervals(for: "vid") == nil)
        let (plainCache, calls) = make(cached: LyricsAnswer(result: .plain("x"), credit: nil), remote: { Self.synced })
        await plainCache.prepare(Self.query, duration: 200, allowNetwork: true)
        let yt = await calls.youtube
        #expect(plainCache.intervals(for: "vid") == nil && yt == 0)
    }

    @Test("a slow source times out and the plan is not delayed past the timeout")
    func timeout() async {
        let (l, _) = make(remote: {
            try await Task.sleep(for: .seconds(30))
            return Self.synced
        }, timeout: 0.2)
        let start = Date()
        await l.prepare(Self.query, duration: 200, allowNetwork: true)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(l.intervals(for: "vid") == nil)
    }

    @Test("an unknown duration is never looked up")
    func noDuration() async {
        let (l, calls) = make(remote: { Self.synced })
        await l.prepare(Self.query, duration: 0, allowNetwork: true)
        let (cache, yt) = (await calls.cache, await calls.youtube)
        #expect(cache == 0 && yt == 0)
    }
}
