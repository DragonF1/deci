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

/// One lease's filter state: its own EQ, AutoEQ, loudness compensator and loudness equalizer at the lease's own sample
/// rate, and the meters it feeds. The chain's settings are shared; this state is not, so two items can render at once
/// (each deck's delay lines belong to its own item) without ever touching each other.
fileprivate final class MusicLeaseDSP: @unchecked Sendable {
    let sampleRate: Double
    let eq: EQProcessor
    let autoEQ: AutoEQProcessor
    let compensator: LoudnessCompensator
    /// Immutable, so it is replaced whole (the main thread writes the word, the renderer reads it), never edited.
    nonisolated(unsafe) var equalizer: LoudnessEqualizer

    let peakBits = Atomic<UInt32>(0)
    let levelBits = Atomic<UInt32>(0)

    init(sampleRate: Double, equalizerEnabled: Bool) {
        self.sampleRate = sampleRate
        eq = EQProcessor(sampleRate: sampleRate)
        autoEQ = AutoEQProcessor(sampleRate: sampleRate)
        compensator = LoudnessCompensator(sampleRate: sampleRate)
        equalizer = Self.makeEqualizer(enabled: equalizerEnabled, sampleRate: sampleRate)
    }

    private static func makeEqualizer(enabled: Bool, sampleRate: Double) -> LoudnessEqualizer {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = enabled
        return LoudnessEqualizer(settings: settings, sampleRate: Float(sampleRate))
    }

    /// The old equalizer is released after the renderer has surely moved on (the same 0.5 s grace the biquad setups use).
    func replaceEqualizer(enabled: Bool) {
        let old = equalizer
        equalizer = Self.makeEqualizer(enabled: enabled, sampleRate: sampleRate)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { _ = old }
    }

    func noteLevel(_ samples: UnsafePointer<Float>, count: Int) {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        guard rms.isFinite, rms > 0 else { return }
        Self.raise(levelBits, to: rms)
    }

    func notePeak(_ samples: UnsafePointer<Float>, count: Int) {
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        guard peak.isFinite, peak > 0 else { return }
        Self.raise(peakBits, to: peak)
    }

    private static func raise(_ bits: borrowing Atomic<UInt32>, to value: Float) {
        var current = bits.load(ordering: .relaxed)
        while value > Float(bitPattern: current) {
            let result = bits.compareExchange(expected: current, desired: value.bitPattern, ordering: .relaxed)
            if result.exchanged { return }
            current = result.original
        }
    }
}

/// The music player's DSP: volume and boost gain with a short ramp, a 10-band EQ, AutoEQ headphone correction,
/// loudness equalization and compensation, and a soft limiter, built from the same processors the process taps use.
///
/// Threading: the setters run on the main thread. Rendering runs on whatever thread the tap calls from, through a
/// `MusicRenderLease`, and is real-time safe: no allocation, no locks, no logging, no Objective-C.
///
/// The settings (bands, AutoEQ profile, loudness switches, master gain) live here and are shared. The filters do not:
/// every lease owns a full set at its own sample rate, built when the lease is created (on the tap's prepare thread, which
/// is not real-time) and kept in step with the settings by `settingsLock`, which only non-render threads take. So an owner
/// and a standby render the whole chain at the same time, each on its own state; a lease that has been superseded or
/// released renders silence.
final class MusicDSPChain: @unchecked Sendable {

    // MARK: - Settings (the lock guards them and the registry; the render thread never takes it)

    private let settingsLock = OSAllocatedUnfairLock()
    private nonisolated(unsafe) var registry: [Int: MusicLeaseDSP] = [:]
    private nonisolated(unsafe) var autoEQProfileValue: AutoEQProfile?
    private let defaultRate: Double

    private(set) var eqSettings: EQSettings = .flat
    private(set) var autoEQPreampEnabled = true
    private(set) var loudnessCompensationEnabled = false
    private(set) var loudnessCompensationVolume: Float = 1
    private(set) var loudnessEqualizationEnabled = false

    var autoEQProfile: AutoEQProfile? { settingsLock.withLockUnchecked { autoEQProfileValue } }

    // MARK: - Shared with the render thread

    private let targetGainBits = Atomic<UInt32>(Float(1).bitPattern)
    /// Bumped by a snapping `setTargetGain`; each lease jumps to the target once per bump.
    fileprivate let snapGeneration = Atomic<Int>(0)
    private let frameCount = Atomic<Int>(0)
    private let tokenSource = Atomic<Int>(0)
    private let ownerToken = Atomic<Int>(0)

    private let formatLock = OSAllocatedUnfairLock<MusicTapFormat?>(initialState: nil)

    // MARK: - Init

    init(sampleRate: Double) {
        defaultRate = Self.isUsable(sampleRate) ? sampleRate : 48_000
    }

    private static func isUsable(_ rate: Double) -> Bool {
        rate.isFinite && rate > 0
    }

    // MARK: - Setters (main thread)

    /// The linear gain (volume times boost; 0 when muted) every lease ramps to over about 30 ms.
    /// `snap` jumps to it at the next render instead, for the very first value a stored setting gives.
    /// Non-finite values are ignored and negative ones clamp to 0.
    func setTargetGain(_ gain: Float, snap: Bool = false) {
        guard gain.isFinite else { return }
        targetGainBits.store(max(0, gain).bitPattern, ordering: .relaxed)
        if snap { snapGeneration.wrappingAdd(1, ordering: .releasing) }
    }

    var targetGain: Float { Float(bitPattern: targetGainBits.load(ordering: .relaxed)) }

    func setEQ(_ settings: EQSettings) {
        settingsLock.withLockUnchecked {
            eqSettings = settings
            for dsp in registry.values { dsp.eq.updateSettings(settings) }
        }
    }

    func setAutoEQProfile(_ profile: AutoEQProfile?) {
        settingsLock.withLockUnchecked {
            autoEQProfileValue = profile
            for dsp in registry.values { dsp.autoEQ.updateProfile(profile) }
        }
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        settingsLock.withLockUnchecked {
            autoEQPreampEnabled = enabled
            for dsp in registry.values { dsp.autoEQ.setPreampEnabled(enabled) }
        }
    }

    /// `volume` is the level the listener hears the loudness contours at: device volume times the row's volume.
    func setLoudnessCompensation(enabled: Bool, volume: Float) {
        settingsLock.withLockUnchecked {
            loudnessCompensationEnabled = enabled
            loudnessCompensationVolume = volume
            for dsp in registry.values { Self.applyCompensation(to: dsp, enabled: enabled, volume: volume) }
        }
    }

    func setLoudnessEqualization(enabled: Bool) {
        settingsLock.withLockUnchecked {
            guard enabled != loudnessEqualizationEnabled else { return }
            loudnessEqualizationEnabled = enabled
            for dsp in registry.values { dsp.replaceEqualizer(enabled: enabled) }
        }
    }

    private static func applyCompensation(to dsp: MusicLeaseDSP, enabled: Bool, volume: Float) {
        if enabled {
            dsp.compensator.updateForVolume(volume)
        } else {
            dsp.compensator.setEnabled(false)
        }
    }

    /// Frames the renderer has processed, summed over leases (not counting silenced renders).
    var framesProcessed: Int { frameCount.load(ordering: .relaxed) }

    /// The loudest sample rendered since the last call, post gain: what is heard. With two leases rendering it is the
    /// louder of the two. Reading resets it.
    func consumePeak() -> Float {
        settingsLock.withLockUnchecked {
            var peak: Float = 0
            for dsp in registry.values {
                peak = max(peak, Float(bitPattern: dsp.peakBits.exchange(0, ordering: .relaxed)))
            }
            return peak
        }
    }

    /// The loudest buffer RMS rendered since the last call, taken before the volume gain (so the volume slider does not
    /// move it, and mute leaves it at rest). With two leases rendering the powers add. Reading resets it.
    func consumeLevel() -> Float {
        settingsLock.withLockUnchecked {
            var power: Float = 0
            for dsp in registry.values {
                let level = Float(bitPattern: dsp.levelBits.exchange(0, ordering: .relaxed))
                power += level * level
            }
            return power.squareRoot()
        }
    }

    // MARK: - Format diagnostics

    func noteFormat(_ format: MusicTapFormat) {
        formatLock.withLock { $0 = format }
    }

    var observedFormat: MusicTapFormat? {
        formatLock.withLock { $0 }
    }

    // MARK: - Lease state

    /// Builds a lease's filters at `rate` from the current settings and registers them for later changes. Runs on the
    /// thread that creates the lease; the lock makes the build and the registration one step, so no change is missed.
    fileprivate func makeDSP(rate: Double, token: Int) -> MusicLeaseDSP {
        settingsLock.withLockUnchecked {
            let dsp = MusicLeaseDSP(sampleRate: rate, equalizerEnabled: loudnessEqualizationEnabled)
            dsp.eq.updateSettings(eqSettings)
            if !autoEQPreampEnabled { dsp.autoEQ.setPreampEnabled(false) }
            if let profile = autoEQProfileValue { dsp.autoEQ.updateProfile(profile) }
            if loudnessCompensationEnabled {
                Self.applyCompensation(to: dsp, enabled: true, volume: loudnessCompensationVolume)
            }
            registry[token] = dsp
            return dsp
        }
    }

    fileprivate func forget(token: Int) {
        settingsLock.withLockUnchecked { _ = registry.removeValue(forKey: token) }
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

    fileprivate var fallbackRate: Double { defaultRate }

    #if DEBUG
    /// Test hook: whether `lease` is the chain's owner.
    func owns(_ lease: MusicRenderLease) -> Bool {
        ownerToken.load(ordering: .acquiring) == lease.token
    }
    #endif

    // MARK: - Render (any thread, real-time safe)

    fileprivate func render(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, lease: MusicRenderLease) {
        guard frames > 0, list.count > 0 else { return }

        // The owner plays. A standby that has not claimed the chain renders too, on its own filters: its item may be primed
        // with frames while paused and they get the EQ like any others. Anything else (released, or superseded by the lease
        // that claimed the chain after it) is stale and renders silence.
        let isOwner = ownerToken.load(ordering: .acquiring) == lease.token
        guard isOwner || lease.isUnclaimedStandby else {
            Self.silence(list)
            lease.noteSilenced(frames)
            return
        }
        // Only what is heard is metered: the owner, or a standby armed to start. A paused standby priming its buffers is not.
        let metered = isOwner || lease.isArmed
        let dsp = lease.dsp

        let target = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        let snaps = snapGeneration.load(ordering: .acquiring)
        if snaps != lease.seenSnapGeneration {
            lease.seenSnapGeneration = snaps
            lease.currentGain = target
        }
        let startGain = lease.currentGain
        let fade = lease.beginFade()

        if list.count == 1 {
            let buffer = list[0]
            let channels = max(1, Int(buffer.mNumberChannels))
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let count = min(frames, available)
            guard count > 0 else { return }

            if channels == 2 {
                lease.noteFull(count)
                renderStereo(data, frames: count, startGain: startGain, target: target, fade: fade, metered: metered, lease: lease, dsp: dsp)
            } else {
                lease.noteGainOnly(count)
                renderGainOnly(list, interleavedChannels: channels, frames: count, startGain: startGain, target: target, fade: fade, metered: metered, lease: lease, dsp: dsp)
            }
        } else if list.count == 2, let left = Self.planarChannel(list[0]), let right = Self.planarChannel(list[1]) {
            let count = min(frames, left.frames, right.frames)
            guard count > 0 else { return }
            if count <= lease.scratchFrames {
                lease.noteFull(count)
                let scratch = lease.scratch
                for frame in 0..<count {
                    scratch[frame * 2] = left.data[frame]
                    scratch[frame * 2 + 1] = right.data[frame]
                }
                renderStereo(scratch, frames: count, startGain: startGain, target: target, fade: fade, metered: metered, lease: lease, dsp: dsp)
                for frame in 0..<count {
                    left.data[frame] = scratch[frame * 2]
                    right.data[frame] = scratch[frame * 2 + 1]
                }
            } else {
                lease.noteGainOnly(count)
                renderGainOnly(list, interleavedChannels: 1, frames: count, startGain: startGain, target: target, fade: fade, metered: metered, lease: lease, dsp: dsp)
            }
        } else {
            lease.noteGainOnly(frames)
            renderGainOnly(list, interleavedChannels: 1, frames: frames, startGain: startGain, target: target, fade: fade, metered: metered, lease: lease, dsp: dsp)
        }
    }

    /// Stereo interleaved Float32 in place: the full chain.
    private func renderStereo(
        _ samples: UnsafeMutablePointer<Float>,
        frames: Int,
        startGain: Float,
        target: Float,
        fade: MusicFade,
        metered: Bool,
        lease: MusicRenderLease,
        dsp: MusicLeaseDSP
    ) {
        let sampleCount = frames * 2
        frameCount.wrappingAdd(frames, ordering: .relaxed)
        defer { lease.endFade(fade.advanced(by: frames)) }

        if startGain == 0 && target == 0 {
            memset(samples, 0, sampleCount * MemoryLayout<Float>.size)
            return
        }
        if metered { dsp.noteLevel(samples, count: sampleCount) }
        lease.currentGain = Self.applyGain(
            samples, frames: frames, channels: 2, startGain: startGain, target: target, coefficient: lease.rampCoefficient
        )
        Self.zeroNonFinite(samples, count: sampleCount)

        let input = UnsafePointer(samples)
        dsp.eq.process(input: input, output: samples, frameCount: frames)
        dsp.autoEQ.process(input: input, output: samples, frameCount: frames)
        let equalizer = dsp.equalizer
        if equalizer.isEnabled {
            equalizer.process(input: input, output: samples, frameCount: frames, channelCount: 2)
        }
        dsp.compensator.process(input: input, output: samples, frameCount: frames)

        SoftLimiter.processBuffer(samples, sampleCount: sampleCount)
        Self.zeroNonFinite(samples, count: sampleCount)
        fade.apply(to: samples, frames: frames, channels: 2)
        if metered { dsp.notePeak(samples, count: sampleCount) }
    }

    /// Mono, more than two channels, or planar frames beyond the scratch: the gain, the limiter and the meter only.
    private func renderGainOnly(
        _ list: UnsafeMutableAudioBufferListPointer,
        interleavedChannels: Int,
        frames: Int,
        startGain: Float,
        target: Float,
        fade: MusicFade,
        metered: Bool,
        lease: MusicRenderLease,
        dsp: MusicLeaseDSP
    ) {
        var endGain = startGain
        var counted = false
        var processedFrames = 0
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
                processedFrames = count
            }
            if startGain == 0 && target == 0 {
                memset(data, 0, sampleCount * MemoryLayout<Float>.size)
                continue
            }
            if metered { dsp.noteLevel(data, count: sampleCount) }
            endGain = Self.applyGain(
                data, frames: count, channels: channels, startGain: startGain, target: target, coefficient: lease.rampCoefficient
            )
            Self.zeroNonFinite(data, count: sampleCount)
            SoftLimiter.processBuffer(data, sampleCount: sampleCount)
            Self.zeroNonFinite(data, count: sampleCount)
            fade.apply(to: data, frames: count, channels: channels)
            if metered { dsp.notePeak(data, count: sampleCount) }
        }
        lease.currentGain = endGain
        lease.endFade(fade.advanced(by: processedFrames))
    }

    // MARK: - Render helpers

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

/// A lease's fade gain: a linear ramp from the current value to a target over a number of frames, applied per frame so it
/// is exact across buffer boundaries. Idle (1, nothing remaining) until `setFade` is called.
fileprivate struct MusicFade {
    var value: Float = 1
    var target: Float = 1
    var step: Float = 0
    var remaining = 0

    /// The state after `frames` more frames.
    func advanced(by frames: Int) -> MusicFade {
        guard remaining > 0, frames > 0 else { return self }
        var next = self
        let used = min(frames, remaining)
        next.remaining = remaining - used
        next.value = next.remaining == 0 ? target : value + step * Float(used)
        return next
    }

    /// Multiplies `frames` frames in place by the fade, starting from this state.
    func apply(to samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        guard remaining > 0 else {
            if value != 1 {
                var gain = value
                vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(frames * channels))
            }
            return
        }
        let ramped = min(frames, remaining)
        for frame in 0..<ramped {
            let gain = frame == remaining - 1 ? target : value + step * Float(frame + 1)
            let base = frame * channels
            for channel in 0..<channels { samples[base + channel] *= gain }
        }
        if ramped < frames && target != 1 {
            var rest = target
            vDSP_vsmul(samples + ramped * channels, 1, &rest, samples + ramped * channels, 1, vDSP_Length((frames - ramped) * channels))
        }
    }
}

/// One item's right to render through the chain. Its filters, scratch buffer, gain ramp, fade and meters are its own, so
/// a stale item can never scribble on the current one's and two leases render side by side. `claims` makes a lease the
/// chain's owner; a superseded or released lease renders silence.
final class MusicRenderLease: @unchecked Sendable {
    private let chain: MusicDSPChain
    fileprivate let token: Int
    fileprivate let dsp: MusicLeaseDSP
    fileprivate let rampCoefficient: Float
    fileprivate let scratch: UnsafeMutablePointer<Float>
    fileprivate let scratchFrames: Int
    private let armedFlag = Atomic<Bool>(false)
    /// Set once the lease has claimed the chain (at creation, or later by `claim`); never cleared.
    private let claimedFlag: Atomic<Bool>
    private let releasedFlag = Atomic<Bool>(false)

    /// Renderer-owned (one render call at a time per lease).
    fileprivate nonisolated(unsafe) var currentGain: Float
    fileprivate nonisolated(unsafe) var seenSnapGeneration: Int
    private nonisolated(unsafe) var fade = MusicFade()
    private nonisolated(unsafe) var seenFadeGeneration = 0

    private let fadeTargetBits = Atomic<UInt32>(Float(1).bitPattern)
    private let fadeFrames = Atomic<Int>(0)
    private let fadeGeneration = Atomic<Int>(0)

    #if DEBUG
    /// What the renderer did with this lease's frames, for the tests: through the whole chain, volume and limiter only
    /// (mono or multichannel streams), or silenced.
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

    /// A standby that has not claimed the chain and has not been released: it renders next to the owner.
    fileprivate var isUnclaimedStandby: Bool {
        !claimedFlag.load(ordering: .acquiring) && !releasedFlag.load(ordering: .acquiring)
    }

    /// Armed: about to be heard, so its output counts in the meters.
    fileprivate var isArmed: Bool { armedFlag.load(ordering: .acquiring) }

    /// The sample rate this lease's filters were built for (the stream's, or the chain's when the stream's is unusable).
    var processorSampleRate: Double { dsp.sampleRate }

    /// Stereo planar buffers are interleaved into the scratch, allocated here: `maxFrames * 2` samples.
    /// The filters are built here, synchronously, for the stream's rate and the chain's current settings: the tap's
    /// prepare callback runs on a media thread that is not real-time, so the first buffers already get the whole chain.
    ///
    /// `claims` makes the new lease the chain's owner, which silences the previous one: right for the item that plays.
    /// A standby deck's lease passes false, so preparing it never silences the deck that is playing; it renders next to
    /// the owner on its own filters and claims the chain when its deck becomes the active one.
    init(chain: MusicDSPChain, sampleRate: Double, maxFrames: Int, claims: Bool = true) {
        self.chain = chain
        let usable = sampleRate.isFinite && sampleRate > 0
        let rate = usable ? sampleRate : chain.fallbackRate
        // 30 ms time constant: the gain covers 63 % of a jump in that time.
        rampCoefficient = Float(1 - exp(-1 / (rate * 0.030)))
        scratchFrames = max(0, maxFrames)
        scratch = .allocate(capacity: max(1, scratchFrames * 2))
        scratch.initialize(repeating: 0, count: max(1, scratchFrames * 2))
        claimedFlag = Atomic<Bool>(claims)
        let token = claims ? chain.claimOwnership() : chain.newToken()
        self.token = token
        dsp = chain.makeDSP(rate: rate, token: token)
        currentGain = chain.targetGain
        seenSnapGeneration = chain.snapGeneration.load(ordering: .acquiring)
    }

    deinit {
        releasedFlag.store(true, ordering: .releasing)
        disarm()
        chain.releaseOwnership(token: token)
        chain.forget(token: token)
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
        chain.forget(token: token)
    }

    /// Marks a standby as about to be heard (its first frames play while the old item's last ones play out): its output
    /// then counts in the chain's meters. It renders the full chain either way.
    func arm() {
        armedFlag.store(true, ordering: .releasing)
    }

    /// Back to unmetered.
    func disarm() {
        armedFlag.store(false, ordering: .releasing)
    }

    /// The hand-over: this lease becomes the chain's owner and the previous owner renders silence from now on.
    func claim() {
        claimedFlag.store(true, ordering: .releasing)
        chain.transferOwnership(to: token)
        disarm()
    }

    // MARK: - Fade

    /// Ramps this lease's fade gain (on top of the master gain, default 1) linearly to `gain` over `seconds`, sample
    /// accurately across buffers, from wherever it is now. `seconds <= 0` jumps at the next render. A later call replaces
    /// the ramp in progress. Any thread.
    func setFade(to gain: Float, over seconds: Double = 0) {
        guard gain.isFinite else { return }
        let rate = dsp.sampleRate
        let frames = seconds.isFinite && seconds > 0 ? Int((seconds * rate).rounded()) : 0
        fadeTargetBits.store(max(0, gain).bitPattern, ordering: .relaxed)
        fadeFrames.store(frames, ordering: .relaxed)
        fadeGeneration.wrappingAdd(1, ordering: .releasing)
    }

    /// The fade the renderer is heading for.
    var fadeTarget: Float { Float(bitPattern: fadeTargetBits.load(ordering: .relaxed)) }

    fileprivate func beginFade() -> MusicFade {
        let generation = fadeGeneration.load(ordering: .acquiring)
        if generation != seenFadeGeneration {
            seenFadeGeneration = generation
            let target = Float(bitPattern: fadeTargetBits.load(ordering: .relaxed))
            let frames = fadeFrames.load(ordering: .relaxed)
            if frames <= 0 {
                fade = MusicFade(value: target, target: target, step: 0, remaining: 0)
            } else {
                fade.target = target
                fade.step = (target - fade.value) / Float(frames)
                fade.remaining = frames
            }
        }
        return fade
    }

    fileprivate func endFade(_ state: MusicFade) {
        fade = state
    }
}
