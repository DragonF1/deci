import Foundation
import os

/// The "do not mix" choices of the listener, on disk: songs flagged "Always start clean" and pairs (one song into
/// another) flagged the same. One small JSON file next to the session file, `MusicMixFlags.json`:
/// `{"version":1,"cleanStart":["id"],"pairs":[["from","to"]]}`. It is not part of the analysis database on purpose: that
/// one is a cache that may be dropped, a choice of the listener must outlive it.
///
/// Reads are answered from memory. Writes are atomic and happen on a queue of their own, at most one a second (the first
/// change after a quiet second goes out at once, a burst leaves one trailing write), the way `MusicSessionStore` does
/// it. Each list keeps at most `cap` entries and drops the oldest. A file that cannot be read, or has another version, is
/// moved to `MusicMixFlags.json.bad` and the store starts empty: it never throws and never holds playback up.
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
        var cancelTimer: (@Sendable () -> Void)?
        var timerID = 0
        var writes = 0
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
        state.withLock { state in
            let had = state.cleanStart.contains(videoId)
            guard had != on else { return }
            if on {
                state.cleanStart.append(videoId)
                if state.cleanStart.count > Self.cap { state.cleanStart.removeFirst(state.cleanStart.count - Self.cap) }
            } else {
                state.cleanStart.removeAll { $0 == videoId }
            }
            changed(&state)
        }
    }

    func setPairClean(_ on: Bool, from: String, to: String) {
        let pair = Pair(from: from, to: to)
        state.withLock { state in
            let had = state.pairs.contains(pair)
            guard had != on else { return }
            if on {
                state.pairs.append(pair)
                if state.pairs.count > Self.cap { state.pairs.removeFirst(state.pairs.count - Self.cap) }
            } else {
                state.pairs.removeAll { $0 == pair }
            }
            changed(&state)
        }
    }

    /// Writes what is waiting now and returns once every earlier write has landed.
    func flush() {
        state.withLock { state in
            cancelTimer(&state)
            if state.dirty { handOver(&state) }
        }
        io.sync {}
    }

    /// Returns once every write handed over so far has finished.
    func waitForWrites() {
        io.sync {}
    }

    /// A flag changed (called with the state held): writes now after a quiet second, otherwise leaves one trailing write.
    private func changed(_ state: inout State) {
        state.dirty = true
        if let last = state.lastWrite {
            let elapsed = now().timeIntervalSince(last)
            if elapsed >= 0, elapsed < Self.writeInterval {
                if state.cancelTimer == nil { armTimer(after: Self.writeInterval - elapsed, &state) }
                return
            }
        }
        cancelTimer(&state)
        handOver(&state)
    }

    // MARK: - Queue and timer (called with the state held)

    private func handOver(_ state: inout State) {
        state.dirty = false
        state.lastWrite = now()
        state.writes += 1
        let file = File(
            version: Self.version, cleanStart: state.cleanStart, pairs: state.pairs.map { [$0.from, $0.to] }
        )
        let url = fileURL
        io.async { Self.write(file, to: url) }
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
            if state.dirty { handOver(&state) }
        }
    }

    // MARK: - Files (run on `io`)

    private static func read(_ url: URL) -> (cleanStart: [String], pairs: [Pair]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], []) }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == version,
              file.pairs.allSatisfy({ $0.count == 2 }) else {
            logger.notice("mix flags file unusable, moved aside")
            moveAside(url)
            return ([], [])
        }
        var seenIds = Set<String>()
        let ids = file.cleanStart.filter { seenIds.insert($0).inserted }
        var seenPairs = Set<Pair>()
        let pairs = file.pairs.map { Pair(from: $0[0], to: $0[1]) }.filter { seenPairs.insert($0).inserted }
        return (Array(ids.suffix(cap)), Array(pairs.suffix(cap)))
    }

    private static func moveAside(_ url: URL) {
        let bad = url.appendingPathExtension("bad")
        do {
            try? FileManager.default.removeItem(at: bad)
            try FileManager.default.moveItem(at: url, to: bad)
        } catch {
            try? FileManager.default.removeItem(at: url)
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
