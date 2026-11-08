// DeciTests/Music/LiveChecks/LiveRateSnapProbe.swift
// Informational probe (never fails): which AVPlayer rate changes open a gap of digital silence in the chain output.
// Gated like the live checks. Each case plays a real song through the real engine deck and DSP chain, records the chain
// output (zeroed afterwards, so nothing is heard) and lists every silence of 30 ms or more that starts after the change.

import Foundation
import AVFoundation
import Testing
@testable import Deci

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECI_LIVE"] == "1" && ProcessInfo.processInfo.environment["DECI_LIVE_ONLY"] != "engine"))
struct LiveRateSnapProbe {
    private static func smooth(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

    @Test("rate changes: lone sets gap, the engine glide does not")
    func rateChangeGaps() async throws {
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

        /// Runs `body` after the deck has settled at `start`, records the chain, and prints the gaps that follow the body's start.
        func measure(_ label: String, start: Float, algorithm: AVAudioTimePitchAlgorithm, body: () async -> Void) async -> Int {
            engine.avPlayer.currentItem?.audioTimePitchAlgorithm = algorithm
            engine.avPlayer.rate = start
            try? await Task.sleep(for: .seconds(2))
            let recorder = MusicRenderRecorder(seconds: 40)
            MusicRenderRecorder.current = recorder
            try? await Task.sleep(for: .seconds(1))
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            await body()
            try? await Task.sleep(for: .seconds(1.5))
            MusicRenderRecorder.current = nil
            var detail: [String] = []
            _ = LiveScan.chainDropouts(recorder.snapshot(), fadeStart: t0, fadeEnd: nil, minMs: 8, rateEvents: [], roles: [:], samples: [], detail: &detail)
            let gaps = detail.filter { $0.contains("during fade") }.compactMap { line -> String? in
                guard let ms = line.components(separatedBy: ", ").dropFirst().first else { return nil }
                return ms
            }
            print("LIVE rateprobe \(label) [\(algorithm == .spectral ? "spectral" : "timeDomain")]: gaps \(gaps.count) \(gaps.joined(separator: " "))")
            return gaps.count
        }

        /// A smoothstep from `from` to `target` in 0.1 s ticks over `seconds`, set straight on the player.
        func ticks(from: Float, to target: Float, seconds: Double, finalSet: Float?) async {
            let n = Int(seconds / 0.1)
            for i in 1..<n {
                engine.avPlayer.rate = from + (target - from) * Float(Self.smooth(Double(i) / Double(n)))
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let finalSet { engine.avPlayer.rate = finalSet }
        }

        let algorithm = AVAudioTimePitchAlgorithm.spectral
        for trial in 0..<2 {
            _ = trial
            _ = await measure("control, no change at 0.988", start: 0.988, algorithm: algorithm) { try? await Task.sleep(for: .seconds(6)) }
            _ = await measure("control, no change at 1", start: 1, algorithm: algorithm) { try? await Task.sleep(for: .seconds(6)) }
            let tickGaps = await measure("ticks 0.988 to 0.9999 over 6 s", start: 0.988, algorithm: algorithm) {
                await ticks(from: 0.988, to: 0.9999, seconds: 6, finalSet: nil)
            }
            #expect(tickGaps == 0, "a smoothstep in 0.1 s ticks between non-1 rates opened a gap")
            let glideGaps = await measure("engine glide 0.988 over 6 s (ends at exactly 1)", start: 0.988, algorithm: algorithm) {
                engine.debugStartGlide(from: 0.988, over: 6)
                _ = await waitUntil(timeout: .seconds(12)) { engine.debugGlide == nil }
            }
            // A lone rate change from a steady state does open a gap (35 to 150 ms, crossing exactly 1 the longest), but the
            // engine's glide, including its final set to exactly 1, measures none down to 8 ms.
            #expect(glideGaps == 0, "the engine's glide back to 1 opened a gap")
            _ = await measure("lone set 0.9999 to 1", start: 0.9999, algorithm: algorithm) { engine.avPlayer.rate = 1 }
        }
        engine.unload()
    }
}
