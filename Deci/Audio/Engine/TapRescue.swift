// Deci/Audio/Engine/TapRescue.swift
import Foundation

/// What a promoted rescue observed, for the engine's `[RESCUE]` line.
struct TapRescueReport: Equatable {
    /// Seconds from the candidate tap starting to its first buffer holding signal.
    var candidateSignalLatency: Double
}

/// Decides, from the two taps' last-signal stamps, whether a rescue's candidate tap proved the
/// primary dead. A tap that is stuck reads exact zeros while the app plays; a fresh tap of the
/// same process hears the app at once. So the candidate must hear signal within `window` while
/// the primary stays at exact zero. Pure value type: the controller feeds it host ticks.
struct TapRescueVerifier: Equatable {
    /// How long the candidate has to hear signal. Longer than a candidate's first callbacks
    /// (tens of ms), short enough that a silent app costs one brief probe.
    static let window: Double = 0.5
    /// After the candidate passes, the controller waits this long and checks the primary again,
    /// so a pause that ends mid-verify (both taps hear it) is not mistaken for a dead primary.
    static let primaryRecheckDelay: Duration = .milliseconds(30)

    enum Verdict: Equatable {
        case waiting
        /// The candidate heard signal `latency` seconds after it started.
        case candidateHeard(latency: Double)
        case primaryRecovered
        case candidateSilent
    }

    /// The primary's `_lastInputSignalHostTime` when the rescue began (0 = none yet).
    let primarySignalAtStart: UInt64
    let candidateStartHostTime: UInt64
    let nanosPerTick: Double

    init(primarySignalAtStart: UInt64, candidateStartHostTime: UInt64, nanosPerTick: Double = ZeroRunClock.nanosPerTick) {
        self.primarySignalAtStart = primarySignalAtStart
        self.candidateStartHostTime = candidateStartHostTime
        self.nanosPerTick = nanosPerTick
    }

    /// A buffer with signal reached the primary after the rescue began.
    func primaryRecovered(primarySignal: UInt64) -> Bool {
        primarySignal > primarySignalAtStart
    }

    /// `candidateSignal` is 0 until the candidate hears something. The primary is judged first:
    /// a primary that heard signal is not stuck, whatever the candidate heard.
    func verdict(primarySignal: UInt64, candidateSignal: UInt64, now: UInt64) -> Verdict {
        if primaryRecovered(primarySignal: primarySignal) { return .primaryRecovered }
        if candidateSignal != 0 {
            let ticks = candidateSignal > candidateStartHostTime ? candidateSignal - candidateStartHostTime : 0
            return .candidateHeard(latency: Double(ticks) * nanosPerTick / 1e9)
        }
        let elapsed = now > candidateStartHostTime ? Double(now - candidateStartHostTime) * nanosPerTick / 1e9 : 0
        return elapsed > Self.window ? .candidateSilent : .waiting
    }
}

/// One `[RESCUE]` line: the outcome of a rescue and everything needed to read it later.
struct TapRescueLogEntry: Equatable {
    enum Outcome: Equatable {
        case promoted(candidateLatency: Double)
        case candidateSilent
        case primaryRecovered
        case failed(String)
    }

    enum Level: Equatable {
        case notice, info, error
    }

    let appName: String
    let pid: Int32
    let outcome: Outcome
    /// The ladder rung the rescue ran on (0 = the 0.25 s one).
    let rung: Int
    let readings: TapHealthReadings
    let tapSourceDeviceUID: String?
    let devices: [String]

    /// Promotions and errors always matter. An inconclusive probe is a notice for the first
    /// rungs of an episode, then info: the steady 20 s probes of a long pause would flood the log.
    var level: Level {
        switch outcome {
        case .promoted: return .notice
        case .failed: return .error
        case .candidateSilent, .primaryRecovered: return rung < TapWatchdog.rescueThresholds.count ? .notice : .info
        }
    }

    /// The line body, without the `[RESCUE]` prefix the engine adds.
    var line: String {
        let name: String
        var suffix = ""
        switch outcome {
        case .promoted(let latency):
            name = "promoted"
            suffix = " candidate=\(String(format: "%.3f", latency))s"
        case .candidateSilent:
            name = "candidate-silent"
        case .primaryRecovered:
            name = "primary-recovered"
        case .failed(let reason):
            name = "failed"
            suffix = " error=\(reason)"
        }
        let source = readings.tapIsStream ? "stream:\(tapSourceDeviceUID ?? "?")" : "mixdown"
        let drift = readings.tapDriftCompensation ? "on" : "off"
        return "\(name) \(appName) (PID \(pid)) rung=\(rung) "
            + "silence=\(String(format: "%.2f", readings.secondsSinceInputSignal))s "
            + "age=\(String(format: "%.2f", readings.secondsSinceTapStart))s "
            + "src=\(source) drift=\(drift) devices=[\(devices.joined(separator: ","))]\(suffix)"
    }
}
