// DeciTests/Music/MusicAudioTestSupport.swift
// Shared by the music audio suites: test signals, AudioBufferLists over test-owned memory, and a tone file in
// the shape YouTube serves (fragmented AAC mp4) that is read back offline. Nothing here reaches an output device.

import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
@testable import Deci

nonisolated enum MusicTestSignal {
    /// A sine wave, one array per channel (every channel carries the same wave).
    static func sine(
        frequency: Double,
        amplitude: Float,
        sampleRate: Double,
        frames: Int,
        channels: Int = 2
    ) -> [[Float]] {
        let wave = (0..<frames).map { frame in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
        }
        return Array(repeating: wave, count: channels)
    }

    static func constant(_ value: Float, frames: Int, channels: Int = 2) -> [[Float]] {
        Array(repeating: Array(repeating: value, count: frames), count: channels)
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }
}

/// An `AudioBufferList` over memory the test owns, either one interleaved buffer or one buffer per channel.
nonisolated final class TestBufferList {
    enum Layout { case interleaved, planar }

    let layout: Layout
    let channelCount: Int
    let frames: Int
    let list: UnsafeMutableAudioBufferListPointer
    private let rawList: UnsafeMutableRawPointer
    private var blocks: [UnsafeMutablePointer<Float>] = []

    init(channels: [[Float]], layout: Layout) {
        precondition(!channels.isEmpty && channels.allSatisfy { $0.count == channels[0].count })
        self.layout = layout
        self.channelCount = channels.count
        self.frames = channels[0].count

        let bufferCount = layout == .interleaved ? 1 : channels.count
        let byteCount = MemoryLayout<AudioBufferList>.size + (bufferCount - 1) * MemoryLayout<AudioBuffer>.stride
        rawList = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
        let typed = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        typed.pointee.mNumberBuffers = UInt32(bufferCount)
        list = UnsafeMutableAudioBufferListPointer(typed)

        switch layout {
        case .interleaved:
            let block = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frames * channels.count))
            for frame in 0..<frames {
                for channel in 0..<channels.count { block[frame * channels.count + channel] = channels[channel][frame] }
            }
            blocks.append(block)
            list[0] = AudioBuffer(
                mNumberChannels: UInt32(channels.count),
                mDataByteSize: UInt32(frames * channels.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(block)
            )
        case .planar:
            for (index, channel) in channels.enumerated() {
                let block = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frames))
                for frame in 0..<frames { block[frame] = channel[frame] }
                blocks.append(block)
                list[index] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(block)
                )
            }
        }
    }

    deinit {
        for block in blocks { block.deallocate() }
        rawList.deallocate()
    }

    func samples(channel: Int) -> [Float] {
        switch layout {
        case .interleaved:
            (0..<frames).map { blocks[0][$0 * channelCount + channel] }
        case .planar:
            (0..<frames).map { blocks[channel][$0] }
        }
    }
}

/// The offline file the tap proof runs on: stereo AAC in a fragmented mp4, like the streams YouTube serves.
enum ToneFile {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Writes `samples` (interleaved stereo Float32) as fragmented AAC mp4.
    static func write(interleavedStereo samples: [Float], sampleRate: Double, to url: URL) async throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { throw Failure(description: "format \(formatStatus)") }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ],
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure(description: "cannot add input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure(description: "startWriting: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)

        let chunkFrames = 1024
        let totalFrames = samples.count / 2
        var frame = 0
        while frame < totalFrames {
            let count = min(chunkFrames, totalFrames - frame)
            let byteCount = count * 8
            var block: CMBlockBuffer?
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
            )
            guard blockStatus == noErr, let block else { throw Failure(description: "block \(blockStatus)") }
            let replaced = samples.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!.advanced(by: frame * 8), blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: byteCount
                )
            }
            guard replaced == noErr else { throw Failure(description: "replace \(replaced)") }

            var sampleBuffer: CMSampleBuffer?
            let bufferStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: formatDescription, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sampleBuffer
            )
            guard bufferStatus == noErr, let sampleBuffer else { throw Failure(description: "sample buffer \(bufferStatus)") }

            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard input.append(sampleBuffer) else { throw Failure(description: "append: \(String(describing: writer.error))") }
            frame += count
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw Failure(description: "finish: \(String(describing: writer.error))") }
    }

    /// Decodes the file's audio track to interleaved stereo Float32 through `AVAssetReaderAudioMixOutput`,
    /// with the tap's mix when `chain` is given. Offline: nothing is played.
    static func read(url: URL, tappedBy chain: MusicDSPChain?) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure(description: "no audio track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2,
        ])
        if let chain {
            guard let mix = await MusicAudioTap.makeAudioMix(for: asset, chain: chain) else {
                throw Failure(description: "no mix")
            }
            output.audioMix = mix
        }
        guard reader.canAdd(output) else { throw Failure(description: "cannot add output") }
        reader.add(output)
        guard reader.startReading() else { throw Failure(description: "startReading: \(String(describing: reader.error))") }

        var result: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == noErr else { throw Failure(description: "copy \(status)") }
            result.append(contentsOf: chunk)
        }
        guard reader.status == .completed else { throw Failure(description: "read: \(String(describing: reader.error))") }
        return result
    }
}
