import Foundation
import Testing
@testable import Deci

/// The Swift front end and the Core ML model against numbers the Python reference produced for 32 s of a generated
/// drum loop (synth-32s-int16-22050.pcm, int16 at 22050 Hz, about 120 bpm with a slow drift). Hosted: the model is loaded from the app bundle.
@Suite(.serialized) struct BeatThisParityTests {
    private struct Reference: Decodable {
        var first_samples: [Float]
        var mel_first_8_frames: [[Float]]
        var chunk_starts_first_5: [Int]
        var logits_first_20_beat_coreml: [Float]
        var logits_first_20_downbeat_coreml: [Float]
    }

    private struct Times: Decodable { var beats: [Double]; var downbeats: [Double] }

    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private static func samples() throws -> [Float] {
        let data = try Data(contentsOf: folder.appendingPathComponent("synth-32s-int16-22050.pcm"))
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
    }

    private static func reference() throws -> Reference {
        try JSONDecoder().decode(Reference.self, from: Data(contentsOf: folder.appendingPathComponent("synth-reference.json")))
    }

    private static func tracker() throws -> BeatThisTracker {
        try #require(BeatThisEngine.sharedTracker)
    }

    @Test func fixtureIsThirtyTwoSeconds() throws {
        #expect(try Self.samples().count == 32 * 22050)
    }

    @Test func melFirstFramesMatchReference() throws {
        let ref = try Self.reference()
        let samples = try Self.samples()
        for (a, b) in zip(samples, ref.first_samples) { #expect(abs(a - b) <= 1e-4) }
        let mel = try Self.tracker().mel.logMel(samples)
        #expect(mel.count / 128 == BeatThisMel.frameCount(samples: samples.count))
        var worst: Float = 0
        for t in 0..<8 {
            for b in 0..<128 {
                let want = ref.mel_first_8_frames[t][b], got = mel[t * 128 + b]
                worst = max(worst, abs(got - want) / max(abs(want), 1e-2))
            }
        }
        #expect(worst < 1e-3)
    }

    @Test func chunkStartsMatchReference() throws {
        let ref = try Self.reference()
        let length = BeatThisMel.frameCount(samples: 32 * 22050)
        let starts = BeatThisChunker.starts(length: length)
        #expect(starts.first == ref.chunk_starts_first_5.first)
        #expect(starts.count == 2)
    }

    @Test func firstLogitsMatchCoreMLReference() throws {
        let ref = try Self.reference()
        let tracker = try Self.tracker()
        let spect = tracker.mel.logMel(try Self.samples())
        let length = spect.count / 128
        let starts = BeatThisChunker.starts(length: length)
        let logits = try starts.map { try tracker.model.predict(chunk: BeatThisChunker.chunk(spect: spect, length: length, start: $0)) }
        let piece = BeatThisChunker.aggregate(starts: starts, logits: logits, length: length)
        var worst: Float = 0
        for i in 0..<20 {
            worst = max(worst, abs(piece.beat[i] - ref.logits_first_20_beat_coreml[i]), abs(piece.downbeat[i] - ref.logits_first_20_downbeat_coreml[i]))
        }
        #expect(worst < 0.5)
    }

    @Test func pickedTimesMatchPythonRunBeforeTwentyNineSeconds() throws {
        let want = try JSONDecoder().decode(Times.self, from: Data(contentsOf: Self.folder.appendingPathComponent("synth-python-times-before-29s.json")))
        let out = try #require(try Self.tracker().track(samples: Self.samples()))
        let beats = out.beats.filter { $0 < 29 }
        let downbeats = out.downbeats.filter { $0 < 29 }
        #expect(beats.count == want.beats.count)
        #expect(downbeats.count == want.downbeats.count)
        for (x, y) in zip(beats, want.beats) { #expect(abs(x - y) <= 0.0105) }
        for (x, y) in zip(downbeats, want.downbeats) { #expect(abs(x - y) <= 0.0105) }
    }

    @Test func engineGivesAGridFor32SecondsOfMusic() throws {
        let outcome = BeatThisEngine.grid(samples: try Self.samples(), duration: 32)
        guard case .grid(let grid) = outcome else {
            Issue.record("no grid: \(outcome)")
            return
        }
        #expect(grid.bpm > 60 && grid.bpm < 200)
        #expect(grid.beatConfidence > 0.5)
    }

    @Test func engineAnswersCancelledOrShortAudioWithoutCrashing() throws {
        // Two seconds of silence: no beats, so no grid, and the caller falls back to the finder.
        let outcome = BeatThisEngine.grid(samples: [Float](repeating: 0, count: 2 * 22050), duration: 2)
        if case .grid = outcome { Issue.record("silence gave a grid") }
    }
}
