// Deci/Music/History/WatchtimeTracker.swift
import Foundation

/// One stretch of the song heard without a jump, in media seconds, with the volume it played at.
struct WatchtimeSegment: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var volume: Int
    var muted: Bool
}

/// What one watchtime ping says about the listening since the previous one.
struct WatchtimeDetails: Sendable, Equatable {
    /// The stretches heard since the previous ping, oldest first: `st` and `et`, with `volume` and `muted` per stretch.
    var segments: [WatchtimeSegment]
    /// Seconds since the session began, on the clock the schedule runs on: `rt`.
    var realTime: TimeInterval
    /// When the schedule means to send the next ping: `rtn`.
    var nextRealTime: TimeInterval?
    /// When this ping was due, when it was sent by the schedule or flushed ahead of it: `rti`.
    var scheduledRealTime: TimeInterval?
    /// Milliseconds since the listener last touched a control: `lact`.
    var idleMilliseconds = 0
    /// `state`: playing, or paused (a pause flush and the final ping).
    var isPlaying: Bool
    /// The session's last ping: `final=1`.
    var isFinal: Bool
}

/// Cuts one playback session's listening into the pings YouTube Music's own player sends to `api/stats/watchtime`.
///
/// The schedule follows the web player's (`Nt8` in base.js): `rt` is wall-clock seconds since the session began, a
/// ping carries `rti` (the time it was due) and `rtn` (the time the next one is due), and a pause flushes what was
/// heard and stops the clock until playback resumes. Deci's differences: the first ping goes out with the playback
/// ping (at 30 s of listening, see `open`), after which every ping is a steady `interval` of playing apart, and a
/// stretch heard is counted by the same rule as `PlaybackTimeAccumulator`, so a seek is never listening time.
struct WatchtimeTracker: Equatable {
    /// Playing seconds between pings once the first one is out. The web player's steady-state step is 40 s.
    static let interval: TimeInterval = 40
    /// Volume the player reports until Deci's own volume is wired in.
    static let fullVolume = 100

    private(set) var isOpen = false
    private(set) var isFinished = false

    private var lastPosition: TimeInterval?
    private var lastWasPlaying = false
    private var lastVolume = Self.fullVolume
    private var lastMuted = false
    /// The stretch being heard now: closed by a seek or a change of volume, and sent with the next ping.
    private var current: WatchtimeSegment?
    /// Closed stretches waiting for the next ping.
    private var closed: [WatchtimeSegment] = []
    /// When the next scheduled ping is due; nil while paused.
    private var nextDue: TimeInterval?

    /// Feeds one player tick. Returns the ping that is due on it: the scheduled one while playing, or the flush on a pause.
    mutating func record(
        position: TimeInterval,
        isPlaying: Bool,
        now: TimeInterval,
        volume: Int = fullVolume,
        muted: Bool = false
    ) -> WatchtimeDetails? {
        guard !isFinished, position.isFinite else { return nil }
        let wasPlaying = lastWasPlaying
        if isPlaying { hear(to: position, volume: volume, muted: muted) }
        lastPosition = position
        lastWasPlaying = isPlaying
        lastVolume = volume
        lastMuted = muted
        guard isOpen else { return nil }

        guard isPlaying else {
            // The tick a pause shows on: send what was heard, and let the schedule start over on resume.
            guard wasPlaying else { return nil }
            let due = nextDue
            nextDue = nil
            return flush(realTime: now, due: due, next: nil, isPlaying: false, isFinal: false)
        }
        // Back from a pause: the 40 s count starts again from here.
        guard wasPlaying, let due = nextDue else {
            nextDue = Self.anchor(now)
            return nil
        }
        guard now >= due, hasUnsent else { return nil }
        // A long sleep sends one ping and re-anchors, instead of one per missed interval.
        var next = due + Self.interval
        if next <= now { next = Self.anchor(now) }
        nextDue = next
        return flush(realTime: now, due: due, next: next, isPlaying: true, isFinal: false)
    }

    /// A seek landed at `position`: what was heard before it and what comes after are separate stretches.
    mutating func seek(to position: TimeInterval) {
        guard !isFinished, position.isFinite else { return }
        lastPosition = position
    }

    /// The playback ping went out: the first watchtime ping covers everything heard so far, and the schedule starts.
    /// Nil when already open or finished.
    mutating func open(position: TimeInterval, now: TimeInterval) -> WatchtimeDetails? {
        guard !isOpen, !isFinished else { return nil }
        isOpen = true
        nextDue = lastWasPlaying ? Self.anchor(now) : nil
        return flush(realTime: now, due: nil, next: nextDue, isPlaying: lastWasPlaying, isFinal: false, emptyAt: position)
    }

    /// The session is over. The last ping, once; nil when nothing was ever opened or it was already sent.
    mutating func finish(position: TimeInterval, now: TimeInterval) -> WatchtimeDetails? {
        guard isOpen, !isFinished else { return nil }
        // The step between the last tick and the end (a track ends between two ticks) was heard as well.
        if lastWasPlaying, position.isFinite { hear(to: position, volume: lastVolume, muted: lastMuted) }
        isFinished = true
        let due = nextDue
        nextDue = nil
        return flush(realTime: now, due: due, next: nil, isPlaying: false, isFinal: true, emptyAt: position)
    }

    // MARK: - Segments

    private var hasUnsent: Bool { current != nil || !closed.isEmpty }

    /// Counts the step from the last position to `position` as heard when it is a plausible step between two ticks,
    /// and cuts a new stretch when it does not carry on from the one before.
    private mutating func hear(to position: TimeInterval, volume: Int, muted: Bool) {
        guard let last = lastPosition else { return }
        let delta = position - last
        guard delta > 0, delta <= PlaybackTimeAccumulator.maxDelta else { return }

        if var open = current, open.end == last, open.volume == volume, open.muted == muted {
            open.end = position
            current = open
        } else {
            if let open = current { closed.append(open) }
            current = WatchtimeSegment(start: last, end: position, volume: volume, muted: muted)
        }
    }

    /// Takes the stretches heard since the previous ping. Nil when there are none, unless `emptyAt` asks for the
    /// empty stretch at that position, so the opening and the final ping always carry one.
    private mutating func flush(
        realTime: TimeInterval,
        due: TimeInterval?,
        next: TimeInterval?,
        isPlaying: Bool,
        isFinal: Bool,
        emptyAt: TimeInterval? = nil
    ) -> WatchtimeDetails? {
        var segments = closed
        if let current { segments.append(current) }
        if segments.isEmpty {
            guard let emptyAt else { return nil }
            let at = emptyAt.isFinite ? emptyAt : (lastPosition ?? 0)
            segments = [WatchtimeSegment(start: at, end: at, volume: lastVolume, muted: lastMuted)]
        }
        closed = []
        current = nil
        return WatchtimeDetails(
            segments: segments,
            realTime: realTime,
            nextRealTime: next,
            scheduledRealTime: due,
            isPlaying: isPlaying,
            isFinal: isFinal
        )
    }

    /// The next whole second `interval` on, the way the web player rounds a due time.
    private static func anchor(_ now: TimeInterval) -> TimeInterval {
        now.rounded(.up) + interval
    }
}
