// Deci/Music/Playback/MusicDSPChain.swift
import Accelerate
import AudioToolbox
import Foundation
import os
import Synchronization

/// What an `MTAudioProcessingTap` was prepared with, kept for diagnostics.
struct MusicTapFormat: Equatable, Sendable, CustomStringConvertible {
    let sampleRate: Double
    let channelCount: Int
    let isFloat32: Bool
    let isInterleaved: Bool

    var description: String {
        "\(Int(sampleRate)) Hz, \(channelCount) ch, \(isFloat32 ? "Float32" : "not Float32"), \(isInterleaved ? "interleaved" : "planar")"
    }
}

/// The music player's DSP: volume and boost gain with a short ramp, a 10-band EQ, AutoEQ headphone correction,
/// loudness equalization and compensation, and a soft limiter, built from the same processors the process taps use.
///
/// Threading: the setters run on the main thread. Rendering runs on whatever thread the tap calls from, through a
/// `MusicRenderLease`, and is real-time safe: no allocation, no locks, no logging, no Objective-C. State the renderer
/// reads is either an atomic or a `nonisolated(unsafe)` word that the main thread replaces whole (the same pattern as
/// `ProcessTapController`). One item at a time may render: leases claim ownership and a wait-free busy flag turns a
/// stale or contended render into silence, so two items can never race on the filters' delay lines.
final class MusicDSPChain: @unchecked Sendable {

    // MARK: - Processors (replaced or reconfigured on the main thread only)

    private let eqProcessor: EQProcessor
    private let autoEQProcessor: AutoEQProcessor
    private let loudnessCompensator: LoudnessCompensator
    private nonisolated(unsafe) var loudnessEqualizer: LoudnessEqualizer

    // MARK: - Main-thread state

    private(set) var eqSettings: EQSettings = .flat
    private(set) var autoEQPreampEnabled = true
    private(set) var loudnessCompensationEnabled = false
    private(set) var loudnessCompensationVolume: Float = 1
    private(set) var loudnessEqualizationEnabled = false

    var autoEQProfile: AutoEQProfile? { autoEQProcessor.currentProfile }

    // MARK: - Shared with the render thread

    private let targetGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let snapGain = Atomic<Bool>(false)
    private let peakBits = Atomic<UInt32>(0)
    private let frameCount = Atomic<Int>(0)
    private let rateBits: Atomic<UInt64>
    /// The rate the newest lease asked the processors to be rebuilt for.
    private let requestedRateBits: Atomic<UInt64>
    private let tokenSource = Atomic<Int>(0)
    private let ownerToken = Atomic<Int>(0)
    private let renderBusy = Atomic<Bool>(false)

    /// Owned by the renderer under `renderBusy`.
    private nonisolated(unsafe) var currentGain: Float = 1

    private let formatLock = OSAllocatedUnfairLock<MusicTapFormat?>(initialState: nil)

    // MARK: - Init

    init(sampleRate: Double) {
        let rate = Self.isUsable(sampleRate) ? sampleRate : 48_000
        eqProcessor = EQProcessor(sampleRate: rate)
        autoEQProcessor = AutoEQProcessor(sampleRate: rate)
        loudnessCompensator = LoudnessCompensator(sampleRate: rate)
        loudnessEqualizer = LoudnessEqualizer(settings: LoudnessEqualizerSettings(), sampleRate: Float(rate))
        rateBits = Atomic<UInt64>(rate.bitPattern)
        requestedRateBits = Atomic<UInt64>(rate.bitPattern)
    }

    private static func isUsable(_ rate: Double) -> Bool {
        rate.isFinite && rate > 0
    }

    // MARK: - Setters (main thread)

    /// The linear gain (volume times boost; 0 when muted) the renderer ramps to over about 30 ms.
    /// `snap` jumps to it at the next render instead, for the very first value a stored setting gives.
    /// Non-finite values are ignored and negative ones clamp to 0.
    func setTargetGain(_ gain: Float, snap: Bool = false) {
        guard gain.isFinite else { return }
        targetGainBits.store(max(0, gain).bitPattern, ordering: .relaxed)
        if snap { snapGain.store(true, ordering: .relaxed) }
    }

    var targetGain: Float { Float(bitPattern: targetGainBits.load(ordering: .relaxed)) }

    func setEQ(_ settings: EQSettings) {
        eqSettings = settings
        eqProcessor.updateSettings(settings)
    }

    func setAutoEQProfile(_ profile: AutoEQProfile?) {
        autoEQProcessor.updateProfile(profile)
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        autoEQPreampEnabled = enabled
        autoEQProcessor.setPreampEnabled(enabled)
    }

    /// `volume` is the level the listener hears the loudness contours at: device volume times the row's volume.
    func setLoudnessCompensation(enabled: Bool, volume: Float) {
        loudnessCompensationEnabled = enabled
        loudnessCompensationVolume = volume
        if enabled {
            loudnessCompensator.updateForVolume(volume)
        } else {
            loudnessCompensator.setEnabled(false)
        }
    }

    func setLoudnessEqualization(enabled: Bool) {
        guard enabled != loudnessEqualizationEnabled else { return }
        loudnessEqualizationEnabled = enabled
        replaceLoudnessEqualizer(sampleRate: processorSampleRate)
    }

    /// The sample rate the processors' coefficients are for.
    var processorSampleRate: Double { Double(bitPattern: rateBits.load(ordering: .relaxed)) }

    /// Frames the renderer has processed (not counting dropped or silenced renders).
    var framesProcessed: Int { frameCount.load(ordering: .relaxed) }

    /// The loudest sample rendered since the last call, post gain: what is heard. Reading resets it.
    func consumePeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    // MARK: - Format diagnostics

    func noteFormat(_ format: MusicTapFormat) {
        formatLock.withLock { $0 = format }
    }

    var observedFormat: MusicTapFormat? {
        formatLock.withLock { $0 }
    }

    // MARK: - Sample rate (main thread)

    /// Asks for the processors to be rebuilt for a stream at `rate`. Never blocks the caller: the rebuild runs on the
    /// main queue, and the renderer bypasses the rate-dependent stages until it has finished.
    ///
    /// Every lease asks, even at the rate the processors already have, and a queued rebuild goes to the newest rate
    /// asked for, not the one that queued it: an item that comes right after one at another rate must not find the
    /// processors rebuilt for the earlier rate (the rebuild is a no-op when the rate already matches).
    fileprivate func requestRebuild(forRate rate: Double) {
        requestedRateBits.store(rate.bitPattern, ordering: .releasing)
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                rebuildProcessors(forRate: Double(bitPattern: requestedRateBits.load(ordering: .acquiring)))
            }
        }
    }

    private func rebuildProcessors(forRate rate: Double) {
        guard rate != processorSampleRate else { return }
        eqProcessor.updateSampleRate(rate)
        autoEQProcessor.updateSampleRate(rate)
        loudnessCompensator.updateSampleRate(rate)
        replaceLoudnessEqualizer(sampleRate: rate)
        rateBits.store(rate.bitPattern, ordering: .releasing)
    }

    /// The loudness equalizer is immutable: a new instance replaces it and the old one is released after the renderer
    /// has surely moved on (the same 0.5 s grace the biquad setups use).
    private func replaceLoudnessEqualizer(sampleRate: Double) {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = loudnessEqualizationEnabled
        let old = loudnessEqualizer
        loudnessEqualizer = LoudnessEqualizer(settings: settings, sampleRate: Float(sampleRate))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { _ = old }
    }

    // MARK: - Ownership

    fileprivate func claimOwnership() -> Int {
        let token = tokenSource.wrappingAdd(1, ordering: .relaxed).newValue
        ownerToken.store(token, ordering: .releasing)
        return token
    }

    fileprivate func releaseOwnership(token: Int) {
        _ = ownerToken.compareExchange(expected: token, desired: 0, ordering: .acquiringAndReleasing)
    }

    #if DEBUG
    /// Test hook: makes every render started inside `body` find the chain busy.
    func holdingRenderLock(_ body: () -> Void) {
        renderBusy.store(true, ordering: .releasing)
        body()
        renderBusy.store(false, ordering: .releasing)
    }
    #endif

    // MARK: - Render (any thread, real-time safe)

    fileprivate func render(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, lease: MusicRenderLease) {
        guard frames > 0, list.count > 0 else { return }

        guard ownerToken.load(ordering: .acquiring) == lease.token,
              renderBusy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged
        else {
            Self.silence(list)
            return
        }
        defer { renderBusy.store(false, ordering: .releasing) }

        let target = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        if snapGain.exchange(false, ordering: .relaxed) { currentGain = target }
        let startGain = currentGain
        let processorsReady = rateBits.load(ordering: .acquiring) == lease.rateBits

        if list.count == 1 {
            let buffer = list[0]
            let channels = max(1, Int(buffer.mNumberChannels))
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let count = min(frames, available)
            guard count > 0 else { return }

            if channels == 2 {
                renderStereo(data, frames: count, startGain: startGain, target: target, processorsReady: processorsReady, lease: lease)
            } else {
                renderGainOnly(list, interleavedChannels: channels, frames: count, startGain: startGain, target: target, lease: lease)
            }
        } else if list.count == 2, let left = Self.planarChannel(list[0]), let right = Self.planarChannel(list[1]) {
            let count = min(frames, left.frames, right.frames)
            guard count > 0 else { return }
            if count <= lease.scratchFrames {
                let scratch = lease.scratch
                for frame in 0..<count {
                    scratch[frame * 2] = left.data[frame]
                    scratch[frame * 2 + 1] = right.data[frame]
                }
                renderStereo(scratch, frames: count, startGain: startGain, target: target, processorsReady: processorsReady, lease: lease)
                for frame in 0..<count {
                    left.data[frame] = scratch[frame * 2]
                    right.data[frame] = scratch[frame * 2 + 1]
                }
            } else {
                renderGainOnly(list, interleavedChannels: 1, frames: count, startGain: startGain, target: target, lease: lease)
            }
        } else {
            renderGainOnly(list, interleavedChannels: 1, frames: frames, startGain: startGain, target: target, lease: lease)
        }
    }

    /// Stereo interleaved Float32 in place: the full chain.
    private func renderStereo(
        _ samples: UnsafeMutablePointer<Float>,
        frames: Int,
        startGain: Float,
        target: Float,
        processorsReady: Bool,
        lease: MusicRenderLease
    ) {
        let sampleCount = frames * 2
        frameCount.wrappingAdd(frames, ordering: .relaxed)

        if startGain == 0 && target == 0 {
            memset(samples, 0, sampleCount * MemoryLayout<Float>.size)
            return
        }
        currentGain = Self.applyGain(
            samples, frames: frames, channels: 2, startGain: startGain, target: target, coefficient: lease.rampCoefficient
        )
        Self.zeroNonFinite(samples, count: sampleCount)

        if processorsReady {
            let input = UnsafePointer(samples)
            eqProcessor.process(input: input, output: samples, frameCount: frames)
            autoEQProcessor.process(input: input, output: samples, frameCount: frames)
            let equalizer = loudnessEqualizer
            if equalizer.isEnabled {
                equalizer.process(input: input, output: samples, frameCount: frames, channelCount: 2)
            }
            loudnessCompensator.process(input: input, output: samples, frameCount: frames)
        }

        SoftLimiter.processBuffer(samples, sampleCount: sampleCount)
        Self.zeroNonFinite(samples, count: sampleCount)
        notePeak(samples, count: sampleCount)
    }

    /// Mono, more than two channels, or planar frames beyond the scratch: the gain, the limiter and the meter only.
    private func renderGainOnly(
        _ list: UnsafeMutableAudioBufferListPointer,
        interleavedChannels: Int,
        frames: Int,
        startGain: Float,
        target: Float,
        lease: MusicRenderLease
    ) {
        var endGain = startGain
        var counted = false
        for index in 0..<list.count {
            let buffer = list[index]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = list.count == 1 ? interleavedChannels : max(1, Int(buffer.mNumberChannels))
            let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            guard count > 0 else { continue }
            let sampleCount = count * channels

            if !counted {
                frameCount.wrappingAdd(count, ordering: .relaxed)
                counted = true
            }
            if startGain == 0 && target == 0 {
                memset(data, 0, sampleCount * MemoryLayout<Float>.size)
                continue
            }
            endGain = Self.applyGain(
                data, frames: count, channels: channels, startGain: startGain, target: target, coefficient: lease.rampCoefficient
            )
            Self.zeroNonFinite(data, count: sampleCount)
            SoftLimiter.processBuffer(data, sampleCount: sampleCount)
            Self.zeroNonFinite(data, count: sampleCount)
            notePeak(data, count: sampleCount)
        }
        currentGain = endGain
    }

    // MARK: - Render helpers

    private func notePeak(_ samples: UnsafePointer<Float>, count: Int) {
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        guard peak.isFinite, peak > 0 else { return }
        var current = peakBits.load(ordering: .relaxed)
        while peak > Float(bitPattern: current) {
            let result = peakBits.compareExchange(expected: current, desired: peak.bitPattern, ordering: .relaxed)
            if result.exchanged { return }
            current = result.original
        }
    }

    /// Multiplies by a gain that glides from `startGain` to `target` (one-pole, per frame, the same for every channel),
    /// then holds the target. Returns the gain after the last frame.
    private static func applyGain(
        _ samples: UnsafeMutablePointer<Float>,
        frames: Int,
        channels: Int,
        startGain: Float,
        target: Float,
        coefficient: Float
    ) -> Float {
        var gain = startGain
        var frame = 0
        while frame < frames && gain != target {
            let base = frame * channels
            for channel in 0..<channels { samples[base + channel] *= gain }
            gain += (target - gain) * coefficient
            // Settle exactly: no endless approach, no denormals while muted.
            if abs(target - gain) < 1e-6 { gain = target }
            frame += 1
        }
        if frame < frames && target != 1 {
            var rest = target
            vDSP_vsmul(samples + frame * channels, 1, &rest, samples + frame * channels, 1, vDSP_Length((frames - frame) * channels))
        }
        return gain
    }

    /// Replaces NaN and infinity with silence, so nothing downstream (the limiter least of all) can turn it into noise.
    private static func zeroNonFinite(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for index in 0..<count where !samples[index].isFinite {
            samples[index] = 0
        }
    }

    private static func silence(_ list: UnsafeMutableAudioBufferListPointer) {
        for index in 0..<list.count {
            let buffer = list[index]
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    private static func planarChannel(_ buffer: AudioBuffer) -> (data: UnsafeMutablePointer<Float>, frames: Int)? {
        guard buffer.mNumberChannels == 1, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
        return (data, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
    }
}

/// One item's right to render through the chain. Its scratch buffer is its own, so a stale item can never scribble on
/// the current one's. Creating a lease makes it the chain's only renderer; `release` gives that up.
final class MusicRenderLease: @unchecked Sendable {
    private let chain: MusicDSPChain
    fileprivate let token: Int
    fileprivate let rateBits: UInt64
    fileprivate let rampCoefficient: Float
    fileprivate let scratch: UnsafeMutablePointer<Float>
    fileprivate let scratchFrames: Int

    /// Stereo planar buffers are interleaved into the scratch, allocated here: `maxFrames * 2` samples.
    /// The processors are rebuilt on the main queue for the stream's rate when it differs (never waited for).
    init(chain: MusicDSPChain, sampleRate: Double, maxFrames: Int) {
        self.chain = chain
        let usable = sampleRate.isFinite && sampleRate > 0
        let rate = usable ? sampleRate : chain.processorSampleRate
        rateBits = rate.bitPattern
        // 30 ms time constant: the gain covers 63 % of a jump in that time.
        rampCoefficient = Float(1 - exp(-1 / (rate * 0.030)))
        scratchFrames = max(0, maxFrames)
        scratch = .allocate(capacity: max(1, scratchFrames * 2))
        scratch.initialize(repeating: 0, count: max(1, scratchFrames * 2))
        token = chain.claimOwnership()
        if usable {
            chain.requestRebuild(forRate: rate)
        }
    }

    deinit {
        chain.releaseOwnership(token: token)
        scratch.deallocate()
    }

    /// Processes `frames` frames of the buffer list in place. Real-time safe.
    func render(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        chain.render(list, frames: frames, lease: self)
    }

    /// Gives up the chain: until another lease is created, every render is silence.
    func release() {
        chain.releaseOwnership(token: token)
    }
}
