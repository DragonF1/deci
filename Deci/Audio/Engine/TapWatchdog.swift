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
    /// The tap is a device-stream tap (false: stereo mixdown), and whether its aggregate was built
    /// with drift compensation. Filled in every build: the `[RESCUE]` line reports them.
    var tapIsStream = false
    var tapDriftCompensation = false

    // Debug soak instrumentation: filled by DEBUG builds only, left at these defaults otherwise.
    /// Host tick the debug fields below were read at.
    var sampledHostTime: UInt64 = 0
    var zeroRun = ZeroRunTracker()
    var zeroRunForensics = ZeroRunForensics()
}

/// One health-monitor tick for one tap: its readings plus what the engine knows.
struct TapHealthSample: Equatable {
    var readings: TapHealthReadings
    /// The tapped process is running output IO (HAL `IsRunningOutput`). Nil when it was not read:
    /// the engine asks only once a rule is close to firing (`TapWatchdog.needsPlayingState`).
    var appIsPlaying: Bool?
    var isUserMuted: Bool
    /// When the sample was taken, in seconds on any steady clock (the engine passes the tick's
    /// `timeIntervalSinceReferenceDate`). Only differences matter.
    var clock: Double = 0
}

enum TapWatchdogReason: String, Equatable {
    /// The tap went digitally silent after an IO overload and never came back.
    case silentAfterOverload
    /// A fresh or just-switched tap delivered nothing while the app played.
    case silentAfterTapStart
    /// Digital silence while the app kept its output running, with no known cause.
    case unexplainedSilence
    /// Live input, but the processing chain wrote silence.
    case outputSilent
}

/// What the watchdog wants done about a tap.
enum TapWatchdogAction: Equatable {
    /// Probe with a candidate tap (make-before-break). It promotes only when the candidate hears
    /// signal while this tap reads exact zeros; the engine reports an inconclusive probe back
    /// through `rescueInconclusive`. `rung` is the ladder step that fired.
    case rescue(TapWatchdogReason, rung: Int)
    /// Tear the tap down and build it again.
    case rebuild(TapWatchdogReason)
}

/// Decides when a tap is stuck and what to do about it.
///
/// A process tap with drift compensation off (every Bluetooth output, every tap of the clock
/// device's own stream) can stop delivering samples for good after a system-wide stall: when
/// the tapped app's IO thread and the aggregate's IO thread both miss their deadlines (CPU or
/// memory pressure), the tap keeps returning exact zeros while the app plays on. With
/// `.mutedWhenTapped` that is total silence until the tap is rebuilt or the app restarts its
/// output. Measured in a standalone repro: a simultaneous 600-1000 ms stall stuck the tap in
/// 2 of 3 runs; a fresh tap of the same process heard the app at once.
///
/// Digital silence is also what a paused app with an open stream sends (Chrome does, while
/// YouTube Music is paused, with IsRunningOutput true), so silence alone proves nothing. The one
/// reliable test is a candidate tap that hears signal while this tap reads exact zeros. Probing
/// is cheap and inaudible (the candidate's output is muted until it is promoted), so the ladder
/// probes early and backs off: at 0.25, 2, 4 and 8 s of silence, then every 20 s, and starts
/// over when signal returns. A probe that proves nothing steps the ladder; it never rebuilds.
/// Pure value type, one per app pid, kept across rebuilds.
///
/// Three refinements keep the probes rare. Once two inconclusive probes come within
/// `ladderResetAfter` of each other, signal that returns inside that window keeps the ladder at
/// rung 1, so a bursty app is not probed at every gap. A single probe (a gap between tracks)
/// still resets to rung 0.
/// Silence is counted from when the app was seen starting to play, not from the last signal
/// minutes ago. And after three promotions in a row the ladder never drops below rung 1.
struct TapWatchdog: Equatable {
    /// Silence at which each of the first rungs rescues. The first is also the silence below
    /// which a tap counts as having signal.
    static let rescueThresholds: [Double] = [0.25, 2.0, 4.0, 8.0]
    /// Between the steady probes after the last threshold.
    static let probeInterval: Double = 20.0
    /// How recent a discontinuity or tap start must be to count as the cause (reason only).
    static let disturbanceWindow: Double = 15.0
    /// Live input with silent output before rebuilding.
    static let outputSilentFor: Double = 1.5
    /// Rebuilds per episode after a rescue failed for a reason other than silence. A tap that
    /// cannot be probed is still rebuilt, but not in a loop.
    static let maxFallbackRebuilds = 3
    /// Rebuilds for silent output per playing run.
    static let maxOutputRebuilds = 2
    /// Inconclusive probes this close together (each to the one before) form a chain, and while
    /// the last is this recent, signal keeps the ladder at rung 1 instead of resetting it.
    static let ladderResetAfter: Double = 10
    /// Chain length before the memory holds: one probe is a track gap, two is a bursty app or a pause.
    static let ladderMemoryProbes = 2
    /// Promotions this close together (each to the one before) count as one storm.
    static let promotionStormWindow: Double = 30
    /// Promotions in a storm before the ladder floor rises.
    static let promotionStormCount = 3

    /// Silence at which `rung` rescues: the listed thresholds, then one every `probeInterval`.
    static func rescueThreshold(rung: Int) -> Double {
        if rung < rescueThresholds.count { return rescueThresholds[max(0, rung)] }
        return rescueThresholds[rescueThresholds.count - 1] + probeInterval * Double(rung - rescueThresholds.count + 1)
    }

    /// The first rung whose threshold lies strictly past `silence`.
    static func firstRung(after silence: Double) -> Int {
        var rung = 0
        while rescueThreshold(rung: rung) <= silence { rung += 1 }
        return rung
    }

    /// Whether IsRunningOutput is worth reading: only once a rule could fire on it. A tap already
    /// known to be stopped waits for the output rule; the engine re-reads it once a second.
    func needsPlayingState(_ readings: TapHealthReadings) -> Bool {
        (!isStopped && effectiveSilence(readings) >= Self.rescueThreshold(rung: nextRung))
            || readings.secondsSinceHealthyOutput >= Self.outputSilentFor
    }

    /// The ladder rung the next rescue runs on.
    private(set) var nextRung = 0
    private(set) var fallbackRebuilds = 0
    private(set) var outputRebuilds = 0
    /// Clock of the last probe that proved nothing; nil when none since the ladder last reset.
    private(set) var lastInconclusiveClock: Double?
    private(set) var recentInconclusive = 0
    /// The app was last seen not running output, so its silence says nothing until it plays.
    private(set) var isStopped = false
    /// The input silence when the app was seen starting to play: what came before was idle time.
    private(set) var silenceAtPlayStart: Double = 0
    /// Promotions in the current storm, and the clock of the latest one.
    private(set) var recentPromotions = 0
    private(set) var lastPromotionClock: Double?

    /// Input silence counted from the play start, never negative.
    func effectiveSilence(_ r: TapHealthReadings) -> Double {
        max(0, r.secondsSinceInputSignal - silenceAtPlayStart)
    }

    mutating func evaluate(_ sample: TapHealthSample) -> TapWatchdogAction? {
        let r = sample.readings
        // Signal came back, or a new tap restarted the clock: the offset no longer applies.
        if r.secondsSinceInputSignal < silenceAtPlayStart { silenceAtPlayStart = 0 }
        if sample.appIsPlaying == false {
            self = TapWatchdog()
            isStopped = true
            return nil
        }
        if sample.appIsPlaying == true, isStopped {
            isStopped = false
            silenceAtPlayStart = r.secondsSinceInputSignal
        }
        let silent = effectiveSilence(r)
        if silent < Self.rescueThreshold(rung: 0) {
            // Signal is flowing (or a promoted tap's clock just restarted): a new episode, unless
            // a probe proved nothing a moment ago and this is only a burst between gaps.
            // The memory keeps one rung at most: after a long pause climbed the ladder, a tap that
            // dies right after playback resumes still waits 2 s, not the paused rung's minute.
            let remembered = recentInconclusive >= Self.ladderMemoryProbes
                && (lastInconclusiveClock.map { sample.clock - $0 < Self.ladderResetAfter } ?? false)
            if remembered {
                nextRung = min(nextRung, 1)
            } else {
                resetLadder(clock: sample.clock)
            }
        }
        guard !sample.isUserMuted, !r.isSwitching, sample.appIsPlaying == true else { return nil }

        if r.secondsSinceHealthyOutput >= Self.outputSilentFor, outputRebuilds < Self.maxOutputRebuilds {
            outputRebuilds += 1
            return .rebuild(.outputSilent)
        }

        guard silent >= Self.rescueThreshold(rung: nextRung) else { return nil }
        let reason: TapWatchdogReason
        if r.secondsSinceDiscontinuity < Self.disturbanceWindow {
            // The discontinuity is on the current tap (a rebuilt tap starts with none).
            reason = .silentAfterOverload
        } else if r.secondsSinceTapStart < Self.disturbanceWindow {
            reason = .silentAfterTapStart
        } else {
            reason = .unexplainedSilence
        }
        return .rescue(reason, rung: nextRung)
    }

    /// A rescue proved nothing (the candidate heard no signal, or the primary recovered): wait
    /// for the next rung past the silence the rescue ran at. `silence` is the raw reading.
    mutating func rescueInconclusive(atSilence silence: Double, clock: Double) {
        nextRung = max(nextRung + 1, Self.firstRung(after: max(0, silence - silenceAtPlayStart)))
        let chained = lastInconclusiveClock.map { clock - $0 < Self.ladderResetAfter } ?? false
        recentInconclusive = chained ? recentInconclusive + 1 : 1
        lastInconclusiveClock = clock
    }

    /// A rescue promoted its candidate: the new tap starts a new episode. Promotions each within
    /// `promotionStormWindow` of the last count as a storm, which raises the ladder floor.
    mutating func rescuePromoted(clock: Double) {
        if let last = lastPromotionClock, clock - last < Self.promotionStormWindow {
            recentPromotions += 1
        } else {
            recentPromotions = 1
        }
        lastPromotionClock = clock
        lastInconclusiveClock = nil
        recentInconclusive = 0
        resetLadder(clock: clock)
    }

    /// Rung 1 while a promotion storm is on (three promotions in a row, the last under 30 s ago),
    /// else rung 0: a tap that keeps dying and being replaced is not probed at 0.25 s again.
    private func floorRung(clock: Double) -> Int {
        guard recentPromotions >= Self.promotionStormCount, let last = lastPromotionClock,
              clock - last < Self.promotionStormWindow else { return 0 }
        return 1
    }

    private mutating func resetLadder(clock: Double) {
        nextRung = floorRung(clock: clock)
        fallbackRebuilds = 0
        // The probe chain outlives the reset until it expires: the next gap may extend it.
        if let last = lastInconclusiveClock, clock - last < Self.ladderResetAfter { return }
        lastInconclusiveClock = nil
        recentInconclusive = 0
    }

    /// Takes one of the episode's fallback rebuilds; false once they are spent.
    mutating func claimFallbackRebuild() -> Bool {
        guard fallbackRebuilds < Self.maxFallbackRebuilds else { return false }
        fallbackRebuilds += 1
        return true
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
/// each onset and each end is reported once however the 250 ms health tick falls against them.
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
/// the IO thread saw something rather than the moment a health tick noticed it.
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
