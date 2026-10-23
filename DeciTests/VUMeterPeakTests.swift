// DeciTests/VUMeterPeakTests.swift
// The VU meter holds a peak marker and lets it fall at 30 Hz once the level drops. A meter whose poller has stopped (the
// popup is closed) must drop the marker and cancel the fall at once: a hidden popup has nothing to animate.

import Testing
@testable import Deci

@MainActor
@Suite("VUMeter peak")
struct VUMeterPeakTests {
    // MARK: - A live meter

    @Test("a level above the held peak raises it")
    func raises() {
        #expect(VUMeter.peakStep(level: 0.6, peak: 0.4, isLive: true, isDecaying: false) == .raise(0.6))
        #expect(VUMeter.peakStep(level: 0.6, peak: 0.4, isLive: true, isDecaying: true) == .raise(0.6))
    }

    @Test("a level under the held peak starts a fall when none runs")
    func startsTheFall() {
        #expect(VUMeter.peakStep(level: 0.2, peak: 0.4, isLive: true, isDecaying: false) == .decay)
    }

    @Test("a level under the held peak leaves a fall that already runs")
    func keepsTheFall() {
        #expect(VUMeter.peakStep(level: 0.2, peak: 0.4, isLive: true, isDecaying: true) == .none)
    }

    @Test("a level equal to the peak changes nothing")
    func equalLevel() {
        #expect(VUMeter.peakStep(level: 0.4, peak: 0.4, isLive: true, isDecaying: false) == .none)
        #expect(VUMeter.peakStep(level: 0, peak: 0, isLive: true, isDecaying: false) == .none)
    }

    // MARK: - A stopped meter

    @Test("a stopped meter with a held peak resets it and cancels the fall")
    func stoppedWithPeak() {
        #expect(VUMeter.peakStep(level: 0, peak: 0.4, isLive: false, isDecaying: false) == .reset)
        #expect(VUMeter.peakStep(level: 0, peak: 0.4, isLive: false, isDecaying: true) == .reset)
    }

    @Test("a stopped meter with a fall running and no peak left still cancels the fall")
    func stoppedWithFallOnly() {
        #expect(VUMeter.peakStep(level: 0, peak: 0, isLive: false, isDecaying: true) == .reset)
    }

    @Test("a stopped meter at rest does nothing")
    func stoppedAtRest() {
        #expect(VUMeter.peakStep(level: 0, peak: 0, isLive: false, isDecaying: false) == .none)
    }

    @Test("a stopped meter never starts a fall, whatever level it is given")
    func stoppedNeverFalls() {
        #expect(VUMeter.peakStep(level: 0.9, peak: 0, isLive: false, isDecaying: false) == .none)
        #expect(VUMeter.peakStep(level: 0, peak: 0.9, isLive: false, isDecaying: false) != .decay)
    }
}
