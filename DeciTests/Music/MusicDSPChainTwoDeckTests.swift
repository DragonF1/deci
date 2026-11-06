// DeciTests/Music/MusicDSPChainTwoDeckTests.swift
// Phase 1b: two leases render at the same time, each on its own filters at its own sample rate, under shared settings.
// Covers the per-lease fade (the hook the crossfade drives), equal-power sums and the combined meters. Offline, on test
// buffers.

import Foundation
import AudioToolbox
import Testing
@testable import Deci

@MainActor
@Suite("MusicDSPChain two decks")
struct MusicDSPChainTwoDeckTests {
    private func lease(_ chain: MusicDSPChain, rate: Double = 48_000, claims: Bool = true) -> MusicRenderLease {
        MusicRenderLease(chain: chain, sampleRate: rate, maxFrames: 16_384, claims: claims)
    }

    @discardableResult
    private func render(_ lease: MusicRenderLease, _ channels: [[Float]], layout: TestBufferList.Layout = .interleaved) -> [Float] {
        let buffers = TestBufferList(channels: channels, layout: layout)
        lease.render(buffers.list, frames: buffers.frames)
        return buffers.samples(channel: 0)
    }

    private func boost(_ band: Int, _ gain: Float) -> EQSettings {
        var gains = [Float](repeating: 0, count: EQSettings.bandCount)
        gains[band] = gain
        return EQSettings(bandGains: gains)
    }

    private func settledRMS(_ samples: [Float]) -> Float {
        MusicTestSignal.rms(Array(samples.suffix(samples.count / 2)))
    }

    private func tone(rate: Double, amplitude: Float = 0.1) -> [[Float]] {
        MusicTestSignal.sine(frequency: 1_000, amplitude: amplitude, sampleRate: rate, frames: Int(rate))
    }

    /// Deterministic white noise in [-amplitude, amplitude].
    private func noise(seed: UInt64, amplitude: Float, frames: Int) -> [[Float]] {
        var state = seed
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
        }
        return [(0..<frames).map { _ in next() }, (0..<frames).map { _ in next() }]
    }

    private func power(_ samples: [Float]) -> Double {
        samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
    }

    // MARK: - Two leases at once

    @Test("two leases at 44.1 and 48 kHz render a 1 kHz tone at the same time, each with the boost, neither silenced")
    func bothDecksGetTheBoost() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setEQ(boost(5, 12))
        let owner = lease(chain, rate: 44_100)
        let standby = lease(chain, rate: 48_000, claims: false)

        let ownerTone = tone(rate: 44_100)
        let standbyTone = tone(rate: 48_000)
        let ownerOut = render(owner, ownerTone)
        let standbyOut = render(standby, standbyTone)

        #expect(abs(settledRMS(ownerOut) / settledRMS(ownerTone[0]) - 3.98) < 0.2)
        #expect(abs(settledRMS(standbyOut) / settledRMS(standbyTone[0]) - 3.98) < 0.2)
        #expect((ownerOut + standbyOut).allSatisfy { $0.isFinite })
        #expect(owner.debugCounters.silencedFrames == 0)
        #expect(standby.debugCounters.silencedFrames == 0)
        #expect(owner.debugCounters.gainOnlyFrames == 0 && standby.debugCounters.gainOnlyFrames == 0)
    }

    @Test("interleaved renders on one lease do not disturb the other's filter state")
    func filterStateIsNotShared() {
        let input = tone(rate: 48_000)
        let aloneChain = MusicDSPChain(sampleRate: 48_000)
        aloneChain.setEQ(boost(5, 12))
        let reference = render(lease(aloneChain), input)

        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setEQ(boost(5, 12))
        let owner = lease(chain)
        let standby = lease(chain, claims: false)
        var out: [Float] = []
        let chunk = 480
        for start in stride(from: 0, to: input[0].count, by: chunk) {
            let slice = input.map { Array($0[start..<min(start + chunk, $0.count)]) }
            // The standby gets unrelated audio in between; a shared delay line would smear it into the owner.
            render(standby, noise(seed: UInt64(start + 1), amplitude: 0.3, frames: chunk))
            out += render(owner, slice)
        }
        #expect(zip(out, reference).map { abs($0 - $1) }.max() ?? 1 < 1e-5, "separate delay lines give the same output as a lone lease")
    }

    @Test("a settings change reaches every live lease, and a lease made afterwards starts with it")
    func settingsReachBothDecks() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let owner = lease(chain)
        let standby = lease(chain, claims: false)
        let input = tone(rate: 48_000)
        let reference = settledRMS(input[0])

        chain.setEQ(boost(5, 12))
        #expect(abs(settledRMS(render(owner, input)) / reference - 3.98) < 0.2)
        #expect(abs(settledRMS(render(standby, input)) / reference - 3.98) < 0.2)

        let late = lease(chain, claims: false)
        #expect(abs(settledRMS(render(late, input)) / reference - 3.98) < 0.2, "a new lease builds from the current settings")

        chain.setEQ(.flat)
        #expect(abs(settledRMS(render(owner, input)) / reference - 1) < 0.02)
        #expect(abs(settledRMS(render(standby, input)) / reference - 1) < 0.02)
    }

    @Test("the master gain and its snap apply to both decks")
    func masterGainReachesBothDecks() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let owner = lease(chain)
        let standby = lease(chain, claims: false)
        chain.setTargetGain(0.5, snap: true)
        let ownerOut = render(owner, MusicTestSignal.constant(0.4, frames: 64))
        let standbyOut = render(standby, MusicTestSignal.constant(0.4, frames: 64))
        #expect(ownerOut.allSatisfy { abs($0 - 0.2) < 1e-3 })
        #expect(standbyOut.allSatisfy { abs($0 - 0.2) < 1e-3 })
    }

    @Test("a lease created while the volume is down starts at that volume, not at full")
    func newLeaseStartsAtTheCurrentGain() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0.25, snap: true)
        _ = render(lease(chain), MusicTestSignal.constant(0.4, frames: 8))
        let fresh = lease(chain, claims: false)
        let out = render(fresh, MusicTestSignal.constant(0.4, frames: 64))
        #expect(out.allSatisfy { abs($0 - 0.1) < 1e-3 })
    }

    // MARK: - Fade

    @Test("the fade ramps linearly to its target over the requested frames, exactly across buffer boundaries")
    func fadeRampsAcrossBuffers() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let deck = lease(chain)
        deck.setFade(to: 0.25, over: 1_000.0 / 48_000)
        var out: [Float] = []
        for size in [300, 300, 300, 300, 300] {
            out += render(deck, MusicTestSignal.constant(0.4, frames: size))
        }
        for frame in 0..<1_000 {
            let expected = 0.4 * (1 + (0.25 - 1) * Float(frame + 1) / 1_000)
            #expect(abs(out[frame] - expected) < 2e-4, "frame \(frame): \(out[frame]) vs \(expected)")
        }
        #expect(out[1_000...].allSatisfy { abs($0 - 0.1) < 1e-3 }, "it holds the target afterwards")
    }

    @Test("a new fade starts from wherever the last one is, and zero seconds jumps")
    func fadeRetargetsFromTheCurrentValue() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let deck = lease(chain)
        deck.setFade(to: 0, over: 100.0 / 48_000)
        let first = render(deck, MusicTestSignal.constant(0.4, frames: 50))
        #expect(abs(first[49] - 0.4 * 0.5) < 2e-4)

        deck.setFade(to: 1, over: 100.0 / 48_000)
        let second = render(deck, MusicTestSignal.constant(0.4, frames: 200))
        #expect(abs(second[0] - 0.4 * (0.5 + 0.005)) < 2e-4)
        #expect(abs(second[99] - 0.4) < 2e-4)
        #expect(second[100...].allSatisfy { abs($0 - 0.4) < 1e-3 })

        deck.setFade(to: 0.5)
        let jumped = render(deck, MusicTestSignal.constant(0.4, frames: 16))
        #expect(jumped.allSatisfy { abs($0 - 0.2) < 1e-3 })
    }

    @Test("a fade to zero silences that lease only, and the default fade is 1")
    func fadeIsPerLease() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let owner = lease(chain)
        let standby = lease(chain, claims: false)
        let untouched = render(owner, MusicTestSignal.constant(0.3, frames: 64))
        #expect(untouched.allSatisfy { abs($0 - 0.3) < 1e-3 })

        standby.setFade(to: 0)
        #expect(render(standby, MusicTestSignal.constant(0.3, frames: 64)).allSatisfy { $0 == 0 })
        #expect(render(owner, MusicTestSignal.constant(0.3, frames: 64)).allSatisfy { abs($0 - 0.3) < 1e-3 })
    }

    @Test("the fade also runs on mono and planar streams, once per buffer list")
    func fadeOnOtherLayouts() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let deck = lease(chain)
        deck.setFade(to: 0, over: 100.0 / 48_000)
        let buffers = TestBufferList(channels: MusicTestSignal.constant(0.4, frames: 50), layout: .planar)
        deck.render(buffers.list, frames: 50)
        for channel in 0..<2 { #expect(abs(buffers.samples(channel: channel)[49] - 0.2) < 2e-4) }
        let mono = TestBufferList(channels: MusicTestSignal.constant(0.4, frames: 50, channels: 1), layout: .interleaved)
        deck.render(mono.list, frames: 50)
        #expect(abs(mono.samples(channel: 0)[49]) < 2e-4, "the ramp carried on to its end: one step per list, not per channel")
    }

    @Test("equal-power sweep: cos and sin fades on two uncorrelated signals keep the summed power within 0.5 dB")
    func equalPowerSweep() {
        let frames = 32_768
        let a = noise(seed: 1, amplitude: 0.2, frames: frames)
        let b = noise(seed: 99, amplitude: 0.2, frames: frames)

        let chain = MusicDSPChain(sampleRate: 48_000)
        let single = lease(chain)
        let singlePower = power(render(single, a))

        for step in 0...8 {
            let angle = Double(step) / 8 * Double.pi / 2
            let chain = MusicDSPChain(sampleRate: 48_000)
            let left = lease(chain)
            let right = lease(chain, claims: false)
            left.setFade(to: Float(cos(angle)))
            right.setFade(to: Float(sin(angle)))
            let sum = zip(render(left, a), render(right, b)).map { $0 + $1 }
            let decibels = 10 * log10(power(sum) / singlePower)
            #expect(abs(decibels) < 0.5, "angle \(step)/8 quarter turn: \(decibels) dB")
        }
    }

    // MARK: - Meters

    @Test("the meters see both decks: peak is the louder one, level powers add, and nothing is counted twice")
    func metersCombineBothDecks() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let owner = lease(chain)
        let standby = lease(chain, claims: false)
        standby.arm()
        render(owner, MusicTestSignal.constant(0.3, frames: 256))
        render(standby, MusicTestSignal.constant(0.4, frames: 256))
        #expect(abs(chain.consumePeak() - 0.4) < 1e-3)
        render(owner, MusicTestSignal.constant(0.3, frames: 256))
        render(standby, MusicTestSignal.constant(0.4, frames: 256))
        #expect(abs(chain.consumeLevel() - 0.5) < 1e-3, "sqrt(0.3^2 + 0.4^2)")
        #expect(chain.consumePeak() > 0)
        #expect(chain.consumeLevel() == 0, "read once, gone")
        #expect(chain.consumePeak() == 0)
    }

    @Test("the meters keep reading when one deck renders more often than the other: nothing flickers to zero between reads")
    func metersHoldUntilRead() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let owner = lease(chain)
        let standby = lease(chain, claims: false)
        standby.arm()
        render(standby, MusicTestSignal.constant(0.4, frames: 256))
        for _ in 0..<5 { render(owner, MusicTestSignal.constant(0.2, frames: 256)) }
        #expect(abs(chain.consumePeak() - 0.4) < 1e-3, "the quieter deck's later buffers do not wipe the louder one's reading")
    }

    @Test("a released lease stops contributing to the meters, and so does one that is gone")
    func releasedLeaseLeavesTheMeters() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let owner = lease(chain)
        let standby = lease(chain, claims: false)
        standby.arm()
        render(owner, MusicTestSignal.constant(0.3, frames: 256))
        render(standby, MusicTestSignal.constant(0.4, frames: 256))
        standby.release()
        #expect(abs(chain.consumePeak() - 0.3) < 5e-3, "the released lease's unread 0.4 is gone with it")

        var gone: MusicRenderLease? = lease(chain, claims: false)
        gone?.arm()
        render(gone!, MusicTestSignal.constant(0.5, frames: 256))
        gone = nil
        render(owner, MusicTestSignal.constant(0.3, frames: 256))
        #expect(abs(chain.consumePeak() - 0.3) < 5e-3)
    }

    @Test("the level follows the fade: a deck fading to zero stops counting, so the meters track a crossfade")
    func levelFollowsTheFade() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let owner = lease(chain)
        render(owner, MusicTestSignal.constant(0.4, frames: 256))
        let full = chain.consumeLevel()
        owner.setFade(to: 0)
        render(owner, MusicTestSignal.constant(0.4, frames: 256))
        #expect(full > 0.39)
        #expect(chain.consumeLevel() == 0)

        owner.setFade(to: 1, over: 512.0 / 48_000)
        render(owner, MusicTestSignal.constant(0.4, frames: 256))
        let halfway = chain.consumeLevel()
        #expect(halfway > 0.05 && halfway < 0.3, "mid-ramp reads between silence and full, got \(halfway)")
    }

    @Test("a nonsense fade length cannot trap: huge, negative and non-finite seconds clamp")
    func fadeLengthClamps() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let owner = lease(chain)
        for seconds in [1e300, -5, .infinity, .nan, 1e12] as [Double] {
            owner.setFade(to: 0.5, over: seconds)
            let out = render(owner, MusicTestSignal.constant(0.4, frames: 64))
            #expect(out.allSatisfy { $0.isFinite })
        }
        owner.setFade(to: 0.5, over: 0)
        #expect(owner.fadeTarget == 0.5)
    }

    // MARK: - Concurrency

    @Test("settings changes from the main thread while two threads render stay finite and never crash")
    func settingsChurnWhileRendering() async {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let owner = lease(chain, rate: 44_100)
        let standby = lease(chain, rate: 48_000, claims: false)
        standby.arm()
        let finite = await withTaskGroup(of: Bool.self) { group in
            for deck in [owner, standby] {
                group.addTask {
                    var ok = true
                    for _ in 0..<300 {
                        let buffers = TestBufferList(
                            channels: MusicTestSignal.sine(frequency: 1_000, amplitude: 0.1, sampleRate: 48_000, frames: 512),
                            layout: .interleaved
                        )
                        deck.render(buffers.list, frames: 512)
                        ok = ok && buffers.samples(channel: 0).allSatisfy { $0.isFinite }
                    }
                    return ok
                }
            }
            group.addTask { @MainActor in
                for index in 0..<100 {
                    chain.setEQ(self.boost(index % EQSettings.bandCount, Float(index % 7)))
                    chain.setLoudnessEqualization(enabled: index % 2 == 0)
                    chain.setLoudnessCompensation(enabled: index % 3 == 0, volume: Float(index % 10) / 10)
                    chain.setTargetGain(Float(index % 5) / 4)
                    if index % 25 == 0 { _ = self.lease(chain, claims: false) }
                }
                return true
            }
            var all = true
            for await result in group { all = all && result }
            return all
        }
        #expect(finite)
    }
}
