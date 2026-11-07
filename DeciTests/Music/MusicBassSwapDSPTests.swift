// DeciTests/Music/MusicBassSwapDSPTests.swift
// Tier 3b P4: the 150 Hz split, the per-lease bass channel (y = f * high + b * low), and what two leases do together in a
// beat mix: the lows hand over in one step on a beat, the highs fade across the whole overlap. Offline, on test buffers.

import Foundation
import AudioToolbox
import Testing
@testable import Deci

@MainActor
@Suite("MusicBassSwap DSP")
struct MusicBassSwapDSPTests {
    private let rate = 48_000.0

    private func lease(_ chain: MusicDSPChain, claims: Bool = true) -> MusicRenderLease {
        MusicRenderLease(chain: chain, sampleRate: rate, maxFrames: 16_384, claims: claims)
    }

    @discardableResult
    private func render(_ lease: MusicRenderLease, _ mono: [Float]) -> [Float] {
        let buffers = TestBufferList(channels: [mono, mono], layout: .interleaved)
        lease.render(buffers.list, frames: buffers.frames)
        return buffers.samples(channel: 0)
    }

    private func renderChunked(_ lease: MusicRenderLease, _ signal: [Float], chunk: Int = 480) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(signal.count)
        for start in stride(from: 0, to: signal.count, by: chunk) {
            out += render(lease, Array(signal[start..<min(signal.count, start + chunk)]))
        }
        return out
    }

    /// Deterministic noise in -amplitude...amplitude.
    private func noise(frames: Int, amplitude: Float, seed: UInt32) -> [Float] {
        var state = seed | 1
        return (0..<frames).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return amplitude * Float(Int32(bitPattern: state)) / Float(Int32.max)
        }
    }

    private func sine(_ frequency: Double, amplitude: Float, frames: Int) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    private func db(_ ratio: Float) -> Float { 20 * log10(max(ratio, 1e-9)) }

    /// Plays two signals through the two leases of a beat mix the way the engine wires them: an equal-power fade over
    /// `overlap` seconds, the bass held by the outgoing lease until `swapAt`, then handed over across `handover` seconds.
    /// Returns what each lease output (left channel), frame for frame.
    private func mix(
        _ outgoingSignal: [Float], _ incomingSignal: [Float], overlap: Double, swapAt: Double, handover: Double
    ) -> (outgoing: [Float], incoming: [Float]) {
        let chain = MusicDSPChain(sampleRate: rate)
        let outgoing = lease(chain)
        let incoming = lease(chain, claims: false)
        incoming.setFade(to: 0)
        render(incoming, [Float](repeating: 0.1, count: 16))
        outgoing.drain(over: overlap, curve: .equalPower)
        incoming.claim()
        incoming.setFade(to: 1, over: overlap, curve: .equalPower)
        outgoing.beginBass(gain: 1)
        incoming.beginBass(gain: 0)
        outgoing.setBass(to: 0, over: handover, after: swapAt)
        incoming.setBass(to: 1, over: handover, after: swapAt)
        let frames = min(outgoingSignal.count, incomingSignal.count)
        var a: [Float] = []
        var b: [Float] = []
        a.reserveCapacity(frames)
        b.reserveCapacity(frames)
        let chunk = 480
        for start in stride(from: 0, to: frames, by: chunk) {
            let end = min(frames, start + chunk)
            a += render(outgoing, Array(outgoingSignal[start..<end]))
            b += render(incoming, Array(incomingSignal[start..<end]))
        }
        return (a, b)
    }

    private func windowRMS(_ samples: [Float], from: Int, length: Int) -> Float {
        MusicTestSignal.rms(Array(samples[from..<min(samples.count, from + length)]))
    }

    // MARK: - The split

    @Test("the split is a 150 Hz low-pass: a 50 Hz sine passes, a 2 kHz sine is gone, and low + high is the input")
    func splitBands() {
        var split = MusicBassSplit(sampleRate: rate)
        let frames = 48_000
        let low = sine(50, amplitude: 0.5, frames: frames)
        let high = sine(2_000, amplitude: 0.5, frames: frames)
        var lowOut: [Float] = []
        var highOut: [Float] = []
        for index in 0..<frames {
            lowOut.append(split.lowpass(low[index], channel: 0))
        }
        split.reset()
        for index in 0..<frames {
            highOut.append(split.lowpass(high[index], channel: 0))
        }
        let passed = MusicTestSignal.rms(Array(lowOut[24_000...])) / MusicTestSignal.rms(Array(low[24_000...]))
        let removed = MusicTestSignal.rms(Array(highOut[24_000...])) / MusicTestSignal.rms(Array(high[24_000...]))
        #expect(abs(db(passed)) < 0.2, "50 Hz passes: \(db(passed)) dB")
        #expect(db(removed) < -60, "2 kHz is removed: \(db(removed)) dB")
        // -3 dB at the corner, the Butterworth point.
        split.reset()
        let corner = sine(MusicBassSplit.cutoffHz, amplitude: 0.5, frames: frames)
        var cornerOut: [Float] = []
        for sample in corner { cornerOut.append(split.lowpass(sample, channel: 0)) }
        let atCorner = MusicTestSignal.rms(Array(cornerOut[24_000...])) / MusicTestSignal.rms(Array(corner[24_000...]))
        #expect(abs(db(atCorner) + 3.01) < 0.15, "corner \(db(atCorner)) dB")
    }

    @Test("low + high reconstructs the input within 1e-6, through the split and through the two-band path with b = f = 1")
    func reconstruction() {
        var split = MusicBassSplit(sampleRate: rate)
        let input = noise(frames: 20_000, amplitude: 0.8, seed: 3)
        var worst: Float = 0
        for sample in input {
            let low = split.lowpass(sample, channel: 0)
            let high = sample - low
            worst = max(worst, abs(low + high - sample))
        }
        #expect(worst < 1e-6, "split reconstruction error \(worst)")

        // The same through a lease: a bass ramp that never moves keeps the two-band path in use (it is not steady), and
        // with b = f = 1 the output has to match the plain path.
        let chain = MusicDSPChain(sampleRate: rate)
        let plain = lease(chain)
        let banded = lease(MusicDSPChain(sampleRate: rate))
        banded.beginBass(gain: 1)
        banded.setBass(to: 1, over: 100, after: 0)
        let reference = renderChunked(plain, input)
        let result = renderChunked(banded, input)
        var error: Float = 0
        for (x, y) in zip(reference, result) { error = max(error, abs(x - y)) }
        #expect(error < 1e-6, "two-band path with b = f = 1 differs from the plain path by \(error)")
    }

    @Test("with b equal to f the output is bit-exact with the path before the bass channel existed")
    func bypassIsBitExact() {
        let input = noise(frames: 30_000, amplitude: 0.9, seed: 11)
        for held: Float in [1, 0.5] {
            let plain = lease(MusicDSPChain(sampleRate: rate))
            let banded = lease(MusicDSPChain(sampleRate: rate))
            plain.setFade(to: held)
            banded.setFade(to: held)
            banded.beginBass(gain: held)
            let a = renderChunked(plain, input, chunk: 777)
            let b = renderChunked(banded, input, chunk: 777)
            #expect(a == b, "bit-exact at b = f = \(held)")
        }
    }

    @Test("a bass channel that was begun and ended leaves the lease exactly as it was")
    func endedBassIsInvisible() {
        let input = noise(frames: 20_000, amplitude: 0.9, seed: 5)
        let plain = lease(MusicDSPChain(sampleRate: rate))
        let used = lease(MusicDSPChain(sampleRate: rate))
        used.beginBass(gain: 0)
        used.setBass(to: 1, over: 0.1)
        _ = render(used, [Float](repeating: 0.3, count: 4_800))
        used.endBass()
        _ = render(plain, [Float](repeating: 0.3, count: 4_800))
        #expect(renderChunked(plain, input) == renderChunked(used, input))
    }

    @Test("the split starts from silence at beginBass: no ringing from the audio before it")
    func beginClearsTheFilter() {
        let loud = sine(60, amplitude: 0.9, frames: 9_600)
        let chain = MusicDSPChain(sampleRate: rate)
        let owner = lease(chain)
        owner.beginBass(gain: 1)
        owner.setBass(to: 1, over: 100)
        _ = renderChunked(owner, loud)
        owner.beginBass(gain: 0)
        let silence = renderChunked(owner, [Float](repeating: 0, count: 4_800))
        #expect(MusicTestSignal.peak(silence) < 1e-3, "no ringing after a restart: \(MusicTestSignal.peak(silence))")
    }

    // MARK: - Two leases in a mix

    @Test("identical kick trains on the beat: the mixed peak stays within 2 percent of one deck's")
    func coincidentKicks() {
        let seconds = 16.0
        let frames = Int(seconds * rate)
        let kick = BeatSynth.kickTemplate(sampleRate: rate)
        var train = [Float](repeating: 0, count: frames)
        BeatSynth.mix(kick, into: &train, at: 0, sampleRate: rate, gain: 0.85)
        var time = 0.0
        while time < seconds - 0.25 {
            BeatSynth.mix(kick, into: &train, at: time, sampleRate: rate, gain: 0.85)
            time += 0.5
        }
        let single = MusicTestSignal.peak(renderChunked(lease(MusicDSPChain(sampleRate: rate)), train))
        let result = mix(train, train, overlap: seconds, swapAt: seconds / 2, handover: 1)
        var peak: Float = 0
        var peakAt = 0
        for index in 0..<frames {
            let sum = abs(result.outgoing[index] + result.incoming[index])
            if sum > peak { peak = sum; peakAt = index }
        }
        print("BASSSWAP kicks single=\(single) mixedPeak=\(peak) ratio=\(peak / single) at=\(Double(peakAt) / rate)s")
        #expect(peak <= single * 1.02, "mixed peak \(peak) against a single deck's \(single)")
    }

    @Test("uncorrelated noise holds its loudness through the whole overlap: every 4-bar window within 1 dB")
    func noiseHoldsLoudness() {
        let overlap = 32.0
        let frames = Int(overlap * rate)
        let a = noise(frames: frames, amplitude: 0.3, seed: 1)
        let b = noise(frames: frames, amplitude: 0.3, seed: 99)
        let reference = MusicTestSignal.rms(a)
        let result = mix(a, b, overlap: overlap, swapAt: overlap / 2, handover: 1)
        let sum = zip(result.outgoing, result.incoming).map { $0 + $1 }
        let window = Int(8 * rate)
        var worst: Float = 0
        for start in stride(from: 0, to: frames - window + 1, by: window) {
            let level = db(windowRMS(sum, from: start, length: window) / reference)
            worst = max(worst, abs(level))
            #expect(abs(level) <= 1, "window at \(Double(start) / rate) s: \(level) dB")
        }
        print("BASSSWAP noise worst window deviation \(worst) dB")
    }

    @Test("two loud correlated signals never sum above 1.0 + 1e-3 on the mixed bus, bass swap included")
    func mixedBusPeak() {
        let overlap = 8.0
        let frames = Int(overlap * rate)
        for amplitude in [Float(0.99), 1.4] {
            let low = sine(80, amplitude: amplitude * 0.6, frames: frames)
            let mid = sine(220, amplitude: amplitude * 0.4, frames: frames)
            let signal = zip(low, mid).map { $0 + $1 }
            let result = mix(signal, signal, overlap: overlap, swapAt: overlap / 2, handover: 0.5)
            var peak: Float = 0
            for index in 0..<frames { peak = max(peak, abs(result.outgoing[index] + result.incoming[index])) }
            print("BASSSWAP bus peak amplitude \(amplitude): \(peak)")
            #expect(peak <= 1.0 + 1e-3, "mixed peak \(peak) at amplitude \(amplitude)")
            #expect(peak > 0.85, "and the mix is not crushed far under the ceiling: \(peak)")
        }
    }

    @Test("a sine below 100 Hz stays steady across the swap: within 0.5 dB, no step over 1 dB")
    func lowSineSteadyAcrossSwap() {
        let overlap = 16.0
        let frames = Int(overlap * rate)
        let signal = sine(50, amplitude: 0.45, frames: frames)
        let result = mix(signal, signal, overlap: overlap, swapAt: 8, handover: 1)
        let sum = zip(result.outgoing, result.incoming).map { $0 + $1 }
        let window = Int(0.1 * rate)
        var levels: [Float] = []
        var start = Int(6.5 * rate)
        while start + window <= Int(10.5 * rate) {
            levels.append(db(windowRMS(sum, from: start, length: window)))
            start += window
        }
        let spread = (levels.max() ?? 0) - (levels.min() ?? 0)
        var largestStep: Float = 0
        for pair in zip(levels, levels.dropFirst()) { largestStep = max(largestStep, abs(pair.1 - pair.0)) }
        print("BASSSWAP low sine spread \(spread) dB, largest step \(largestStep) dB")
        #expect(spread <= 0.5, "level moves by \(spread) dB around the swap")
        #expect(largestStep <= 1, "largest step \(largestStep) dB")
    }

    @Test("the lows hand over on the swap point: before it the outgoing lease carries them, after it the incoming one")
    func lowsChangeDeckAtTheSwap() {
        let overlap = 16.0
        let frames = Int(overlap * rate)
        let signal = sine(10, amplitude: 0.3, frames: frames)
        let result = mix(signal, signal, overlap: overlap, swapAt: 8, handover: 0.5)
        let window = Int(0.2 * rate)
        // (10 Hz: nearly all low band.) Compare the two decks' content a second either side of the swap.
        let before = Int(7 * rate)
        let after = Int(9.5 * rate)
        let outBefore = windowRMS(result.outgoing, from: before, length: window)
        let inBefore = windowRMS(result.incoming, from: before, length: window)
        let outAfter = windowRMS(result.outgoing, from: after, length: window)
        let inAfter = windowRMS(result.incoming, from: after, length: window)
        #expect(outBefore > inBefore * 2, "before the swap the outgoing deck holds the lows: \(outBefore) vs \(inBefore)")
        #expect(inAfter > outAfter * 2, "after it the incoming deck does: \(inAfter) vs \(outAfter)")
    }

    // MARK: - Rider

    @Test("one band is today's rule, and two bands with b equal to g collapse to it")
    func riderOneBandRegression() {
        for step in 0...100 {
            let g = Float(step) / 100
            let today = g / (g + max(0, 1 - g * g).squareRoot())
            #expect(MusicFade.headroomShare(high: g, low: nil) == today)
            #expect(abs(MusicFade.headroomShare(high: g, low: g) - today) < 1e-6, "g = \(g)")
        }
    }

    @Test("the two leases' shares add to one at every point of a swap, so the pair never sums above the ceiling")
    func ridersShareOneCeiling() {
        for step in 0...100 {
            let angle = Double(step) / 100 * Double.pi / 2
            let gh = Float(cos(angle))
            for bass in stride(from: Float(0), through: 1, by: 0.05) {
                let outgoing = MusicFade.headroomShare(high: gh, low: bass)
                let incoming = MusicFade.headroomShare(high: Float(sin(angle)), low: 1 - bass)
                #expect(abs(outgoing + incoming - 1) < 1e-5, "gh \(gh) bass \(bass): \(outgoing + incoming)")
            }
        }
    }

    @Test("a lease without a bass channel renders the one-band rider unchanged")
    func oneBandRenderUnchanged() {
        let plain = lease(MusicDSPChain(sampleRate: rate))
        plain.setFade(to: 0, over: 2, curve: .equalPower)
        let signal = sine(220, amplitude: 0.9, frames: 96_000)
        let out = renderChunked(plain, signal)
        // The rule: each sample is held to 1/k before the gain, so the output never passes g / k.
        for index in stride(from: 4_000, to: 96_000, by: 997) {
            let g = Float(cos(Double(index + 1) / 96_000 * Double.pi / 2))
            let k = g + max(0, 1 - g * g).squareRoot()
            #expect(abs(out[index]) <= g / k + 0.02, "frame \(index)")
        }
    }
}
