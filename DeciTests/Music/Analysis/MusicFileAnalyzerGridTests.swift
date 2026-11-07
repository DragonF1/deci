// DeciTests/Music/Analysis/MusicFileAnalyzerGridTests.swift
// The file front end returns a beat grid from the same decode that measures loudness, and stores it in the row.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicFileAnalyzerGrid", .serialized)
struct MusicFileAnalyzerGridTests {
    static let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci-3b/fixtures", isDirectory: true)

    static func writeKicks(name: String, bpm: Double, seconds: Double) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let track = BeatSynth.pulse(bpm: bpm, seconds: seconds, sampleRate: 44_100, offset: 0.3, click: false)
        var stereo = [Float](repeating: 0, count: track.samples.count * 2)
        for (index, sample) in track.samples.enumerated() { stereo[2 * index] = sample; stereo[2 * index + 1] = sample }
        try await ToneFile.write(interleavedStereo: stereo, sampleRate: 44_100, to: url)
        return url
    }

    @Test("an AAC kick file analyses with a grid at its tempo, and the entry stores it")
    func gridFromFile() async throws {
        let url = try await Self.writeKicks(name: "grid-kicks-124.m4a", bpm: 124, seconds: 30)
        let result = try await MusicFileAnalyzer.analyze(file: url, exactDuration: 30)
        let grid = try #require(result.measurement.beatGrid, "no grid")
        #expect(abs(grid.bpm - 124) < 0.5, "bpm \(grid.bpm)")
        #expect(grid.beatConfidence >= 0.8, "confidence \(grid.beatConfidence)")

        let entry = MusicAnalysis(videoId: "4D7u5KF7SP8", result: result, source: .playbackCache)
        #expect(entry.version == MusicAnalysis.currentVersion)
        #expect(entry.usableGrid == grid)
    }

    @Test("a file with no beats still analyses, with no grid")
    func noGridIsNotAFailure() async throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = Self.directory.appendingPathComponent("grid-tone.m4a")
        try? FileManager.default.removeItem(at: url)
        let tone = MusicTestSignal.sine(frequency: 440, amplitude: 0.3, sampleRate: 44_100, frames: 44_100 * 8, channels: 1)[0]
        var stereo = [Float](repeating: 0, count: tone.count * 2)
        for (index, sample) in tone.enumerated() { stereo[2 * index] = sample; stereo[2 * index + 1] = sample }
        try await ToneFile.write(interleavedStereo: stereo, sampleRate: 44_100, to: url)
        let result = try await MusicFileAnalyzer.analyze(file: url, exactDuration: 8)
        #expect(result.measurement.beatGrid == nil)
        #expect(!result.measurement.isSilent)
    }
}
