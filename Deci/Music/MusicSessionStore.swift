import Foundation
import os

/// The remembered listening session on disk: one JSON file in Deci's Application Support folder.
///
/// Writes are atomic and happen on a queue of their own, never on the caller's thread, at most one a second: the first
/// save after a quiet second goes out at once, and a burst after it leaves the newest snapshot waiting for one trailing
/// write (the persister's `MusicWriteScheduler` keeps the clock, so tests move time by hand). `flush()` writes what is
/// waiting right now, for the quit path. `delete()` drops the waiting write and the file, in order with every write
/// before it.
///
/// Reading is where the session's rules live: `load` hands back a snapshot only when it is readable, of this format,
/// at most `MusicSessionSnapshot.lifetime` old and for the asked channel. Any other file is deleted on the spot, so a
/// session that cannot be used never lingers. Logs carry counts and error kinds only: never a title or an id.
final class MusicSessionStore: Sendable {
    /// The shortest time between two writes.
    static let writeInterval: TimeInterval = 1

    private static let fileName = "music-session.json"
    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicSession")

    private struct State {
        /// The newest snapshot that is waiting for the trailing write.
        var pending: MusicSessionSnapshot?
        /// When the last write was handed to the queue; nil at the start and after a delete.
        var lastWrite: Date?
        var cancelTimer: (@Sendable () -> Void)?
        /// Numbers the timers, so one that was cancelled but had already started finds its number gone.
        var timerID = 0
        var writes = 0
    }

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let scheduler: MusicWriteScheduler
    /// Every file operation runs here, one at a time and in the order it was handed over.
    private let io = DispatchQueue(label: "com.abraham.Deci.music.session", qos: .utility)
    /// Held for a few instructions only. Work is handed to `io` while it is held, which is what keeps a write and a
    /// delete in the order they were asked for.
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        fileURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        scheduler: MusicWriteScheduler = DispatchWriteScheduler()
    ) {
        self.fileURL = fileURL
        self.now = now
        self.scheduler = scheduler
    }

    /// The store the app uses, on its own file.
    static func live() -> MusicSessionStore {
        MusicSessionStore(fileURL: liveFileURL())
    }

    static func liveFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Deci", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// How many writes have been handed to the queue (finished or not).
    var writeCount: Int { state.withLock { $0.writes } }

    // MARK: - Writing

    /// Writes the snapshot now when the last write was a second ago or more, otherwise keeps it for the one trailing
    /// write that is due a second after the last. A newer snapshot replaces one that is waiting.
    func save(_ snapshot: MusicSessionSnapshot) {
        state.withLock { state in
            if let last = state.lastWrite {
                let elapsed = now().timeIntervalSince(last)
                // A clock that moved backwards counts as a quiet second rather than parking the write.
                if elapsed >= 0, elapsed < Self.writeInterval {
                    state.pending = snapshot
                    if state.cancelTimer == nil { armTimer(after: Self.writeInterval - elapsed, &state) }
                    return
                }
            }
            cancelTimer(&state)
            state.pending = nil
            handOver(snapshot, &state)
        }
    }

    /// Writes whatever is waiting, now, and returns once every earlier write has landed. The quit path uses it.
    func flush() {
        state.withLock { state in
            cancelTimer(&state)
            if let pending = state.pending {
                state.pending = nil
                handOver(pending, &state)
            }
        }
        io.sync {}
    }

    /// Forgets the session: the waiting write is dropped and the file removed.
    func delete() {
        state.withLock { state in
            cancelTimer(&state)
            state.pending = nil
            state.lastWrite = nil
            let url = fileURL
            io.async { Self.remove(url) }
        }
    }

    /// Returns once every write and delete handed over so far has finished.
    func waitForWrites() {
        io.sync {}
    }

    // MARK: - Reading

    /// The saved session if it can be used, else nil. A file that is unreadable, of another version, older than the
    /// lifetime or for a different `channel` is deleted. With no `channel` the account is not checked: the caller
    /// peeks, and checks it when it has the account. No file is nil and creates nothing.
    func load(forChannel channel: String? = nil) -> MusicSessionSnapshot? {
        io.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            guard let data = try? Data(contentsOf: fileURL), let snapshot = MusicSessionSnapshot.decode(data) else {
                Self.logger.notice("session file unreadable, deleted")
                Self.remove(fileURL)
                return nil
            }
            // A save from the future (the clock was set back) would never expire, so past a minute of skew it counts
            // as expired too.
            let age = now().timeIntervalSince(snapshot.savedAt)
            if age > MusicSessionSnapshot.lifetime || age < -60 {
                Self.logger.notice("session file expired, deleted")
                Self.remove(fileURL)
                return nil
            }
            if let channel, snapshot.channelKey != channel {
                Self.logger.notice("session file for another account, deleted")
                Self.remove(fileURL)
                return nil
            }
            return snapshot
        }
    }

    // MARK: - Queue and timer (called with the state held)

    private func handOver(_ snapshot: MusicSessionSnapshot, _ state: inout State) {
        state.lastWrite = now()
        state.writes += 1
        let url = fileURL
        io.async { Self.write(snapshot, to: url) }
    }

    private func armTimer(after delay: TimeInterval, _ state: inout State) {
        state.timerID += 1
        let id = state.timerID
        state.cancelTimer = scheduler.schedule(after: delay) { [weak self] in self?.timerFired(id) }
    }

    private func cancelTimer(_ state: inout State) {
        state.cancelTimer?()
        state.cancelTimer = nil
        state.timerID += 1
    }

    private func timerFired(_ id: Int) {
        state.withLock { state in
            guard state.timerID == id, state.cancelTimer != nil else { return }
            state.cancelTimer = nil
            guard let pending = state.pending else { return }
            state.pending = nil
            handOver(pending, &state)
        }
    }

    // MARK: - Files (run on `io`)

    private static func write(_ snapshot: MusicSessionSnapshot, to url: URL) {
        do {
            let data = try snapshot.encoded()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            let kind = error as NSError
            logger.error("session write failed: \(kind.domain, privacy: .public) \(kind.code, privacy: .public)")
        }
    }

    private static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // Already gone.
        } catch {
            let kind = error as NSError
            logger.error("session delete failed: \(kind.domain, privacy: .public) \(kind.code, privacy: .public)")
        }
    }
}
