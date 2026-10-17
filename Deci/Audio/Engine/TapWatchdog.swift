// Deci/Audio/Engine/TapWatchdog.swift
import Foundation

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

    // Debug soak instrumentation: filled by DEBUG builds only, left at these defaults otherwise.
    /// Host tick the debug fields below were read at.
    var sampledHostTime: UInt64 = 0
    var zeroRun = ZeroRunTracker()
    var zeroRunForensics = ZeroRunForensics()
    /// The tap is a device-stream tap (false: stereo mixdown).
    var tapIsStream = false
    var tapDriftCompensation = false
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

/// Tracks runs of exact-zero tap input (the stuck-tap signature) for the debug soak, with the
/// host time of each run's first buffer. Fed once per primary IO callback, so it must stay
/// allocation-free. Pure value type; `reset()` on tap start. Runs shorter than `minRunSeconds`
/// (the gaps between sounds) are ignored.
struct ZeroRunTracker: Equatable {
    static let minRunSeconds: Double = 0.1

    /// Host tick of the first zero buffer of the ongoing run; 0 = no run.
    private(set) var runStartHostTime: UInt64 = 0
    private(set) var runFrames: UInt64 = 0
    private(set) var runSeconds: Double = 0
    /// Runs that ended after reaching `minRunSeconds`, and the latest one's onset and size.
    private(set) var completedRuns: UInt32 = 0
    private(set) var lastRunStartHostTime: UInt64 = 0
    private(set) var lastRunFrames: UInt64 = 0
    private(set) var lastRunSeconds: Double = 0
    /// A zero run is ongoing, of any length.
    private(set) var isInRun = false

    /// The ongoing run has reached `minRunSeconds`.
    var ongoingRunCrossed: Bool { isInRun && runSeconds >= Self.minRunSeconds }

    /// A callback with no frames (a NULL buffer) says nothing about the input and is skipped.
    /// A non-positive rate counts no time, so such a run never crosses.
    mutating func record(isZero: Bool, frames: Int, sampleRate: Double, hostTime: UInt64) {
        guard frames > 0 else { return }
        guard isZero else {
            endRun()
            return
        }
        if !isInRun {
            isInRun = true
            runStartHostTime = hostTime
            runFrames = 0
        }
        runFrames &+= UInt64(frames)
        // From the frame total, not a running sum of seconds, so 100 ms lands exactly on 100 ms.
        runSeconds = sampleRate > 0 ? Double(runFrames) / sampleRate : 0
    }

    mutating func reset() {
        self = ZeroRunTracker()
    }

    private mutating func endRun() {
        guard isInRun else { return }
        if runSeconds >= Self.minRunSeconds {
            completedRuns &+= 1
            lastRunStartHostTime = runStartHostTime
            lastRunFrames = runFrames
            lastRunSeconds = runSeconds
        }
        isInRun = false
        runStartHostTime = 0
        runFrames = 0
        runSeconds = 0
    }
}

/// How the first zero buffer of a run looked against the callback before it.
struct ZeroRunForensics: Equatable {
    /// Host tick of that buffer (the `ZeroRunTracker.runStartHostTime` of its run); 0 = none yet.
    var startHostTime: UInt64 = 0
    /// Host ticks since the previous primary callback; 0 = there was none (first of a tap).
    var hostDeltaTicks: UInt64 = 0
    var sampleTimeDelta: Float64 = 0
    var rateScalar: Float64 = 0
    var numberBuffers: UInt32 = 0
    var firstBufferBytes: UInt32 = 0
    var firstBufferChannels: UInt32 = 0

    func summary(nanosPerTick: Double = ZeroRunClock.nanosPerTick) -> String {
        let hasPrevious = hostDeltaTicks != 0
        let hostDelta = hasPrevious ? String(format: "%.3fms", Double(hostDeltaTicks) * nanosPerTick / 1e6) : "n/a"
        let sampleDelta = hasPrevious ? String(format: "%.1f", sampleTimeDelta) : "n/a"
        return "prevCb=\(hostDelta) dSample=\(sampleDelta) rateScalar=\(String(format: "%.6f", rateScalar)) "
            + "buffers=\(numberBuffers) buf0=\(firstBufferBytes)B/\(firstBufferChannels)ch"
    }
}

enum ZeroRunEvent: Equatable {
    /// An ongoing run crossed 100 ms.
    case onset(startHostTime: UInt64)
    /// A run of at least 100 ms ended; `run` is the tracker's completed-run count.
    case ended(startHostTime: UInt64, frames: UInt64, seconds: Double, run: UInt32)

    var startHostTime: UInt64 {
        switch self {
        case .onset(let start), .ended(let start, _, _, _): return start
        }
    }
}

extension ZeroRunEvent {
    /// The `[ZERORUN]` line body: kind, app, onset wall time (from the IO thread's host clock,
    /// so independent of the monitor tick), tap config and the onset buffer's forensics.
    func logLine(
        appName: String,
        pid: Int32,
        playing: Bool,
        devices: [String],
        tapSourceDeviceUID: String?,
        readings: TapHealthReadings,
        now: Date,
        timeZone: TimeZone = .current,
        nanosPerTick: Double = ZeroRunClock.nanosPerTick
    ) -> String {
        let onset = ZeroRunClock.wallTime(ofHostTime: startHostTime, sampledAt: readings.sampledHostTime, now: now, nanosPerTick: nanosPerTick)
        let kind: String
        var length = ""
        switch self {
        case .onset:
            kind = "onset"
        case .ended(_, let frames, let seconds, let run):
            kind = "ended"
            length = " length=\(String(format: "%.3f", seconds))s frames=\(frames) run=\(run)"
        }
        let source = readings.tapIsStream ? "stream:\(tapSourceDeviceUID ?? "?")" : "mixdown"
        let drift = readings.tapDriftCompensation ? "on" : "off"
        // The forensics describe the latest run; an older run's line must not borrow them.
        let forensics = readings.zeroRunForensics.startHostTime == startHostTime
            ? readings.zeroRunForensics.summary(nanosPerTick: nanosPerTick) : "forensics=n/a"
        // Tap age at the onset, so a fresh tap that never heard signal stands apart from an old one dying.
        let sinceOnset = readings.sampledHostTime >= startHostTime
            ? Double(readings.sampledHostTime - startHostTime) * nanosPerTick / 1e9 : 0
        let age = String(format: "%.2f", max(0, readings.secondsSinceTapStart - sinceOnset))
        return "\(kind) \(appName) (PID \(pid)) at \(ZeroRunClock.clockString(onset, timeZone: timeZone))\(length) "
            + "src=\(source) drift=\(drift) playing=\(playing) devices=[\(devices.joined(separator: ","))] age=\(age)s \(forensics)"
    }
}

/// Main-thread side of the zero-run log: which of a tracker's runs were already reported, so
/// each onset and each end is reported once however the 1 s monitor tick falls against them.
struct ZeroRunLogCursor: Equatable {
    private var onsetLogged: UInt64 = 0
    private var endedLogged: UInt64 = 0

    /// A run that began and ended between two ticks reports its onset together with its end.
    mutating func events(for run: ZeroRunTracker) -> [ZeroRunEvent] {
        var events: [ZeroRunEvent] = []
        if run.completedRuns > 0, run.lastRunStartHostTime != endedLogged {
            if run.lastRunStartHostTime != onsetLogged {
                events.append(.onset(startHostTime: run.lastRunStartHostTime))
            }
            events.append(.ended(
                startHostTime: run.lastRunStartHostTime,
                frames: run.lastRunFrames,
                seconds: run.lastRunSeconds,
                run: run.completedRuns
            ))
            onsetLogged = run.lastRunStartHostTime
            endedLogged = run.lastRunStartHostTime
        }
        if run.ongoingRunCrossed, run.runStartHostTime != onsetLogged {
            events.append(.onset(startHostTime: run.runStartHostTime))
            onsetLogged = run.runStartHostTime
        }
        return events
    }
}

/// Host ticks (`mach_absolute_time`) to wall-clock time, for stamping log lines with the moment
/// the IO thread saw something rather than the moment a 1 s tick noticed it.
enum ZeroRunClock {
    static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1.0 }
        return Double(info.numer) / Double(info.denom)
    }()

    /// `now` is the wall time of host tick `sampledHostTime`. A tick after it (the IO thread
    /// stamped a run between the two reads) clamps to `now`.
    static func wallTime(
        ofHostTime hostTime: UInt64,
        sampledAt sampledHostTime: UInt64,
        now: Date,
        nanosPerTick: Double = ZeroRunClock.nanosPerTick
    ) -> Date {
        guard sampledHostTime > hostTime else { return now }
        return now.addingTimeInterval(-Double(sampledHostTime - hostTime) * nanosPerTick / 1e9)
    }

    /// HH:mm:ss.SSS in the given time zone.
    static func clockString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
