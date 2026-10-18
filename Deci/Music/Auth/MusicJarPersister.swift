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
/// - any other change only marks the jar dirty. Dirty data has no timer: it rides on the next write, or
///   `flushNow()` writes it when the app quits. A timer would raise a prompt at a random moment;
/// - a refused write keeps its data and arms nothing. The next sign-in change or the quit flush tries again;
/// - `saveSignedIn` (a first sign-in, a channel switch, an account swap) writes at once;
/// - `discard` (sign-out) deletes the item and forgets everything held back. A refused delete is logged,
///   remembered as owed, and retried by `flushNow()`. A later save replaces the item, so it settles an owed
///   delete without a second call.
///
/// The client hands over the whole encoded jar every time, so nothing is ever dropped from what is saved;
/// only the timing changes.
///
/// Two locks, never nested the wrong way round. `item` serializes every call into the store and every
/// decision about what to store, so a write can never land after a delete that came later. `state` guards
/// the bookkeeping and is held for a few instructions only, never across a store call, so `stage` and the
/// timers stay quick while a call sits behind a Keychain prompt. The order is `item` then `state`.
///
/// A write that finds the item busy does not queue behind it: it leaves its jar in `pending` and the thread
/// that holds the item arms the follow-up when it lets go. The quit flush skips a busy item the same way,
/// because the app is about to exit and must not hang behind a prompt. What that can cost: a jar staged
/// after the busy write began is not written at that quit. The write in flight carries the jar that was
/// newest when it began, which is the same jar unless a response landed in the meantime.
final class MusicJarPersister: Sendable {
    /// Every keychain log line, as fixed text: nothing that comes from a cookie or an account.
    enum Event: String, Sendable {
        case read = "keychain read"
        case writeSignInChanged = "keychain write (sign-in cookie changed)"
        case writeQuitFlush = "keychain write (quit flush)"
        case writeSignedIn = "keychain write (signed in)"
        case delete = "keychain delete"
        case deleteFailed = "keychain delete failed"
        case writeFailed = "keychain write failed"
    }

    static let signInWriteInterval: TimeInterval = 60

    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicClient")

    /// The newest jar the item does not hold yet.
    private struct Pending {
        let data: Data
        /// A sign-in cookie is among the changes since the last write, so the jar is on the 60 s clock.
        let signInChanged: Bool
        /// Numbers the jars in the order they were staged, so a write can tell its jar from a newer one.
        let serial: Int
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
        var serial = 0
        /// A delete the Keychain refused, still to be done.
        var deleteOwed = false
    }

    /// What one write finds to do when it holds the item.
    private enum Job {
        case nothing
        case save(Pending)
        case delete
    }

    /// Why a write is running: a sign-in change (a stage or its timer) or the quit flush.
    private enum Trigger {
        case signInChange
        case quit
    }

    private let store: MusicSecretStore
    private let now: @Sendable () -> Date
    private let scheduler: MusicWriteScheduler
    private let report: @Sendable (Event) -> Void
    private let item = OSAllocatedUnfairLock()
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
        if event == .writeFailed || event == .deleteFailed {
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
    /// back belonged to the session it replaces and is dropped. Waits for a write already in flight, since
    /// the caller needs to know this one landed. Throws when the Keychain refuses, and then nothing else
    /// changes.
    func saveSignedIn(_ data: Data) throws {
        defer { armIfNeeded() }
        try item.withLock {
            do {
                try store.save(data)
            } catch {
                report(.writeFailed)
                throw error
            }
            let current = now()
            state.withLock { state in
                cancelTimer(&state)
                state.pending = nil
                state.lastWrite = current
                state.deleteOwed = false
            }
            report(.writeSignedIn)
        }
    }

    /// The jar changed after a response. `signInChanged` says whether a sign-in cookie is among the changes.
    func stage(_ data: Data, signInChanged: Bool) {
        let writeNow = state.withLock { state -> Bool in
            let current = now()
            state.serial += 1
            let changed = signInChanged || (state.pending?.signInChanged ?? false)
            state.pending = Pending(data: data, signInChanged: changed, serial: state.serial)
            return changed && isSignInWindowOpen(state, at: current)
        }
        if writeNow {
            writeIfFree(for: .signInChange)
        } else {
            armIfNeeded()
        }
    }

    /// Writes whatever is held back, now, on the calling thread: a jar waiting for its minute or for the
    /// next write, and a delete that was refused. Does nothing when nothing is held, and returns at once
    /// when another thread is inside a store call (see the type comment). The quit path calls this: the app
    /// exits right after, so nothing can wait for a timer or an actor.
    func flushNow() {
        writeIfFree(for: .quit)
    }

    /// Sign-out: deletes the item and forgets everything held back, so no timer or flush can write the
    /// old cookies back. Waits for a write in flight so that the delete lands after it. A refused delete
    /// is logged and retried by `flushNow()`.
    func discard() {
        defer { armIfNeeded() }
        item.withLock {
            state.withLock { state in
                cancelTimer(&state)
                state.pending = nil
                state.lastWrite = nil
            }
            deleteItem()
        }
    }

    // MARK: - Store calls (called with the item held)

    /// Takes the item when it is free and does what `trigger` calls for; skips when another thread has it.
    private func writeIfFree(for trigger: Trigger) {
        let ran: Bool? = item.withLockIfAvailable {
            run(trigger)
            return true
        }
        // Whoever held the item arms the follow-up after letting go, so only a thread that ran does it here.
        if ran != nil { armIfNeeded() }
    }

    private func run(_ trigger: Trigger) {
        let job = state.withLock { state -> Job in
            switch trigger {
            case .signInChange:
                // Checked again here: another thread may have written between this one's check and now.
                guard let pending = state.pending, pending.signInChanged, isSignInWindowOpen(state, at: now()) else {
                    return .nothing
                }
                return .save(pending)
            case .quit:
                if let pending = state.pending { return .save(pending) }
                return state.deleteOwed ? .delete : .nothing
            }
        }
        switch job {
        case .nothing:
            break
        case .save(let pending):
            save(pending, as: trigger == .quit ? .writeQuitFlush : .writeSignInChanged)
        case .delete:
            deleteItem()
        }
    }

    private func save(_ pending: Pending, as event: Event) {
        do {
            try store.save(pending.data)
        } catch {
            let current = now()
            state.withLock { state in
                state.lastWrite = current
                // Keep the data for a later try, but off the 60 s clock: a refused prompt must not come
                // back every minute. A jar staged while this call was out is newer and keeps its own flag.
                if state.pending?.serial == pending.serial {
                    state.pending = Pending(data: pending.data, signInChanged: false, serial: pending.serial)
                }
            }
            report(.writeFailed)
            return
        }
        let current = now()
        state.withLock { state in
            state.lastWrite = current
            // A save replaces the item, so a delete that was owed is settled too.
            state.deleteOwed = false
            if state.pending?.serial == pending.serial { state.pending = nil }
        }
        report(event)
    }

    private func deleteItem() {
        do {
            try store.delete()
        } catch {
            state.withLock { $0.deleteOwed = true }
            report(.deleteFailed)
            return
        }
        state.withLock { $0.deleteOwed = false }
        report(.delete)
    }

    // MARK: - Timer

    private func isSignInWindowOpen(_ state: State, at current: Date) -> Bool {
        guard let last = state.lastWrite else { return true }
        return current.timeIntervalSince(last) >= Self.signInWriteInterval
    }

    /// Makes sure one timer is waiting for the moment a jar on the 60 s clock is due, and none otherwise.
    /// Every thread that held the item calls this after letting go, which is what keeps a change that was
    /// skipped behind a busy item from being forgotten.
    private func armIfNeeded() {
        state.withLock { state in
            let current = now()
            guard let pending = state.pending, pending.signInChanged else {
                cancelTimer(&state)
                return
            }
            let deadline = state.lastWrite.map { $0.addingTimeInterval(Self.signInWriteInterval) } ?? current
            if let timer = state.timer, timer.fireAt == deadline { return }
            cancelTimer(&state)
            state.timerCount += 1
            let id = state.timerCount
            // A clock set backwards cannot park a write for hours.
            let delay = max(0, min(deadline.timeIntervalSince(current), Self.signInWriteInterval))
            let cancel = scheduler.schedule(after: delay) { [weak self] in self?.timerFired(id) }
            state.timer = ArmedTimer(id: id, fireAt: deadline, cancel: cancel)
        }
    }

    private func cancelTimer(_ state: inout State) {
        state.timer?.cancel()
        state.timer = nil
    }

    /// A timer that was cancelled but had already started finds its id gone and does nothing.
    private func timerFired(_ id: Int) {
        let isCurrent = state.withLock { state -> Bool in
            guard state.timer?.id == id else { return false }
            state.timer = nil
            return true
        }
        if isCurrent { writeIfFree(for: .signInChange) }
    }
}
