// DeciTests/Music/BeatSync/BeatSyncSpikeTests.swift
// Tier 3a, part 1: the beat sync spike. Real playback on the real engine, measured on the muted capture of this
// process's own output. Opt-in (they play for about half an hour in all):
//   xcodebuild test ... TEST_RUNNER_DECI_BEAT_SYNC_SPIKE=1 -only-testing:DeciTests/BeatSyncSpikeTests
// TEST_RUNNER_DECI_BEAT_SYNC_DEVICE_UID picks the output device (default: the system default output).
// Results are appended to /Volumes/Storage/_test/deci-3a/sync/runs.jsonl, and the report files are rewritten from it.

import Foundation
import AVFoundation
import Testing
@testable import Deci

private nonisolated let spikeEnabled = ProcessInfo.processInfo.environment["DECI_BEAT_SYNC_SPIKE"] == "1"
private nonisolated let spikeDevice = ProcessInfo.processInfo.environment["DECI_BEAT_SYNC_DEVICE_UID"]

@MainActor
@Suite("Beat sync spike", .serialized, .enabled(if: spikeEnabled))
struct BeatSyncSpikeTests {
    private func runAndRecord(_ rig: BeatSyncRig, _ config: BeatSyncRunConfig) async throws -> BeatSyncRunRecord {
        let record = try await rig.measure(config)
        try BeatSyncRig.append(record)
        return record
    }

    private let timeDomain = AVAudioTimePitchAlgorithm.timeDomain
    private let spectral = AVAudioTimePitchAlgorithm.spectral

    @Test("smoke: one run at rate 1.00 measures clicks for both decks")
    func smoke() async throws {
        let rig = try await BeatSyncRig.open(deviceUID: spikeDevice)
        defer { rig.close() }
        let record = try await runAndRecord(rig, BeatSyncRunConfig(label: "smoke", rate: 1, algorithm: timeDomain))
        #expect(record.failure == nil, "\(record.failure ?? "")")
        #expect(record.matched >= 20)
    }

    @Test("the rate sweep: 5 runs per rate per pitch algorithm, plus the default algorithm at 1.00")
    func rateSweep() async throws {
        let rig = try await BeatSyncRig.open(deviceUID: spikeDevice)
        defer { rig.close() }
        var failures: [String] = []
        for run in 1...5 {
            let record = try await runAndRecord(rig, BeatSyncRunConfig(label: "sweep-\(run)", rate: 1, algorithm: nil))
            if let failure = record.failure { failures.append("default 1.00 #\(run): \(failure)") }
        }
        for algorithm in [timeDomain, spectral] {
            for rate in [1.0, 0.96, 1.04, 0.92, 1.08] {
                for run in 1...5 {
                    let record = try await runAndRecord(
                        rig, BeatSyncRunConfig(label: "sweep-\(run)", rate: rate, algorithm: algorithm)
                    )
                    if let failure = record.failure { failures.append("\(algorithm.rawValue) \(rate) #\(run): \(failure)") }
                }
            }
        }
        try BeatSyncReport.write()
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test("one 60 s overlap at rate 1.00 for drift over a whole track")
    func longRun() async throws {
        let rig = try await BeatSyncRig.open(deviceUID: spikeDevice)
        defer { rig.close() }
        let record = try await runAndRecord(rig, BeatSyncRunConfig(label: "long-60s", rate: 1, algorithm: nil, overlapSeconds: 60))
        try BeatSyncReport.write()
        #expect(record.failure == nil, "\(record.failure ?? "")")
    }

    @Test("does a shared clock matter: B and A on the host clock, then on the output device's audio clock")
    func sharedClock() async throws {
        let rig = try await BeatSyncRig.open(deviceUID: spikeDevice)
        defer { rig.close() }
        var failures: [String] = []
        for clock in [BeatSyncRunConfig.Clock.host, .audioDevice] {
            for run in 1...3 {
                var config = BeatSyncRunConfig(label: "clock-\(run)", rate: 1, algorithm: nil)
                config.clock = clock
                let record = try await runAndRecord(rig, config)
                if let failure = record.failure { failures.append("\(clock.rawValue) #\(run): \(failure)") }
            }
        }
        try BeatSyncReport.write()
        #expect(failures.isEmpty, "\(failures)")
    }
}
