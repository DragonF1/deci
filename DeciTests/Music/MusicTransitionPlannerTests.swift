// DeciTests/Music/MusicTransitionPlannerTests.swift
// Tier 2b P1: the pure transition planner.

import Foundation
import Testing
@testable import Deci

@Suite("MusicTransitionPlanner")
struct MusicTransitionPlannerTests {
    typealias P = MusicTransitionPlanner

    // MARK: Builders

    static func analysis(
        _ id: String, duration: Double = 200, silenceStart: Double = 0, silenceEnd: Double? = nil,
        introEnd: Double? = nil, outroStart: Double? = nil, lufs: Double = -14, youtube: Double? = nil
    ) -> MusicAnalysis {
        let end = silenceEnd ?? duration
        return MusicAnalysis(
            videoId: id, version: MusicAnalysis.currentVersion,
            format: .init(codec: "mp4a.40.2", itag: 140, durationMs: Int(duration * 1000)),
            analyzedAt: Date(timeIntervalSince1970: 0), source: .playbackCache,
            silenceStart: silenceStart, silenceEnd: end,
            introEnd: introEnd ?? silenceStart, outroStart: outroStart ?? end,
            integratedLUFS: lufs, samplePeakDb: -1, introLUFS: nil, outroLUFS: nil, energy: [],
            youtubeLoudnessDb: youtube, youtubePerceptualLoudnessDb: nil
        )
    }

    static func side(
        _ id: String, duration: Double? = 200, analysis: MusicAnalysis? = nil, youtube: Double? = nil
    ) -> MusicTransitionSide {
        MusicTransitionSide(videoId: id, durationSeconds: duration, analysis: analysis, youtubeLoudnessDb: youtube)
    }

    static func inputs(
        a: MusicTransitionSide, b: MusicTransitionSide, crossfade: Bool = true, setting: Double = 6,
        album: Bool = false, loop: Bool = false, cleanStart: Bool = false, cleanPair: Bool = false,
        skip: Bool = false
    ) -> MusicTransitionInputs {
        MusicTransitionInputs(
            outgoing: a, incoming: b, crossfadeOn: crossfade, settingSeconds: setting, albumInOrder: album,
            loopSong: loop, cleanStartFlag: cleanStart, cleanPairFlag: cleanPair, manualSkip: skip
        )
    }

    /// Both sides analysed; defaults give the first worked example.
    static func smart(
        aEnd: Double = 197, aOutro: Double = 185, bStart: Double = 0, bIntroEnd: Double = 8,
        aDuration: Double = 200, bDuration: Double = 200, aLufs: Double = -14, bLufs: Double = -14,
        crossfade: Bool = true, setting: Double = 6
    ) -> MusicTransitionInputs {
        inputs(
            a: side("aaaaaaaaaaa", duration: aDuration, analysis: analysis(
                "aaaaaaaaaaa", duration: aDuration, silenceEnd: aEnd, outroStart: aOutro, lufs: aLufs)),
            b: side("bbbbbbbbbbb", duration: bDuration, analysis: analysis(
                "bbbbbbbbbbb", duration: bDuration, silenceStart: bStart, introEnd: bIntroEnd, lufs: bLufs)),
            crossfade: crossfade, setting: setting
        )
    }

    // MARK: Eligibility (D3)

    @Test func albumInOrderIsTierOneGaplessWithNoTrims() {
        var i = Self.smart(); i.albumInOrder = true
        let plan = P.plan(i)
        var expected = TransitionPlan.tier1Gapless; expected.reason = .albumInOrder
        #expect(plan == expected)
    }

    @Test func loopSongIsTierOne() {
        var i = Self.smart(); i.loopSong = true
        var expected = TransitionPlan.tier1Gapless; expected.reason = .loopSong
        #expect(P.plan(i) == expected)
    }

    @Test func sameIdTwiceIsTreatedAsLoop() {
        let a = Self.analysis("same", silenceEnd: 197, outroStart: 185)
        let i = Self.inputs(a: Self.side("same", analysis: a), b: Self.side("same", analysis: a))
        var expected = TransitionPlan.tier1Gapless; expected.reason = .loopSong
        #expect(P.plan(i) == expected)
    }

    @Test(arguments: [nil, 0.0, -5.0, Double.nan, Double.infinity])
    func unknownOrInvalidDurationIsTierOne(_ bad: Double?) {
        var i = Self.smart(); i.incoming.durationSeconds = bad
        var expected = TransitionPlan.tier1Gapless; expected.reason = .noDuration
        #expect(P.plan(i) == expected)
        var j = Self.smart(); j.outgoing.durationSeconds = bad
        #expect(P.plan(j) == expected)
    }

    @Test func cleanFlagOnIncomingGivesCleanWithTrimsKept() {
        var i = Self.smart(aEnd: 197, bStart: 1.5); i.cleanStartFlag = true
        let plan = P.plan(i)
        #expect(plan.mode == .clean)
        #expect(plan.reason == .noMix)
        #expect(plan.fadeSeconds == 0)
        #expect(plan.fadeStartSec == nil)
        #expect(plan.outgoingEndSec == 197)
        #expect(plan.incomingStartSec == 1.5)
        #expect(plan.incomingGainDb == 0 && plan.outgoingGainDb == 0)
    }

    @Test func cleanPairFlagGivesClean() {
        var i = Self.smart(); i.cleanPairFlag = true
        #expect(P.plan(i).mode == .clean)
    }

    @Test func cleanWinsOverCrossfadeOff() {
        var i = Self.smart(crossfade: false); i.cleanStartFlag = true
        #expect(P.plan(i).mode == .clean)
    }

    @Test func crossfadeOffIsGaplessWithTrims() {
        var i = Self.smart(aEnd: 197, bStart: 2, crossfade: false)
        i.crossfadeOn = false
        let plan = P.plan(i)
        #expect(plan.mode == .gapless)
        #expect(plan.reason == .off)
        #expect(plan.fadeSeconds == 0)
        #expect(plan.outgoingEndSec == 197)
        #expect(plan.incomingStartSec == 2)
        #expect(plan.fadeStartSec == nil)
    }

    @Test func bothFreshIsSmart() {
        let plan = P.plan(Self.smart())
        #expect(plan.mode == .smart)
        #expect(plan.reason == .ok)
    }

    @Test func missingIncomingAnalysisIsFixedButOutgoingStillTrims() {
        var i = Self.smart(aEnd: 197)
        i.incoming.analysis = nil
        let plan = P.plan(i)
        #expect(plan.mode == .fixed)
        #expect(plan.reason == .partialAnalysis)
        #expect(plan.outgoingEndSec == 197)
        #expect(plan.incomingStartSec == 0)
        #expect(plan.fadeSeconds == 6)
        #expect(plan.fadeStartSec == nil)
    }

    @Test func missingOutgoingAnalysisIsFixedButIncomingStillTrims() {
        var i = Self.smart(bStart: 3)
        i.outgoing.analysis = nil
        let plan = P.plan(i)
        #expect(plan.mode == .fixed)
        #expect(plan.reason == .partialAnalysis)
        #expect(plan.outgoingEndSec == nil)
        #expect(plan.incomingStartSec == 3)
    }

    @Test func noAnalysisAtAllIsFixedTierOne() {
        let i = Self.inputs(a: Self.side("a"), b: Self.side("b"), setting: 5)
        let plan = P.plan(i)
        #expect(plan.mode == .fixed)
        #expect(plan.reason == .noAnalysis)
        #expect(plan.fadeSeconds == 5)
        #expect(plan.incomingStartSec == 0)
        #expect(plan.outgoingEndSec == nil)
        #expect(plan.incomingGainDb == 0 && plan.outgoingGainDb == 0)
    }

    // MARK: Trims (D4)

    @Test func incomingTrimIsSilenceStartCappedAtFifteen() {
        #expect(P.plan(Self.smart(bStart: 4.2)).incomingStartSec == 4.2)
        #expect(P.plan(Self.smart(bStart: 40, bIntroEnd: 50)).incomingStartSec == 15)
    }

    @Test func incomingTrimBelowQuarterSecondIsIgnored() {
        #expect(P.plan(Self.smart(bStart: 0.24, bIntroEnd: 8)).incomingStartSec == 0)
        #expect(P.plan(Self.smart(bStart: 0.25, bIntroEnd: 8)).incomingStartSec == 0.25)
    }

    @Test func outgoingTrimIsSilenceEnd() {
        #expect(P.plan(Self.smart(aEnd: 190, aOutro: 180)).outgoingEndSec == 190)
    }

    @Test func outgoingTrimBelowQuarterSecondIsIgnored() {
        #expect(P.plan(Self.smart(aEnd: 199.8, aOutro: 190)).outgoingEndSec == nil)
        #expect(P.plan(Self.smart(aEnd: 199.75, aOutro: 190)).outgoingEndSec == 199.75)
    }

    @Test func outgoingTrimBelowHalfDurationFailsSanityCheck() {
        let i = Self.inputs(
            a: Self.side("a", analysis: Self.analysis("a", silenceEnd: 99, outroStart: 99)),
            b: Self.side("b"), crossfade: false)
        #expect(P.plan(i).outgoingEndSec == nil)
        let ok = Self.inputs(
            a: Self.side("a", analysis: Self.analysis("a", silenceEnd: 100, outroStart: 100)),
            b: Self.side("b"), crossfade: false)
        #expect(P.plan(ok).outgoingEndSec == 100)
    }

    @Test func outgoingTrimIsClampedToStreamDuration() {
        // The analysis claims 205 s but the stream is 200 s: end is the natural end, so no trim.
        let a = Self.analysis("a", duration: 200, silenceEnd: 205, outroStart: 190)
        let i = Self.inputs(a: Self.side("a", duration: 200, analysis: a), b: Self.side("b"), crossfade: false)
        #expect(P.plan(i).outgoingEndSec == nil)
    }

    @Test func nonFiniteAnalysisSideIsTreatedAsMissing() {
        var i = Self.smart(aEnd: 190)
        i.outgoing.analysis?.silenceEnd = .nan
        var plan = P.plan(i)
        #expect(plan.mode == .fixed)
        #expect(plan.outgoingEndSec == nil)
        i = Self.smart(bStart: 3)
        i.incoming.analysis?.introEnd = .infinity
        plan = P.plan(i)
        #expect(plan.mode == .fixed)
        #expect(plan.incomingStartSec == 0)
        i = Self.smart()
        i.outgoing.analysis?.outroStart = -.infinity
        #expect(P.plan(i).mode == .fixed)
    }

    @Test func nonFiniteSettingGivesGapless() {
        var i = Self.smart(); i.outgoing.analysis = nil
        i.settingSeconds = .nan
        #expect(P.plan(i).mode == .gapless)
    }

    // MARK: Smart fade (D5)

    @Test func workedExampleOne() {
        let plan = P.plan(Self.smart(aEnd: 197, aOutro: 185, bIntroEnd: 8))
        #expect(plan.fadeSeconds == 8)
        #expect(plan.fadeStartSec == 185)
        #expect(plan.outgoingEndSec == 197)
        // 4 s of audible tail are skipped.
        #expect(197 - (plan.fadeStartSec! + plan.fadeSeconds) == 4)
    }

    @Test func workedExampleTwoCapBites() {
        let plan = P.plan(Self.smart(aEnd: 197, aOutro: 157, bIntroEnd: 5))
        #expect(plan.fadeSeconds == 5)
        #expect(plan.fadeStartSec == 182)
        #expect(197 - (plan.fadeStartSec! + plan.fadeSeconds) == 10)
    }

    @Test func fadeClampsToTwoSecondsFloor() {
        let plan = P.plan(Self.smart(aEnd: 197, aOutro: 196, bIntroEnd: 0.5))
        #expect(plan.fadeSeconds == 2)
    }

    @Test func fadeClampsToTwelveSecondsCeiling() {
        let plan = P.plan(Self.smart(aEnd: 197, aOutro: 150, bIntroEnd: 30))
        #expect(plan.fadeSeconds == 12)
        // cap: max(150, 197 - 12 - 10 = 175) = 175.
        #expect(plan.fadeStartSec == 175)
    }

    @Test func hardEndingGetsFadeOverItsLastSeconds() {
        // outroStart == silenceEnd: outroLen 0 -> fade 2, fadeStart = aEnd - fade.
        let plan = P.plan(Self.smart(aEnd: 197, aOutro: 197, bIntroEnd: 8))
        #expect(plan.fadeSeconds == 2)
        #expect(plan.fadeStartSec == 195)
    }

    @Test func introLengthUsesSilenceStartOffset() {
        // introEnd 13, silenceStart 5 -> introLen 8 (and the incoming is parked at 5).
        let plan = P.plan(Self.smart(bStart: 5, bIntroEnd: 13))
        #expect(plan.fadeSeconds == 8)
        #expect(plan.incomingStartSec == 5)
    }

    @Test func shortTrackRuleHalvesTheOutgoingTail() {
        // A is 5 s long: fade0 2 clamps to aEnd / 2 = 2.5 -> min(2, 2.5) = 2.
        let a = Self.analysis("a", duration: 5, silenceEnd: 5, outroStart: 4)
        let i = Self.inputs(
            a: Self.side("a", duration: 5, analysis: a),
            b: Self.side("b", analysis: Self.analysis("b", introEnd: 8)))
        let plan = P.plan(i)
        #expect(plan.mode == .smart)
        #expect(plan.fadeSeconds == 2)
        #expect(plan.fadeStartSec == 3)
    }

    @Test func shortTrackRuleLimitsFadeToHalfOfIncomingSpan() {
        // B is 5 s: span 5, half 2.5, fade0 would be 8 -> 2.5.
        let b = Self.analysis("b", duration: 5, introEnd: 4)
        let a = Self.analysis("a", silenceEnd: 197, outroStart: 150)
        let plan = P.plan(Self.inputs(a: Self.side("a", analysis: a), b: Self.side("b", duration: 5, analysis: b)))
        #expect(plan.fadeSeconds == 2.5)
        #expect(plan.mode == .smart)
    }

    @Test func fadeBelowOneSecondFallsBackToGaplessKeepingTrims() {
        // B is 1.8 s long: half is 0.9 -> gapless, trims kept.
        let b = Self.analysis("b", duration: 1.8, silenceStart: 0, introEnd: 0.5)
        let a = Self.analysis("a", silenceEnd: 197, outroStart: 185)
        let plan = P.plan(Self.inputs(a: Self.side("a", analysis: a), b: Self.side("b", duration: 1.8, analysis: b)))
        #expect(plan.mode == .gapless)
        #expect(plan.reason == .tooShort)
        #expect(plan.fadeSeconds == 0)
        #expect(plan.fadeStartSec == nil)
        #expect(plan.outgoingEndSec == 197)
        #expect(plan.incomingGainDb == 0 && plan.outgoingGainDb == 0)
    }

    @Test func capMovesFadeLaterAndFadeAlwaysFitsInTail() {
        for outro in stride(from: 0.0, through: 197.0, by: 7.3) {
            for intro in [0.0, 1, 3, 9, 20] {
                let plan = P.plan(Self.smart(aEnd: 197, aOutro: outro, bIntroEnd: intro))
                guard plan.mode == .smart, let start = plan.fadeStartSec else { continue }
                #expect(start >= 0)
                #expect(start + plan.fadeSeconds <= 197 + 1e-9)
                #expect(197 - (start + plan.fadeSeconds) <= P.skipCap + 1e-9)
                #expect(plan.fadeSeconds >= 1 && plan.fadeSeconds <= 12)
            }
        }
    }

    @Test func fadeStartIsNeverNegative() {
        // 6 s song, outro starts at 0: aEnd 6, fade 2, fadeStart 4.
        let a = Self.analysis("a", duration: 6, silenceEnd: 6, introEnd: 0, outroStart: 0)
        let plan = P.plan(Self.inputs(
            a: Self.side("a", duration: 6, analysis: a),
            b: Self.side("b", analysis: Self.analysis("b", introEnd: 8))))
        #expect(plan.fadeStartSec! >= 0)
    }

    @Test func smartUsesTrimmedEndForTailMath() {
        // Analyser end 190 of 200: aEnd is 190, outro 180, intro 8 -> fade 8, start 182 is capped:
        // max(180, 190 - 8 - 10 = 172) = 180; fits (<= 182).
        let plan = P.plan(Self.smart(aEnd: 190, aOutro: 180, bIntroEnd: 8))
        #expect(plan.outgoingEndSec == 190)
        #expect(plan.fadeStartSec == 180)
    }

    // MARK: Fixed (D6)

    @Test func fixedUsesSettingWhenRoomy() {
        var i = Self.smart(); i.incoming.analysis = nil; i.settingSeconds = 8
        let plan = P.plan(i)
        #expect(plan.fadeSeconds == 8)
        #expect(plan.mode == .fixed)
    }

    @Test func fixedFadeIsLimitedByHalfOfEachSide() {
        let i = Self.inputs(a: Self.side("a", duration: 6), b: Self.side("b", duration: 200), setting: 12)
        #expect(P.plan(i).fadeSeconds == 3)
        let j = Self.inputs(a: Self.side("a", duration: 200), b: Self.side("b", duration: 5), setting: 12)
        #expect(P.plan(j).fadeSeconds == 2.5)
    }

    @Test func fixedFadeBelowOneIsGapless() {
        let i = Self.inputs(a: Self.side("a", duration: 1.9), b: Self.side("b"), setting: 6)
        let plan = P.plan(i)
        #expect(plan.mode == .gapless)
        #expect(plan.reason == .tooShort)
    }

    @Test func fixedUsesIncomingSpanAfterTrim() {
        // B 20 s with 15 s parked in: span 5, half 2.5.
        var b = Self.analysis("b", duration: 20, silenceStart: 18, introEnd: 19)
        b.outroStart = 19; b.silenceEnd = 20
        let i = Self.inputs(a: Self.side("a"), b: Self.side("b", duration: 20, analysis: b), setting: 12)
        let plan = P.plan(i)
        #expect(plan.incomingStartSec == 15)
        #expect(plan.fadeSeconds == 2.5)
    }

    // MARK: Loudness (D7)

    @Test func incomingLouderGetsAttenuationAndGlide() {
        let plan = P.plan(Self.smart(aLufs: -14, bLufs: -11))
        #expect(plan.incomingGainDb == -3)
        #expect(plan.incomingGlideSeconds == 8)
        #expect(plan.outgoingGainDb == 0)
        #expect(plan.outgoingRampSeconds == 0)
    }

    @Test func incomingQuieterAttenuatesOutgoingOnly() {
        let plan = P.plan(Self.smart(aLufs: -10, bLufs: -13))
        #expect(plan.incomingGainDb == 0)
        #expect(plan.incomingGlideSeconds == 0)
        #expect(plan.outgoingGainDb == -3)
        // fade 8 -> min(2, 8/3) = 2.
        #expect(plan.outgoingRampSeconds == 2)
    }

    @Test func outgoingRampIsAThirdOfShortFades() {
        let plan = P.plan(Self.smart(aEnd: 197, aOutro: 196, bIntroEnd: 0.5, aLufs: -10, bLufs: -13))
        #expect(plan.fadeSeconds == 2)
        #expect(abs(plan.outgoingRampSeconds - 2.0 / 3.0) < 1e-12)
    }

    @Test func offsetClampsAtSixDb() {
        #expect(P.plan(Self.smart(aLufs: -20, bLufs: -8)).incomingGainDb == -6)
        #expect(P.plan(Self.smart(aLufs: -8, bLufs: -20)).outgoingGainDb == -6)
    }

    @Test func deadbandIgnoresUnderOneDb() {
        let plan = P.plan(Self.smart(aLufs: -14, bLufs: -13.1))
        #expect(plan.incomingGainDb == 0 && plan.outgoingGainDb == 0)
        let edge = P.plan(Self.smart(aLufs: -14, bLufs: -13))
        #expect(edge.incomingGainDb == -1)
    }

    @Test func sameSourceRuleNeverMixesLufsWithYoutube() {
        // A has LUFS, B only YouTube: no match.
        var a = Self.analysis("a", lufs: -14, youtube: nil)
        var b = Self.analysis("b", lufs: -.infinity, youtube: -3)
        let sa = Self.side("a", analysis: a, youtube: nil)
        var sb = Self.side("b", analysis: b, youtube: -3)
        #expect(P.offsetDb(outgoing: sa, incoming: sb) == nil)
        // Both YouTube: B is 3 dB louder.
        a.integratedLUFS = -.infinity
        let sa2 = Self.side("a", analysis: a, youtube: -6)
        #expect(P.offsetDb(outgoing: sa2, incoming: sb) == 3)
        // Both LUFS beat YouTube.
        b.integratedLUFS = -10
        a.integratedLUFS = -12
        sb = Self.side("b", analysis: b, youtube: -20)
        #expect(P.offsetDb(outgoing: Self.side("a", analysis: a, youtube: 0), incoming: sb) == 2)
    }

    @Test func offsetNilWithoutAnyLoudness() {
        #expect(P.offsetDb(outgoing: Self.side("a"), incoming: Self.side("b")) == nil)
    }

    @Test func offsetIgnoresNonFiniteLoudness() {
        let sa = Self.side("a", youtube: .nan)
        let sb = Self.side("b", youtube: -3)
        #expect(P.offsetDb(outgoing: sa, incoming: sb) == nil)
    }

    @Test func nothingOffsetOutsideSmart() {
        var fixed = Self.smart(aLufs: -20, bLufs: -8)
        fixed.incoming.youtubeLoudnessDb = nil
        fixed.outgoing.analysis?.silenceEnd = .nan
        #expect(P.plan(fixed).incomingGainDb == 0)
        #expect(P.plan(Self.smart(aLufs: -20, bLufs: -8, crossfade: false)).incomingGainDb == 0)
        var clean = Self.smart(aLufs: -20, bLufs: -8); clean.cleanStartFlag = true
        let plan = P.plan(clean)
        #expect(plan.incomingGainDb == 0 && plan.outgoingGainDb == 0)
        var tooShort = Self.smart(bDuration: 1.8, aLufs: -20, bLufs: -8)
        tooShort.incoming.analysis?.introEnd = 0.5
        #expect(P.plan(tooShort).incomingGainDb == 0)
    }

    // MARK: Manual skip (D8)

    @Test func manualSkipIsQuickFixedFade() {
        var i = Self.smart(aEnd: 197, bStart: 2, bIntroEnd: 9)
        i.manualSkip = true
        let plan = P.plan(i)
        #expect(plan.mode == .fixed)
        #expect(plan.fadeSeconds == 0.3)
        #expect(plan.fadeStartSec == nil)
        #expect(plan.incomingStartSec == 2)
        #expect(plan.outgoingEndSec == nil)
    }

    @Test func manualSkipAppliesIncomingAttenuationOnly() {
        var loud = Self.smart(aLufs: -14, bLufs: -11); loud.manualSkip = true
        let plan = P.plan(loud)
        #expect(plan.incomingGainDb == -3)
        #expect(plan.incomingGlideSeconds == 8)
        var quiet = Self.smart(aLufs: -10, bLufs: -14); quiet.manualSkip = true
        let q = P.plan(quiet)
        #expect(q.outgoingGainDb == 0 && q.incomingGainDb == 0)
    }

    @Test func manualSkipIgnoresCleanFlagAndCrossfadeOff() {
        var i = Self.smart(crossfade: false); i.manualSkip = true; i.cleanStartFlag = true
        let plan = P.plan(i)
        #expect(plan.mode == .fixed)
        #expect(plan.fadeSeconds == 0.3)
    }

    @Test func manualSkipWithoutAnalysesStillQuickFades() {
        let i = Self.inputs(a: Self.side("a"), b: Self.side("b"), skip: true)
        let plan = P.plan(i)
        #expect(plan.mode == .fixed && plan.fadeSeconds == 0.3 && plan.incomingStartSec == 0)
    }

    // MARK: isFresh (D2)

    static func stream(
        _ id: String = "aaaaaaaaaaa", duration: Double? = 200, itag: Int = 140, codec: String? = "mp4a.40.2"
    ) -> ResolvedStream {
        ResolvedStream(
            videoId: id, url: URL(string: "https://example.invalid/x")!, itag: itag, durationSeconds: duration,
            expiresAt: Date(timeIntervalSince1970: 9_999_999_999), playbackTrackingURL: nil, httpHeaders: [:],
            audioCodec: codec
        )
    }

    @Test func freshRowPasses() {
        #expect(P.isFresh(Self.analysis("aaaaaaaaaaa", silenceStart: 1, silenceEnd: 198, outroStart: 190), for: Self.stream()))
    }

    @Test func staleVersionFails() {
        var a = Self.analysis("aaaaaaaaaaa"); a.version = MusicAnalysis.currentVersion + 1
        #expect(!P.isFresh(a, for: Self.stream()))
    }

    @Test func formatMismatchFails() {
        let a = Self.analysis("aaaaaaaaaaa")
        #expect(!P.isFresh(a, for: Self.stream(duration: 201)))
        #expect(!P.isFresh(a, for: Self.stream(itag: 251)))
        #expect(!P.isFresh(a, for: Self.stream(codec: "opus")))
        #expect(!P.isFresh(a, for: Self.stream(duration: nil)))
        #expect(!P.isFresh(a, for: Self.stream("zzzzzzzzzzz")))
    }

    @Test func nonFiniteFieldsFail() {
        for keyPath in [\MusicAnalysis.silenceStart, \.silenceEnd, \.introEnd, \.outroStart] {
            var a = Self.analysis("aaaaaaaaaaa", silenceStart: 1, silenceEnd: 198, outroStart: 190)
            a[keyPath: keyPath] = .nan
            #expect(!P.isFresh(a, for: Self.stream()))
            a[keyPath: keyPath] = .infinity
            #expect(!P.isFresh(a, for: Self.stream()))
        }
        var nan = Self.analysis("aaaaaaaaaaa"); nan.integratedLUFS = .nan
        #expect(!P.isFresh(nan, for: Self.stream()))
    }

    @Test func shortSpanFails() {
        let tight = Self.analysis("aaaaaaaaaaa", silenceStart: 100, silenceEnd: 109.9, introEnd: 100, outroStart: 109.9)
        #expect(!P.isFresh(tight, for: Self.stream()))
        let ok = Self.analysis("aaaaaaaaaaa", silenceStart: 100, silenceEnd: 110, introEnd: 100, outroStart: 110)
        #expect(P.isFresh(ok, for: Self.stream()))
    }

    @Test func inverseEdgesFail() {
        var a = Self.analysis("aaaaaaaaaaa"); a.silenceStart = 50; a.silenceEnd = 40
        #expect(!P.isFresh(a, for: Self.stream()))
    }

    @Test func allSilentRowFails() {
        let a = Self.analysis("aaaaaaaaaaa", lufs: -.infinity)
        #expect(!P.isFresh(a, for: Self.stream()))
    }

    @Test func gatedLufsWithRealEdgesStillPasses() {
        let a = Self.analysis("aaaaaaaaaaa", silenceStart: 1, silenceEnd: 150, outroStart: 140, lufs: -.infinity)
        #expect(P.isFresh(a, for: Self.stream()))
    }
}
