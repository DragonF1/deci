// Deci/Audio/Engine/DebugSoakConfig.swift
//
// Debug-only environment flags for the automated tap soak (see TapWatchdog's ZeroRunTracker).
// - `DECI_DEBUG_TAP_SOURCE=mixdown` builds every tap as the stereo mixdown, across device
//   switches too; any other value is a device UID to stream-tap, as a follows-default app gets.
// - `DECI_DEBUG_TAP_DRIFT=on|off` overrides the drift-compensation decision for every tap.
// - `DECI_DEBUG_REFRESH_S=<seconds>` overrides the process monitor's 10 s periodic refresh.
// - `DECI_DEBUG_ZERO_LOG=1` logs each zero run of 100 ms or more as `[ZERORUN]` (notice level).

#if DEBUG
import Foundation

struct DebugSoakConfig: Equatable {
    static let current = DebugSoakConfig(environment: ProcessInfo.processInfo.environment)

    private let tapSource: String?
    let driftOverride: Bool?
    let refreshSeconds: Double?
    let zeroLog: Bool

    init(environment: [String: String]) {
        tapSource = environment["DECI_DEBUG_TAP_SOURCE"]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        switch environment["DECI_DEBUG_TAP_DRIFT"] {
        case "on": driftOverride = true
        case "off": driftOverride = false
        default: driftOverride = nil
        }
        refreshSeconds = environment["DECI_DEBUG_REFRESH_S"].flatMap(Double.init).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        zeroLog = environment["DECI_DEBUG_ZERO_LOG"] == "1"
    }

    var forceMixdown: Bool { tapSource?.lowercased() == "mixdown" }

    /// The device UID of a forced stream tap; nil for `mixdown` or when unset.
    var forcedStreamTapSource: String? { forceMixdown ? nil : tapSource }

    /// The `[SOAK]` log line body.
    var summary: String {
        let drift = driftOverride.map { $0 ? "on" : "off" } ?? "auto"
        let refresh = refreshSeconds.map { String(format: "%gs", $0) } ?? "10s(default)"
        return "tapSource=\(tapSource ?? "default") drift=\(drift) refresh=\(refresh) zeroLog=\(zeroLog ? "on" : "off")"
    }
}
#endif
