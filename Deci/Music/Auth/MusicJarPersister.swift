import Foundation
import os

/// Runs a block once, a while from now. The persister's only clock-driven part, behind a protocol so
/// tests move time by hand instead of sleeping.
protocol MusicWriteScheduler: Sendable {
    /// Calls `work` once, `delay` seconds from now, on any thread, never before this call returns. The
    /// returned closure cancels the call if it has not started yet.
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

/// A utility-queue timer on the wall clock, so a deadline that passed while the Mac slept fires on wake.
struct DispatchWriteScheduler: MusicWriteScheduler {
    private let queue = DispatchQueue(label: "com.abraham.Deci.music.cookie-writes", qos: .utility)

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        queue.asyncAfter(wallDeadline: .now() + delay) {
            if !cancelled.withLock({ $0 }) { work() }
        }
        return { cancelled.withLock { $0 = true } }
    }
}

/// Decides when the cookie jar reaches the Keychain, and is the only thing that touches the item.
///
/// The Keychain item prompts whenever the running build is not on its access list, which is every new
/// build until the owner clicks "Always Allow". YouTube rotates cookies on most responses, so writing on
/// every change meant a prompt on nearly every request. The policy:
/// - a sign-in cookie change is written at once, but at most once per 60 s (later changes wait for the
///   minute and go out as one write of the newest jar);
/// - any other change only marks the jar dirty. Dirty data rides on the next write, goes out 30 minutes
///   after it first went dirty, or is written by `flushNow()` when the app quits;
/// - `saveSignedIn` (a first sign-in, a channel switch, an account swap) writes at once;
/// - `discard` (sign-out) deletes the item and forgets everything held back.
///
/// The client hands over the whole encoded jar every time, so nothing is ever dropped from what is saved;
/// only the timing changes. Every method is safe from any thread and runs under one lock, store call
/// included: a write that was already decided can never land after a delete, and the quit flush is plain
/// synchronous code that needs no actor hop.
final class MusicJarPersister: Sendable {
    /// Every keychain log line, as fixed text: nothing that comes from a cookie or an account.
    enum Event: String, Sendable {
        case read = "keychain read"
        case writeSignInChanged = "keychain write (sign-in cookie changed)"
        case writeQuitFlush = "keychain write (quit flush)"
        case writePeriodic = "keychain write (periodic)"
        case writeSignedIn = "keychain write (signed in)"
        case delete = "keychain delete"
        case writeFailed = "keychain write failed"
    }

    static let signInWriteInterval: TimeInterval = 60
    static let dirtyWriteInterval: TimeInterval = 30 * 60

    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicClient")

    /// The newest jar the item does not hold yet.
    private struct Pending {
        let data: Data
        /// A sign-in cookie is among the changes since the last write.
        let signInChanged: Bool
        /// When the jar first went dirty.
        let since: Date
    }

    private struct ArmedTimer {
        let id: Int
        let fireAt: Date
        let cancel: @Sendable () -> Void
    }

    private struct State {
        var pending: Pending?
        var lastWrite: Date?
        var timer: ArmedTimer?
        var timerCount = 0
    }

    private let store: MusicSecretStore
    private let now: @Sendable () -> Date
    private let scheduler: MusicWriteScheduler
    private let report: @Sendable (Event) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        store: MusicSecretStore,
        now: @escaping @Sendable () -> Date = { Date() },
        scheduler: MusicWriteScheduler = DispatchWriteScheduler(),
        report: @escaping @Sendable (Event) -> Void = MusicJarPersister.log
    ) {
        self.store = store
        self.now = now
        self.scheduler = scheduler
        self.report = report
    }

    private static func log(_ event: Event) {
        if event == .writeFailed {
            logger.error("\(event.rawValue, privacy: .public)")
        } else {
            logger.notice("\(event.rawValue, privacy: .public)")
        }
    }

    // MARK: - Reading

    /// The stored jar. The client calls this once per launch and keeps the jar in memory after that.
    func load() -> Data? {
        report(.read)
        return store.load()
    }

    // MARK: - Writing

    /// A new session (first sign-in, channel switch, account swap): written at once, whatever was held
    /// back belonged to the session it replaces and is dropped. Throws when the Keychain refuses, and
    /// then nothing else changes.
    func saveSignedIn(_ data: Data) throws {
        try state.withLock { state in
            do {
                try store.save(data)
            } catch {
                report(.writeFailed)
                throw error
            }
            cancelTimer(&state)
            state.pending = nil
            state.lastWrite = now()
            report(.writeSignedIn)
        }
    }

    /// The jar changed after a response. `signInChanged` says whether a sign-in cookie is among the changes.
    func stage(_ data: Data, signInChanged: Bool) {
        state.withLock { state in
            let current = now()
            let changed = signInChanged || (state.pending?.signInChanged ?? false)
            state.pending = Pending(data: data, signInChanged: changed, since: state.pending?.since ?? current)
            if changed, isSignInWindowOpen(state, at: current) {
                write(&state, as: .writeSignInChanged, at: current)
            } else {
                arm(&state, at: current)
            }
        }
    }

    /// Writes whatever is held back, now, on the calling thread. Does nothing when nothing is.
    /// The quit path calls this: the app exits right after, so nothing can wait for a timer or an actor.
    func flushNow() {
        state.withLock { state in
            guard state.pending != nil else { return }
            write(&state, as: .writeQuitFlush, at: now())
        }
    }

    /// Sign-out: deletes the item and forgets everything held back, so no timer or flush can write the
    /// old cookies back.
    func discard() {
        state.withLock { state in
            cancelTimer(&state)
            state.pending = nil
            state.lastWrite = nil
            store.delete()
            report(.delete)
        }
    }

    // MARK: - Policy (called with the lock held)

    private func isSignInWindowOpen(_ state: State, at current: Date) -> Bool {
        guard let last = state.lastWrite else { return true }
        return current.timeIntervalSince(last) >= Self.signInWriteInterval
    }

    private func write(_ state: inout State, as event: Event, at current: Date) {
        guard let pending = state.pending else { return }
        cancelTimer(&state)
        state.lastWrite = current
        do {
            try store.save(pending.data)
            state.pending = nil
            report(event)
        } catch {
            // Keep the data for a later try, but off the 60 s clock: a refused prompt must not come
            // back every minute. The next sign-in change, the 30 minute mark or the quit flush retries.
            state.pending = Pending(data: pending.data, signInChanged: false, since: current)
            report(.writeFailed)
            arm(&state, at: current)
        }
    }

    /// Makes sure one timer is waiting for the moment the held-back jar is due, and none when nothing is held.
    private func arm(_ state: inout State, at current: Date) {
        guard let pending = state.pending else {
            cancelTimer(&state)
            return
        }
        let deadline: Date
        if pending.signInChanged, let last = state.lastWrite {
            deadline = last.addingTimeInterval(Self.signInWriteInterval)
        } else {
            deadline = max(pending.since, state.lastWrite ?? pending.since).addingTimeInterval(Self.dirtyWriteInterval)
        }
        if let timer = state.timer, timer.fireAt == deadline { return }
        cancelTimer(&state)
        state.timerCount += 1
        let id = state.timerCount
        // A clock set backwards cannot park a write for hours.
        let delay = max(0, min(deadline.timeIntervalSince(current), Self.dirtyWriteInterval))
        let cancel = scheduler.schedule(after: delay) { [weak self] in self?.timerFired(id) }
        state.timer = ArmedTimer(id: id, fireAt: deadline, cancel: cancel)
    }

    private func cancelTimer(_ state: inout State) {
        state.timer?.cancel()
        state.timer = nil
    }

    /// A timer that was cancelled but had already started finds its id gone and does nothing.
    private func timerFired(_ id: Int) {
        state.withLock { state in
            guard state.timer?.id == id else { return }
            state.timer = nil
            guard let pending = state.pending else { return }
            write(&state, as: pending.signInChanged ? .writeSignInChanged : .writePeriodic, at: now())
        }
    }
}
