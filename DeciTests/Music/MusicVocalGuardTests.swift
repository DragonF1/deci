// DeciTests/Music/MusicVocalGuardTests.swift
// Tier 3c: the structural vocal guard. The pure collision maths, the no-op rules, the log line and the setting.

import Foundation
import Testing
@testable import Deci

@Suite("MusicVocalGuard")
struct MusicVocalGuardTests {
    typealias G = MusicVocalGuard

    private func collision(
        outro: Double, introEnd: Double, outStart: Double, inStart: Double = 0, rate: Double = 1, length: Double
    ) -> Double {
        G.collisionSec(
            outroStartA: outro, introEndB: introEnd, outStart: outStart, inStart: inStart, rate: rate, length: length
        )
    }

    // MARK: Collision maths

    @Test("both sides singing: A sings until its outro, B from its intro end")
    func bothVocal() {
        // A sings wall [0, 10], B sings wall [4, 16]: they share 6 s.
        #expect(abs(collision(outro: 110, introEnd: 4, outStart: 100, length: 16) - 6) < 1e-12)
    }

    @Test("one side silent in the overlap gives no collision")
    func oneSideSilent() {
        // A is in its outro the whole overlap (outro starts before the overlap).
        #expect(collision(outro: 90, introEnd: 0, outStart: 100, length: 16) == 0)
        // B is still in its intro the whole overlap.
        #expect(collision(outro: 200, introEnd: 40, outStart: 100, inStart: 0, length: 16) == 0)
    }

    @Test("clamps: A past the end of the overlap, B before its start")
    func clamps() {
        // A sings the whole 8 s, B from the start: the whole overlap collides.
        #expect(collision(outro: 500, introEnd: -3, outStart: 100, length: 8) == 8)
        // Outro long before the overlap: A clamps to 0.
        #expect(collision(outro: -50, introEnd: 0, outStart: 100, length: 8) == 0)
        // B starts after the end of the overlap: clamps to the length.
        #expect(collision(outro: 500, introEnd: 900, outStart: 100, length: 8) == 0)
    }

    @Test("a faster incoming reaches its vocals sooner in wall time")
    func rateScalesTheIncoming() {
        // B sings from item time 10.5, rate 1.05: wall 10 s into the overlap. A sings wall [0, 12].
        let fast = collision(outro: 112, introEnd: 10.5, outStart: 100, rate: 1.05, length: 16)
        #expect(abs(fast - 2) < 1e-9)
        let same = collision(outro: 112, introEnd: 10.5, outStart: 100, rate: 1, length: 16)
        #expect(abs(same - 1.5) < 1e-9)
    }

    @Test("the incoming start offsets its intro end")
    func incomingStartOffsets() {
        #expect(abs(collision(outro: 110, introEnd: 12, outStart: 100, inStart: 8, length: 16) - 6) < 1e-12)
    }

    @Test("bad numbers give no collision")
    func badNumbers() {
        #expect(collision(outro: 110, introEnd: 4, outStart: 100, length: 0) == 0)
        #expect(collision(outro: 110, introEnd: 4, outStart: 100, length: -4) == 0)
        #expect(collision(outro: .nan, introEnd: 4, outStart: 100, length: 8) == 0)
        #expect(collision(outro: 110, introEnd: .infinity, outStart: 100, length: 8) == 0)
        #expect(collision(outro: 110, introEnd: 4, outStart: .nan, length: 8) == 0)
        // A rate that is not a rate reads as 1.
        #expect(collision(outro: 110, introEnd: 4, outStart: 100, rate: 0, length: 16)
            == collision(outro: 110, introEnd: 4, outStart: 100, rate: 1, length: 16))
    }

    // MARK: Proxy no-ops

    private func analysis(introEnd: Double, outroStart: Double) -> MusicAnalysis {
        MusicTransitionPlannerTests.analysis("aaaaaaaaaaa", introEnd: introEnd, outroStart: outroStart)
    }

    @Test("the proxy is nil without analysis, with non-finite values, introEnd >= outroStart or outroStart <= 0")
    func proxyNoOps() {
        let ok = analysis(introEnd: 8, outroStart: 180)
        #expect(G.proxy(outgoing: ok, incoming: ok) != nil)
        #expect(G.proxy(outgoing: nil, incoming: ok) == nil)
        #expect(G.proxy(outgoing: ok, incoming: nil) == nil)
        for bad in [
            analysis(introEnd: .nan, outroStart: 180), analysis(introEnd: 8, outroStart: .infinity),
            analysis(introEnd: 180, outroStart: 180), analysis(introEnd: 190, outroStart: 180),
            analysis(introEnd: -5, outroStart: 0), analysis(introEnd: -5, outroStart: -1),
        ] {
            #expect(G.proxy(outgoing: bad, incoming: ok) == nil)
            #expect(G.proxy(outgoing: ok, incoming: bad) == nil)
            #expect(G.collisionSec(outgoing: bad, incoming: ok, outStart: 100, inStart: 0, length: 8) == nil)
        }
    }

    @Test("the analysis form reads the outgoing outro and the incoming intro end")
    func analysisForm() throws {
        let a = analysis(introEnd: 8, outroStart: 110)
        let b = analysis(introEnd: 4, outroStart: 190)
        let value = try #require(G.collisionSec(outgoing: a, incoming: b, outStart: 100, inStart: 0, length: 16))
        #expect(abs(value - 6) < 1e-12)
    }

    // MARK: Log line

    @Test("the vocal guard log line names the action, both collisions and the fade, and is nil for an untouched plan")
    func logLine() {
        var plan = TransitionPlan.tier1Gapless
        #expect(MusicTransitionLog.vocalGuardLine(from: "a", to: "b", plan: plan) == nil)
        plan.vocalAction = "shorten"
        plan.vocalBeforeSec = 6.2
        plan.vocalCollisionSec = 0
        plan.fadeSeconds = 5
        #expect(MusicTransitionLog.vocalGuardLine(from: "a", to: "b", plan: plan)
            == "transition_vocal_guard from=a to=b action=shorten before=6.20 after=0.00 fade=5.00")
    }

    // MARK: Setting

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("the setting is on by default, an absent or wrong-typed key reads as on, false survives a round trip")
    @MainActor
    func setting() throws {
        #expect(AppSettings().musicVocalGuard)
        #expect(MusicPlaybackPreferences().vocalGuard)
        #expect(try decode("{}").musicVocalGuard)
        #expect(try decode(#"{"musicBeatMix": false}"#).musicVocalGuard)
        #expect(try decode(#"{"musicVocalGuard": "no"}"#).musicVocalGuard)
        #expect(try decode(#"{"musicVocalGuard": false}"#).musicVocalGuard == false)
        var settings = AppSettings()
        settings.musicVocalGuard = false
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).musicVocalGuard == false)
        var preferences = settings.musicPlayback
        #expect(preferences.vocalGuard == false)
        preferences.vocalGuard = true
        settings.musicPlayback = preferences
        #expect(settings.musicVocalGuard)
    }

    @Test("the old settings fixtures read the setting as on")
    @MainActor
    func fixtures() throws {
        for name in ["settings-v10.json", "settings-v11.json"] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
            let settings = try JSONDecoder().decode(AppSettings.self, from: try Data(contentsOf: url))
            #expect(settings.musicVocalGuard, "\(name)")
        }
    }

    @Test("the planner's guard counts the outgoing deck rate: item seconds of the held deck, collision back in wall seconds")
    func outgoingDeckRateInGuard() throws {
        typealias BT = MusicBeatPlannerTests
        var i = BT.inputs()
        // A sings to item 200 (outro), B from item 8 (intro end). Plain deck: A heard [0, 10], B from 8, collision 2 s.
        let plain = try #require(MusicBeatPlanner.guardCollision(i, outStart: 190, inStart: 0, rate: 1, wallLength: 16))
        #expect(abs(plain - 2) < 1e-9)
        // Outgoing held at 1.05, incoming at 1.05 too (relative 1): the overlap is 16.8 outgoing item s, the collision is
        // the same 2 item s, which is 2 / 1.05 wall s.
        i.outgoing.deckRate = 1.05
        let held = try #require(MusicBeatPlanner.guardCollision(i, outStart: 190, inStart: 0, rate: 1.05, wallLength: 16))
        #expect(abs(held - 2 / 1.05) < 1e-9)
    }
}
