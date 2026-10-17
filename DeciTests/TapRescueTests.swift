// DeciTests/TapRescueTests.swift
//
// Pure-value tests for the rescue's verify decision and its [RESCUE] log line.

import Testing
import Foundation
@testable import Deci

/// One host tick per nanosecond, so a test can write times as seconds * 1e9.
private let nsPerTick = 1.0
private func ticks(_ seconds: Double) -> UInt64 { UInt64(seconds * 1e9) }

@Suite("TapRescueVerifier")
struct TapRescueVerifierTests {
    private static let primaryAtStart = ticks(100)
    private static let start = ticks(200)

    private func verifier(primaryAtStart: UInt64 = TapRescueVerifierTests.primaryAtStart) -> TapRescueVerifier {
        TapRescueVerifier(primarySignalAtStart: primaryAtStart, candidateStartHostTime: Self.start, nanosPerTick: nsPerTick)
    }

    @Test("The candidate has 500 ms")
    func windowIsHalfASecond() {
        #expect(TapRescueVerifier.window == 0.5)
    }

    @Test("No signal anywhere yet, inside the window: keep waiting")
    func waiting() {
        let v = verifier()
        #expect(v.verdict(primarySignal: Self.primaryAtStart, candidateSignal: 0, now: Self.start + ticks(0.1)) == .waiting)
        #expect(v.verdict(primarySignal: Self.primaryAtStart, candidateSignal: 0, now: Self.start + ticks(0.499)) == .waiting)
    }

    @Test("No candidate signal after the window: candidate silent")
    func candidateSilent() {
        let v = verifier()
        #expect(v.verdict(primarySignal: Self.primaryAtStart, candidateSignal: 0, now: Self.start + ticks(0.501)) == .candidateSilent)
    }

    @Test("Candidate signal inside the window passes, with the observed latency")
    func candidateHeard() {
        let v = verifier()
        let verdict = v.verdict(primarySignal: Self.primaryAtStart, candidateSignal: Self.start + ticks(0.043), now: Self.start + ticks(0.05))
        guard case .candidateHeard(let latency) = verdict else {
            Issue.record("expected candidateHeard, got \(verdict)")
            return
        }
        #expect(abs(latency - 0.043) < 1e-9)
    }

    @Test("A candidate that heard signal in time still passes when the poll runs after the window")
    func lateReadStillCounts() {
        let v = verifier()
        let verdict = v.verdict(primarySignal: Self.primaryAtStart, candidateSignal: Self.start + ticks(0.4), now: Self.start + ticks(0.6))
        #expect(verdict == .candidateHeard(latency: 0.4))
    }

    @Test("The primary regaining signal aborts the rescue, even when the candidate heard it too")
    func primaryRecovered() {
        let v = verifier()
        #expect(v.verdict(primarySignal: Self.start + ticks(0.1), candidateSignal: 0, now: Self.start + ticks(0.2)) == .primaryRecovered)
        #expect(v.verdict(primarySignal: Self.start + ticks(0.1), candidateSignal: Self.start + ticks(0.1), now: Self.start + ticks(0.2)) == .primaryRecovered)
        #expect(v.verdict(primarySignal: Self.start + ticks(0.1), candidateSignal: 0, now: Self.start + ticks(0.9)) == .primaryRecovered)
    }

    @Test("A primary that never had signal (stamp 0) recovers on its first non-zero buffer")
    func primaryNeverHeardSignal() {
        let v = verifier(primaryAtStart: 0)
        #expect(v.verdict(primarySignal: 0, candidateSignal: 0, now: Self.start + ticks(0.1)) == .waiting)
        #expect(v.verdict(primarySignal: Self.start + ticks(0.05), candidateSignal: 0, now: Self.start + ticks(0.1)) == .primaryRecovered)
    }

    @Test("primaryRecovered(primarySignal:) is the re-check made after the candidate passed")
    func recheck() {
        let v = verifier()
        #expect(!v.primaryRecovered(primarySignal: Self.primaryAtStart))
        #expect(v.primaryRecovered(primarySignal: Self.start + ticks(0.2)))
    }
}

@Suite("TapRescueLogEntry")
struct TapRescueLogEntryTests {
    private func readings(silent: Double = 0.31, age: Double = 120, stream: Bool = true, drift: Bool = false) -> TapHealthReadings {
        var r = TapHealthReadings(
            isSwitching: false,
            secondsSinceTapStart: age,
            inputSignalSeen: true,
            secondsSinceInputSignal: silent,
            secondsSinceDiscontinuity: .infinity,
            discontinuityCount: 0,
            secondsSinceHealthyOutput: 0.1
        )
        r.tapIsStream = stream
        r.tapDriftCompensation = drift
        return r
    }

    private func entry(
        _ outcome: TapRescueLogEntry.Outcome,
        rung: Int = 0,
        readings: TapHealthReadings? = nil,
        devices: [String] = ["uid-a"]
    ) -> TapRescueLogEntry {
        TapRescueLogEntry(
            appName: "QuickTime Player",
            pid: 4242,
            outcome: outcome,
            rung: rung,
            readings: readings ?? self.readings(),
            tapSourceDeviceUID: "uid-a",
            devices: devices
        )
    }

    @Test("A promoted rescue carries every field, including the candidate's signal latency")
    func promotedLine() {
        let e = entry(.promoted(candidateLatency: 0.043))
        #expect(e.line == "promoted QuickTime Player (PID 4242) rung=0 silence=0.31s age=120.00s src=stream:uid-a drift=off devices=[uid-a] candidate=0.043s")
        #expect(e.level == .notice)
    }

    @Test("A mixdown tap with drift on, on two devices")
    func mixdownLine() {
        let e = entry(.promoted(candidateLatency: 0.2), readings: readings(stream: false, drift: true), devices: ["uid-a", "uid-b"])
        #expect(e.line.contains("src=mixdown drift=on devices=[uid-a,uid-b]"))
    }

    @Test("A candidate that heard nothing is candidate-silent, with no latency")
    func candidateSilentLine() {
        let e = entry(.candidateSilent, rung: 1, readings: readings(silent: 2.04))
        #expect(e.line == "candidate-silent QuickTime Player (PID 4242) rung=1 silence=2.04s age=120.00s src=stream:uid-a drift=off devices=[uid-a]")
    }

    @Test("A primary that recovered during verify is its own outcome")
    func primaryRecoveredLine() {
        #expect(entry(.primaryRecovered).line.hasPrefix("primary-recovered QuickTime Player (PID 4242) rung=0 "))
    }

    @Test("A failed rescue names the error and logs at error level")
    func failedLine() {
        let e = entry(.failed("Failed to create aggregate device: -1"))
        #expect(e.line.hasPrefix("failed QuickTime Player (PID 4242) rung=0 "))
        #expect(e.line.hasSuffix(" error=Failed to create aggregate device: -1"))
        #expect(e.level == .error)
    }

    @Test("Inconclusive outcomes are notices for the first four rungs and info for the steady 20 s probes")
    func levels() {
        for rung in 0..<4 {
            #expect(entry(.candidateSilent, rung: rung).level == .notice)
            #expect(entry(.primaryRecovered, rung: rung).level == .notice)
        }
        #expect(entry(.candidateSilent, rung: 4).level == .info)
        #expect(entry(.primaryRecovered, rung: 9).level == .info)
        // A promotion is always worth a notice, whatever the rung.
        #expect(entry(.promoted(candidateLatency: 0.1), rung: 7).level == .notice)
        #expect(entry(.failed("x"), rung: 7).level == .error)
    }
}
