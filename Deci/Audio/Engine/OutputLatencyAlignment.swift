// Deci/Audio/Engine/OutputLatencyAlignment.swift
import AudioToolbox
import Foundation

/// How long a frame takes to reach the sound at a device's output: its device latency, safety offset and first
/// stream's latency, as frames at the device's own rate.
nonisolated struct OutputLatency: Equatable {
    var frames: UInt32
    var sampleRate: Float64

    /// Whether the rate can turn the frames into time.
    var isUsable: Bool { sampleRate > 0 && sampleRate.isFinite }

    var seconds: Double { Double(frames) / sampleRate }

    /// The sum of the three parts. nil when it does not fit in 32 bits or the rate is not a usable one.
    static func total(device: UInt32, safetyOffset: UInt32, stream: UInt32, sampleRate: Float64) -> OutputLatency? {
        let sum = UInt64(device) + UInt64(safetyOffset) + UInt64(stream)
        guard sum <= UInt64(UInt32.max) else { return nil }
        let latency = OutputLatency(frames: UInt32(sum), sampleRate: sampleRate)
        return latency.isUsable ? latency : nil
    }
}

/// Reads a device's output latency. A protocol so the alignment can be tested without Core Audio.
nonisolated protocol OutputLatencyReading {
    /// nil when any of the device's latency properties could not be read.
    func outputLatency(deviceUID: String) -> OutputLatency?
}

/// Reads the latency of a real device, found by its UID.
nonisolated struct CoreAudioOutputLatencyReader: OutputLatencyReading {
    func outputLatency(deviceUID: String) -> OutputLatency? {
        guard let ids = try? AudioObjectID.readDeviceList(),
              let device = ids.first(where: { (try? $0.readDeviceUID()) == deviceUID }) else { return nil }
        return device.readOutputLatency()
    }
}

/// Works out the extra output latency each sub-device of a stacked aggregate needs so that all of them sound together.
/// The HAL adds no compensation between sub-devices, so with no help a device with a longer link delay (two Bluetooth
/// headsets, say) trails the other by the difference.
nonisolated enum OutputLatencyAlignment {
    /// A set of devices whose latencies are further apart than this is taken as a bad reading, not a real gap.
    static let maxSpread: TimeInterval = 1.0

    struct Result: Equatable {
        let extraFrames: [String: UInt32]
        /// One line for the log: each device's latency in ms and the frames added to it.
        let summary: String
    }

    /// The frames each device is delayed by: the gap to the slowest device, which gets none. Counted at the first
    /// device's rate, since that device is the aggregate's clock and every sub-device runs at the aggregate's rate.
    /// Every device is in the answer. All of them get 0 when any reading is missing or unusable, or the readings are
    /// more than `maxSpread` apart: delaying on a guess would do more harm than the lag.
    static func extraFrames(for uids: [String], latency: (String) -> OutputLatency?) -> [String: UInt32] {
        let none = Dictionary(uids.map { ($0, UInt32(0)) }, uniquingKeysWith: { first, _ in first })
        var readings: [String: OutputLatency] = [:]
        for uid in uids {
            guard let reading = latency(uid), reading.isUsable else { return none }
            readings[uid] = reading
        }
        let seconds = readings.values.map(\.seconds)
        guard let slowest = seconds.max(), let fastest = seconds.min(), slowest - fastest <= maxSpread,
              let clockRate = uids.first.flatMap({ readings[$0]?.sampleRate }) else {
            return none
        }
        return readings.mapValues { UInt32(((slowest - $0.seconds) * clockRate).rounded()) }
    }

    /// The log line: each device with its latency in ms and the frames it is given, or that it could not be read.
    static func summary(for uids: [String], latency: (String) -> OutputLatency?, extraFrames: [String: UInt32]) -> String {
        uids.map { uid in
            guard let reading = latency(uid), reading.isUsable else { return "\(uid) unreadable" }
            let milliseconds = String(format: "%.1f", reading.seconds * 1000)
            return "\(uid) \(milliseconds) ms +\(extraFrames[uid] ?? 0) frames"
        }.joined(separator: ", ")
    }

    /// Reads every device once and works out what each is given.
    static func align(_ uids: [String], using reader: any OutputLatencyReading) -> Result {
        var readings: [String: OutputLatency] = [:]
        for uid in uids {
            readings[uid] = reader.outputLatency(deviceUID: uid)
        }
        let extra = extraFrames(for: uids) { readings[$0] }
        return Result(extraFrames: extra, summary: summary(for: uids, latency: { readings[$0] }, extraFrames: extra))
    }
}

/// The sub-device entries of an aggregate description.
nonisolated enum AggregateSubDeviceList {
    /// The first device is the clock and needs no drift compensation; every other one is kept in step with it. With a
    /// table, every entry also carries its extra output latency, 0 for a device that is not in it; with nil the entries
    /// have no latency key at all.
    static func entries(uids: [String], extraOutputLatencyFrames: [String: UInt32]?) -> [[String: Any]] {
        uids.enumerated().map { index, uid in
            var entry: [String: Any] = [
                kAudioSubDeviceUIDKey: uid,
                kAudioSubDeviceDriftCompensationKey: index > 0
            ]
            if let extra = extraOutputLatencyFrames {
                entry[kAudioSubDeviceExtraOutputLatencyKey] = extra[uid] ?? 0
            }
            return entry
        }
    }
}
