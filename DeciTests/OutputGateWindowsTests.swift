// DeciTests/OutputGateWindowsTests.swift
//
// Pure-value tests for OutputGateWindows: the sample-count windows the output gate
// uses, derived from the device rate. Re-derived whenever the rate changes outside
// activate() (BT A2DP<->SCO switch, crossfade promotion).

import Testing
import Foundation
@testable import Deci

@Suite("OutputGateWindows: rate to sample counts")
struct OutputGateWindowsTests {

    @Test("48 kHz: 40 ms ramp is 1920 samples, 200 ms hold is 9600 samples")
    func at48k() {
        let w = OutputGateWindows(sampleRate: 48_000)
        #expect(w.rampSamples == 1920)
        #expect(w.silenceHoldSamples == 9600)
    }

    @Test("44.1 kHz")
    func at44k() {
        let w = OutputGateWindows(sampleRate: 44_100)
        #expect(abs(w.rampSamples - 1764) < 0.01)
        #expect(w.silenceHoldSamples == 8820)
    }

    @Test("16 kHz (BT SCO wideband): windows shrink with the rate")
    func atSCOWideband() {
        let w = OutputGateWindows(sampleRate: 16_000)
        #expect(abs(w.rampSamples - 640) < 0.01)
        #expect(w.silenceHoldSamples == 3200)
    }

    @Test("8 kHz (BT SCO narrowband)")
    func atSCONarrowband() {
        let w = OutputGateWindows(sampleRate: 8_000)
        #expect(abs(w.rampSamples - 320) < 0.01)
        #expect(w.silenceHoldSamples == 1600)
    }

    @Test("Same wall-clock duration at every rate")
    func durationIsRateIndependent() {
        for rate in [8_000.0, 16_000, 44_100, 48_000, 96_000, 192_000] {
            let w = OutputGateWindows(sampleRate: rate)
            #expect(abs(Double(w.rampSamples) / rate - 0.040) < 1e-4)
            #expect(abs(Double(w.silenceHoldSamples) / rate - 0.200) < 1e-3)
        }
    }

    @Test("A 48 kHz window left in place after a drop to 16 kHz would be 3x too long (why re-rating matters)")
    func staleWindowWouldBeWrong() {
        let stale = OutputGateWindows(sampleRate: 48_000)
        let fresh = OutputGateWindows(sampleRate: 16_000)
        #expect(stale.silenceHoldSamples == fresh.silenceHoldSamples * 3)
    }

    @Test("Zero, negative, NaN and infinite rates fall back to 48 kHz")
    func invalidRatesFallBack() {
        let reference = OutputGateWindows(sampleRate: 48_000)
        for bad in [0.0, -44_100, .nan, .infinity, -.infinity] {
            #expect(OutputGateWindows(sampleRate: bad) == reference)
        }
    }

    @Test("Absurdly high rates do not overflow the Int32 hold window")
    func hugeRateDoesNotOverflow() {
        let w = OutputGateWindows(sampleRate: 1e12)
        #expect(w.silenceHoldSamples == Int32.max)
        #expect(w.rampSamples.isFinite)
    }
}
