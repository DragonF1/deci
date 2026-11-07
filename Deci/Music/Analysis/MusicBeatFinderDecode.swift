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

    /// The whole file averaged to mono at its own sample rate. `maxSeconds` stops reading early.
    static func decodeMono(file: URL, maxSeconds: Double? = nil) async throws -> Decoded {
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
        let frameLimit = maxSeconds.map { Int(($0 * sampleRate).rounded()) } ?? Int.max
        guard reader.startReading() else { throw Failure.unreadable }

        var mono = [Float]()
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
