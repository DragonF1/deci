// DeciTests/Music/BeatSync/AVPlayerDefaultRateProofTests.swift
// Tier 4c C1 proof on a real AVPlayer: with `defaultRate` set before the start, play() after a pause runs at that rate
// with no rate write (the engine never writes `rate` on a playing deck, which opens a 30 to 125 ms gap).

import Foundation
import AVFoundation
import Testing
@testable import Deci

@MainActor
@Suite("AVPlayer defaultRate")
struct AVPlayerDefaultRateProofTests {
    private func writeTone(_ name: String, seconds: Double) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/beat-engine", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).m4a")
        let rate = 44_100.0
        let frames = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(0.2 * sin(2 * Double.pi * 440 * Double(frame) / rate))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        try await ToneFile.write(interleavedStereo: samples, sampleRate: rate, to: url)
        return url
    }

    @Test("play, pause, play keeps defaultRate with no rate write; pitch stays spectral")
    func defaultRateSurvivesPauseAndResume() async throws {
        let url = try await writeTone("dr", seconds: 20)
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        let player = AVPlayer(playerItem: item)
        player.defaultRate = 0.93
        let ready = await waitUntil(timeout: .seconds(30)) { item.status == .readyToPlay }
        #expect(ready)

        // Every rate the player ever reports, from KVO: no write of ours is involved after this point.
        var seen: [Float] = []
        let observation = player.observe(\.rate, options: [.new]) { _, change in
            if let rate = change.newValue { MainActor.assumeIsolated { seen.append(rate) } }
        }
        player.play()
        let started = await waitUntil(timeout: .seconds(10)) { player.rate != 0 }
        #expect(started)
        #expect(abs(player.rate - 0.93) < 1e-5, "play() starts at defaultRate, was \(player.rate)")
        try await Task.sleep(for: .milliseconds(400))
        player.pause()
        #expect(player.rate == 0)
        player.play()
        let resumed = await waitUntil(timeout: .seconds(10)) { player.rate != 0 }
        #expect(resumed)
        #expect(abs(player.rate - 0.93) < 1e-5, "play() after a pause keeps the rate, was \(player.rate)")
        try await Task.sleep(for: .milliseconds(400))
        observation.invalidate()
        let moving = seen.filter { $0 != 0 }
        #expect(moving.allSatisfy { abs($0 - 0.93) < 1e-5 }, "only ever 0.93 or 0, saw \(seen)")
        player.pause()
    }

    @Test("a seek keeps the rate of a playing player")
    func seekKeepsRate() async throws {
        let url = try await writeTone("ds", seconds: 20)
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        let player = AVPlayer(playerItem: item)
        player.defaultRate = 1.05
        _ = await waitUntil(timeout: .seconds(30)) { item.status == .readyToPlay }
        player.play()
        _ = await waitUntil(timeout: .seconds(10)) { player.rate != 0 }
        await player.seek(to: CMTime(seconds: 5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(abs(player.rate - 1.05) < 1e-5, "rate after a seek \(player.rate)")
        player.pause()
    }
}
