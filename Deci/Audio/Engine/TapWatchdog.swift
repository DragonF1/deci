// Deci/Audio/Engine/TapWatchdog.swift

/// What a tap's audio callback reports about itself, read on the main thread. Ages are in
/// seconds ("how long ago"); `.infinity` means "never".
struct TapHealthReadings: Equatable {
    /// A crossfade or destructive switch is rebuilding the tap right now.
    var isSwitching: Bool
    /// Since the current tap began delivering (activation, destructive switch or promotion).
    var secondsSinceTapStart: Double
    /// The current tap has delivered at least one non-zero sample.
    var inputSignalSeen: Bool
    /// Since the last buffer holding any non-zero sample, or since tap start when none yet.
    var secondsSinceInputSignal: Double
    /// Since the input timeline last jumped (a skipped IO cycle, as an overload causes).
    var secondsSinceDiscontinuity: Double
    var discontinuityCount: UInt32
    /// Since the last buffer that was not "live input in, silence out".
    var secondsSinceHealthyOutput: Double
}

/// One health-monitor tick for one tap: its readings plus what the engine knows.
struct TapHealthSample: Equatable {
    var readings: TapHealthReadings
    /// The tapped process is running output IO (HAL `IsRunningOutput`).
    var appIsPlaying: Bool
    var isUserMuted: Bool
}

enum TapWatchdogReason: String, Equatable {
    /// The tap went digitally silent after an IO overload and never came back.
    case silentAfterOverload
    /// A fresh or just-switched tap delivered nothing while the app played.
    case silentAfterTapStart
    /// Long digital silence while the app kept its output running.
    case longSilence
    /// Live input, but the processing chain wrote silence.
    case outputSilent
}

/// Decides when a tap is stuck and must be rebuilt.
///
/// A process tap with drift compensation off (every Bluetooth output, every tap of the clock
/// device's own stream) can stop delivering samples for good after a system-wide stall: when
/// the tapped app's IO thread and the aggregate's IO thread both miss their deadlines (CPU or
/// memory pressure), the tap keeps returning exact zeros while the app plays on. With
/// `.mutedWhenTapped` that is total silence until the tap is rebuilt or the app restarts its
/// output. Measured in a standalone repro: a simultaneous 600-1000 ms stall stuck the tap in
/// 2 of 3 runs; a fresh tap of the same process heard the app at once.
///
/// Digital silence is also what a paused app with an open stream sends, so rebuilds stay rare:
/// fast only right after something that can break a tap, slow otherwise, and capped per
/// silence episode (the app playing with no input signal). Rebuilding a genuinely silent tap
/// is inaudible. Pure value type, one per app pid, kept across rebuilds.
struct TapWatchdog: Equatable {
    /// Silence after an IO discontinuity on the current tap before rebuilding.
    static let silenceAfterOverload: Double = 1.0
    /// Silence on a tap that started or switched recently before rebuilding.
    static let silenceAfterTapStart: Double = 3.0
    /// How recent a discontinuity or tap start must be to count as the cause.
    static let disturbanceWindow: Double = 15.0
    /// Silence with no known cause before rebuilding.
    static let longSilence: Double = 20.0
    /// Live input with silent output before rebuilding.
    static let outputSilentFor: Double = 1.5
    /// Rebuilds for input silence per episode (a fresh tap that is also silent is genuine silence).
    static let maxSilenceRebuilds = 3
    /// Rebuilds for silent output per playing run.
    static let maxOutputRebuilds = 2

    private(set) var silenceRebuilds = 0
    private(set) var longSilenceRebuilds = 0
    private(set) var outputRebuilds = 0

    mutating func evaluate(_ sample: TapHealthSample) -> TapWatchdogReason? {
        let r = sample.readings
        guard sample.appIsPlaying else {
            self = TapWatchdog()
            return nil
        }
        if r.inputSignalSeen && r.secondsSinceInputSignal < 1.0 {
            silenceRebuilds = 0
            longSilenceRebuilds = 0
        }
        guard !sample.isUserMuted, !r.isSwitching else { return nil }

        if r.secondsSinceHealthyOutput >= Self.outputSilentFor, outputRebuilds < Self.maxOutputRebuilds {
            outputRebuilds += 1
            return .outputSilent
        }

        guard silenceRebuilds < Self.maxSilenceRebuilds else { return nil }
        let silent = r.secondsSinceInputSignal
        let reason: TapWatchdogReason
        if r.secondsSinceDiscontinuity < Self.disturbanceWindow, silent >= Self.silenceAfterOverload {
            // The discontinuity is on the current tap (a rebuilt tap starts with none), so a
            // rebuild cannot retrigger this on its own.
            reason = .silentAfterOverload
        } else if silenceRebuilds == 0, r.secondsSinceTapStart < Self.disturbanceWindow,
                  silent >= Self.silenceAfterTapStart {
            reason = .silentAfterTapStart
        } else if longSilenceRebuilds == 0, silent >= Self.longSilence {
            longSilenceRebuilds += 1
            reason = .longSilence
        } else {
            return nil
        }
        silenceRebuilds += 1
        return reason
    }
}
