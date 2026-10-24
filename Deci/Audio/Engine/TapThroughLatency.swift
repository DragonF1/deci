// Deci/Audio/Engine/TapThroughLatency.swift
import CoreAudio
import Foundation

/// The math behind a tap's measured through-latency: how long a buffer takes from the moment the tap captured it (the
/// IO proc's input time) to the moment the aggregate hands it to the hardware (the IO proc's output time). Pure and
/// allocation free, so the IO thread can call it. The Chrome extension adds the figure to the output's latency when it
/// lines Chrome's outputs up, because Chrome cannot see what Deci's tap adds.
nonisolated enum TapThroughLatency {
    /// The most a sample may claim. A larger gap is a bad timestamp pair, not a real delay.
    static let maxSeconds: Double = 0.5

    /// How far each new sample moves the smoothed value. 0.2 settles in about 20 IO cycles and rides out one outlier.
    static let smoothing: Double = 0.2

    /// The seconds between two host times, `scale` being the nanoseconds per host tick. nil when the output time is
    /// before the input time, the scale is not usable, or the gap is outside 0...`maxSeconds`.
    static func seconds(inputHost: UInt64, outputHost: UInt64, scale: Double) -> Double? {
        guard outputHost >= inputHost, scale.isFinite, scale > 0 else { return nil }
        let seconds = Double(outputHost - inputHost) * scale / 1_000_000_000.0
        guard seconds.isFinite, seconds >= 0, seconds <= maxSeconds else { return nil }
        return seconds
    }

    /// Same, from the two time stamps an IO proc gets. nil unless both carry a valid host time.
    static func seconds(input: AudioTimeStamp, output: AudioTimeStamp, scale: Double) -> Double? {
        guard input.mFlags.contains(.hostTimeValid), output.mFlags.contains(.hostTimeValid) else { return nil }
        return seconds(inputHost: input.mHostTime, outputHost: output.mHostTime, scale: scale)
    }

    /// The running value after one more sample: an exponential moving average. With nothing before it (0) the first
    /// sample is taken as it is. A sample that is negative or not finite changes nothing.
    static func smoothed(previous: Double, sample: Double) -> Double {
        guard sample.isFinite, sample >= 0 else { return previous }
        guard previous > 0 else { return sample }
        return previous + smoothing * (sample - previous)
    }
}
