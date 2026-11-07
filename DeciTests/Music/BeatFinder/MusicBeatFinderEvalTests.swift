// DeciTests/Music/BeatFinder/MusicBeatFinderEvalTests.swift
// Opt-in evaluation on real song files: decodes each with the app's decode path, runs the beat finder and writes one
// JSON per song for the librosa comparison. Run with TEST_RUNNER_DECI_BEAT_EVAL=1 (optionally TEST_RUNNER_DECI_BEAT_SONGS
// and TEST_RUNNER_DECI_BEAT_OUT). Reads songs only; writes only under the output folder.

import Foundation
import Testing
@testable import Deci

@Suite("MusicBeatFinder eval", .serialized)
struct MusicBeatFinderEvalTests {
    @Test(
        "analyse every song in the folder",
        .enabled(if: ProcessInfo.processInfo.environment["DECI_BEAT_EVAL"] == "1")
    )
    func evaluate() async throws {
        let environment = ProcessInfo.processInfo.environment
        let songs = URL(fileURLWithPath: environment["DECI_BEAT_SONGS"] ?? "/Volumes/Storage/_test/deci-3a/songs", isDirectory: true)
        let out = URL(fileURLWithPath: environment["DECI_BEAT_OUT"] ?? "/Volumes/Storage/_test/deci-3a/beat/ours", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: songs, includingPropertiesForKeys: nil)
            .filter { ["m4a", "mp4", "aac", "mp3", "wav", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)

        for file in files {
            let clock = ContinuousClock()
            var decoded: MusicBeatDecoder.Decoded?
            let decodeTime = try await clock.measure { decoded = try await MusicBeatDecoder.decodeMono(file: file) }
            let audio = try #require(decoded)
            var result = MusicBeatResult.empty
            let analyzeTime = clock.measure { result = MusicBeatFinder.analyze(samples: audio.samples, sampleRate: audio.sampleRate) }
            func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

            var json: [String: Any] = [
                "id": file.deletingPathExtension().lastPathComponent,
                "seconds": Double(audio.samples.count) / audio.sampleRate,
                "sampleRate": audio.sampleRate,
                "bpm": result.bpm,
                "confidence": result.confidence,
                "beats": result.beats,
                "intervalSpread": result.intervalSpread,
                "decodeSeconds": seconds(decodeTime),
                "analyzeSeconds": seconds(analyzeTime),
            ]
            if let downbeat = result.downbeat {
                json["downbeatPhase"] = downbeat.phase
                json["downbeatConfidence"] = downbeat.confidence
            }
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try data.write(to: out.appendingPathComponent(json["id"] as! String + ".json"))
        }
    }
}
