// DeciTests/Music/MusicFileAnalyzerTests.swift
// The AVAssetReader front end on real fragmented AAC mp4 files written by ToneFile.

import Foundation
import AVFoundation
import os
import Testing
@testable import Deci

@MainActor
@Suite("MusicFileAnalyzer", .serialized)
struct MusicFileAnalyzerTests {
    static let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci-2a", isDirectory: true)

    private static func interleaved(_ channels: [[Float]]) -> [Float] {
        var out = [Float](repeating: 0, count: channels[0].count * 2)
        for frame in 0..<channels[0].count {
            out[frame * 2] = channels[0][frame]
            out[frame * 2 + 1] = channels[1][frame]
        }
        return out
    }

    /// Writes (or reuses) a fragmented AAC file for `name`.
    private static func file(_ name: String, rebuild: Bool = false, channels: () -> [[Float]]) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        if !rebuild, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { return url }
        try? FileManager.default.removeItem(at: url)
        try await ToneFile.write(interleavedStereo: interleaved(channels()), sampleRate: 44_100, to: url)
        return url
    }

    private static func twelveSeconds() async throws -> URL {
        try await file("p2-twelve.m4a", rebuild: true) {
            AnalyzerSignal.concat([
                AnalyzerSignal.segment(rmsDb: nil, seconds: 1.5),
                AnalyzerSignal.segment(rmsDb: -20, seconds: 8),
                AnalyzerSignal.segment(rmsDb: nil, seconds: 2.5),
            ])
        }
    }

    private static func fourMinutes() async throws -> URL {
        try await file("p2-four-minutes.m4a") {
            // Four 60 s sections at different levels, so the file has an intro-like ramp and a body.
            AnalyzerSignal.concat([-30.0, -18, -14, -22].map { AnalyzerSignal.segment(rmsDb: $0, seconds: 60) })
        }
    }

    @Test("Two-segment tone: edges within AAC priming, codec string, exact duration")
    func edgesAndFormat() async throws {
        let url = try await Self.twelveSeconds()
        let result = try await MusicFileAnalyzer.analyze(file: url, exactDuration: 12)
        let m = result.measurement
        #expect(abs(m.silenceStart - 1.5) <= 0.15, "silenceStart \(m.silenceStart)")
        #expect(abs(m.silenceEnd - 9.5) <= 0.15, "silenceEnd \(m.silenceEnd)")
        #expect(abs(m.duration - 12) < 0.1)
        #expect(result.format.codec == "mp4a.40.2")
        #expect(result.format.itag == 0)
        #expect(result.format.durationMs == 12_000)
        #expect(m.energy.count == 120)
        #expect(m.integratedLUFS != nil)
        let entry = MusicAnalysis(videoId: "abcDEF12345", result: result, source: .download)
        #expect(entry.format == result.format)
        #expect(entry.energy == m.energy)
    }

    @Test("A chord file gets a key and an energy in the measurement, and the entry stores them")
    func keyAndEnergyFromFile() async throws {
        let url = try await Self.file("p1-key-cmajor.m4a", rebuild: true) {
            // I-IV-V-vi in C, 2.5 s a chord, three harmonics a note.
            let chords: [[Double]] = [
                [261.63, 329.63, 392.0], [174.61, 220.0, 261.63], [196.0, 246.94, 293.66], [220.0, 261.63, 329.63],
            ]
            let per = 44_100 * 5 / 2
            var mixed = [Float](repeating: 0, count: per * chords.count)
            for (slot, notes) in chords.enumerated() {
                for note in notes {
                    for (harmonic, gain) in [(1.0, 1.0), (2.0, 0.5), (3.0, 0.25)] {
                        let step = 2 * Double.pi * note * harmonic / 44_100
                        for index in 0..<per { mixed[slot * per + index] += Float(gain * 0.1 * sin(step * Double(index))) }
                    }
                }
            }
            return [mixed, mixed]
        }
        let result = try await MusicFileAnalyzer.analyze(file: url, exactDuration: 10)
        let info = try #require(result.measurement.keyInfo)
        #expect(info.tonic == 0 && !info.isMinor, "tonic \(info.tonic) minor \(info.isMinor)")
        #expect(info.trustedCamelot == "8B", "confidence \(info.confidence)")
        #expect((0...1).contains(info.energy))
        let entry = MusicAnalysis(videoId: "abcDEF12345", result: result, source: .download)
        #expect(entry.keyInfoValue == info)
    }

    @Test("Doubled duration: what the reader decodes for a fragmented mp4 versus the true 12 s")
    func doubledDuration() async throws {
        let url = try await Self.twelveSeconds()
        let asset = AVURLAsset(url: url)
        let assetDuration = try await asset.load(.duration).seconds
        let free = try await MusicFileAnalyzer.analyze(file: url, exactDuration: nil)
        let clamped = try await MusicFileAnalyzer.analyze(file: url, exactDuration: 12)
        print("FINDING asset.duration=\(assetDuration) decodedWithoutExact=\(free.decodedSeconds) measuredDuration=\(free.measurement.duration) silenceEnd=\(free.measurement.silenceEnd) decodedWithExact=\(clamped.decodedSeconds) trueDuration=12")
        #expect(abs(clamped.measurement.duration - 12) < 0.1)
        #expect(abs(clamped.decodedSeconds - 12) < 0.1)
        #expect(free.measurement.duration > 0)
    }

    @Test("The decode runs off the main thread")
    func offMainThread() async throws {
        let url = try await Self.twelveSeconds()
        let ranOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        _ = try await MusicFileAnalyzer.analyze(file: url, exactDuration: 12, probe: {
            ranOnMain.withLock { $0 = Thread.isMainThread }
        })
        #expect(ranOnMain.withLock { $0 } == false)
    }

    @Test("Cancelling mid-file throws .cancelled within 500 ms")
    func cancellation() async throws {
        let url = try await Self.fourMinutes()
        let task = Task { try await MusicFileAnalyzer.analyze(file: url, exactDuration: 240) }
        try await Task.sleep(for: .milliseconds(60))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a cancellation")
        } catch let failure as MusicFileAnalyzer.Failure {
            #expect(failure == .cancelled)
        }
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
    }

    @Test("A text file renamed .m4a throws .unreadable, and a missing file too")
    func unreadable() async throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fake = Self.directory.appendingPathComponent("p2-not-audio.m4a")
        try Data("this is not audio, just text".utf8).write(to: fake)
        await #expect(throws: MusicFileAnalyzer.Failure.unreadable) {
            _ = try await MusicFileAnalyzer.analyze(file: fake, exactDuration: nil)
        }
        await #expect(throws: MusicFileAnalyzer.Failure.unreadable) {
            _ = try await MusicFileAnalyzer.analyze(file: Self.directory.appendingPathComponent("p2-missing.m4a"), exactDuration: nil)
        }
    }

    @Test("An all-silent file throws .empty")
    func silentFile() async throws {
        let url = try await Self.file("p2-silent.m4a", rebuild: true) { AnalyzerSignal.segment(rmsDb: nil, seconds: 2) }
        await #expect(throws: MusicFileAnalyzer.Failure.empty) {
            _ = try await MusicFileAnalyzer.analyze(file: url, exactDuration: 2)
        }
    }

    @Test("A four minute stereo 44.1 kHz file analyses in under 3 s")
    func performance() async throws {
        let url = try await Self.fourMinutes()
        let clock = ContinuousClock()
        var result: MusicFileAnalyzer.Result?
        let elapsed = try await clock.measure {
            result = try await MusicFileAnalyzer.analyze(file: url, exactDuration: 240)
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("FINDING analysis_4min seconds=\(seconds) lufs=\(String(describing: result?.measurement.integratedLUFS)) energyBlocks=\(result?.measurement.energy.count ?? -1)")
        #expect(seconds < 3)
        #expect(result?.measurement.energy.count == 2400)
        #expect(result?.measurement.integratedLUFS != nil)
    }
}
