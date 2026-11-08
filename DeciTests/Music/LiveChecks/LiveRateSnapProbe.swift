// DeciTests/Music/LiveChecks/LiveRateSnapProbe.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1). Does putting a playing deck from 0.99998 back to exactly 1 leave a gap in the
// chain's output? Real song, real engine, recorded at the DSP chain like check 10. One lease plays throughout.

import Foundation
import AVFoundation
import Testing
@testable import Deci

@MainActor
@Suite("LiveRateSnapProbe", .serialized, .enabled(if: liveGate))
struct LiveRateSnapProbe {
    @Test("setting the rate from 0.99998 to 1 on a playing deck does not open a gap")
    func rateSnapIsGapless() async throws {
        let world = try await LiveWorld.shared()
        MusicRenderRecorder.mutesOutput = true
        defer { LiveAudio.end() }
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(1, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.avPlayer.preventsDisplaySleepDuringVideoPlayback = false
        engine.load(world.songs[6].stream, startAt: 20, autoplay: true)
        let playing = await waitUntil(timeout: .seconds(30)) { engine.position > 21 && engine.avPlayer.rate != 0 }
        #expect(playing)
        var gaps: [String] = []
        for trial in 0..<5 {
            let recorder = MusicRenderRecorder(seconds: 20)
            MusicRenderRecorder.current = recorder
            engine.avPlayer.rate = 0.99998
            try? await Task.sleep(for: .seconds(2))
            let hostAtSnap = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            engine.avPlayer.rate = 0.9999
            try? await Task.sleep(for: .seconds(2))
            MusicRenderRecorder.current = nil
            let snap = recorder.snapshot()
            var detail: [String] = []
            let scan = LiveScan.chainDropouts(snap, fadeStart: hostAtSnap, fadeEnd: nil, rateEvents: [], roles: [:], samples: [], detail: &detail)
            print("LIVE ratesnap trial \(trial): dropouts \(scan.count) \(detail.joined(separator: "; ")) callbacks \(snap.records.count)")
            if scan.count > 0 { gaps.append(contentsOf: detail) }
        }
        // The end of a beat mix's glide: a deck at 0.985 stepping to 0.99 (no change of path) and then back to exactly 1.
        var glideGaps: [String] = []
        for trial in 0..<3 {
            engine.avPlayer.rate = 0.985
            try? await Task.sleep(for: .seconds(1.5))
            let recorder = MusicRenderRecorder(seconds: 20)
            MusicRenderRecorder.current = recorder
            engine.avPlayer.rate = 0.99
            try? await Task.sleep(for: .seconds(2))
            let hostAtOne = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            engine.avPlayer.rate = 0.9999
            try? await Task.sleep(for: .seconds(2))
            MusicRenderRecorder.current = nil
            let snap = recorder.snapshot()
            var stepDetail: [String] = []
            let scan = LiveScan.chainDropouts(snap, fadeStart: hostAtOne, fadeEnd: nil, rateEvents: [], roles: [:], samples: [], detail: &stepDetail)
            print("LIVE glideend trial \(trial): dropouts \(scan.count) \(stepDetail.joined(separator: "; ")) callbacks \(snap.records.count)")
            glideGaps.append(contentsOf: stepDetail.filter { $0.contains("during fade") })
        }
        engine.unload()
        print("LIVE ratesnap summary: 0.99998 to 1 gaps \(gaps.count)")
        print("LIVE ratesnap summary: 0.99 to 0.9999 gaps \(glideGaps.count)")
    }
}
