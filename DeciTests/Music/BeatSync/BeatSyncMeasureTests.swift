// DeciTests/Music/BeatSync/BeatSyncMeasureTests.swift
// The pure side of the beat sync spike (tier 3a): the click tracks, the per-band click finder and the beat grid
// comparison. All offline and fast: nothing here plays or captures audio.

import Foundation
import Testing
@testable import Deci

@Suite("Beat sync measurement helpers")
struct BeatSyncMeasureTests {
    private let rate = 48_000.0

    // MARK: - Click track

    @Test("a click track has one burst per beat, centred where the grid says, and silence between")
    func clickTrackLayout() {
        let track = BeatSyncSignal.clickTrack(frequency: 1000, sampleRate: rate, seconds: 3)
        #expect(track.count == Int(3 * rate))
        for beat in 0..<5 {
            let centre = Int((BeatSyncSignal.firstCenter + Double(beat) * BeatSyncSignal.beatPeriod) * rate)
            let window = track[(centre - 200)..<(centre + 200)]
            #expect(MusicTestSignal.peak(Array(window)) > 0.3, "beat \(beat) has a burst")
            // Halfway to the next beat is silent.
            let quiet = centre + Int(0.25 * rate)
            #expect(MusicTestSignal.peak(Array(track[quiet..<(quiet + 400)])) == 0)
        }
        #expect(MusicTestSignal.peak(track) <= 0.5 + 1e-6)
    }

    @Test("a burst's centre can sit between samples")
    func fractionalCentre() {
        let a = BeatSyncSignal.clickTrack(frequency: 1000, sampleRate: rate, seconds: 1, centreShift: 0)
        let b = BeatSyncSignal.clickTrack(frequency: 1000, sampleRate: rate, seconds: 1, centreShift: 0.5 / rate)
        #expect(a != b)
    }

    // MARK: - Click finder

    @Test("every click of a 60 s track is found, to a few microseconds")
    func findsEveryClick() {
        for frequency in [1000.0, 3200.0] {
            let track = BeatSyncSignal.clickTrack(frequency: frequency, sampleRate: rate, seconds: 60)
            let found = ClickDetector.detect(track, sampleRate: rate, frequency: frequency)
            #expect(found.count == 120, "\(frequency) Hz: \(found.count) clicks")
            guard found.count == 120 else { continue }
            for (beat, time) in found.enumerated() {
                let expected = BeatSyncSignal.firstCenter + Double(beat) * BeatSyncSignal.beatPeriod
                #expect(abs(time - expected) < 20e-6, "beat \(beat) at \(time), expected \(expected)")
            }
        }
    }

    @Test("a burst shifted by a fraction of a sample is found at the fractional place")
    func subSampleAccuracy() {
        for fraction in [0.0, 0.25, 0.5, 0.75] {
            let shift = fraction / rate
            let track = BeatSyncSignal.clickTrack(frequency: 3200, sampleRate: rate, seconds: 4, centreShift: shift)
            let found = ClickDetector.detect(track, sampleRate: rate, frequency: 3200)
            #expect(found.count == 8)
            guard let first = found.first else { continue }
            #expect(abs(first - (BeatSyncSignal.firstCenter + shift)) < 10e-6, "fraction \(fraction)")
        }
    }

    @Test("two decks mixed together are told apart by their band")
    func separatesBands() {
        let a = BeatSyncSignal.clickTrack(frequency: 1000, sampleRate: rate, seconds: 10)
        // B plays 0.137 s later than A's beats and has only the beats that fit after it starts.
        let delay = 0.137
        let delayFrames = Int(delay * rate)
        let b = BeatSyncSignal.clickTrack(frequency: 3200, sampleRate: rate, seconds: 10)
        var mix = a
        for index in delayFrames..<mix.count { mix[index] += b[index - delayFrames] }
        let foundA = ClickDetector.detect(mix, sampleRate: rate, frequency: 1000)
        let foundB = ClickDetector.detect(mix, sampleRate: rate, frequency: 3200)
        #expect(foundA.count == 20)
        #expect(foundB.count >= 19)
        #expect(abs(foundA[0] - 0.25) < 20e-6)
        #expect(abs(foundB[0] - (0.25 + Double(delayFrames) / rate)) < 20e-6)
    }

    @Test("silence, empty input and a track too short for one burst find nothing")
    func nothingToFind() {
        #expect(ClickDetector.detect([], sampleRate: rate, frequency: 1000).isEmpty)
        #expect(ClickDetector.detect([Float](repeating: 0, count: 100_000), sampleRate: rate, frequency: 1000).isEmpty)
        #expect(ClickDetector.detect([Float](repeating: 0.5, count: 50), sampleRate: rate, frequency: 1000).isEmpty)
    }

    @Test("a leading silence and a click level change do not move the clicks")
    func leadingSilenceAndLevel() {
        let lead = 24_000
        let track = BeatSyncSignal.clickTrack(frequency: 1000, sampleRate: rate, seconds: 5, amplitude: 0.05)
        let padded = [Float](repeating: 0, count: lead) + track
        let found = ClickDetector.detect(padded, sampleRate: rate, frequency: 1000)
        #expect(found.count == 10)
        #expect(abs((found.first ?? 0) - (0.5 + BeatSyncSignal.firstCenter)) < 20e-6)
    }

    // MARK: - Grid comparison

    /// A's clicks on the nominal grid, and B's clicks as a deck scheduled on A's beat `start` at `rate` would make them.
    private func synthetic(
        start: Int, rate playRate: Double, offsetMs: Double, driftMsPerBeat: Double = 0, count: Int = 30
    ) -> (a: [Double], b: [Double]) {
        let period = BeatSyncSignal.beatPeriod
        let centre = BeatSyncSignal.firstCenter
        let a = (0..<80).map { centre + Double($0) * period }
        let b = (0..<count).map { index -> Double in
            a[start] - centre + (centre + Double(index) * period) / playRate
                + offsetMs / 1000 + driftMsPerBeat / 1000 * Double(index)
        }
        return (a, b)
    }

    @Test("a deck that starts 3 ms late and holds the grid has a 3 ms start error and no drift")
    func constantOffset() throws {
        let (a, b) = synthetic(start: 8, rate: 1, offsetMs: 3)
        let stats = try #require(BeatGrid.compare(aOnsets: a, bOnsets: b, startBeat: 8, rate: 1))
        #expect(abs(stats.startErrorMs - 3) < 1e-6)
        #expect(abs(stats.firstErrorMs - 3) < 1e-6)
        #expect(stats.driftMs < 1e-6)
        #expect(stats.jitterMs < 1e-6)
        #expect(stats.matched == 30)
    }

    @Test("a deck that runs 0.1 ms per beat fast drifts 2.9 ms over 30 beats, with no jitter around the line")
    func steadyDrift() throws {
        let (a, b) = synthetic(start: 4, rate: 1, offsetMs: -1, driftMsPerBeat: 0.1)
        let stats = try #require(BeatGrid.compare(aOnsets: a, bOnsets: b, startBeat: 4, rate: 1))
        #expect(abs(stats.startErrorMs - -1) < 1e-6)
        #expect(abs(stats.driftMs - 2.9) < 1e-6)
        #expect(abs(stats.slopeDriftMs - 2.9) < 1e-6)
        #expect(stats.jitterMs < 1e-6)
    }

    @Test("at a nudged rate the expected grid is B's own: a deck that plays exactly 1.04 has no error")
    func nudgedRateGrid() throws {
        for playRate in [0.92, 0.96, 1.04, 1.08] {
            let (a, b) = synthetic(start: 6, rate: playRate, offsetMs: 0)
            let stats = try #require(BeatGrid.compare(aOnsets: a, bOnsets: b, startBeat: 6, rate: playRate))
            #expect(abs(stats.startErrorMs) < 1e-6, "rate \(playRate)")
            #expect(stats.driftMs < 1e-6, "rate \(playRate)")
        }
    }

    @Test("the same clicks judged against a slightly wrong rate show a drift, and against a very wrong one do not match")
    func wrongRateShowsDrift() throws {
        let (a, b) = synthetic(start: 6, rate: 1.01, offsetMs: 0, count: 10)
        let stats = try #require(BeatGrid.compare(aOnsets: a, bOnsets: b, startBeat: 6, rate: 1))
        #expect(stats.driftMs > 40)
        let (farA, farB) = synthetic(start: 6, rate: 1.08, offsetMs: 0)
        #expect(BeatGrid.compare(aOnsets: farA, bOnsets: farB, startBeat: 6, rate: 1) == nil)
    }

    @Test("jitter is the spread around the fitted line")
    func jitter() throws {
        var (a, b) = synthetic(start: 5, rate: 1, offsetMs: 0, count: 40)
        for index in b.indices { b[index] += (index.isMultiple(of: 2) ? 1 : -1) * 0.0005 }
        let stats = try #require(BeatGrid.compare(aOnsets: a, bOnsets: b, startBeat: 5, rate: 1))
        #expect(abs(stats.jitterMs - 0.5) < 0.05)
        #expect(abs(stats.driftMs - 1.0) < 1e-6)
        a.removeAll()
    }

    @Test("a deck whose clicks sit half a beat off cannot be matched and gives no result")
    func unmatchable() {
        let (a, b) = synthetic(start: 5, rate: 1, offsetMs: 250)
        #expect(BeatGrid.compare(aOnsets: a, bOnsets: b, startBeat: 5, rate: 1) == nil)
    }

    @Test("no clicks for B, or a start beat past A's clicks, give no result")
    func missingData() {
        let (a, b) = synthetic(start: 5, rate: 1, offsetMs: 0)
        #expect(BeatGrid.compare(aOnsets: a, bOnsets: [], startBeat: 5, rate: 1) == nil)
        #expect(BeatGrid.compare(aOnsets: a, bOnsets: b, startBeat: 500, rate: 1) == nil)
        #expect(BeatGrid.compare(aOnsets: a, bOnsets: b, startBeat: 5, rate: 0) == nil)
        #expect(BeatGrid.compare(aOnsets: [0.25], bOnsets: b, startBeat: 0, rate: 1) == nil)
    }

    @Test("the summary of several runs reports the mean and spread of a constant offset")
    func summary() {
        let values = [4.0, 5.0, 6.0]
        let s = BeatSyncSummary(values)
        #expect(abs(s.mean - 5) < 1e-9)
        #expect(abs(s.stdev - (2.0 / 3).squareRoot()) < 1e-9)
        #expect(s.minimum == 4 && s.maximum == 6)
        #expect(BeatSyncSummary([]).mean == 0)
    }

    // MARK: - Verdict

    private func record(start: Double, drift: Double, failure: String? = nil, rate: Double = 1) -> BeatSyncRunRecord {
        BeatSyncRunRecord(
            label: "t", rate: rate, algorithm: "default", clock: "none", device: "d", deviceUID: "u", sampleRate: 48_000,
            startBeat: 6, overlapSeconds: 16, aCount: 40, bCount: 30, startErrorMs: start, firstErrorMs: start,
            meanErrorMs: start, driftMs: drift, slopeDriftMs: 0, jitterMs: 0, matched: 30, hostStartErrorMs: 0,
            aGridHostErrorMs: 0, failure: failure, errorsMs: [], bOnsets: []
        )
    }

    @Test("runs inside both limits pass")
    func verdictPass() {
        #expect(BeatSyncReport.verdict([record(start: 3, drift: 2), record(start: -9, drift: 9.9)]) == .pass)
    }

    @Test("a steady 25 ms offset passes only once calibrated out")
    func verdictCalibrated() {
        let runs = [record(start: 25, drift: 1), record(start: 26, drift: 1), record(start: 24, drift: 2)]
        #expect(BeatSyncReport.verdict(runs) == .passCalibrated)
    }

    @Test("an offset that wanders by more than the limit fails, whatever the mean")
    func verdictWandering() {
        let runs = [record(start: 5, drift: 1), record(start: 40, drift: 1)]
        #expect(BeatSyncReport.verdict(runs) == .fail)
    }

    @Test("drift over the limit, a failed run, or no runs are not a pass")
    func verdictFails() {
        #expect(BeatSyncReport.verdict([record(start: 1, drift: 10.5)]) == .fail)
        #expect(BeatSyncReport.verdict([record(start: 1, drift: 1, failure: "no clicks")]) == .fail)
        #expect(BeatSyncReport.verdict([]) == .noData)
    }

    @Test("a group's latency is its mean start error minus the default-algorithm 1.00 baseline")
    func latencyAgainstBaseline() {
        var base = record(start: 2, drift: 1)
        base.algorithm = "default"
        var nudged = record(start: 12, drift: 1, rate: 0.96)
        nudged.algorithm = "spectral"
        let groups = BeatSyncReport.groups([base, nudged])
        #expect(groups.count == 2)
        #expect(groups.first { $0.algorithm == "spectral" }?.latencyVsBaselineMs == 10)
        #expect(groups.first { $0.algorithm == "default" }?.latencyVsBaselineMs == 0)
    }
}
