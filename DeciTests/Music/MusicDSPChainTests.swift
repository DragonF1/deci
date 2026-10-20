// DeciTests/Music/MusicDSPChainTests.swift
// The music player's DSP: gain ramp, mute, boost, EQ, AutoEQ, loudness, limiter, layouts, sample-rate changes, and the
// lease that keeps two items from rendering through the chain at once. Everything runs offline on test buffers.

import Foundation
import AudioToolbox
import Testing
@testable import Deci

@MainActor
@Suite("MusicDSPChain")
struct MusicDSPChainTests {
    private static let rate = 48_000.0

    private func make(
        rate: Double = MusicDSPChainTests.rate,
        maxFrames: Int = 16_384
    ) -> (chain: MusicDSPChain, lease: MusicRenderLease) {
        let chain = MusicDSPChain(sampleRate: rate)
        return (chain, MusicRenderLease(chain: chain, sampleRate: rate, maxFrames: maxFrames))
    }

    @discardableResult
    private func render(
        _ lease: MusicRenderLease,
        _ channels: [[Float]],
        layout: TestBufferList.Layout = .interleaved
    ) -> TestBufferList {
        let buffers = TestBufferList(channels: channels, layout: layout)
        lease.render(buffers.list, frames: buffers.frames)
        return buffers
    }

    private func bandGains(_ index: Int, _ gain: Float) -> EQSettings {
        var gains = [Float](repeating: 0, count: EQSettings.bandCount)
        gains[index] = gain
        return EQSettings(bandGains: gains)
    }

    /// RMS of the second half of a render, past the filters' start-up.
    private func settledRMS(_ samples: [Float]) -> Float {
        MusicTestSignal.rms(Array(samples.suffix(samples.count / 2)))
    }

    private let oneKilohertz = MusicTestSignal.sine(frequency: 1_000, amplitude: 0.1, sampleRate: 48_000, frames: 48_000)

    // MARK: - Gain

    @Test("unity gain with a flat EQ leaves the signal unchanged")
    func unityPassesThrough() {
        let (_, lease) = make()
        let input = MusicTestSignal.sine(frequency: 440, amplitude: 0.5, sampleRate: Self.rate, frames: 4_800)
        let output = render(lease, input)
        for channel in 0..<2 {
            let difference = zip(output.samples(channel: channel), input[channel]).map { abs($0 - $1) }.max() ?? 1
            #expect(difference < 1e-3)
        }
    }

    @Test("a gain change ramps over about 30 ms instead of jumping")
    func gainRamps() {
        let (chain, lease) = make()
        chain.setTargetGain(0.25)
        let output = render(lease, MusicTestSignal.constant(0.5, frames: 48_000)).samples(channel: 0)

        #expect(output[0] > 0.49, "the first sample must not jump to the new gain")
        // One time constant (30 ms = 1440 frames): gain = 0.25 + 0.75 * e^-1.
        let expectedAtConstant = 0.5 * (0.25 + 0.75 * Float(exp(-1.0)))
        #expect(abs(output[1_440] - expectedAtConstant) < 0.005)
        #expect(abs(output[47_999] - 0.125) < 0.002)
        // The flat EQ bank is ten near-identity biquads: they leave a static error of about 0.05 percent (0.004 dB),
        // inaudible, so "never goes back up" and "never undershoots" carry that much slack.
        #expect(zip(output, output.dropFirst()).allSatisfy { $0 >= $1 - 1e-5 }, "a downward ramp does not wobble")
        #expect((output.min() ?? 0) > 0.125 - 3e-4, "and never undershoots the target")
    }

    @Test("a snapped gain applies from the very first sample")
    func snappedGain() {
        let (chain, lease) = make()
        chain.setTargetGain(0.25, snap: true)
        let output = render(lease, MusicTestSignal.constant(0.5, frames: 64))
        #expect(abs(output.samples(channel: 0)[0] - 0.125) < 1e-6)
        #expect(abs(output.samples(channel: 1)[63] - 0.125) < 1e-6)
    }

    @Test("mute fades to exact silence and unmuting brings the signal back")
    func muteAndUnmute() {
        let (chain, lease) = make()
        chain.setTargetGain(0)
        let muted = render(lease, MusicTestSignal.constant(0.5, frames: 48_000)).samples(channel: 0)
        #expect(muted[0] > 0.4, "the fade starts from the old level, so there is no click")
        #expect(muted.suffix(100).allSatisfy { abs($0) < 1e-4 })

        chain.setTargetGain(1)
        let back = render(lease, MusicTestSignal.constant(0.5, frames: 48_000)).samples(channel: 0)
        #expect(abs(back[47_999] - 0.5) < 1e-3)
    }

    @Test("a muted chain that stays muted settles at zero, not a slowly shrinking denormal")
    func mutedSettlesAtZero() {
        let (chain, lease) = make()
        chain.setTargetGain(0, snap: true)
        for _ in 0..<4 { render(lease, MusicTestSignal.constant(0.5, frames: 4_800)) }
        let output = render(lease, MusicTestSignal.constant(0.5, frames: 64)).samples(channel: 0)
        #expect(output.allSatisfy { $0 == 0 })
    }

    @Test("boost multiplies the gain and the limiter keeps the result under full scale")
    func boostIsLimited() {
        let (chain, lease) = make()
        chain.setTargetGain(4, snap: true)
        let constant = render(lease, MusicTestSignal.constant(0.5, frames: 256)).samples(channel: 0)
        #expect(constant.allSatisfy { $0 > 0.95 && $0 <= 1.0 }, "2.0 limited, not clipped flat")

        let sine = render(lease, MusicTestSignal.sine(frequency: 300, amplitude: 0.5, sampleRate: Self.rate, frames: 4_800))
        let peak = MusicTestSignal.peak(sine.samples(channel: 0))
        #expect(peak <= 1.0 && peak > 0.95)
    }

    @Test("a non-finite or negative target gain is ignored or clamped")
    func badGainIsContained() {
        let (chain, _) = make()
        chain.setTargetGain(0.5, snap: true)
        chain.setTargetGain(.nan)
        chain.setTargetGain(.infinity)
        #expect(chain.targetGain == 0.5)
        chain.setTargetGain(-1)
        #expect(chain.targetGain == 0)
    }

    // MARK: - Layouts

    @Test("planar and interleaved stereo come out the same, with the EQ running")
    func layoutsAgree() {
        let left = MusicTestSignal.sine(frequency: 440, amplitude: 0.2, sampleRate: Self.rate, frames: 4_800, channels: 1)[0]
        let right = MusicTestSignal.sine(frequency: 1_000, amplitude: 0.1, sampleRate: Self.rate, frames: 4_800, channels: 1)[0]

        var results: [[[Float]]] = []
        for layout in [TestBufferList.Layout.interleaved, .planar] {
            let (chain, lease) = make()
            chain.setEQ(bandGains(5, 9))
            chain.setTargetGain(0.7, snap: true)
            let output = render(lease, [left, right], layout: layout)
            results.append([output.samples(channel: 0), output.samples(channel: 1)])
        }
        for channel in 0..<2 {
            let difference = zip(results[0][channel], results[1][channel]).map { abs($0 - $1) }.max() ?? 1
            #expect(difference < 1e-5)
        }
        #expect(MusicTestSignal.peak(results[1][1]) > 0.1, "the planar path really processed (gain 0.7 plus a boost)")
    }

    @Test("mono gets the gain and nothing else, in either layout")
    func monoIsGainOnly() {
        for layout in [TestBufferList.Layout.interleaved, .planar] {
            let (chain, lease) = make()
            chain.setEQ(bandGains(5, 12))
            chain.setTargetGain(0.5, snap: true)
            let input = MusicTestSignal.sine(frequency: 1_000, amplitude: 0.4, sampleRate: Self.rate, frames: 2_400, channels: 1)
            let output = render(lease, input, layout: layout).samples(channel: 0)
            let difference = zip(output, input[0]).map { abs($0 - 0.5 * $1) }.max() ?? 1
            #expect(difference < 1e-6, "no EQ on mono")
        }
    }

    @Test("more than two channels get the gain and nothing else")
    func surroundIsGainOnly() {
        let (chain, lease) = make()
        chain.setEQ(bandGains(5, 12))
        chain.setTargetGain(0.5, snap: true)
        let input = MusicTestSignal.sine(frequency: 1_000, amplitude: 0.4, sampleRate: Self.rate, frames: 2_400, channels: 6)
        for layout in [TestBufferList.Layout.interleaved, .planar] {
            let output = render(lease, input, layout: layout)
            for channel in 0..<6 {
                let difference = zip(output.samples(channel: channel), input[channel]).map { abs($0 - 0.5 * $1) }.max() ?? 1
                #expect(difference < 1e-6)
            }
        }
    }

    @Test("a planar buffer longer than the scratch gets the gain only and never overruns")
    func planarBeyondScratch() {
        let (chain, lease) = make(maxFrames: 1_024)
        chain.setEQ(bandGains(5, 12))
        chain.setTargetGain(0.5, snap: true)
        let input = MusicTestSignal.sine(frequency: 1_000, amplitude: 0.2, sampleRate: Self.rate, frames: 4_096)
        let output = render(lease, input, layout: .planar)
        for channel in 0..<2 {
            let difference = zip(output.samples(channel: channel), input[channel]).map { abs($0 - 0.5 * $1) }.max() ?? 1
            #expect(difference < 1e-6)
        }
    }

    @Test("an empty buffer is harmless")
    func emptyBuffer() {
        let (_, lease) = make()
        let buffers = TestBufferList(channels: [[], []], layout: .planar)
        lease.render(buffers.list, frames: 0)
        #expect(buffers.frames == 0)
    }

    // MARK: - EQ and AutoEQ

    @Test("a band boost raises the energy at its frequency, and a far band leaves it alone")
    func eqBand() {
        let (chain, lease) = make()
        chain.setEQ(bandGains(5, 12))
        let boosted = settledRMS(render(lease, oneKilohertz).samples(channel: 0))
        let reference = settledRMS(oneKilohertz[0])
        #expect(abs(boosted / reference - 3.98) < 0.2, "+12 dB is a factor of about 3.98, got \(boosted / reference)")

        let (farChain, farLease) = make()
        farChain.setEQ(bandGains(0, 12))
        let far = settledRMS(render(farLease, oneKilohertz).samples(channel: 0))
        #expect(abs(far / reference - 1) < 0.03)
    }

    @Test("a disabled EQ is bypassed whatever its gains")
    func eqDisabled() {
        let (chain, lease) = make()
        var settings = bandGains(5, 12)
        settings.isEnabled = false
        chain.setEQ(settings)
        let output = settledRMS(render(lease, oneKilohertz).samples(channel: 0))
        #expect(abs(output / settledRMS(oneKilohertz[0]) - 1) < 1e-3)
        #expect(chain.eqSettings == settings)
    }

    private func autoEQ(preamp: Float) -> AutoEQProfile {
        AutoEQProfile(
            id: "test-profile", name: "Test", source: .bundled, preampDB: preamp,
            filters: [AutoEQFilter(type: .peaking, frequency: 1_000, gainDB: 6, q: 1.0)]
        )
    }

    @Test("an AutoEQ profile shapes the sound, its preamp can be bypassed, and nil removes it")
    func autoEQProfile() {
        let reference = settledRMS(oneKilohertz[0])

        let (chain, lease) = make()
        chain.setAutoEQProfile(autoEQ(preamp: -6))
        #expect(chain.autoEQProfile?.id == "test-profile")
        let withPreamp = settledRMS(render(lease, oneKilohertz).samples(channel: 0))
        #expect(abs(withPreamp / reference - 1) < 0.05, "+6 dB at 1 kHz and a -6 dB preamp cancel, got \(withPreamp / reference)")

        let (bypassChain, bypassLease) = make()
        bypassChain.setAutoEQPreampEnabled(false)
        #expect(!bypassChain.autoEQPreampEnabled)
        bypassChain.setAutoEQProfile(autoEQ(preamp: -6))
        let withoutPreamp = settledRMS(render(bypassLease, oneKilohertz).samples(channel: 0))
        #expect(abs(withoutPreamp / reference - 2) < 0.1, "+6 dB is a factor of about 2, got \(withoutPreamp / reference)")

        let (offChain, offLease) = make()
        offChain.setAutoEQProfile(autoEQ(preamp: -6))
        offChain.setAutoEQProfile(nil)
        #expect(offChain.autoEQProfile == nil)
        let removed = settledRMS(render(offLease, oneKilohertz).samples(channel: 0))
        #expect(abs(removed / reference - 1) < 1e-3)
    }

    // MARK: - Loudness

    @Test("loudness compensation shapes a quiet bass tone, and off leaves it alone")
    func loudnessCompensation() {
        let bass = MusicTestSignal.sine(frequency: 60, amplitude: 0.05, sampleRate: Self.rate, frames: 48_000)
        let reference = settledRMS(bass[0])

        let (chain, lease) = make()
        chain.setLoudnessCompensation(enabled: true, volume: 0.1)
        #expect(chain.loudnessCompensationEnabled)
        #expect(chain.loudnessCompensationVolume == 0.1)
        let compensated = settledRMS(render(lease, bass).samples(channel: 0))
        #expect(compensated / reference > 1.5, "low volume lifts the bass, got \(compensated / reference)")

        chain.setLoudnessCompensation(enabled: false, volume: 0.1)
        #expect(!chain.loudnessCompensationEnabled)
        let off = settledRMS(render(lease, bass).samples(channel: 0))
        #expect(abs(off / reference - 1) < 0.02)
    }

    @Test("loudness equalization lifts a quiet signal over a few seconds, and off stops it")
    func loudnessEqualization() {
        let quiet = MusicTestSignal.sine(frequency: 1_000, amplitude: 0.03, sampleRate: Self.rate, frames: 48_000 * 6)
        let reference = settledRMS(quiet[0])

        let (chain, lease) = make()
        chain.setLoudnessEqualization(enabled: true)
        #expect(chain.loudnessEqualizationEnabled)
        let lifted = settledRMS(render(lease, quiet).samples(channel: 0))
        #expect(lifted / reference > 1.2, "got \(lifted / reference)")

        chain.setLoudnessEqualization(enabled: false)
        #expect(!chain.loudnessEqualizationEnabled)
        let off = settledRMS(render(lease, quiet).samples(channel: 0))
        #expect(abs(off / reference - 1) < 0.01)
    }

    // MARK: - Safety

    @Test("NaN and infinity never reach the output, and the filters recover on the next buffer")
    func nanGuard() {
        let (chain, lease) = make()
        chain.setLoudnessEqualization(enabled: true)
        chain.setEQ(bandGains(5, 6))
        var poisoned = MusicTestSignal.sine(frequency: 1_000, amplitude: 0.1, sampleRate: Self.rate, frames: 4_800)
        poisoned[0][100] = .nan
        poisoned[1][200] = .infinity
        let first = render(lease, poisoned)
        for channel in 0..<2 { #expect(first.samples(channel: channel).allSatisfy { $0.isFinite }) }

        let clean = MusicTestSignal.sine(frequency: 1_000, amplitude: 0.1, sampleRate: Self.rate, frames: 4_800)
        let second = render(lease, clean)
        for channel in 0..<2 {
            let samples = second.samples(channel: channel)
            #expect(samples.allSatisfy { $0.isFinite })
            #expect(MusicTestSignal.peak(samples) > 0.05, "the audio comes back, it is not stuck on silence")
        }
    }

    @Test("a gain stage that overflows is silenced rather than limited into NaN")
    func overflowIsSilenced() {
        let (chain, lease) = make()
        chain.setTargetGain(4, snap: true)
        let huge = render(lease, MusicTestSignal.constant(Float.greatestFiniteMagnitude, frames: 256))
        #expect(huge.samples(channel: 0).allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test("the peak reports the level of what was rendered and resets when read")
    func peakLevel() {
        let (chain, lease) = make()
        #expect(chain.consumePeak() == 0)
        render(lease, MusicTestSignal.constant(0.5, frames: 512))
        #expect(abs(chain.consumePeak() - 0.5) < 1e-3)
        #expect(chain.consumePeak() == 0)

        chain.setTargetGain(0, snap: true)
        render(lease, MusicTestSignal.constant(0.5, frames: 512))
        #expect(chain.consumePeak() == 0, "the meter shows what is heard, so mute reads zero")
    }

    @Test("the level is the RMS of the signal before the gain, and resets when read")
    func levelIsPreGainRMS() {
        let (chain, lease) = make()
        chain.setTargetGain(0.25, snap: true)
        #expect(chain.consumeLevel() == 0)

        render(lease, MusicTestSignal.constant(0.5, frames: 512))
        // The volume slider must not move the bars: the level reads the source, not what is heard.
        #expect(abs(chain.consumeLevel() - 0.5) < 1e-4)
        #expect(chain.consumeLevel() == 0)
    }

    @Test("the level of a sine is its RMS, peak over root two")
    func levelOfASine() {
        let (chain, lease) = make()
        render(lease, MusicTestSignal.sine(frequency: 1_000, amplitude: 0.4, sampleRate: Self.rate, frames: 4_800))
        #expect(abs(chain.consumeLevel() - Float(0.4 / 2.0.squareRoot())) < 2e-3)
    }

    @Test("the level keeps the loudest buffer since the last read")
    func levelKeepsTheLoudest() {
        let (chain, lease) = make()
        render(lease, MusicTestSignal.constant(0.1, frames: 256))
        render(lease, MusicTestSignal.constant(0.6, frames: 256))
        render(lease, MusicTestSignal.constant(0.2, frames: 256))
        #expect(abs(chain.consumeLevel() - 0.6) < 1e-4)
    }

    @Test("a muted chain reports no level, so the bars rest")
    func levelRestsWhenMuted() {
        let (chain, lease) = make()
        chain.setTargetGain(0, snap: true)
        render(lease, MusicTestSignal.constant(0.5, frames: 512))
        #expect(chain.consumeLevel() == 0)

        chain.setTargetGain(1, snap: true)
        render(lease, MusicTestSignal.constant(0.5, frames: 512))
        #expect(chain.consumeLevel() > 0.4)
    }

    @Test("reading the level leaves the peak alone, and reading the peak leaves the level alone")
    func levelAndPeakAreSeparate() {
        let (chain, lease) = make()
        render(lease, MusicTestSignal.constant(0.5, frames: 512))

        #expect(abs(chain.consumeLevel() - 0.5) < 1e-4)
        #expect(abs(chain.consumePeak() - 0.5) < 1e-3, "the Mixer row's meter still has its reading")

        render(lease, MusicTestSignal.constant(0.3, frames: 512))
        #expect(abs(chain.consumePeak() - 0.3) < 1e-3)
        #expect(abs(chain.consumeLevel() - 0.3) < 1e-4)
    }

    @Test("every layout reports a level, and a buffer of NaN reports none")
    func levelInEveryLayout() {
        let (chain, lease) = make()
        render(lease, MusicTestSignal.constant(0.5, frames: 256, channels: 1))
        #expect(abs(chain.consumeLevel() - 0.5) < 1e-4)

        render(lease, MusicTestSignal.constant(0.4, frames: 256), layout: .planar)
        #expect(abs(chain.consumeLevel() - 0.4) < 1e-4)

        render(lease, MusicTestSignal.constant(0.3, frames: 256, channels: 3))
        #expect(abs(chain.consumeLevel() - 0.3) < 1e-4)

        render(lease, MusicTestSignal.constant(Float.nan, frames: 256))
        #expect(chain.consumeLevel() == 0)
    }

    @Test("every rendered frame is counted")
    func framesAreCounted() {
        let (chain, lease) = make()
        render(lease, MusicTestSignal.constant(0.1, frames: 300))
        render(lease, MusicTestSignal.constant(0.1, frames: 212), layout: .planar)
        #expect(chain.framesProcessed == 512)
    }

    // MARK: - Sample rate

    @Test("a stream at another sample rate bypasses the EQ until the processors are rebuilt, then recovers")
    func sampleRateMismatch() async {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setEQ(bandGains(5, 12))
        let lease = MusicRenderLease(chain: chain, sampleRate: 44_100, maxFrames: 16_384)
        #expect(chain.processorSampleRate == 48_000, "creating the lease must not block on the rebuild")

        let tone = MusicTestSignal.sine(frequency: 1_000, amplitude: 0.1, sampleRate: 44_100, frames: 44_100)
        let reference = settledRMS(tone[0])
        let bypassed = settledRMS(render(lease, tone).samples(channel: 0))
        #expect(abs(bypassed / reference - 1) < 1e-3, "the EQ is bypassed while its coefficients are for 48 kHz")

        let rebuilt = await waitUntil(timeout: .seconds(5)) { chain.processorSampleRate == 44_100 }
        #expect(rebuilt)
        let recovered = settledRMS(render(lease, tone).samples(channel: 0))
        #expect(abs(recovered / reference - 3.98) < 0.2, "got \(recovered / reference)")
    }

    @Test("two items in quick succession: the rebuild queued for the first one's rate never leaves the second one bypassed")
    func rapidRateChange() async {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setEQ(bandGains(5, 12))
        // The main queue gets no turn between the two: the first item asks for 44.1 kHz, the second is back at the
        // processors' own rate and so used to ask for nothing, which left the earlier request free to win.
        _ = MusicRenderLease(chain: chain, sampleRate: 44_100, maxFrames: 16_384)
        let lease = MusicRenderLease(chain: chain, sampleRate: 48_000, maxFrames: 16_384)

        // Anything queued on the main queue ahead of this has run once it returns.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(chain.processorSampleRate == 48_000, "the processors follow the newest item's rate")

        let reference = settledRMS(oneKilohertz[0])
        let heard = settledRMS(render(lease, oneKilohertz).samples(channel: 0))
        #expect(abs(heard / reference - 3.98) < 0.2, "the EQ must be on for the second item, got \(heard / reference)")
    }

    @Test("three rates asked for before the main queue runs: the last one wins")
    func lastRequestedRateWins() async {
        let chain = MusicDSPChain(sampleRate: 48_000)
        _ = MusicRenderLease(chain: chain, sampleRate: 44_100, maxFrames: 1_024)
        _ = MusicRenderLease(chain: chain, sampleRate: 32_000, maxFrames: 1_024)
        _ = MusicRenderLease(chain: chain, sampleRate: 22_050, maxFrames: 1_024)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(chain.processorSampleRate == 22_050)
    }

    @Test("the gain ramp still runs while the EQ is bypassed for a sample-rate change")
    func gainRunsDuringBypass() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let lease = MusicRenderLease(chain: chain, sampleRate: 44_100, maxFrames: 4_096)
        chain.setTargetGain(0.5, snap: true)
        let output = render(lease, MusicTestSignal.constant(0.4, frames: 64)).samples(channel: 0)
        #expect(output.allSatisfy { abs($0 - 0.2) < 1e-6 })
    }

    @Test("a lease at the processors' own rate leaves them as they are")
    func matchingRate() {
        let chain = MusicDSPChain(sampleRate: 44_100)
        _ = MusicRenderLease(chain: chain, sampleRate: 44_100, maxFrames: 1_024)
        #expect(chain.processorSampleRate == 44_100)
    }

    @Test("a nonsense sample rate is ignored")
    func badRate() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        for rate in [0, -44_100, .nan, .infinity] as [Double] {
            _ = MusicRenderLease(chain: chain, sampleRate: rate, maxFrames: 1_024)
        }
        #expect(chain.processorSampleRate == 48_000)
    }

    // MARK: - Overlap between two items

    @Test("only the newest lease renders; the old item's tap is silenced")
    func newestLeaseOwnsTheChain() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let old = MusicRenderLease(chain: chain, sampleRate: Self.rate, maxFrames: 4_096)
        let new = MusicRenderLease(chain: chain, sampleRate: Self.rate, maxFrames: 4_096)

        let silenced = render(old, MusicTestSignal.constant(0.5, frames: 256))
        #expect(silenced.samples(channel: 0).allSatisfy { $0 == 0 })
        #expect(chain.framesProcessed == 0)

        let heard = render(new, MusicTestSignal.constant(0.5, frames: 256))
        #expect(abs(heard.samples(channel: 0)[255] - 0.5) < 1e-3)
        #expect(chain.framesProcessed == 256)
    }

    @Test("releasing the owner silences it, and releasing a stale lease does not take ownership away")
    func releaseSemantics() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let old = MusicRenderLease(chain: chain, sampleRate: Self.rate, maxFrames: 1_024)
        let new = MusicRenderLease(chain: chain, sampleRate: Self.rate, maxFrames: 1_024)

        old.release()
        let stillOwned = render(new, MusicTestSignal.constant(0.5, frames: 64))
        #expect(abs(stillOwned.samples(channel: 0)[63] - 0.5) < 1e-3)

        new.release()
        let released = render(new, MusicTestSignal.constant(0.5, frames: 64))
        #expect(released.samples(channel: 0).allSatisfy { $0 == 0 })
    }

    @Test("a render that finds the chain busy is dropped to silence instead of racing the other thread")
    func busyRenderIsDropped() {
        let (chain, lease) = make()
        var dropped: TestBufferList?
        chain.holdingRenderLock {
            dropped = render(lease, MusicTestSignal.constant(0.5, frames: 128))
        }
        #expect(dropped?.samples(channel: 0).allSatisfy { $0 == 0 } == true)
        #expect(chain.framesProcessed == 0)

        let afterwards = render(lease, MusicTestSignal.constant(0.5, frames: 128))
        #expect(abs(afterwards.samples(channel: 0)[127] - 0.5) < 1e-3, "the lock is free again")
    }

    @Test("two threads rendering at once never corrupt the output or crash")
    func concurrentRendersStayFinite() async {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        chain.setEQ(bandGains(5, 6))
        let leases = [
            MusicRenderLease(chain: chain, sampleRate: Self.rate, maxFrames: 2_048),
            MusicRenderLease(chain: chain, sampleRate: Self.rate, maxFrames: 2_048),
        ]
        let finite = await withTaskGroup(of: Bool.self) { group in
            for lease in leases {
                group.addTask {
                    var allFinite = true
                    for _ in 0..<200 {
                        let buffers = TestBufferList(
                            channels: MusicTestSignal.sine(frequency: 1_000, amplitude: 0.1, sampleRate: 48_000, frames: 512),
                            layout: .planar
                        )
                        lease.render(buffers.list, frames: buffers.frames)
                        allFinite = allFinite && buffers.samples(channel: 0).allSatisfy { $0.isFinite }
                    }
                    return allFinite
                }
            }
            var all = true
            for await ok in group { all = all && ok }
            return all
        }
        #expect(finite)
    }

    @Test("a tap format is recorded for diagnostics")
    func recordsFormat() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        #expect(chain.observedFormat == nil)
        let format = MusicTapFormat(sampleRate: 44_100, channelCount: 2, isFloat32: true, isInterleaved: false)
        chain.noteFormat(format)
        #expect(chain.observedFormat == format)
        #expect(format.description.contains("44100"))
    }
}
