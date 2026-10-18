// Deci/Music/Playback/MusicAudioTap.swift
import AVFoundation
import AudioToolbox
import MediaToolbox
import os

/// Puts the `MusicDSPChain` on an `AVPlayerItem` with an `MTAudioProcessingTap`.
///
/// The player runs in Deci's own process, which the Core Audio process-tap mixer never taps, so the audio is shaped
/// here instead: the tap sits on the item's first audio track, after the player decodes it and before the output.
enum MusicAudioTap {
    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicAudioTap")

    /// The audio mix for `asset`'s first audio track with the tap attached, or nil when the asset has no readable audio
    /// track or the tap cannot be created (the caller then plays the item unprocessed).
    ///
    /// `onPassThrough` is called, from whatever thread Core Audio prepares the tap on, when the tap meets a format it
    /// cannot process and lets the audio through untouched: the caller then has to apply volume and mute itself.
    static func makeAudioMix(
        for asset: AVAsset,
        chain: MusicDSPChain,
        onPassThrough: @escaping @Sendable () -> Void = {}
    ) async -> AVAudioMix? {
        let track: AVAssetTrack
        do {
            guard let first = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
            track = first
        } catch {
            // A cancelled load is a newer track or a timeout taking over, not a failure.
            if !Task.isCancelled { noteLoadFailure(error) }
            return nil
        }
        guard let tap = makeTap(chain: chain, onPassThrough: onPassThrough) else { return nil }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    private static let loggedLoadFailure = OSAllocatedUnfairLock(initialState: false)

    /// Logged once: fixed text and the error's domain and code. Never the error's own text, which can carry the URL.
    private static func noteLoadFailure(_ error: any Error) {
        let first = loggedLoadFailure.withLock { logged in
            defer { logged = true }
            return !logged
        }
        guard first else { return }
        let nsError = error as NSError
        logger.error("Loading the audio track for the tap failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
    }

    private static func makeTap(chain: MusicDSPChain, onPassThrough: @escaping @Sendable () -> Void) -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(MusicTapContext(chain: chain, onPassThrough: onPassThrough))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context.toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        guard status == noErr, let tap else {
            // Finalize never runs for a tap that was not created, so the context is released here.
            context.release()
            logger.error("MTAudioProcessingTapCreate failed with status \(status)")
            return nil
        }
        return tap
    }
}

/// What the tap's C callbacks reach through the tap's storage. Holds the chain and a pass-through report, nothing else:
/// no player, no service, no UI. Retained once with `Unmanaged.passRetained` when the tap is made and released in
/// `finalize`.
final class MusicTapContext: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicAudioTap")

    let chain: MusicDSPChain
    /// Told from `prepare` when the format is one the DSP cannot process and the audio goes through untouched.
    private let onPassThrough: @Sendable () -> Void
    /// Set in prepare, cleared in unprepare. The tap calls prepare, process and unprepare one after another.
    private nonisolated(unsafe) var lease: MusicRenderLease?

    init(chain: MusicDSPChain, onPassThrough: @escaping @Sendable () -> Void = {}) {
        self.chain = chain
        self.onPassThrough = onPassThrough
    }

    func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        let isFloat = format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
        let isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let observed = MusicTapFormat(
            sampleRate: format.mSampleRate,
            channelCount: Int(format.mChannelsPerFrame),
            isFloat32: isFloat,
            isInterleaved: isInterleaved
        )
        chain.noteFormat(observed)
        Self.logger.info("Tap prepared: \(observed.description), up to \(maxFrames) frames per call")

        guard isFloat else {
            // Not something the DSP understands: let the audio through untouched rather than mangle it.
            Self.logger.error("Tap format is not Float32 PCM, passing the audio through")
            lease = nil
            onPassThrough()
            return
        }
        lease = MusicRenderLease(chain: chain, sampleRate: format.mSampleRate, maxFrames: maxFrames)
    }

    func unprepare() {
        lease?.release()
        lease = nil
    }

    /// Real-time safe: no allocation, locks or logging.
    func render(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        lease?.render(list, frames: frames)
    }
}

// MARK: - C callbacks (no captures: everything comes through the tap's storage)

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<MusicTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, format in
    let context = Unmanaged<MusicTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.prepare(maxFrames: Int(maxFrames), format: format.pointee)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    Unmanaged<MusicTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepare()
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else {
        numberFramesOut.pointee = 0
        return
    }
    let context = Unmanaged<MusicTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.render(UnsafeMutableAudioBufferListPointer(bufferListInOut), frames: Int(numberFramesOut.pointee))
}
