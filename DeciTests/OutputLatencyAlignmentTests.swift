// DeciTests/OutputLatencyAlignmentTests.swift
//
// Tests OutputLatencyAlignment, which works out how many extra frames of output latency each sub-device of a stacked
// aggregate needs so that every device sounds at the same moment. The HAL adds no compensation between sub-devices by
// itself, so two Bluetooth headsets with different link delays play out of step. The helper is pure: the readings come
// in as values and no Core Audio is touched.

import Testing
@testable import Deci

/// A reader that answers from a table; a device that is not in it cannot be read.
nonisolated struct FakeOutputLatencyReader: OutputLatencyReading {
    var table: [String: OutputLatency]

    func outputLatency(deviceUID: String) -> OutputLatency? { table[deviceUID] }
}

@Suite("Output latency alignment")
struct OutputLatencyAlignmentTests {
    /// The pair from the owner's setup, at 44.1 kHz: 203.2 ms and 235.2 ms.
    private let xm5 = OutputLatency(frames: 8961, sampleRate: 44_100)
    private let buds = OutputLatency(frames: 10_373, sampleRate: 44_100)

    private func extra(_ table: [String: OutputLatency], for uids: [String]) -> [String: UInt32] {
        OutputLatencyAlignment.extraFrames(for: uids) { table[$0] }
    }

    // MARK: Extra frames

    @Test("the faster headset is delayed by the difference and the slowest gets none")
    func pairFromTheOwnersSetup() {
        let result = extra(["xm5": xm5, "buds": buds], for: ["xm5", "buds"])
        #expect(result == ["xm5": 1412, "buds": 0])
    }

    @Test("the order of the devices does not change the answer")
    func orderDoesNotMatter() {
        let table = ["xm5": xm5, "buds": buds]
        #expect(extra(table, for: ["buds", "xm5"]) == extra(table, for: ["xm5", "buds"]))
    }

    @Test("equal latencies need nothing")
    func equalLatenciesGiveZeros() {
        let same = OutputLatency(frames: 8961, sampleRate: 44_100)
        #expect(extra(["a": same, "b": same], for: ["a", "b"]) == ["a": 0, "b": 0])
    }

    @Test("with three devices each is delayed up to the slowest")
    func threeDevices() {
        let table = [
            "a": OutputLatency(frames: 4410, sampleRate: 44_100),
            "b": OutputLatency(frames: 8820, sampleRate: 44_100),
            "c": OutputLatency(frames: 13_230, sampleRate: 44_100)
        ]
        #expect(extra(table, for: ["a", "b", "c"]) == ["a": 8820, "b": 4410, "c": 0])
    }

    @Test("a device that is the only one has nothing to line up with")
    func singleDevice() {
        #expect(extra(["solo": xm5], for: ["solo"]) == ["solo": 0])
        #expect(extra([:], for: ["solo"]) == ["solo": 0], "even when it cannot be read")
        #expect(extra([:], for: []).isEmpty)
    }

    @Test("a device named twice is one entry and does not trap")
    func duplicateUIDs() {
        #expect(extra(["a": xm5], for: ["a", "a"]) == ["a": 0])
    }

    // MARK: Sample rates

    @Test("the frames are counted at the clock's rate: a 44.1 kHz device behind a 48 kHz clock")
    func mixedRatesFastDeviceOn441() {
        let table = [
            "slow48": OutputLatency(frames: 9600, sampleRate: 48_000),   // 0.2 s
            "fast441": OutputLatency(frames: 4410, sampleRate: 44_100)   // 0.1 s
        ]
        #expect(extra(table, for: ["slow48", "fast441"]) == ["slow48": 0, "fast441": 4800])
    }

    @Test("the frames are counted at the clock's rate: a 48 kHz device ahead of a 44.1 kHz clock")
    func mixedRatesFastDeviceOn48() {
        let table = [
            "slow441": OutputLatency(frames: 8820, sampleRate: 44_100),  // 0.2 s
            "fast48": OutputLatency(frames: 4800, sampleRate: 48_000)    // 0.1 s
        ]
        #expect(extra(table, for: ["slow441", "fast48"]) == ["slow441": 0, "fast48": 4410])
    }

    @Test("the same delay in seconds at two rates needs nothing")
    func sameSecondsAtTwoRates() {
        let table = [
            "a": OutputLatency(frames: 4800, sampleRate: 48_000),
            "b": OutputLatency(frames: 4410, sampleRate: 44_100)
        ]
        #expect(extra(table, for: ["a", "b"]) == ["a": 0, "b": 0])
    }

    @Test("a gap that is not a whole number of frames is rounded to the nearest")
    func roundsToTheNearestFrame() {
        let table = [
            "slow": OutputLatency(frames: 4801, sampleRate: 48_000),     // 100.0208 ms
            "fast": OutputLatency(frames: 100, sampleRate: 44_100)       // 2.2676 ms
        ]
        // Clock "fast" at 44.1 kHz: (4801 / 48000 - 100 / 44100) * 44100 = 4410.92 - 100 = 4310.92, which
        // truncation would make 4310.
        #expect(extra(table, for: ["fast", "slow"]) == ["slow": 0, "fast": 4311])
    }

    // MARK: Readings that cannot be trusted

    @Test("a missing reading gives zeros for every device, not just the one that is missing")
    func missingReading() {
        #expect(extra(["xm5": xm5], for: ["xm5", "buds"]) == ["xm5": 0, "buds": 0], "the slow one is missing")
        #expect(extra(["buds": buds], for: ["xm5", "buds"]) == ["xm5": 0, "buds": 0], "the fast one is missing")
        #expect(extra([:], for: ["xm5", "buds"]) == ["xm5": 0, "buds": 0])
    }

    @Test("a reading with no usable sample rate counts as missing")
    func unusableRate() {
        let zeroRate = OutputLatency(frames: 100, sampleRate: 0)
        let nanRate = OutputLatency(frames: 100, sampleRate: .nan)
        #expect(extra(["xm5": xm5, "buds": zeroRate], for: ["xm5", "buds"]) == ["xm5": 0, "buds": 0])
        #expect(extra(["xm5": xm5, "buds": nanRate], for: ["xm5", "buds"]) == ["xm5": 0, "buds": 0])
    }

    @Test("a spread of exactly one second is still lined up")
    func spreadOfOneSecond() {
        let table = [
            "slow": OutputLatency(frames: 44_100, sampleRate: 44_100),
            "fast": OutputLatency(frames: 0, sampleRate: 44_100)
        ]
        #expect(extra(table, for: ["slow", "fast"]) == ["slow": 0, "fast": 44_100])
    }

    @Test("a spread over one second is a bad reading, so nothing is delayed")
    func spreadOverOneSecond() {
        let table = [
            "slow": OutputLatency(frames: 44_101, sampleRate: 44_100),
            "fast": OutputLatency(frames: 0, sampleRate: 44_100)
        ]
        #expect(extra(table, for: ["slow", "fast"]) == ["slow": 0, "fast": 0])
    }

    @Test("one outlier over a second off spoils the whole set")
    func outlierSpoilsTheSet() {
        let table = [
            "a": OutputLatency(frames: 4410, sampleRate: 44_100),
            "b": OutputLatency(frames: 8820, sampleRate: 44_100),
            "c": OutputLatency(frames: 100_000, sampleRate: 44_100)
        ]
        #expect(extra(table, for: ["a", "b", "c"]) == ["a": 0, "b": 0, "c": 0])
    }

    // MARK: The total

    @Test("the total is the device latency, the safety offset and the first stream's latency")
    func totalAddsThreeParts() throws {
        let total = try #require(OutputLatency.total(device: 6000, safetyOffset: 11, stream: 2950, sampleRate: 44_100))
        #expect(total == OutputLatency(frames: 8961, sampleRate: 44_100))
    }

    @Test("a total that does not fit in 32 bits or has no usable rate is not a reading")
    func totalRejectsGarbage() {
        #expect(OutputLatency.total(device: .max, safetyOffset: 1, stream: 0, sampleRate: 44_100) == nil)
        #expect(OutputLatency.total(device: 1, safetyOffset: 1, stream: 1, sampleRate: 0) == nil)
        #expect(OutputLatency.total(device: 1, safetyOffset: 1, stream: 1, sampleRate: -44_100) == nil)
        #expect(OutputLatency.total(device: 1, safetyOffset: 1, stream: 1, sampleRate: .infinity) == nil)
        #expect(OutputLatency.total(device: 1, safetyOffset: 1, stream: 1, sampleRate: .nan) == nil)
    }

    @Test("a latency in seconds follows from its frames and rate")
    func seconds() {
        #expect(abs(xm5.seconds - 0.2032) < 0.0001)
        #expect(abs(buds.seconds - 0.2352) < 0.0001)
    }

    // MARK: Reading and logging

    @Test("align reads each device through the reader and names the extra frames in the log line")
    func alignWithAReader() {
        let reader = FakeOutputLatencyReader(table: ["xm5": xm5, "buds": buds])
        let result = OutputLatencyAlignment.align(["xm5", "buds"], using: reader)
        #expect(result.extraFrames == ["xm5": 1412, "buds": 0])
        #expect(result.summary == "xm5 203.2 ms +1412 frames, buds 235.2 ms +0 frames")
    }

    @Test("align says which device could not be read, and delays none")
    func alignWithAnUnreadableDevice() {
        let reader = FakeOutputLatencyReader(table: ["xm5": xm5])
        let result = OutputLatencyAlignment.align(["xm5", "buds"], using: reader)
        #expect(result.extraFrames == ["xm5": 0, "buds": 0])
        #expect(result.summary == "xm5 203.2 ms +0 frames, buds unreadable")
    }
}
