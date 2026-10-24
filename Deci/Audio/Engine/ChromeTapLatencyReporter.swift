// Deci/Audio/Engine/ChromeTapLatencyReporter.swift
import Foundation

/// Decides what the engine tells the Chrome extension about Deci's own tap of Chrome.
///
/// Chrome Multi plays a tab to several outputs and lines the chains up by the latency Chrome reports for each. When
/// Chrome follows the default output, Deci's stream tap captures that output and plays it again through its aggregate,
/// which adds a delay Chrome cannot see (the other outputs are direct). The engine measures that delay per tapped
/// device (`TapHealthReadings.tapThroughSeconds`) and this type turns the readings into messages: a map from each tapped
/// output device UID to the seconds, sent only when it changed enough to matter, and an empty map, once, when the
/// measurement stops applying. Pure, so it can be tested without Core Audio.
struct ChromeTapLatencyReporter {
    /// One live tap as the engine sees it at a poll.
    struct Observation {
        var bundleID: String?
        /// The output devices the tap plays on.
        var deviceUIDs: [String]
        /// Nil for a tap that has not rendered yet.
        var readings: TapHealthReadings?
    }

    /// A value must move by more than this from the last one sent to be sent again. The extension re-aligns its
    /// outputs on each change, so a smoothed reading's jitter must not cause one.
    static let changeThreshold: Double = 0.005

    /// Whether `bundleID` is Chrome, the only app whose tap the extension needs to hear about.
    static func isChrome(_ bundleID: String?) -> Bool {
        bundleID == ChromeExtensionInstaller.chromeBundleID
    }

    /// What was last handed out; empty when nothing is in force at the extension.
    private(set) var lastEmitted: [String: Double] = [:]

    /// The map to send for these taps, or nil when nothing needs sending. Only Chrome's stream taps with a positive,
    /// finite measurement count; each of their output devices maps to the seconds (the larger one when two taps share a
    /// device). A map goes out when the set of devices differs from the last one sent or any value moved by more than
    /// `changeThreshold` from it. An empty map goes out once when there was something in force and now is nothing: the
    /// Chrome tap is gone, turned into a mixdown, has no readings, or reads 0.
    mutating func next(readings observations: [Observation]) -> [String: Double]? {
        var current: [String: Double] = [:]
        for observation in observations where Self.isChrome(observation.bundleID) {
            guard let readings = observation.readings, readings.tapIsStream else { continue }
            let seconds = readings.tapThroughSeconds
            guard seconds.isFinite, seconds > 0 else { continue }
            for uid in observation.deviceUIDs {
                current[uid] = max(current[uid] ?? 0, seconds)
            }
        }

        if current.isEmpty {
            guard !lastEmitted.isEmpty else { return nil }
            lastEmitted = [:]
            return [:]
        }

        let sameDevices = Set(current.keys) == Set(lastEmitted.keys)
        let moved = current.contains { uid, seconds in
            abs(seconds - (lastEmitted[uid] ?? 0)) > Self.changeThreshold
        }
        guard !sameDevices || moved else { return nil }
        lastEmitted = current
        return current
    }
}
