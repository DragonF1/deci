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

    /// The deck handle the tap being built belongs to. The engine sets it around a mix build, so the mix builder keeps its
    /// signature; with none, the tap is the active deck's (it claims the chain as it prepares, as it always did).
    @TaskLocal static var currentDeck: MusicTapDeck?

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
        guard let tap = makeTap(chain: chain, deck: currentDeck ?? MusicTapDeck(role: .active), onPassThrough: onPassThrough)
        else { return nil }

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

    private static func makeTap(
        chain: MusicDSPChain, deck: MusicTapDeck, onPassThrough: @escaping @Sendable () -> Void
    ) -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(MusicTapContext(chain: chain, deck: deck, onPassThrough: onPassThrough))
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

/// The engine's handle on one deck's tap. The engine creates it before the mix is built; the tap's prepare attaches the
/// lease it makes, and the engine drives the lease through it: arm just before the deck's scheduled start, activate when
/// the deck becomes the one that plays, retire when it is over. Thread-safe: the tap prepares on a Core Audio thread.
final class MusicTapDeck: @unchecked Sendable {
    enum Role: Sendable { case active, standby }

    let role: Role
    private struct State {
        var lease: MusicRenderLease?
        var armed = false
        var active = false
        /// Once set, this deck never arms or claims again, whatever arrives late (a tap that prepares after its deck
        /// was torn down, a stale arm).
        var retired = false
        /// The outgoing side of a crossfade: a tap that prepares again mid-fade comes back draining.
        var draining = false
        /// The incoming side of a crossfade: a tap that prepares again mid-fade comes back ramping up.
        var fadingIn = false
        /// The loudness offset the deck is heading for (1 = none), so a re-prepared tap comes back with it.
        var offsetGain: Float = 1
    }
    /// Every decision about the lease and the call that carries it out happen under this one lock, so a late arm can
    /// never outlive a disarm. The lease calls are atomic operations and a non-blocking main-queue post: safe to make here.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How a re-prepared tap picks its fade up again, mid-crossfade (approximate by design).
    static let reattachDrain = 0.03
    static let reattachRamp = 0.1

    init(role: Role) {
        self.role = role
    }

    /// Called from the tap's prepare with the lease it made (which does not claim). An active deck claims the chain now;
    /// a standby deck waits to be armed and activated, whichever of those came before its tap was ready.
    func attach(_ lease: MusicRenderLease) {
        state.withLock { state in
            state.lease = lease
            // A re-prepared tap gets a fresh lease at offset 1: bring the deck's offset back with a short ramp.
            if state.offsetGain != 1 { lease.setOffset(to: state.offsetGain, over: MusicTapDeck.reattachRamp) }
            if state.retired {
                lease.release()
            } else if state.draining {
                // Re-prepared in the middle of its own fade-out: it never claims again, and goes quickly rather than
                // cutting off.
                lease.drain(over: MusicTapDeck.reattachDrain, curve: .linear)
            } else if state.fadingIn {
                state.active = true
                lease.claim()
                lease.setFade(to: 1, over: MusicTapDeck.reattachRamp, curve: .linear, fromSilence: true)
            } else if role == .active || state.active {
                state.active = true
                lease.claim()
            } else if state.armed {
                lease.arm()
            }
        }
    }

    #if DEBUG
    /// The tap's lease, for the tests.
    var debugLease: MusicRenderLease? { state.withLock { $0.lease } }
    #endif

    /// Called from the tap's unprepare: the lease is going away.
    func detach() {
        state.withLock { $0.lease = nil }
    }

    /// Lets this deck's tap render next to the playing deck's.
    func arm() {
        state.withLock { state in
            guard !state.retired, !state.active else { return }
            state.armed = true
            state.lease?.arm()
        }
    }

    /// Puts the deck back to unarmed, so it is no longer metered (its start was cancelled).
    func disarm() {
        state.withLock { state in
            state.armed = false
            state.lease?.disarm()
        }
    }

    /// This deck is the one that plays now: its tap owns the chain.
    func activate() {
        state.withLock { state in
            guard !state.retired else { return }
            state.active = true
            state.armed = false
            state.lease?.claim()
        }
    }

    /// Whether the deck's tap has built its lease, so a fade set now takes effect.
    var hasLease: Bool { state.withLock { $0.lease != nil } }

    /// Ramps this deck's fade gain (see `MusicRenderLease.setFade`). Nothing when the tap has no lease yet.
    func fade(to gain: Float, over seconds: Double = 0, curve: MusicFadeCurve = .linear, fromSilence: Bool = false) {
        state.withLock { $0.lease?.setFade(to: gain, over: seconds, curve: curve, fromSilence: fromSilence) }
    }

    /// Ramps this deck's loudness offset (see `MusicRenderLease.setOffset`): attenuation only, clamped to [0, 1]. The
    /// target is kept so a re-prepared tap picks it up again.
    func setOffset(to gain: Float, over seconds: Double = 0) {
        guard gain.isFinite else { return }
        let clamped = min(1, max(0, gain))
        state.withLock { state in
            state.offsetGain = clamped
            state.lease?.setOffset(to: clamped, over: seconds)
        }
    }

    /// Tier 3b P4: starts this deck's bass channel at `gain` (see `MusicRenderLease.beginBass`).
    func beginBass(gain: Float) {
        state.withLock { $0.lease?.beginBass(gain: gain) }
    }

    /// Ramps the bass gain: `seconds` long, starting `delay` seconds of rendered audio from now.
    func setBass(to gain: Float, over seconds: Double = 0, after delay: Double = 0) {
        state.withLock { $0.lease?.setBass(to: gain, over: seconds, after: delay) }
    }

    /// Back to the plain path.
    func endBass() {
        state.withLock { $0.lease?.endBass() }
    }

    #if DEBUG
    var debugBass: MusicRenderLease.DebugBass? { state.withLock { $0.lease?.debugBass } }
    var debugRenderedFrames: Int? { state.withLock { $0.lease?.renderedFrames } }
    var debugLeaseRate: Double? { state.withLock { $0.lease?.processorSampleRate } }
    #endif

    /// Makes this deck the outgoing side of a crossfade: it fades to silence and stays audible until it has (see
    /// `MusicRenderLease.drain`). Call before the incoming deck activates.
    /// `delay` seconds of rendered audio pass first at full level (a quick cut waits for the incoming first frame).
    func drain(over seconds: Double, curve: MusicFadeCurve = .equalPower, after delay: Double = 0) {
        state.withLock { state in
            guard !state.retired else { return }
            state.draining = true
            state.lease?.drain(over: seconds, curve: curve, after: delay)
        }
    }

    /// Tier 4b: starts the echo tail on this deck's lease (see `MusicRenderLease.beginEcho`). `delay` is in seconds; the cut
    /// comes `cutAfter` seconds of rendered audio from now.
    func beginEcho(delay: Double, cutAfter: Double, feedback: Float = MusicEchoSettings.defaultFeedback) {
        state.withLock { state in
            guard !state.retired, let lease = state.lease else { return }
            lease.beginEcho(MusicEchoSettings(
                delayFrames: lease.frames(forSeconds: delay), cutAfterFrames: lease.frames(forSeconds: cutAfter),
                feedback: feedback, wetGain: MusicEchoSettings.defaultWetGain, lowpassHz: MusicEchoSettings.defaultLowpassHz
            ))
        }
    }

    /// False when this deck's lease renders through the gain-only path (no echo possible). True with no lease yet.
    var supportsEcho: Bool { state.withLock { $0.lease?.supportsEcho ?? true } }

    /// Fades the echo tail out over `seconds` (about 30 ms) instead of stepping it off.
    func releaseEcho(over seconds: Double) {
        state.withLock { $0.lease?.releaseEcho(over: seconds) }
    }

    /// Forgets the echo history on this deck's lease (see `MusicRenderLease.clearEchoHistory`).
    func clearEchoHistory() {
        state.withLock { $0.lease?.clearEchoHistory() }
    }

    /// The echo is over (the lease is about to be released).
    func endEcho() {
        state.withLock { $0.lease?.endEcho() }
    }

    /// Tier 4b P2: starts the high-pass sweep on this deck's lease. The cutoff starts to move `after` seconds of rendered
    /// audio from now and takes `over` seconds to get from `fromHz` to `toHz`.
    func beginSweep(fromHz: Double, toHz: Double, after: Double, over: Double) {
        state.withLock { state in
            guard !state.retired, let lease = state.lease else { return }
            lease.beginSweep(MusicSweepSettings(
                startFrame: lease.frames(forSeconds: after), durationFrames: max(1, lease.frames(forSeconds: over)),
                fromHz: Float(fromHz), toHz: Float(toHz), highpass: true
            ))
        }
    }

    /// False when this deck's lease renders through the gain-only path (no sweep possible). True with no lease yet.
    var supportsSweep: Bool { state.withLock { $0.lease?.supportsEcho ?? true } }

    /// The sweep is over (the lease is about to be released).
    func endSweep() {
        state.withLock { $0.lease?.endSweep() }
    }

    /// Marks this deck as the incoming side of a crossfade until `endOverlap()`.
    func beginFadeIn() {
        state.withLock { $0.fadingIn = true }
    }

    /// The overlap is over: a later re-prepare is an ordinary one.
    func endOverlap() {
        state.withLock { $0.fadingIn = false }
    }

    /// This deck is over: its tap stops rendering, and the deck never claims again.
    func retire() {
        state.withLock { state in
            state.retired = true
            state.active = false
            state.armed = false
            state.lease?.release()
        }
    }
}

/// What the tap's C callbacks reach through the tap's storage. Holds the chain and a pass-through report, nothing else:
/// no player, no service, no UI. Retained once with `Unmanaged.passRetained` when the tap is made and released in
/// `finalize`.
final class MusicTapContext: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicAudioTap")

    let chain: MusicDSPChain
    private let deck: MusicTapDeck
    /// Told from `prepare` when the format is one the DSP cannot process and the audio goes through untouched.
    private let onPassThrough: @Sendable () -> Void
    /// Set in prepare, cleared in unprepare. The tap calls prepare, process and unprepare one after another.
    private nonisolated(unsafe) var lease: MusicRenderLease?

    init(chain: MusicDSPChain, deck: MusicTapDeck = MusicTapDeck(role: .active), onPassThrough: @escaping @Sendable () -> Void = {}) {
        self.chain = chain
        self.deck = deck
        self.onPassThrough = onPassThrough
    }

    #if DEBUG
    /// Which threads the tap's prepare callback ran on, for the tests: the lease (and its filters) is built there.
    struct PrepareThread: Sendable, Equatable {
        let isMain: Bool
        let qos: Int
        let name: String
    }
    static let debugPrepareThreads = OSAllocatedUnfairLock<[PrepareThread]>(initialState: [])
    #endif

    func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        #if DEBUG
        let info = PrepareThread(isMain: Thread.isMainThread, qos: Int(qos_class_self().rawValue), name: Thread.current.name ?? "")
        Self.debugPrepareThreads.withLock { $0.append(info) }
        #endif
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
        let made = MusicRenderLease(chain: chain, sampleRate: format.mSampleRate, maxFrames: maxFrames, claims: false)
        lease = made
        deck.attach(made)
    }

    func unprepare() {
        deck.detach()
        lease?.release()
        lease = nil
    }

    /// Real-time safe: no allocation, locks or logging.
    func render(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, sourceStart: Double = .nan) {
        lease?.render(list, frames: frames, sourceStart: sourceStart)
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
    var range = CMTimeRange()
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &range, numberFramesOut)
    guard status == noErr else {
        numberFramesOut.pointee = 0
        return
    }
    let context = Unmanaged<MusicTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.render(UnsafeMutableAudioBufferListPointer(bufferListInOut), frames: Int(numberFramesOut.pointee), sourceStart: range.start.seconds)
}
