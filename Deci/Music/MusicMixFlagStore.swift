import Foundation
import os

/// The "do not mix" choices of the listener, on disk: songs flagged "Always start clean" and pairs (one song into
/// another) flagged the same. One small JSON file next to the session file, `MusicMixFlags.json`:
/// `{"version":1,"cleanStart":["id"],"pairs":[["from","to"]]}`. It is not part of the analysis database on purpose: that
/// one is a cache that may be dropped, a choice of the listener must outlive it.
///
/// Reads are answered from memory. Writes are atomic and happen on a queue of their own, at most one a second (the first
/// change after a quiet second goes out at once, a burst leaves one trailing write), the way `MusicSessionStore` does
/// it. Each list keeps at most `cap` entries and drops the oldest. A file that is not valid JSON is
/// moved to a timestamped `.bad` name and the store starts empty; one that cannot be read, or has another version, is left
/// untouched and the store runs from memory with writes off. It never throws and never holds playback up.
/// Logs carry counts only, never an id.
final class MusicMixFlagStore: Sendable {
    static let writeInterval: TimeInterval = 1
    static let cap = 5000
    static let version = 1
    static let fileName = "MusicMixFlags.json"

    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicMixFlags")

    private struct Pair: Hashable, Codable {
        var from: String
        var to: String
    }

    private struct File: Codable {
        var version: Int
        var cleanStart: [String]
        var pairs: [[String]]
    }

    private struct State {
        var cleanStart: [String] = []
        var pairs: [Pair] = []
        var dirty = false
        var lastWrite: Date?
        var armed = false
        var cancelTimer: (@Sendable () -> Void)?
        var timerID = 0
        var writes = 0
        /// False when the file on disk could not be read or is from a newer version: it is left as it is and this session
        /// runs from memory, so the listener's flags on disk are never overwritten.
        var writable = true
    }

    private struct Loaded {
        var cleanStart: [String] = []
        var pairs: [Pair] = []
        var writable = true
    }

    /// A timer to start once the state lock is released: the id it was reserved under, and its delay.
    private struct TimerRequest {
        var id: Int
        var delay: TimeInterval
    }

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let scheduler: MusicWriteScheduler
    private let io = DispatchQueue(label: "com.abraham.Deci.music.mixflags", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        fileURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        scheduler: MusicWriteScheduler = DispatchWriteScheduler()
    ) {
        self.fileURL = fileURL
        self.now = now
        self.scheduler = scheduler
        let loaded = io.sync { Self.read(fileURL) }
        state.withLock {
            $0.cleanStart = loaded.cleanStart
            $0.pairs = loaded.pairs
            $0.writable = loaded.writable
        }
    }

    /// The store the app uses, on its own file beside the session file.
    static func live() -> MusicMixFlagStore {
        MusicMixFlagStore(fileURL: liveFileURL())
    }

    static func liveFileURL() -> URL {
        MusicSessionStore.liveFileURL().deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: false)
    }

    /// How many writes have been handed to the queue.
    var writeCount: Int { state.withLock { $0.writes } }

    // MARK: - Reading

    func startsClean(_ videoId: String) -> Bool {
        state.withLock { $0.cleanStart.contains(videoId) }
    }

    func pairIsClean(from: String, to: String) -> Bool {
        state.withLock { $0.pairs.contains(Pair(from: from, to: to)) }
    }

    var cleanStartCount: Int { state.withLock { $0.cleanStart.count } }
    var pairCount: Int { state.withLock { $0.pairs.count } }

    // MARK: - Changing

    func setStartsClean(_ on: Bool, videoId: String) {
        let request = state.withLock { state -> TimerRequest? in
            let had = state.cleanStart.contains(videoId)
            guard had != on else { return nil }
            if on {
                state.cleanStart.append(videoId)
                if state.cleanStart.count > Self.cap { state.cleanStart.removeFirst(state.cleanStart.count - Self.cap) }
            } else {
                state.cleanStart.removeAll { $0 == videoId }
            }
            return changed(&state)
        }
        start(request)
    }

    func setPairClean(_ on: Bool, from: String, to: String) {
        let pair = Pair(from: from, to: to)
        let request = state.withLock { state -> TimerRequest? in
            let had = state.pairs.contains(pair)
            guard had != on else { return nil }
            if on {
                state.pairs.append(pair)
                if state.pairs.count > Self.cap { state.pairs.removeFirst(state.pairs.count - Self.cap) }
            } else {
                state.pairs.removeAll { $0 == pair }
            }
            return changed(&state)
        }
        start(request)
    }

    /// Writes what is waiting now and returns once every earlier write has landed.
    func flush() {
        let cancel = state.withLock { state -> (@Sendable () -> Void)? in
            let cancel = cancelTimer(&state)
            if state.dirty { handOver(&state) }
            return cancel
        }
        cancel?()
        io.sync {}
    }

    /// Returns once every write handed over so far has finished.
    func waitForWrites() {
        io.sync {}
    }

    /// A flag changed (called with the state held): writes now after a quiet second, otherwise leaves one trailing write.
    /// Returns the timer to start once the lock is released: the scheduler is never called under it.
    private func changed(_ state: inout State) -> TimerRequest? {
        state.dirty = true
        if let last = state.lastWrite {
            let elapsed = now().timeIntervalSince(last)
            if elapsed >= 0, elapsed < Self.writeInterval {
                guard !state.armed else { return nil }
                state.armed = true
                state.timerID += 1
                return TimerRequest(id: state.timerID, delay: Self.writeInterval - elapsed)
            }
        }
        // The timer, if one is waiting, is left to find nothing dirty: its id goes stale here.
        state.armed = false
        state.timerID += 1
        let stale = state.cancelTimer
        state.cancelTimer = nil
        handOver(&state)
        if let stale { io.async { stale() } }
        return nil
    }

    // MARK: - Queue and timer

    /// Starts a timer reserved under the lock, outside it, and keeps its cancel if it is still the current one.
    private func start(_ request: TimerRequest?) {
        guard let request else { return }
        let cancel = scheduler.schedule(after: request.delay) { [weak self] in self?.timerFired(request.id) }
        let current = state.withLock { state -> Bool in
            guard state.armed, state.timerID == request.id else { return false }
            state.cancelTimer = cancel
            return true
        }
        if !current { cancel() }
    }

    /// Called with the state held. Returns the cancel of the timer that was waiting, to be called after the unlock.
    private func cancelTimer(_ state: inout State) -> (@Sendable () -> Void)? {
        let cancel = state.cancelTimer
        state.cancelTimer = nil
        state.armed = false
        state.timerID += 1
        return cancel
    }

    private func handOver(_ state: inout State) {
        state.dirty = false
        guard state.writable else { return }
        state.lastWrite = now()
        state.writes += 1
        let file = File(
            version: Self.version, cleanStart: state.cleanStart, pairs: state.pairs.map { [$0.from, $0.to] }
        )
        let url = fileURL
        io.async { Self.write(file, to: url) }
    }

    private func timerFired(_ id: Int) {
        state.withLock { state in
            guard state.armed, state.timerID == id else { return }
            state.armed = false
            state.cancelTimer = nil
            if state.dirty { handOver(&state) }
        }
    }

    // MARK: - Files (run on `io`)

    /// Reads the file. Only a file that is read but is not valid JSON of this shape is moved aside (to a `.bad` name with
    /// a timestamp, never deleted). A file that cannot be read (an I/O error) or has another version is left untouched and
    /// the store runs from memory with writes off for the session.
    private static func read(_ url: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return Loaded() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let kind = error as NSError
            logger.error("mix flags file unreadable, left as it is: \(kind.domain, privacy: .public) \(kind.code, privacy: .public)")
            return Loaded(writable: false)
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.pairs.allSatisfy({ $0.count == 2 }) else {
            logger.notice("mix flags file is not valid, moved aside")
            return Loaded(writable: moveAside(url))
        }
        guard file.version == version else {
            logger.notice("mix flags file has another version, left as it is")
            return Loaded(writable: false)
        }
        var seenIds = Set<String>()
        let ids = file.cleanStart.filter { seenIds.insert($0).inserted }
        var seenPairs = Set<Pair>()
        let pairs = file.pairs.map { Pair(from: $0[0], to: $0[1]) }.filter { seenPairs.insert($0).inserted }
        return Loaded(cleanStart: Array(ids.suffix(cap)), pairs: Array(pairs.suffix(cap)))
    }

    /// Moves a file that is not valid to `<name>.<seconds>.bad`. Returns false (and leaves it where it is) when the move
    /// fails: the original is never deleted.
    private static func moveAside(_ url: URL) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        var bad = url.appendingPathExtension("\(stamp)").appendingPathExtension("bad")
        var n = 1
        while FileManager.default.fileExists(atPath: bad.path) {
            bad = url.appendingPathExtension("\(stamp)-\(n)").appendingPathExtension("bad")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: bad)
            return true
        } catch {
            return false
        }
    }

    private static func write(_ file: File, to url: URL) {
        do {
            let data = try JSONEncoder().encode(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            let kind = error as NSError
            logger.error("mix flags write failed: \(kind.domain, privacy: .public) \(kind.code, privacy: .public)")
        }
    }
}
