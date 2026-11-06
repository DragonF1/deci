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
    /// The loudest buffer RMS since the last read, before the volume gain: for the player column's spectrum. It has its
    /// own reader, so it never shares `peakBits`, which the Mixer row consumes.
    private let levelBits = Atomic<UInt32>(0)
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

    /// The loudest buffer RMS rendered since the last call, taken before the volume gain (so the volume slider does not
    /// move it, and mute leaves it at rest). Reading resets it.
    func consumeLevel() -> Float {
        Float(bitPattern: levelBits.exchange(0, ordering: .relaxed))
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

    fileprivate func newToken() -> Int {
        tokenSource.wrappingAdd(1, ordering: .relaxed).newValue
    }

    fileprivate func claimOwnership() -> Int {
        let token = tokenSource.wrappingAdd(1, ordering: .relaxed).newValue
        ownerToken.store(token, ordering: .releasing)
        return token
    }

    fileprivate func releaseOwnership(token: Int) {
        _ = ownerToken.compareExchange(expected: token, desired: 0, ordering: .acquiringAndReleasing)
    }

    /// Makes the lease with `token` the owner without creating one (the hand-over from the old deck to the new).
    fileprivate func transferOwnership(to token: Int) {
        ownerToken.store(token, ordering: .releasing)
    }

    /// Takes the render flag, once: nobody spins for it. The lease that loses (the owner or an armed standby, which only
    /// meet on it for the instant of a hand-over) renders its buffer gain-only instead of waiting.
    private func acquireRender() -> Bool {
        renderBusy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged
    }

    #if DEBUG
    /// Test hook: whether `lease` is the chain's owner.
    func owns(_ lease: MusicRenderLease) -> Bool {
        ownerToken.load(ordering: .acquiring) == lease.token
    }

    /// Test hook: whether a render by `lease` would run the rate-dependent stages.
    func processorsReady(for lease: MusicRenderLease) -> Bool {
        rateBits.load(ordering: .acquiring) == lease.rateBits
    }

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

        let isOwner = ownerToken.load(ordering: .acquiring) == lease.token
        guard isOwner || lease.isArmed else {
            // A standby that has not claimed the chain keeps its frames (its item may be primed with them while paused):
            // the volume only, nothing shared. Any other lease is stale, and renders silence.
            if lease.isUnclaimedStandby {
                renderUnshared(list, frames: frames, lease: lease)
            } else {
                Self.silence(list)
                lease.noteSilenced(frames)
            }
            return
        }
        guard acquireRender() else {
            // Lost the race for the filters: the buffer still plays, with the volume and the limiter. Silence here would
            // drop the old item's last frames or the new one's first.
            renderUnshared(list, frames: frames, lease: lease)
            return
        }
        defer { renderBusy.store(false, ordering: .releasing) }
        lease.noteFull(frames)

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
        noteLevel(samples, count: sampleCount)
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
            noteLevel(data, count: sampleCount)
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

    /// The volume and the limiter on the buffer, touching no shared render state (no filters, no gain ramp, no meter):
    /// safe next to the lease that holds the render flag. The gain steps to the target instead of gliding.
    private func renderUnshared(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, lease: MusicRenderLease) {
        var target = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        for index in 0..<list.count {
            let buffer = list[index]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let count = min(available, frames * channels)
            guard count > 0 else { continue }
            if target == 0 {
                memset(data, 0, count * MemoryLayout<Float>.size)
                continue
            }
            if target != 1 { vDSP_vsmul(data, 1, &target, data, 1, vDSP_Length(count)) }
            Self.zeroNonFinite(data, count: count)
            SoftLimiter.processBuffer(data, sampleCount: count)
            Self.zeroNonFinite(data, count: count)
        }
        lease.noteGainOnly(frames)
    }

    // MARK: - Render helpers

    /// Keeps the loudest buffer RMS seen since the level was last read. Takes the buffer as it came in, before the gain.
    /// A buffer with a NaN or infinity in it measures as non-finite and is skipped.
    private func noteLevel(_ samples: UnsafePointer<Float>, count: Int) {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        guard rms.isFinite, rms > 0 else { return }
        var current = levelBits.load(ordering: .relaxed)
        while rms > Float(bitPattern: current) {
            let result = levelBits.compareExchange(expected: current, desired: rms.bitPattern, ordering: .relaxed)
            if result.exchanged { return }
            current = result.original
        }
    }

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
    private let armedFlag = Atomic<Bool>(false)
    /// The rate to rebuild the processors for when this lease claims the chain; nil when the stream's rate is unusable.
    private let claimRate: Double?
    /// Set once the lease has claimed the chain (at creation, or later by `claim`); never cleared.
    private let claimedFlag: Atomic<Bool>
    private let releasedFlag = Atomic<Bool>(false)

    #if DEBUG
    /// What the renderer did with this lease's frames, for the tests: through the whole chain, volume and limiter only,
    /// or silenced.
    struct DebugCounters: Sendable, Equatable {
        var calls = 0
        var fullFrames = 0
        var gainOnlyFrames = 0
        var silencedFrames = 0
    }
    private let callCount = Atomic<Int>(0)
    private let fullCount = Atomic<Int>(0)
    private let gainOnlyCount = Atomic<Int>(0)
    private let silencedCount = Atomic<Int>(0)
    var debugCounters: DebugCounters {
        DebugCounters(
            calls: callCount.load(ordering: .relaxed),
            fullFrames: fullCount.load(ordering: .relaxed),
            gainOnlyFrames: gainOnlyCount.load(ordering: .relaxed),
            silencedFrames: silencedCount.load(ordering: .relaxed)
        )
    }
    #endif

    fileprivate func noteFull(_ frames: Int) {
        #if DEBUG
        callCount.wrappingAdd(1, ordering: .relaxed)
        fullCount.wrappingAdd(frames, ordering: .relaxed)
        #endif
    }

    fileprivate func noteGainOnly(_ frames: Int) {
        #if DEBUG
        callCount.wrappingAdd(1, ordering: .relaxed)
        gainOnlyCount.wrappingAdd(frames, ordering: .relaxed)
        #endif
    }

    fileprivate func noteSilenced(_ frames: Int) {
        #if DEBUG
        callCount.wrappingAdd(1, ordering: .relaxed)
        silencedCount.wrappingAdd(frames, ordering: .relaxed)
        #endif
    }

    /// A standby that has not claimed the chain and has not been released: its frames are kept, gain only.
    fileprivate var isUnclaimedStandby: Bool {
        !claimedFlag.load(ordering: .acquiring) && !releasedFlag.load(ordering: .acquiring)
    }

    /// Armed: eligible to render next to the owner (see `arm`).
    fileprivate var isArmed: Bool { armedFlag.load(ordering: .acquiring) }

    /// Stereo planar buffers are interleaved into the scratch, allocated here: `maxFrames * 2` samples.
    /// The processors are rebuilt on the main queue for the stream's rate when it differs (never waited for).
    ///
    /// `claims` makes the new lease the chain's owner, which silences the previous one: right for the item that plays.
    /// A standby deck's lease passes false, so preparing it never silences the deck that is playing; it renders nothing
    /// until it is armed and then claims the chain when its deck becomes the active one.
    init(chain: MusicDSPChain, sampleRate: Double, maxFrames: Int, claims: Bool = true) {
        self.chain = chain
        let usable = sampleRate.isFinite && sampleRate > 0
        let rate = usable ? sampleRate : chain.processorSampleRate
        rateBits = rate.bitPattern
        // 30 ms time constant: the gain covers 63 % of a jump in that time.
        rampCoefficient = Float(1 - exp(-1 / (rate * 0.030)))
        scratchFrames = max(0, maxFrames)
        scratch = .allocate(capacity: max(1, scratchFrames * 2))
        scratch.initialize(repeating: 0, count: max(1, scratchFrames * 2))
        claimRate = usable ? rate : nil
        claimedFlag = Atomic<Bool>(claims)
        token = claims ? chain.claimOwnership() : chain.newToken()
        // Only the lease that plays asks for the processors to be rebuilt for its rate. A standby that did would rebuild
        // them under the owner (and the owner would lose its EQ for the rest of the song).
        if claims, let claimRate {
            chain.requestRebuild(forRate: claimRate)
        }
    }

    deinit {
        releasedFlag.store(true, ordering: .releasing)
        disarm()
        chain.releaseOwnership(token: token)
        scratch.deallocate()
    }

    /// Processes `frames` frames of the buffer list in place. Real-time safe.
    func render(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        chain.render(list, frames: frames, lease: self)
    }

    /// Gives up the chain: until another lease is created or claims it, every render is silence.
    func release() {
        releasedFlag.store(true, ordering: .releasing)
        disarm()
        chain.releaseOwnership(token: token)
    }

    /// Lets a standby lease render through the shared filters next to the owner, from just before its scheduled start: its first frames are heard
    /// while the old item's last ones are still playing out. Both share the chain's filters for those milliseconds (each
    /// deck having its own filter state is Phase 1b).
    func arm() {
        armedFlag.store(true, ordering: .releasing)
    }

    /// Puts an armed standby back to silence.
    func disarm() {
        armedFlag.store(false, ordering: .releasing)
    }

    /// The hand-over: this lease becomes the chain's owner and the previous owner renders silence from now on.
    func claim() {
        claimedFlag.store(true, ordering: .releasing)
        chain.transferOwnership(to: token)
        disarm()
        // The processors follow this lease's rate (on the main queue, never waited for): until that lands the lease
        // plays without the rate-dependent stages, a few milliseconds at the start of the item.
        if let claimRate { chain.requestRebuild(forRate: claimRate) }
    }
}
