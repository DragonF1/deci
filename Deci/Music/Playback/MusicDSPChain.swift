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
    /// Immutable, so it is replaced whole, never edited. `equalizerOwner` keeps the current one alive (written under the
    /// chain's settings lock); the renderer reads it through `equalizerBits` without a retain.
    private nonisolated(unsafe) var equalizerOwner: LoudnessEqualizer
    private let equalizerBits: Atomic<UInt>

    let peakBits = Atomic<UInt32>(0)
    let levelBits = Atomic<UInt32>(0)

    init(sampleRate: Double, equalizerEnabled: Bool) {
        self.sampleRate = sampleRate
        eq = EQProcessor(sampleRate: sampleRate)
        autoEQ = AutoEQProcessor(sampleRate: sampleRate, requiresMainThread: false)
        compensator = LoudnessCompensator(sampleRate: sampleRate)
        let equalizer = Self.makeEqualizer(enabled: equalizerEnabled, sampleRate: sampleRate)
        equalizerOwner = equalizer
        equalizerBits = Atomic<UInt>(Self.bits(of: equalizer))
    }

    private static func bits(of equalizer: LoudnessEqualizer) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(equalizer).toOpaque())
    }

    /// Runs the loudness equalizer in place when it is on. Render thread: no retain, no lock.
    func processEqualizer(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int) {
        guard let raw = UnsafeRawPointer(bitPattern: equalizerBits.load(ordering: .acquiring)) else { return }
        Unmanaged<LoudnessEqualizer>.fromOpaque(raw)._withUnsafeGuaranteedRef { equalizer in
            if equalizer.isEnabled {
                equalizer.process(input: input, output: output, frameCount: frames, channelCount: 2)
            }
        }
    }

    private static func makeEqualizer(enabled: Bool, sampleRate: Double) -> LoudnessEqualizer {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = enabled
        return LoudnessEqualizer(settings: settings, sampleRate: Float(sampleRate))
    }

    /// The old equalizer is released after the renderer has surely moved on (the same 0.5 s grace the biquad setups use).
    func replaceEqualizer(enabled: Bool) {
        let old = equalizerOwner
        let new = Self.makeEqualizer(enabled: enabled, sampleRate: sampleRate)
        equalizerOwner = new
        equalizerBits.store(Self.bits(of: new), ordering: .releasing)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { _ = old }
    }

    /// `scale` is the lease's fade across the buffer, so a deck fading out leaves the meters as it leaves the speakers.
    func replaceEqualizerIfNeeded(enabled: Bool) {
        if equalizerOwner.isEnabled != enabled { replaceEqualizer(enabled: enabled) }
    }

    func noteLevel(_ samples: UnsafePointer<Float>, count: Int, scale: Float = 1) {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        rms *= scale
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
    /// Bumped by every setter, under the lock: lets `makeDSP` notice a change that landed while it was building.
    private nonisolated(unsafe) var settingsVersion = 0

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
            settingsVersion += 1
            eqSettings = settings
            for dsp in registry.values { dsp.eq.updateSettings(settings) }
        }
    }

    func setAutoEQProfile(_ profile: AutoEQProfile?) {
        settingsLock.withLockUnchecked {
            settingsVersion += 1
            autoEQProfileValue = profile
            for dsp in registry.values { dsp.autoEQ.updateProfile(profile) }
        }
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        settingsLock.withLockUnchecked {
            settingsVersion += 1
            autoEQPreampEnabled = enabled
            for dsp in registry.values { dsp.autoEQ.setPreampEnabled(enabled) }
        }
    }

    /// `volume` is the level the listener hears the loudness contours at: device volume times the row's volume.
    func setLoudnessCompensation(enabled: Bool, volume: Float) {
        settingsLock.withLockUnchecked {
            settingsVersion += 1
            loudnessCompensationEnabled = enabled
            loudnessCompensationVolume = volume
            for dsp in registry.values { Self.applyCompensation(to: dsp, enabled: enabled, volume: volume) }
        }
    }

    func setLoudnessEqualization(enabled: Bool) {
        settingsLock.withLockUnchecked {
            guard enabled != loudnessEqualizationEnabled else { return }
            settingsVersion += 1
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

    /// Builds a lease's filters at `rate` from the current settings and registers them for later changes. The build runs
    /// on the thread that creates the lease and outside the lock (so the meters' main-thread reads never wait for it);
    /// registration is one short step that re-applies the settings if any changed in between.
    fileprivate func makeDSP(rate: Double, token: Int) -> MusicLeaseDSP {
        let (version, equalizerOn) = settingsLock.withLockUnchecked { (settingsVersion, loudnessEqualizationEnabled) }
        let dsp = MusicLeaseDSP(sampleRate: rate, equalizerEnabled: equalizerOn)
        let snapshot = settingsLock.withLockUnchecked { self.snapshot() }
        snapshot.apply(to: dsp)
        return settingsLock.withLockUnchecked {
            if settingsVersion != version { self.snapshot().apply(to: dsp) }
            registry[token] = dsp
            return dsp
        }
    }

    private struct Snapshot {
        let eq: EQSettings
        let profile: AutoEQProfile?
        let preamp: Bool
        let compensation: Bool
        let volume: Float
        let equalizer: Bool

        func apply(to dsp: MusicLeaseDSP) {
            dsp.eq.updateSettings(eq)
            dsp.autoEQ.setPreampEnabled(preamp)
            dsp.autoEQ.updateProfile(profile)
            MusicDSPChain.applyCompensation(to: dsp, enabled: compensation, volume: volume)
            dsp.replaceEqualizerIfNeeded(enabled: equalizer)
        }
    }

    /// The current settings as a value. Call under the lock.
    private func snapshot() -> Snapshot {
        Snapshot(
            eq: eqSettings, profile: autoEQProfileValue, preamp: autoEQPreampEnabled,
            compensation: loudnessCompensationEnabled, volume: loudnessCompensationVolume, equalizer: loudnessEqualizationEnabled
        )
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
        lease.noteRendered(frames)

        // The owner plays. A standby that has not claimed the chain renders too, on its own filters: its item may be primed
        // with frames while paused and they get the EQ like any others. Anything else (released, or superseded by the lease
        // that claimed the chain after it) is stale and renders silence.
        let isOwner = ownerToken.load(ordering: .acquiring) == lease.token
        // A draining lease (the outgoing side of a crossfade) keeps rendering after the chain moved on, until its fade
        // has reached zero.
        guard isOwner || lease.isUnclaimedStandby || lease.isDraining else {
            Self.silence(list)
            lease.noteSilenced(frames)
            return
        }
        // Only what is heard is metered: the owner, or a standby armed to start. A paused standby priming its buffers is not.
        let metered = isOwner || lease.isArmed || lease.isDraining
        let dsp = lease.dsp

        // Generation first (acquire), then the target: a snap stores the target before it bumps the generation, so seeing
        // the new generation guarantees the new target.
        let snaps = snapGeneration.load(ordering: .acquiring)
        let target = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        if snaps != lease.seenSnapGeneration {
            lease.seenSnapGeneration = snaps
            lease.currentGain = target
        }
        let startGain = lease.currentGain
        let fade = lease.beginFade()
        let offset = lease.beginOffset()
        if !isOwner, lease.isDraining, fade.remaining == 0, fade.value <= 0 {
            // The drain is over: nothing of this lease is heard any more.
            Self.silence(list)
            lease.noteSilenced(frames)
            return
        }

        if list.count == 1 {
            let buffer = list[0]
            let channels = max(1, Int(buffer.mNumberChannels))
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let count = min(frames, available)
            guard count > 0 else { return }

            if channels == 2 {
                lease.noteFull(count)
                renderStereo(data, frames: count, startGain: startGain, target: target, fade: fade, offset: offset, metered: metered, lease: lease, dsp: dsp)
            } else {
                lease.noteGainOnly(count)
                renderGainOnly(list, interleavedChannels: channels, frames: count, startGain: startGain, target: target, fade: fade, offset: offset, metered: metered, lease: lease, dsp: dsp)
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
                renderStereo(scratch, frames: count, startGain: startGain, target: target, fade: fade, offset: offset, metered: metered, lease: lease, dsp: dsp)
                for frame in 0..<count {
                    left.data[frame] = scratch[frame * 2]
                    right.data[frame] = scratch[frame * 2 + 1]
                }
            } else {
                lease.noteGainOnly(count)
                renderGainOnly(list, interleavedChannels: 1, frames: count, startGain: startGain, target: target, fade: fade, offset: offset, metered: metered, lease: lease, dsp: dsp)
            }
        } else {
            lease.noteGainOnly(frames)
            renderGainOnly(list, interleavedChannels: 1, frames: frames, startGain: startGain, target: target, fade: fade, offset: offset, metered: metered, lease: lease, dsp: dsp)
        }
    }

    /// Stereo interleaved Float32 in place: the full chain.
    private func renderStereo(
        _ samples: UnsafeMutablePointer<Float>,
        frames: Int,
        startGain: Float,
        target: Float,
        fade: MusicFade,
        offset: MusicFade,
        metered: Bool,
        lease: MusicRenderLease,
        dsp: MusicLeaseDSP
    ) {
        let sampleCount = frames * 2
        frameCount.wrappingAdd(frames, ordering: .relaxed)
        // Tier 3b P4: the bass channel of a beat mix (nil when idle, which is free).
        let bass = lease.beginBassRender(fade: fade)
        defer {
            lease.endFade(fade.advanced(by: frames))
            lease.endOffset(offset.advanced(by: frames))
            if let bass { lease.storeBass(bass.advanced(by: frames)) }
        }

        if startGain == 0 && target == 0 {
            memset(samples, 0, sampleCount * MemoryLayout<Float>.size)
            if bass != nil { lease.resetSplit() }
            return
        }
        if metered { dsp.noteLevel(samples, count: sampleCount, scale: fade.meanValue(over: frames) * offset.meanValue(over: frames)) }
        lease.currentGain = Self.applyGain(
            samples, frames: frames, channels: 2, startGain: startGain, target: target, coefficient: lease.rampCoefficient
        )
        Self.zeroNonFinite(samples, count: sampleCount)

        let input = UnsafePointer(samples)
        dsp.eq.process(input: input, output: samples, frameCount: frames)
        dsp.autoEQ.process(input: input, output: samples, frameCount: frames)
        dsp.processEqualizer(input: input, output: samples, frames: frames)
        dsp.compensator.process(input: input, output: samples, frameCount: frames)

        Self.limitAndFade(samples, frames: frames, channels: 2, fade: fade, offset: offset, lease: lease, bass: bass)
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
        offset: MusicFade,
        metered: Bool,
        lease: MusicRenderLease,
        dsp: MusicLeaseDSP
    ) {
        var endGain = startGain
        let envAtStart = lease.headroomEnv
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
            if metered { dsp.noteLevel(data, count: sampleCount, scale: fade.meanValue(over: count) * offset.meanValue(over: count)) }
            endGain = Self.applyGain(
                data, frames: count, channels: channels, startGain: startGain, target: target, coefficient: lease.rampCoefficient
            )
            Self.zeroNonFinite(data, count: sampleCount)
            lease.headroomEnv = envAtStart
            Self.limitAndFade(data, frames: count, channels: channels, fade: fade, offset: offset, lease: lease)
            if metered { dsp.notePeak(data, count: sampleCount) }
        }
        lease.currentGain = endGain
        lease.endFade(fade.advanced(by: processedFrames))
        lease.endOffset(offset.advanced(by: processedFrames))
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

    /// The limiter, then the fade. During an equal-power ramp the two are done together (see `rideAndApply`).
    private static func limitAndFade(
        _ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int, fade: MusicFade, offset: MusicFade,
        lease: MusicRenderLease, bass: MusicBassGain? = nil
    ) {
        if let bass, channels == 2 {
            if bass.isSteady, fade.remaining == 0, bass.value == fade.value {
                // b == f: the output is f * x, the plain path, bit for bit. The split keeps running so it is warm the
                // moment the two gains part.
                lease.warmSplit(samples, frames: frames)
                limitAndFadeOnly(samples, frames: frames, channels: channels, fade: fade, lease: lease)
            } else {
                bandedLimitAndFade(samples, frames: frames, fade: fade, bass: bass, lease: lease)
            }
        } else {
            limitAndFadeOnly(samples, frames: frames, channels: channels, fade: fade, lease: lease)
        }
        // Tier 2b: the loudness offset comes last, after the limiter, the rider and the fade. It is attenuation only (the
        // lease clamps it to [0, 1]), so it can only lower a level the rider already holds under 1.0. Idle is free.
        offset.apply(to: samples, frames: frames, channels: channels)
    }

    private static func limitAndFadeOnly(
        _ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int, fade: MusicFade, lease: MusicRenderLease
    ) {
        let count = frames * channels
        if fade.isHeadroomRamp {
            fade.rideAndApply(
                to: samples, frames: frames, channels: channels, env: &lease.headroomEnv, release: lease.headroomRelease
            )
            zeroNonFinite(samples, count: count)
            return
        }
        if lease.headroomEnv < 1 && fade.remaining == 0 {
            // The ramp ended with the rider still down: let it back up instead of snapping to 1.
            SoftLimiter.processBuffer(samples, sampleCount: count)
            zeroNonFinite(samples, count: count)
            fade.releaseTail(
                samples, frames: frames, channels: channels, hold: fade.value, env: &lease.headroomEnv, release: lease.headroomRelease
            )
            return
        }
        lease.headroomEnv = 1
        SoftLimiter.processBuffer(samples, sampleCount: count)
        zeroNonFinite(samples, count: count)
        fade.apply(to: samples, frames: frames, channels: channels)
    }

    /// The two-band output of a beat mix, stereo interleaved in place: `y = f * high + b * low`, which is `f * x + (b - f) *
    /// low` with `high = x - low` and `low` the 150 Hz split. The highs follow the lease's fade, the lows its bass gain.
    /// While an equal-power ramp runs the rider holds the output to this lease's share of the summed ceiling (see
    /// `MusicFade.headroomShare`); after it the soft limiter and the release tail do what they do for one band.
    private static func bandedLimitAndFade(
        _ samples: UnsafeMutablePointer<Float>, frames: Int, fade: MusicFade, bass: MusicBassGain, lease: MusicRenderLease
    ) {
        let ramped = fade.isHeadroomRamp ? min(frames, fade.remaining) : 0
        let release = lease.headroomRelease
        var env = lease.headroomEnv
        lease.withSplit { split in
            for frame in 0..<frames {
                let gh = fade.heard(afterFrames: frame + 1)
                let gl = bass.gain(afterFrames: frame + 1)
                let base = frame * 2
                let xl = samples[base]
                let xr = samples[base + 1]
                let lowL = split.lowpass(xl, channel: 0)
                let lowR = split.lowpass(xr, channel: 1)
                var left = gh * (xl - lowL) + gl * lowL
                var right = gh * (xr - lowR) + gl * lowR
                if frame < ramped {
                    let peak = max(abs(left), abs(right))
                    let ceiling = MusicFade.headroomShare(high: gh, low: gl)
                    let need: Float = peak > ceiling && peak.isFinite ? ceiling / peak : 1
                    env = need < env ? need : env + (need - env) * release
                    left *= env
                    right *= env
                }
                samples[base] = left.isFinite ? left : 0
                samples[base + 1] = right.isFinite ? right : 0
            }
        }
        let count = frames * 2
        if ramped > 0 {
            if ramped < frames {
                let rest = samples + ramped * 2
                SoftLimiter.processBuffer(rest, sampleCount: (frames - ramped) * 2)
                zeroNonFinite(rest, count: (frames - ramped) * 2)
                fade.releaseTail(rest, frames: frames - ramped, channels: 2, hold: 1, env: &env, release: release)
            }
        } else if env < 1 && fade.remaining == 0 {
            SoftLimiter.processBuffer(samples, sampleCount: count)
            zeroNonFinite(samples, count: count)
            fade.releaseTail(samples, frames: frames, channels: 2, hold: 1, env: &env, release: release)
        } else {
            env = 1
            SoftLimiter.processBuffer(samples, sampleCount: count)
            zeroNonFinite(samples, count: count)
        }
        lease.headroomEnv = env
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

/// Tier 3b P4: the 150 Hz split of a beat mix. `low` is a 4th-order Butterworth low-pass (two biquads), `high` is `x -
/// low`, so the two always add back to the input exactly. Stereo, one state per channel, in Double so a 150 Hz corner at
/// 48 kHz does not drown in rounding; states below 1e-20 are flushed so a silent input never goes denormal.
struct MusicBassSplit {
    static let cutoffHz = 150.0
    /// Q of the two sections of a 4th-order Butterworth: 1 / (2 cos(pi/8)) and 1 / (2 cos(3 pi/8)).
    private static let qualities = (0.5411961001461970, 1.3065629648763766)

    private struct Section {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        init() {}
        init(sampleRate: Double, q: Double) {
            let w = 2 * Double.pi * min(MusicBassSplit.cutoffHz, sampleRate / 4) / sampleRate
            let alpha = sin(w) / (2 * q)
            let c = cos(w)
            let a0 = 1 + alpha
            b0 = (1 - c) / 2 / a0
            b1 = (1 - c) / a0
            b2 = b0
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }
    }

    private let first: Section
    private let second: Section
    /// Per channel (2) and section (2): the two delay states.
    private var state = SIMD8<Double>(repeating: 0)

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        first = Section(sampleRate: rate, q: Self.qualities.0)
        second = Section(sampleRate: rate, q: Self.qualities.1)
    }

    /// Back to silence: no ringing from an earlier stretch of audio.
    mutating func reset() { state = SIMD8<Double>(repeating: 0) }

    /// The low band of one sample of `channel` (0 or 1).
    mutating func lowpass(_ x: Float, channel: Int) -> Float {
        let offset = (channel & 1) * 4
        // One NaN or infinity must not live on in the IIR state (the flush below is false for NaN): a bad input counts as
        // silence, and a state that went bad anyway is cleared.
        let mid = Self.step(x.isFinite ? Double(x) : 0, first, &state, offset)
        let out = Self.step(mid, second, &state, offset + 2)
        guard out.isFinite else {
            for index in offset..<(offset + 4) { state[index] = 0 }
            return 0
        }
        return Float(out)
    }

    @inline(__always)
    private static func step(_ x: Double, _ s: Section, _ state: inout SIMD8<Double>, _ i: Int) -> Double {
        let y = s.b0 * x + state[i]
        var z1 = s.b1 * x - s.a1 * y + state[i + 1]
        var z2 = s.b2 * x - s.a2 * y
        if abs(z1) < 1e-20 { z1 = 0 }
        if abs(z2) < 1e-20 { z2 = 0 }
        state[i] = z1
        state[i + 1] = z2
        return y
    }
}

/// A lease's bass gain `b`: linear, per frame, held until `delay` frames have been rendered and then ramped. Frame counted
/// like the fade, so a paused deck holds it and the two decks of a mix stay together.
struct MusicBassGain {
    var value: Float
    var target: Float
    var step: Float = 0
    var delay = 0
    var remaining = 0

    init(value: Float) {
        self.value = value
        target = value
    }

    var isSteady: Bool { delay == 0 && remaining == 0 }

    /// The gain as heard `used` frames from now (1 is the next frame).
    func gain(afterFrames used: Int) -> Float {
        guard used > delay else { return value }
        let into = used - delay
        return into >= remaining ? target : value + step * Float(into)
    }

    func advanced(by frames: Int) -> MusicBassGain {
        guard !isSteady, frames > 0 else { return self }
        var next = self
        if frames <= delay {
            next.delay = delay - frames
            return next
        }
        let into = frames - delay
        next.delay = 0
        let used = min(into, remaining)
        next.value = into >= remaining ? target : value + step * Float(into)
        next.remaining = remaining - used
        return next
    }
}

/// How a lease's fade moves between its two gains.
enum MusicFadeCurve: UInt32, Sendable {
    /// A straight ramp.
    case linear = 0
    /// An equal-power ramp: a fade out follows cos, a fade in follows sin, so two uncorrelated signals keep a constant
    /// power through a crossfade. While it runs the limiter ceiling follows 1/(cos + sin), so two correlated signals
    /// never sum above 1.0.
    case equalPower = 1
}

/// A lease's fade gain: a ramp from the current value to a target over a number of frames, applied per frame so it
/// is exact across buffer boundaries. Idle (1, nothing remaining) until `setFade` is called.
struct MusicFade {
    var value: Float = 1
    var target: Float = 1
    var step: Float = 0
    var remaining = 0
    var curve = MusicFadeCurve.linear
    /// Where an equal-power ramp started, and how many frames it spans in all.
    var from: Float = 1
    var total = 0

    /// The gain `used` frames into the ramp (`used` is 1 for the first frame): its value as that frame is heard.
    private func gain(afterFrames used: Int) -> Float {
        if used >= remaining { return target }
        switch curve {
        case .linear:
            return value + step * Float(used)
        case .equalPower:
            let progress = Double(total - remaining + used) / Double(total)
            let angle = progress * Double.pi / 2
            let shape = target >= from ? sin(angle) : 1 - cos(angle)
            return from + (target - from) * Float(shape)
        }
    }

    /// The gain as heard `used` frames from now, whether or not a ramp is running.
    func heard(afterFrames used: Int) -> Float {
        remaining > 0 ? gain(afterFrames: used) : value
    }

    /// The share of the summed ceiling (1.0) this lease may fill while it fades against its partner. The partner holds the
    /// complement: `sqrt(1 - g^2)` on the highs and `1 - b` on the lows. With `e` the larger of this lease's two gains
    /// and `e'` the partner's, the share is `e / (e + e')`, so the two shares add to 1.
    /// One band (`low` nil) is today's rule: `g / (g + sqrt(1 - g^2))`, which two bands with `b == g` reproduce exactly.
    static func headroomShare(high g: Float, low: Float?) -> Float {
        let high = min(1, max(0, g))
        let complement = max(0, 1 - high * high).squareRoot()
        let own: Float
        let other: Float
        if let low {
            let b = min(1, max(0, low))
            own = max(high, b)
            other = max(complement, 1 - b)
        } else {
            own = high
            other = complement
        }
        let sum = own + other
        return sum > 0 ? own / sum : 0
    }

    /// The fade's average over the next `frames` frames (its start and end values: a linear ramp's mean).
    func meanValue(over frames: Int) -> Float {
        guard remaining > 0 else { return value }
        return (value + advanced(by: frames).value) / 2
    }

    /// The state after `frames` more frames.
    func advanced(by frames: Int) -> MusicFade {
        guard remaining > 0, frames > 0 else { return self }
        var next = self
        let used = min(frames, remaining)
        next.value = gain(afterFrames: used)
        next.remaining = remaining - used
        if next.remaining == 0 { next.value = target }
        return next
    }

    /// Whether the headroom rule is in force: an equal-power ramp that has frames left.
    var isHeadroomRamp: Bool { curve == .equalPower && remaining > 0 }

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
            let gain = gain(afterFrames: frame + 1)
            let base = frame * channels
            for channel in 0..<channels { samples[base + channel] *= gain }
        }
        if ramped < frames && target != 1 {
            var rest = target
            vDSP_vsmul(samples + ramped * channels, 1, &rest, samples + ramped * channels, 1, vDSP_Length((frames - ramped) * channels))
        }
    }

    /// The headroom rule for an equal-power ramp, by riding the gain rather than shaping the waveform. Each frame's gain
    /// `g` is the lease's side of the pair, the other side is `sqrt(1 - g^2)`, so the two gains sum to `k = g + sqrt(1 -
    /// g^2)` at most. Every sample is held to `1/k` before the gain: a rider takes the gain down at once when the frame
    /// would pass that (instant attack) and lets it back up over about 60 ms, so a loud master keeps its shape and what
    /// each side adds to the sum is at most `g/k`, which keeps the pair at or under 1.0 for any two signals. Quiet
    /// material (peaks under `1/k`) gets the plain gain. `env` is the rider's gain, kept by the lease between calls.
    func rideAndApply(to samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int, env: inout Float, release: Float) {
        let ramped = min(frames, remaining)
        for frame in 0..<ramped {
            let g = gain(afterFrames: frame + 1)
            let k = g + max(0, 1 - g * g).squareRoot()
            let base = frame * channels
            var peak: Float = 0
            for channel in 0..<channels {
                let magnitude = abs(samples[base + channel])
                if magnitude.isFinite { peak = max(peak, magnitude) }
            }
            let ceiling = 1 / k
            let need: Float = peak > ceiling ? ceiling / peak : 1
            env = need < env ? need : env + (need - env) * release
            let scale = env * g
            for channel in 0..<channels {
                let sample = samples[base + channel]
                samples[base + channel] = sample.isFinite ? sample * scale : 0
            }
        }
        if ramped < frames {
            let rest = samples + ramped * channels
            let count = (frames - ramped) * channels
            SoftLimiter.processBuffer(rest, sampleCount: count)
            releaseTail(rest, frames: frames - ramped, channels: channels, hold: target, env: &env, release: release)
        }
    }

    /// After a ramp: the held gain times the rider, which keeps letting go toward 1 (same coefficient) rather than
    /// snapping, so there is no step in the effective gain. Snaps only within 1e-4, then takes the vDSP path.
    func releaseTail(
        _ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int, hold: Float, env: inout Float, release: Float
    ) {
        var frame = 0
        while frame < frames && env < 1 {
            env += (1 - env) * release
            if 1 - env < 1e-4 { env = 1 }
            let scale = env * hold
            let base = frame * channels
            for channel in 0..<channels { samples[base + channel] *= scale }
            frame += 1
        }
        if frame < frames && hold != 1 {
            var gain = hold
            vDSP_vsmul(samples + frame * channels, 1, &gain, samples + frame * channels, 1, vDSP_Length((frames - frame) * channels))
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
    /// The headroom rider lets go with a 60 ms time constant.
    fileprivate let headroomRelease: Float
    /// The headroom rider's gain (1 when idle). Renderer-owned.
    fileprivate nonisolated(unsafe) var headroomEnv: Float = 1
    fileprivate let scratch: UnsafeMutablePointer<Float>
    fileprivate let scratchFrames: Int
    private let armedFlag = Atomic<Bool>(false)
    /// Set once the lease has claimed the chain (at creation, or later by `claim`); never cleared.
    private let claimedFlag: Atomic<Bool>
    private let releasedFlag = Atomic<Bool>(false)
    /// Set by `drain`: the lease is the outgoing side of a crossfade and renders until its fade reaches zero.
    private let drainingFlag = Atomic<Bool>(false)

    /// Renderer-owned (one render call at a time per lease).
    fileprivate nonisolated(unsafe) var currentGain: Float
    fileprivate nonisolated(unsafe) var seenSnapGeneration: Int
    private nonisolated(unsafe) var fade = MusicFade()
    private nonisolated(unsafe) var seenFadeGeneration = 0
    /// Tier 2b loudness offset: a second, always linear gain after the fade (attenuation only, 1 when idle).
    private nonisolated(unsafe) var offset = MusicFade()
    private nonisolated(unsafe) var seenOffsetGeneration = 0
    private let offsetRequest = Atomic<UInt64>(UInt64(Float(1).bitPattern) << 32)
    private let offsetGeneration = Atomic<Int>(0)

    /// The target (high 32 bits) and the frame count (low 32 bits) of the newest fade in one word, so a reader never
    /// pairs one caller's target with another's length.
    private let fadeRequest = Atomic<UInt64>(UInt64(Float(1).bitPattern) << 32)
    private let fadeGeneration = Atomic<Int>(0)

    // Tier 3b P4: the bass channel. `bassActiveFlag` is off outside a beat mix (every render then takes the old path).
    private let bassActiveFlag = Atomic<Bool>(false)
    private let bassInitialBits = Atomic<UInt32>(Float(1).bitPattern)
    private let bassRequest = Atomic<UInt64>(UInt64(Float(1).bitPattern) << 32)
    private let bassDelayRequest = Atomic<Int>(0)
    private let bassGeneration = Atomic<Int>(0)
    /// Renderer only: the channel was ended but is still rendering until the fade settles (see `beginBassRender`).
    private var bassLinger = false
    /// Every frame the tap has handed this lease (counted on the render thread). Tests read it to see how many frames a
    /// lease renders per wall second at a nudged rate.
    private let renderedFrameCount = Atomic<Int>(0)
    var renderedFrames: Int { renderedFrameCount.load(ordering: .relaxed) }
    fileprivate func noteRendered(_ frames: Int) { renderedFrameCount.wrappingAdd(frames, ordering: .relaxed) }
    private let bassEpoch = Atomic<Int>(0)
    private nonisolated(unsafe) var bassGain = MusicBassGain(value: 1)
    private nonisolated(unsafe) var seenBassGeneration = 0
    private nonisolated(unsafe) var seenBassEpoch = 0
    private nonisolated(unsafe) var split: MusicBassSplit

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

    fileprivate var isDraining: Bool {
        drainingFlag.load(ordering: .acquiring) && !releasedFlag.load(ordering: .acquiring)
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
        headroomRelease = Float(1 - exp(-1 / (rate * 0.060)))
        scratchFrames = max(0, maxFrames)
        scratch = .allocate(capacity: max(1, scratchFrames * 2))
        scratch.initialize(repeating: 0, count: max(1, scratchFrames * 2))
        claimedFlag = Atomic<Bool>(claims)
        let token = claims ? chain.claimOwnership() : chain.newToken()
        self.token = token
        dsp = chain.makeDSP(rate: rate, token: token)
        split = MusicBassSplit(sampleRate: rate)
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

    /// Processes `frames` frames of the buffer list in place. Real-time safe. `sourceStart` is the item time of the
    /// first frame (NaN when unknown); only the DEBUG recorder reads it.
    func render(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, sourceStart: Double = .nan) {
        chain.render(list, frames: frames, lease: self)
        #if DEBUG
        if let recorder = MusicRenderRecorder.current {
            recorder.record(list, frames: frames, token: token, sourceStart: sourceStart, rate: dsp.sampleRate)
        }
        if MusicRenderRecorder.mutesOutput {
            for index in 0..<list.count {
                if let data = list[index].mData { memset(data, 0, Int(list[index].mDataByteSize)) }
            }
        }
        #endif
    }

    #if DEBUG
    /// This lease's identity in a `MusicRenderRecorder` record.
    var debugToken: Int { token }
    #endif

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

    /// Ramps this lease's fade gain (on top of the master gain, default 1) to `gain` over `seconds`, sample accurately
    /// across buffers, from wherever it is now. `seconds <= 0` jumps at the next render. A later call replaces the ramp
    /// in progress. Any thread.
    ///
    /// `fromSilence` starts the ramp at 0 whatever the fade was before, for the incoming side of a crossfade whose
    /// hold at 0 may not have been rendered yet.
    func setFade(to gain: Float, over seconds: Double = 0, curve: MusicFadeCurve = .linear, fromSilence: Bool = false) {
        guard gain.isFinite else { return }
        let rate = dsp.sampleRate
        // An hour is far past any real fade; the frame count is capped at 28 bits, the curve takes two bits above it and "from silence" one more.
        let clamped = seconds.isFinite ? min(max(seconds, 0), 3_600) : 0
        let frames = UInt32(min((clamped * rate).rounded(), Double(Self.maxFadeFrames)))
        let flags = curve.rawValue << 28 | (fromSilence ? 1 << 30 : 0)
        let packed = UInt64(max(0, gain).bitPattern) << 32 | UInt64(flags | frames)
        fadeRequest.store(packed, ordering: .relaxed)
        fadeGeneration.wrappingAdd(1, ordering: .releasing)
    }

    private static let maxFadeFrames: UInt32 = (1 << 28) - 1

    /// Makes this lease the outgoing side of a crossfade: it fades to silence over `seconds` and, unlike a lease that was
    /// superseded, stays audible and metered until it gets there. Call before the incoming lease claims the chain.
    func drain(over seconds: Double, curve: MusicFadeCurve = .equalPower) {
        setFade(to: 0, over: seconds, curve: curve)
        drainingFlag.store(true, ordering: .releasing)
    }

    /// The fade the renderer is heading for.
    var fadeTarget: Float { Float(bitPattern: UInt32(fadeRequest.load(ordering: .relaxed) >> 32)) }

    fileprivate func beginFade() -> MusicFade {
        let generation = fadeGeneration.load(ordering: .acquiring)
        if generation != seenFadeGeneration {
            seenFadeGeneration = generation
            let request = fadeRequest.load(ordering: .relaxed)
            let target = Float(bitPattern: UInt32(request >> 32))
            let low = UInt32(request & 0xFFFF_FFFF)
            let frames = Int(low & Self.maxFadeFrames)
            let curve = MusicFadeCurve(rawValue: (low >> 28) & 3) ?? .linear
            if low & (1 << 30) != 0 { fade.value = 0 }
            if frames <= 0 {
                fade = MusicFade(value: target, target: target, step: 0, remaining: 0)
            } else {
                fade.target = target
                fade.step = (target - fade.value) / Float(frames)
                fade.remaining = frames
                fade.curve = curve
                fade.from = fade.value
                fade.total = frames
            }
        }
        return fade
    }

    fileprivate func endFade(_ state: MusicFade) {
        fade = state
    }

    // MARK: - Bass (Tier 3b P4)

    /// Starts the bass channel at `gain`: from the next render the lease outputs `f * high + b * low` with `b` held at
    /// `gain`, and the 150 Hz split starts from silence so nothing rings from before. Any thread.
    func beginBass(gain: Float) {
        guard gain.isFinite else { return }
        let clamped = min(1, max(0, gain))
        bassInitialBits.store(clamped.bitPattern, ordering: .relaxed)
        bassActiveFlag.store(true, ordering: .relaxed)
        bassEpoch.wrappingAdd(1, ordering: .releasing)
    }

    /// Ramps the bass gain to `gain` over `seconds` (linear, sample accurate), starting `delay` seconds of rendered audio
    /// from now. A later call replaces the ramp in progress. Any thread.
    func setBass(to gain: Float, over seconds: Double = 0, after delay: Double = 0) {
        guard gain.isFinite else { return }
        let rate = dsp.sampleRate
        let frames = UInt32(min((min(max(seconds.isFinite ? seconds : 0, 0), 3_600) * rate).rounded(), Double(Self.maxFadeFrames)))
        let wait = Int(min((min(max(delay.isFinite ? delay : 0, 0), 3_600) * rate).rounded(), Double(Self.maxFadeFrames)))
        bassDelayRequest.store(wait, ordering: .relaxed)
        bassRequest.store(UInt64(min(1, max(0, gain)).bitPattern) << 32 | UInt64(frames), ordering: .relaxed)
        bassGeneration.wrappingAdd(1, ordering: .releasing)
    }

    /// Back to the plain path: `y = f * x`. Any thread.
    func endBass() {
        bassActiveFlag.store(false, ordering: .releasing)
    }

    var isBassActive: Bool { bassActiveFlag.load(ordering: .acquiring) }

    /// The bass gain the renderer is heading for.
    var bassTarget: Float { Float(bitPattern: UInt32(bassRequest.load(ordering: .relaxed) >> 32)) }

    #if DEBUG
    /// What the last `beginBass` and `setBass` asked for, for the tests (the request, not the renderer's state).
    struct DebugBass: Equatable, Sendable {
        var active: Bool
        var initial: Float
        var target: Float
        var rampFrames: Int
        var delayFrames: Int
    }
    var debugBass: DebugBass {
        let request = bassRequest.load(ordering: .relaxed)
        return DebugBass(
            active: isBassActive, initial: Float(bitPattern: bassInitialBits.load(ordering: .relaxed)),
            target: Float(bitPattern: UInt32(request >> 32)), rampFrames: Int(request & 0xFFFF_FFFF),
            delayFrames: bassDelayRequest.load(ordering: .relaxed)
        )
    }
    #endif

    /// The renderer's bass state for this block, nil while the channel is off.
    ///
    /// After `endBass` the two-band path stays until the fade has nothing left to ramp and the bass gain is steady (the
    /// same condition as the bypass): leaving while the fade is still below the bass gain would step the lows from
    /// `b * low` to `f * low`, an audible click.
    fileprivate func beginBassRender(fade: MusicFade) -> MusicBassGain? {
        guard bassActiveFlag.load(ordering: .acquiring) else {
            if bassLinger, fade.remaining > 0 || !bassGain.isSteady { return bassGain }
            bassLinger = false
            return nil
        }
        bassLinger = true
        // Generation first, then the epoch: a begin stores its epoch before any later ramp bumps the generation.
        let generation = bassGeneration.load(ordering: .acquiring)
        let epoch = bassEpoch.load(ordering: .acquiring)
        if epoch != seenBassEpoch {
            seenBassEpoch = epoch
            bassGain = MusicBassGain(value: Float(bitPattern: bassInitialBits.load(ordering: .relaxed)))
            split.reset()
        }
        if generation != seenBassGeneration {
            seenBassGeneration = generation
            let request = bassRequest.load(ordering: .relaxed)
            let target = Float(bitPattern: UInt32(request >> 32))
            let frames = Int(request & 0xFFFF_FFFF)
            let wait = bassDelayRequest.load(ordering: .relaxed)
            if frames <= 0 && wait <= 0 {
                bassGain = MusicBassGain(value: target)
            } else {
                bassGain.target = target
                bassGain.remaining = max(1, frames)
                bassGain.step = (target - bassGain.value) / Float(max(1, frames))
                bassGain.delay = wait
            }
        }
        return bassGain
    }

    fileprivate func storeBass(_ state: MusicBassGain) { bassGain = state }

    fileprivate func resetSplit() { split.reset() }

    fileprivate func withSplit(_ body: (inout MusicBassSplit) -> Void) { body(&split) }

    /// Runs the split over a block without using its output.
    fileprivate func warmSplit(_ samples: UnsafePointer<Float>, frames: Int) {
        for frame in 0..<frames {
            _ = split.lowpass(samples[frame * 2], channel: 0)
            _ = split.lowpass(samples[frame * 2 + 1], channel: 1)
        }
    }

    // MARK: - Offset

    /// Ramps the loudness offset (a gain applied after the limiter, rider and fade) to `gain` over `seconds`, linearly
    /// and sample accurately. Attenuation only: the gain is clamped to [0, 1]. `seconds <= 0` jumps at the next render.
    /// A later call replaces the ramp in progress, from wherever it is. Any thread.
    func setOffset(to gain: Float, over seconds: Double = 0) {
        guard gain.isFinite else { return }
        let rate = dsp.sampleRate
        let clamped = seconds.isFinite ? min(max(seconds, 0), 3_600) : 0
        let frames = UInt32(min((clamped * rate).rounded(), Double(Self.maxFadeFrames)))
        let packed = UInt64(min(1, max(0, gain)).bitPattern) << 32 | UInt64(frames)
        offsetRequest.store(packed, ordering: .relaxed)
        offsetGeneration.wrappingAdd(1, ordering: .releasing)
    }

    /// The offset the renderer is heading for.
    var offsetTarget: Float { Float(bitPattern: UInt32(offsetRequest.load(ordering: .relaxed) >> 32)) }

    fileprivate func beginOffset() -> MusicFade {
        let generation = offsetGeneration.load(ordering: .acquiring)
        if generation != seenOffsetGeneration {
            seenOffsetGeneration = generation
            let request = offsetRequest.load(ordering: .relaxed)
            let target = Float(bitPattern: UInt32(request >> 32))
            let frames = Int(UInt32(request & 0xFFFF_FFFF) & Self.maxFadeFrames)
            if frames <= 0 {
                offset = MusicFade(value: target, target: target, step: 0, remaining: 0)
            } else {
                offset.target = target
                offset.step = (target - offset.value) / Float(frames)
                offset.remaining = frames
                offset.curve = .linear
            }
        }
        return offset
    }

    fileprivate func endOffset(_ state: MusicFade) {
        offset = state
    }
}

#if DEBUG
/// Test seam: records what every lease rendered (a mono mix of the output after the whole chain, with the fade, before
/// the device), one record per render call with the item time of its first frame and the host time it ran. Off unless a
/// test installs one. Storage is allocated up front, so a render call never allocates.
final class MusicRenderRecorder: @unchecked Sendable {
    struct Record: Sendable {
        var token: Int
        var sourceStart: Double
        var hostNanos: UInt64
        var frames: Int
        var sampleOffset: Int
        var sampleRate: Double
    }

    nonisolated(unsafe) static var current: MusicRenderRecorder?
    /// Zeroes every lease's output after it was recorded, so a test hears nothing from the real engine.
    nonisolated(unsafe) static var mutesOutput = false

    private let samples: UnsafeMutablePointer<Float>
    private let sampleCapacity: Int
    private let records: UnsafeMutablePointer<Record>
    private let recordCapacity: Int
    private let sampleCount = Atomic<Int>(0)
    private let recordCount = Atomic<Int>(0)

    init(seconds: Double = 600, sampleRate: Double = 48_000, maxRecords: Int = 400_000) {
        sampleCapacity = Int(seconds * sampleRate)
        samples = .allocate(capacity: sampleCapacity)
        samples.initialize(repeating: 0, count: sampleCapacity)
        recordCapacity = maxRecords
        records = .allocate(capacity: maxRecords)
    }

    deinit {
        samples.deallocate()
        records.deallocate()
    }

    /// Real-time safe: the render thread of one tap writes at a time per call, but two decks render on two threads, so the
    /// space is claimed with an atomic add.
    fileprivate func record(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, token: Int, sourceStart: Double, rate: Double) {
        guard frames > 0, list.count > 0 else { return }
        let offset = sampleCount.wrappingAdd(frames, ordering: .relaxed).oldValue
        let index = recordCount.wrappingAdd(1, ordering: .relaxed).oldValue
        guard offset + frames <= sampleCapacity, index < recordCapacity else { return }
        let out = samples + offset
        if list.count == 1 {
            let buffer = list[0]
            let channels = max(1, Int(buffer.mNumberChannels))
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let count = min(frames, available)
            for frame in 0..<count {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                out[frame] = sum / Float(channels)
            }
        } else if let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = list[1].mData?.assumingMemoryBound(to: Float.self) {
            let count = min(frames, Int(list[0].mDataByteSize) / MemoryLayout<Float>.size, Int(list[1].mDataByteSize) / MemoryLayout<Float>.size)
            for frame in 0..<count { out[frame] = (left[frame] + right[frame]) * 0.5 }
        }
        records[index] = Record(
            token: token, sourceStart: sourceStart, hostNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            frames: frames, sampleOffset: offset, sampleRate: rate
        )
    }

    /// Everything recorded so far (call after the audio stopped, or accept a torn last record).
    func snapshot() -> (records: [Record], samples: [Float]) {
        let n = min(recordCount.load(ordering: .acquiring), recordCapacity)
        let m = min(sampleCount.load(ordering: .acquiring), sampleCapacity)
        return (Array(UnsafeBufferPointer(start: records, count: n)), Array(UnsafeBufferPointer(start: samples, count: m)))
    }
}
#endif
