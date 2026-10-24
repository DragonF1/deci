// DeciTests/TapThroughLatencyTests.swift
//
// TapThroughLatency is the pure math behind the tap's measured through-latency: how long a buffer takes from the
// moment the tap captured it (the IO proc's input time) to the moment the aggregate hands it to the hardware (the
// IO proc's output time). The IO proc itself is never run here: no process tap is created and nothing plays.

import AudioToolbox
import Foundation
import Testing
@testable import Deci

@Suite("TapThroughLatency")
struct TapThroughLatencyTests {
    /// Apple silicon's mach timebase is 125/3 ns per tick; Intel's is 1.
    private let appleSiliconScale = 125.0 / 3.0

    private func closeTo(_ value: Double?, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    private func stamp(host: UInt64?) -> AudioTimeStamp {
        var stamp = AudioTimeStamp()
        if let host {
            stamp.mHostTime = host
            stamp.mFlags = .hostTimeValid
        }
        return stamp
    }

    // MARK: Conversion

    @Test("host ticks convert to seconds with the timebase scale (1:1 scale)")
    func conversionUnitScale() {
        // 46 ms is 46,000,000 ticks at one nanosecond per tick.
        let seconds = TapThroughLatency.seconds(inputHost: 1_000, outputHost: 1_000 + 46_000_000, scale: 1.0)
        #expect(closeTo(seconds, 0.046))
    }

    @Test("host ticks convert to seconds with the Apple silicon scale")
    func conversionAppleSiliconScale() {
        // 1,104,000 ticks * 125/3 ns = 46,000,000 ns.
        let seconds = TapThroughLatency.seconds(inputHost: 5_000_000_000, outputHost: 5_000_000_000 + 1_104_000, scale: appleSiliconScale)
        #expect(closeTo(seconds, 0.046))
    }

    @Test("equal timestamps are a valid zero")
    func equalTimestamps() {
        #expect(TapThroughLatency.seconds(inputHost: 777, outputHost: 777, scale: 1.0) == 0)
    }

    // MARK: Invalid ranges

    @Test("an output time before the input time is rejected, not wrapped around")
    func outputBeforeInput() {
        #expect(TapThroughLatency.seconds(inputHost: 2_000_000, outputHost: 1_000_000, scale: 1.0) == nil)
        #expect(TapThroughLatency.seconds(inputHost: UInt64.max, outputHost: 0, scale: 1.0) == nil)
    }

    @Test("0.5 s is the largest value accepted")
    func upperBoundary() {
        #expect(closeTo(TapThroughLatency.seconds(inputHost: 0, outputHost: 500_000_000, scale: 1.0), 0.5))
        #expect(TapThroughLatency.seconds(inputHost: 0, outputHost: 500_000_001, scale: 1.0) == nil)
        #expect(TapThroughLatency.seconds(inputHost: 0, outputHost: 3_000_000_000, scale: 1.0) == nil)
    }

    @Test("a timebase scale that is zero, negative or not finite is rejected")
    func invalidScale() {
        #expect(TapThroughLatency.seconds(inputHost: 0, outputHost: 1_000_000, scale: 0) == nil)
        #expect(TapThroughLatency.seconds(inputHost: 0, outputHost: 1_000_000, scale: -1) == nil)
        #expect(TapThroughLatency.seconds(inputHost: 0, outputHost: 1_000_000, scale: .nan) == nil)
        #expect(TapThroughLatency.seconds(inputHost: 0, outputHost: 1_000_000, scale: .infinity) == nil)
    }

    @Test("an enormous tick gap is rejected instead of overflowing")
    func hugeGap() {
        #expect(TapThroughLatency.seconds(inputHost: 0, outputHost: UInt64.max, scale: 1e300) == nil)
    }

    // MARK: Timestamps

    @Test("two timestamps with valid host times give the difference")
    func validStamps() {
        let seconds = TapThroughLatency.seconds(input: stamp(host: 10_000), output: stamp(host: 10_000 + 20_000_000), scale: 1.0)
        #expect(closeTo(seconds, 0.020))
    }

    @Test("a timestamp without the host-time flag is rejected, whichever one lacks it")
    func missingHostTimeFlag() {
        #expect(TapThroughLatency.seconds(input: stamp(host: nil), output: stamp(host: 20_000_000), scale: 1.0) == nil)
        #expect(TapThroughLatency.seconds(input: stamp(host: 10_000), output: stamp(host: nil), scale: 1.0) == nil)
        #expect(TapThroughLatency.seconds(input: stamp(host: nil), output: stamp(host: nil), scale: 1.0) == nil)
    }

    @Test("a flagged timestamp whose host time is zero still converts; the flag is what is trusted")
    func zeroHostTimeWithFlag() {
        let seconds = TapThroughLatency.seconds(input: stamp(host: 0), output: stamp(host: 30_000_000), scale: 1.0)
        #expect(closeTo(seconds, 0.030))
    }

    // MARK: Smoothing

    @Test("the first sample, with nothing before it, is taken as it is")
    func firstSample() {
        #expect(TapThroughLatency.smoothed(previous: 0, sample: 0.05) == 0.05)
    }

    @Test("later samples move the value a fifth of the way")
    func emaStep() {
        let next = TapThroughLatency.smoothed(previous: 0.05, sample: 0.10)
        #expect(closeTo(next, 0.06))
        let down = TapThroughLatency.smoothed(previous: 0.10, sample: 0.05)
        #expect(closeTo(down, 0.09))
    }

    @Test("a steady sample leaves the value where it is")
    func emaSteady() {
        #expect(closeTo(TapThroughLatency.smoothed(previous: 0.046, sample: 0.046), 0.046))
    }

    @Test("repeated samples converge on the sample")
    func emaConverges() {
        var value = 0.0
        for _ in 0..<200 { value = TapThroughLatency.smoothed(previous: value, sample: 0.046) }
        #expect(closeTo(value, 0.046, tolerance: 1e-6))
    }

    @Test("a single outlier moves the smoothed value by a fifth of the jump only")
    func emaOutlier() {
        let settled = 0.046
        let after = TapThroughLatency.smoothed(previous: settled, sample: 0.5)
        #expect(closeTo(after, settled + 0.2 * (0.5 - settled)))
    }

    @Test("a sample that is not finite or negative leaves the value alone")
    func emaIgnoresBadSamples() {
        #expect(TapThroughLatency.smoothed(previous: 0.046, sample: .nan) == 0.046)
        #expect(TapThroughLatency.smoothed(previous: 0.046, sample: .infinity) == 0.046)
        #expect(TapThroughLatency.smoothed(previous: 0.046, sample: -0.01) == 0.046)
        #expect(TapThroughLatency.smoothed(previous: 0, sample: .nan) == 0)
    }

    // MARK: Readings

    @Test("TapHealthReadings carries the through-latency, 0 until one is measured")
    func readingsDefault() {
        let readings = TapHealthReadings(
            isSwitching: false,
            secondsSinceTapStart: 1,
            inputSignalSeen: true,
            secondsSinceInputSignal: 0,
            secondsSinceDiscontinuity: .infinity,
            discontinuityCount: 0,
            secondsSinceHealthyOutput: 0
        )
        #expect(readings.tapThroughSeconds == 0)
        var measured = readings
        measured.tapThroughSeconds = 0.046
        #expect(measured != readings)
    }
}
