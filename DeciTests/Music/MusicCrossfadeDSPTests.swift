// DeciTests/Music/MusicCrossfadeDSPTests.swift
// Phase 1c: the equal-power lease fade, the draining lease and the headroom of an overlap. Offline, on test buffers.

import Foundation
import AudioToolbox
import Testing
@testable import Deci

@MainActor
@Suite("MusicDSPChain crossfade")
struct MusicCrossfadeDSPTests {
    private let rate = 48_000.0

    private func lease(_ chain: MusicDSPChain, claims: Bool = true) -> MusicRenderLease {
        MusicRenderLease(chain: chain, sampleRate: rate, maxFrames: 16_384, claims: claims)
    }

    @discardableResult
    private func render(_ lease: MusicRenderLease, _ channels: [[Float]]) -> [Float] {
        let buffers = TestBufferList(channels: channels, layout: .interleaved)
        lease.render(buffers.list, frames: buffers.frames)
        return buffers.samples(channel: 0)
    }

    /// Renders `frames` frames of a constant in chunks and returns the left channel.
    private func renderConstant(_ lease: MusicRenderLease, _ value: Float, frames: Int, chunk: Int = 480) -> [Float] {
        var out: [Float] = []
        var done = 0
        while done < frames {
            let count = min(chunk, frames - done)
            out += render(lease, MusicTestSignal.constant(value, frames: count))
            done += count
        }
        return out
    }

    // MARK: - Curve

    @Test("an equal-power fade out follows cos over its length, sample accurate")
    func fadeOutIsCosine() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setFade(to: 0, over: 1, curve: .equalPower)
        let out = renderConstant(owner, 0.4, frames: 48_000, chunk: 777)
        for fraction in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let index = Int(fraction * 48_000) - 1
            let expected = 0.4 * Float(cos(Double(index + 1) / 48_000 * Double.pi / 2))
            #expect(abs(out[index] - expected) < 5e-3, "cos at \(fraction): \(out[index]) vs \(expected)")
        }
        #expect(abs(out[47_999]) < 1e-3, "the fade ends at zero")
    }

    @Test("an equal-power fade in follows sin from silence")
    func fadeInIsSine() {
        let chain = MusicDSPChain(sampleRate: rate)
        let incoming = lease(chain)
        incoming.setFade(to: 0)
        render(incoming, MusicTestSignal.constant(0.4, frames: 64))
        incoming.setFade(to: 1, over: 1, curve: .equalPower)
        let out = renderConstant(incoming, 0.4, frames: 48_000, chunk: 1_000)
        for fraction in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let index = Int(fraction * 48_000) - 1
            let expected = 0.4 * Float(sin(Double(index + 1) / 48_000 * Double.pi / 2))
            #expect(abs(out[index] - expected) < 5e-3, "sin at \(fraction): \(out[index]) vs \(expected)")
        }
        #expect(abs(out[47_999] - 0.4) < 1e-3)
        let after = render(incoming, MusicTestSignal.constant(0.4, frames: 128))
        #expect(abs(after[100] - 0.4) < 1e-3, "after the fade the lease holds full level")
    }

    @Test("the equal-power pair keeps the power of two uncorrelated signals constant")
    func powerIsConstant() {
        let chain = MusicDSPChain(sampleRate: rate)
        let outgoing = lease(chain)
        let incoming = lease(chain, claims: false)
        incoming.setFade(to: 0)
        render(incoming, MusicTestSignal.constant(0.1, frames: 16))
        outgoing.drain(over: 1, curve: .equalPower)
        incoming.claim()
        incoming.setFade(to: 1, over: 1, curve: .equalPower)
        let a = renderConstant(outgoing, 0.2, frames: 48_000)
        let b = renderConstant(incoming, 0.2, frames: 48_000)
        for index in stride(from: 100, to: 47_900, by: 4_000) {
            let power = a[index] * a[index] + b[index] * b[index]
            #expect(abs(power - 0.04) < 2e-3, "power at \(index): \(power)")
        }
    }

    @Test("a linear fade is unchanged")
    func linearStaysLinear() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setFade(to: 0, over: 1)
        let out = renderConstant(owner, 0.4, frames: 48_000)
        #expect(abs(out[23_999] - 0.2) < 5e-3)
    }

    // MARK: - Draining

    @Test("a draining lease stays audible after the chain moved on, until its fade reaches zero, then it is silent")
    func drainingIsAudibleThenSilent() {
        let chain = MusicDSPChain(sampleRate: rate)
        let outgoing = lease(chain)
        let incoming = lease(chain, claims: false)
        outgoing.drain(over: 0.1, curve: .equalPower)
        incoming.claim()
        #expect(chain.owns(incoming))

        let during = render(outgoing, MusicTestSignal.constant(0.3, frames: 2_400))
        #expect(during.contains { abs($0) > 0.05 }, "audible while draining")
        #expect(outgoing.debugCounters.silencedFrames == 0)

        render(outgoing, MusicTestSignal.constant(0.3, frames: 4_800))
        let after = render(outgoing, MusicTestSignal.constant(0.3, frames: 480))
        #expect(after.allSatisfy { $0 == 0 }, "silent once the fade is over")
        #expect(outgoing.debugCounters.silencedFrames > 0)
    }

    @Test("a lease that was superseded without draining is still silent at once")
    func supersededWithoutDrainStaysSilent() {
        let chain = MusicDSPChain(sampleRate: rate)
        let old = lease(chain)
        let new = lease(chain, claims: false)
        new.claim()
        let out = render(old, MusicTestSignal.constant(0.3, frames: 480))
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test("a released draining lease is silent")
    func releasedDrainingIsSilent() {
        let chain = MusicDSPChain(sampleRate: rate)
        let old = lease(chain)
        old.drain(over: 1, curve: .equalPower)
        old.release()
        let out = render(old, MusicTestSignal.constant(0.3, frames: 480))
        #expect(out.allSatisfy { $0 == 0 })
    }

    // MARK: - Headroom

    @Test("two correlated loud signals never sum above 1.0 through the overlap")
    func correlatedPeakStaysBounded() {
        for amplitude in [Float(0.99), 1.4] {
            let chain = MusicDSPChain(sampleRate: rate)
            let outgoing = lease(chain)
            let incoming = lease(chain, claims: false)
            incoming.setFade(to: 0)
            render(incoming, MusicTestSignal.constant(0.1, frames: 16))
            outgoing.drain(over: 2, curve: .equalPower)
            incoming.claim()
            incoming.setFade(to: 1, over: 2, curve: .equalPower)

            let frames = 96_000
            let signal = MusicTestSignal.sine(frequency: 220, amplitude: amplitude, sampleRate: rate, frames: frames)
            var peak: Float = 0
            let chunk = 480
            for start in stride(from: 0, to: frames, by: chunk) {
                let slice = signal.map { Array($0[start..<(start + chunk)]) }
                let a = render(outgoing, slice)
                let b = render(incoming, slice)
                for (x, y) in zip(a, b) { peak = max(peak, abs(x + y)) }
            }
            #expect(peak <= 1.0 + 1e-4, "summed peak \(peak) at amplitude \(amplitude)")
            #expect(peak > 0.9, "and the overlap is not squashed far below the ceiling: \(peak)")
        }
    }

    @Test("quiet material is not touched by the headroom: an outgoing lease still follows its curve")
    func quietMaterialKeepsItsCurve() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setFade(to: 0, over: 1, curve: .equalPower)
        let out = renderConstant(owner, 0.2, frames: 24_000)
        #expect(abs(out[23_999] - 0.2 * Float(cos(0.5 * Double.pi / 2))) < 3e-3)
    }

    // MARK: - Meters

    @Test("during the overlap the meters count both the draining and the incoming lease")
    func metersCombineDuringOverlap() {
        let chain = MusicDSPChain(sampleRate: rate)
        let outgoing = lease(chain)
        let incoming = lease(chain, claims: false)
        incoming.setFade(to: 0)
        render(incoming, MusicTestSignal.constant(0.1, frames: 16))
        _ = chain.consumePeak()
        _ = chain.consumeLevel()
        outgoing.drain(over: 4, curve: .equalPower)
        incoming.claim()
        incoming.setFade(to: 1, over: 4, curve: .equalPower)
        // Two seconds in: both are well above zero.
        _ = renderConstant(outgoing, 0.3, frames: 96_000)
        _ = renderConstant(incoming, 0.3, frames: 96_000)
        _ = chain.consumeLevel()
        render(outgoing, MusicTestSignal.constant(0.3, frames: 480))
        render(incoming, MusicTestSignal.constant(0.3, frames: 480))
        // Each is ~0.3 * 0.707 at the midpoint: powers add to ~0.3.
        let level = chain.consumeLevel()
        #expect(level > 0.27 && level < 0.33, "combined level \(level)")
    }
}
