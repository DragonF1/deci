// DeciTests/Music/MusicRenderLeaseOffsetTests.swift
// Tier 2b P2: the per-lease loudness offset. A second, always linear gain after the limiter, the rider and the fade,
// attenuation only. Offline, on test buffers.

import Foundation
import AudioToolbox
import Testing
@testable import Deci

@MainActor
@Suite("MusicRenderLease offset")
struct MusicRenderLeaseOffsetTests {
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

    @Test("an offset ramp is linear and sample accurate across buffer sizes")
    func rampIsLinear() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setOffset(to: 0.5, over: 1)
        let out = renderConstant(owner, 0.4, frames: 48_000, chunk: 777)
        for fraction in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let index = Int(fraction * 48_000) - 1
            let expected = 0.4 * Float(1 - 0.5 * Double(index + 1) / 48_000)
            #expect(abs(out[index] - expected) < 2e-3, "linear at \(fraction): \(out[index]) vs \(expected)")
        }
        #expect(abs(out[47_999] - 0.2) < 1e-3, "the ramp ends on its target")
        let after = render(owner, MusicTestSignal.constant(0.4, frames: 256))
        #expect(abs(after[100] - 0.2) < 1e-3, "the target is held")
    }

    @Test("a zero-length offset jumps at the next render")
    func jumps() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setOffset(to: 0.25)
        let out = render(owner, MusicTestSignal.constant(0.4, frames: 64))
        #expect(abs(out[0] - 0.1) < 1e-3)
        #expect(abs(out[63] - 0.1) < 1e-3)
    }

    @Test("a gain above 1 is clamped to 1, a negative one to 0, a non-finite one is ignored")
    func clamps() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setOffset(to: 3)
        #expect(owner.offsetTarget == 1)
        let out = render(owner, MusicTestSignal.constant(0.4, frames: 64))
        #expect(abs(out[10] - 0.4) < 1e-3, "never louder than the source")
        owner.setOffset(to: -2)
        #expect(owner.offsetTarget == 0)
        owner.setOffset(to: 0.5)
        owner.setOffset(to: .nan)
        owner.setOffset(to: .infinity)
        #expect(owner.offsetTarget == 0.5)
    }

    @Test("an idle lease is untouched by the offset channel")
    func idleIsIdentity() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        #expect(owner.offsetTarget == 1)
        let out = renderConstant(owner, 0.4, frames: 4_800)
        #expect(out.allSatisfy { abs($0 - 0.4) < 2e-3 })
    }

    @Test("a constant offset multiplies a fade that is in progress")
    func multipliesFade() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setOffset(to: 0.5)
        owner.setFade(to: 0, over: 1)
        let out = renderConstant(owner, 0.4, frames: 48_000, chunk: 600)
        // Linear fade 1 -> 0 times a constant 0.5.
        for fraction in [0.25, 0.5, 0.75] {
            let index = Int(fraction * 48_000) - 1
            let expected = 0.4 * 0.5 * Float(1 - Double(index + 1) / 48_000)
            #expect(abs(out[index] - expected) < 3e-3, "fade * offset at \(fraction): \(out[index]) vs \(expected)")
        }
    }

    @Test("a new ramp replaces the one in progress, from where it is")
    func replacesRamp() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setOffset(to: 0.5, over: 1)
        let first = renderConstant(owner, 0.4, frames: 24_000)
        owner.setOffset(to: 1, over: 1)
        let second = renderConstant(owner, 0.4, frames: 48_000)
        #expect(abs(first[23_999] - 0.4 * 0.75) < 2e-3)
        #expect(abs(second[0] - first[23_999]) < 3e-3, "no step where the new ramp takes over")
        #expect(abs(second[47_999] - 0.4) < 1e-3)
    }

    @Test("the offset comes after the limiter: a full-scale square at offset 0.5 peaks at 0.5, never over")
    func afterLimiter() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setOffset(to: 0.5)
        var square: [Float] = []
        for frame in 0..<4_800 { square.append((frame / 24) % 2 == 0 ? 1 : -1) }
        let out = render(owner, [square, square])
        let peak = MusicTestSignal.peak(out)
        #expect(peak <= 0.5 + 1e-4, "peak \(peak)")
        #expect(peak > 0.4, "the signal is attenuated, not removed: \(peak)")

        // The same signal without an offset peaks higher, so the 0.5 really comes after the limiter.
        let plain = lease(MusicDSPChain(sampleRate: rate))
        let reference = MusicTestSignal.peak(render(plain, [square, square]))
        #expect(reference <= 1 + 1e-4)
        #expect(abs(peak - reference * 0.5) < 5e-3)
    }

    @Test("the offset never lifts a correlated pair sum above 1.0 during an equal-power overlap")
    func pairSumStaysUnderOne() {
        func overlapSum(incomingOffset: Float) -> (peak: Float, sums: [Float]) {
            let chain = MusicDSPChain(sampleRate: rate)
            let outgoing = lease(chain)
            let incoming = lease(chain, claims: false)
            incoming.setFade(to: 0)
            render(incoming, MusicTestSignal.constant(0.9, frames: 16))
            incoming.setOffset(to: incomingOffset)
            outgoing.drain(over: 1, curve: .equalPower)
            incoming.claim()
            incoming.setFade(to: 1, over: 1, curve: .equalPower, fromSilence: true)
            let a = renderConstant(outgoing, 0.95, frames: 48_000)
            let b = renderConstant(incoming, 0.95, frames: 48_000)
            let sums = zip(a, b).map { $0 + $1 }
            return (sums.map { abs($0) }.max() ?? 0, sums)
        }
        let plain = overlapSum(incomingOffset: 1)
        let offset = overlapSum(incomingOffset: 0.5)
        #expect(plain.peak <= 1.0 + 1e-3, "baseline \(plain.peak)")
        #expect(offset.peak <= 1.0 + 1e-3, "with the offset \(offset.peak)")
        // The offset only ever lowers the incoming side's share.
        for index in stride(from: 0, to: 48_000, by: 500) {
            #expect(offset.sums[index] <= plain.sums[index] + 1e-4)
        }
    }

    @Test("a non-owner standby lease takes an offset too, and it is there when it claims")
    func standbyOffset() {
        let chain = MusicDSPChain(sampleRate: rate)
        _ = lease(chain)
        let standby = lease(chain, claims: false)
        standby.setOffset(to: 0.5)
        let before = render(standby, MusicTestSignal.constant(0.4, frames: 64))
        #expect(abs(before[10] - 0.2) < 1e-3)
        standby.claim()
        let after = render(standby, MusicTestSignal.constant(0.4, frames: 64))
        #expect(abs(after[10] - 0.2) < 1e-3)
    }

    @Test("a re-prepared tap deck brings its offset back on the new lease, with a short ramp")
    func reprepareRestoresOffset() {
        let chain = MusicDSPChain(sampleRate: rate)
        let deck = MusicTapDeck(role: .active)
        let first = lease(chain)
        deck.attach(first)
        deck.setOffset(to: 0.5, over: 0)
        #expect(first.offsetTarget == 0.5)

        deck.detach()
        let second = lease(chain)
        #expect(second.offsetTarget == 1)
        deck.attach(second)
        #expect(second.offsetTarget == 0.5, "restored on attach")
        let out = renderConstant(second, 0.4, frames: 9_600, chunk: 480)
        #expect(out[0] > 0.3, "it ramps in rather than stepping: \(out[0])")
        #expect(abs(out[9_599] - 0.2) < 1e-3, "and settles on the offset after 0.1 s")
        // The deck clamps too.
        deck.setOffset(to: 5)
        #expect(second.offsetTarget == 1)
    }

    @Test("the meter follows fade times offset")
    func metersFollow() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setOffset(to: 0.5)
        render(owner, MusicTestSignal.constant(0.4, frames: 480))
        _ = chain.consumeLevel()
        render(owner, MusicTestSignal.constant(0.4, frames: 4_800))
        let level = chain.consumeLevel()
        #expect(abs(level - 0.2) < 0.01, "level \(level)")

        owner.setFade(to: 0.5)
        render(owner, MusicTestSignal.constant(0.4, frames: 480))
        _ = chain.consumeLevel()
        render(owner, MusicTestSignal.constant(0.4, frames: 4_800))
        let both = chain.consumeLevel()
        #expect(abs(both - 0.1) < 0.01, "fade 0.5 * offset 0.5: \(both)")
    }

    @Test("planar and mono streams get the offset as well")
    func otherLayouts() {
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.setOffset(to: 0.5)
        let planar = TestBufferList(channels: MusicTestSignal.constant(0.4, frames: 256), layout: .planar)
        owner.render(planar.list, frames: planar.frames)
        #expect(abs(planar.samples(channel: 1)[100] - 0.2) < 1e-3)

        let mono = TestBufferList(channels: MusicTestSignal.constant(0.4, frames: 256, channels: 1), layout: .interleaved)
        owner.render(mono.list, frames: mono.frames)
        #expect(abs(mono.samples(channel: 0)[100] - 0.2) < 1e-3)
    }
}
