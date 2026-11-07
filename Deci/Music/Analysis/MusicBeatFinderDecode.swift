// Deci/Music/Analysis/MusicBeatFinderDecode.swift
// Reads a song file to mono Float samples for MusicBeatFinder, with the same AVAssetReader setup as MusicFileAnalyzer:
// native sample rate, 32 bit float PCM, decoded wherever the caller runs it (never the main thread in the app).

import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

nonisolated enum MusicBeatDecoder {
    enum Failure: Error, Equatable { case unreadable, empty }

    struct Decoded: Sendable {
        var samples: [Float]
        var sampleRate: Double
    }

    /// Longest stretch read by default: 10 minutes of 48 kHz mono is about 115 MB, and the finder copies it once.
    static let defaultMaxSeconds = 600.0

    /// The file averaged to mono at its own sample rate, at most `maxSeconds` of it. `@concurrent` keeps the blocking
    /// read off the caller's actor (the app target runs nonisolated async code on the caller's actor otherwise).
    @concurrent
    static func decodeMono(file: URL, maxSeconds: Double = defaultMaxSeconds) async throws -> Decoded {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let description = try? await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { throw Failure.unreadable }
        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)

        guard let reader = try? AVAssetReader(asset: asset) else { throw Failure.unreadable }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.unreadable }
        reader.add(output)
        let frameLimit = max(1, Int((min(maxSeconds, 24 * 3600) * sampleRate).rounded()))
        guard reader.startReading() else { throw Failure.unreadable }

        var mono = [Float]()
        mono.reserveCapacity(min(frameLimit, Int(sampleRate * 600)))
        var scratch = [Float]()
        while mono.count < frameLimit, let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let frames = CMBlockBufferGetDataLength(block) / (MemoryLayout<Float>.size * channels)
            guard frames > 0 else { continue }
            if scratch.count < frames * channels { scratch = [Float](repeating: 0, count: frames * channels) }
            let status = scratch.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * channels * MemoryLayout<Float>.size, destination: $0.baseAddress!)
            }
            guard status == noErr else { reader.cancelReading(); throw Failure.unreadable }
            let take = min(frames, frameLimit - mono.count)
            for frame in 0..<take {
                var sum: Float = 0
                for channel in 0..<channels { sum += scratch[frame * channels + channel] }
                mono.append(sum / Float(channels))
            }
        }
        if mono.count < frameLimit, reader.status == .failed { throw Failure.unreadable }
        reader.cancelReading()
        guard !mono.isEmpty else { throw Failure.empty }
        return Decoded(samples: mono, sampleRate: sampleRate)
    }
}
