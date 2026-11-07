// Deci/Music/Listening/MusicListeningStore.swift
// The listener's own history, kept on this Mac only: one row per song with its play count, the seconds heard and the
// first and last time it played. One SQLite file (system SQLite3, WAL, PRAGMA user_version) behind one actor, like the
// analysis database. Writes are noted in memory and reach the file in one transaction a few seconds later, so playback
// never waits on the disk. A store that cannot open answers nil and drops writes.

import Foundation
import os
import SQLite3

/// What is kept for one song.
struct MusicListeningEntry: Equatable, Sendable {
    let videoId: String
    let playCount: Int
    let totalSeconds: TimeInterval
    let firstPlayed: Date
    let lastPlayed: Date
}

/// When a stretch of listening is a play.
enum MusicListeningRules {
    /// Seconds heard that make a play, or half the song when that is less.
    static let playThreshold: TimeInterval = 30
    /// Less than this heard is noise (a skip on the first tick) and leaves no trace.
    static let minimumRecorded: TimeInterval = 1

    static func countsAsPlay(heardSeconds: TimeInterval, durationSeconds: TimeInterval?) -> Bool {
        guard heardSeconds.isFinite, heardSeconds > 0 else { return false }
        var needed = playThreshold
        if let duration = durationSeconds, duration.isFinite, duration > 0 { needed = min(needed, duration / 2) }
        return heardSeconds >= needed
    }
}

/// What the service needs of the listening history: a write that returns at once and a read of one song.
protocol MusicListeningRecording: Sendable {
    /// One session's listening, noted when the session ends. Never blocks.
    func note(videoId: String, seconds: TimeInterval, countsAsPlay: Bool, at date: Date)
    func entry(for videoId: String) async -> MusicListeningEntry?
    /// Writes what is still held, waiting a moment at most (the app is quitting).
    func flushNow()
}

actor MusicListeningStore: MusicListeningRecording {
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicListening")
    private static let schemaVersion: Int32 = 1

    /// `<Application Support>/Deci/Listening/Listening.sqlite`
    static func liveURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Deci/Listening/Listening.sqlite", isDirectory: false)
    }

    /// Listening noted and not yet written, merged per song.
    private struct Pending {
        var plays = 0
        var seconds: TimeInterval = 0
        var first: Date
        var last: Date
    }

    private struct Buffer {
        var pending: [String: Pending] = [:]
        var flushScheduled = false
    }

    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer?
        init(_ handle: OpaquePointer?) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }

    private nonisolated let buffer = OSAllocatedUnfairLock(initialState: Buffer())
    private nonisolated let debounce: Duration
    private let url: URL?
    private var connection: Connection?
    private var didOpen = false
    private var db: OpaquePointer? {
        openIfNeeded()
        return connection?.handle
    }

    /// `url` nil opens an in-memory database (tests). Nothing is opened until the first call that needs it.
    init(url: URL?, debounce: Duration = .seconds(5)) {
        self.url = url
        self.debounce = debounce
    }

    // MARK: - Writing

    nonisolated func note(videoId: String, seconds: TimeInterval, countsAsPlay: Bool, at date: Date) {
        guard MusicDownloadStore.isValidVideoId(videoId), seconds.isFinite, seconds >= MusicListeningRules.minimumRecorded else { return }
        let schedule = buffer.withLock { state -> Bool in
            var item = state.pending[videoId] ?? Pending(first: date, last: date)
            item.seconds += seconds
            if countsAsPlay { item.plays += 1 }
            item.first = min(item.first, date)
            item.last = max(item.last, date)
            state.pending[videoId] = item
            guard !state.flushScheduled else { return false }
            state.flushScheduled = true
            return true
        }
        guard schedule else { return }
        let wait = debounce
        Task { [self] in
            try? await Task.sleep(for: wait)
            await flush()
        }
    }

    /// Writes everything noted so far in one transaction. A failed write is dropped, never retried forever.
    func flush() {
        let batch = buffer.withLock { state -> [String: Pending] in
            let taken = state.pending
            state.pending = [:]
            state.flushScheduled = false
            return taken
        }
        guard !batch.isEmpty, let db else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        guard let statement = Statement(db, Self.upsertSQL) else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        for (id, item) in batch {
            statement.reset()
            statement.bind(id, at: 1)
            statement.bind(Int64(item.plays), at: 2)
            statement.bind(item.seconds, at: 3)
            statement.bind(item.first.timeIntervalSince1970, at: 4)
            statement.bind(item.last.timeIntervalSince1970, at: 5)
            guard statement.step() == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                Self.log.error("listening_flush failed code=\(sqlite3_errcode(db), privacy: .public)")
                return
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// For the quit path, which cannot await: the write runs on the actor and this waits for it up to a second.
    nonisolated func flushNow() {
        let done = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            await flush()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    // MARK: - Reading

    /// The row of a song, with anything still held for it counted in.
    func entry(for videoId: String) -> MusicListeningEntry? {
        flush()
        guard let db, MusicDownloadStore.isValidVideoId(videoId),
              let statement = Statement(db, "SELECT video_id, play_count, total_seconds, first_played, last_played FROM listening WHERE video_id = ?1")
        else { return nil }
        statement.bind(videoId, at: 1)
        guard statement.step() == SQLITE_ROW, let id = statement.text(0) else { return nil }
        return MusicListeningEntry(
            videoId: id,
            playCount: Int(statement.int(1)),
            totalSeconds: statement.double(2),
            firstPlayed: Date(timeIntervalSince1970: statement.double(3)),
            lastPlayed: Date(timeIntervalSince1970: statement.double(4))
        )
    }

    func count() -> Int {
        guard let db, let statement = Statement(db, "SELECT COUNT(*) FROM listening"), statement.step() == SQLITE_ROW else { return 0 }
        return Int(statement.int(0))
    }

    // MARK: - Open and migrate

    private func openIfNeeded() {
        guard !didOpen else { return }
        didOpen = true
        connection = Connection(Self.open(url: url))
    }

    private static let upsertSQL = """
    INSERT INTO listening (video_id, play_count, total_seconds, first_played, last_played) VALUES (?1, ?2, ?3, ?4, ?5)
    ON CONFLICT(video_id) DO UPDATE SET
      play_count = play_count + excluded.play_count,
      total_seconds = total_seconds + excluded.total_seconds,
      first_played = MIN(first_played, excluded.first_played),
      last_played = MAX(last_played, excluded.last_played)
    """

    private static func open(url: URL?) -> OpaquePointer? {
        guard let url else { return openFile(path: ":memory:") }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        if let db = openFile(path: url.path) { return db }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Present but unreadable: set it aside and start over.
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970))")
        do {
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: url, to: aside)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        } catch {
            return nil
        }
        return openFile(path: url.path)
    }

    private static func openFile(path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
        guard migrate(db) else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static func migrate(_ db: OpaquePointer) -> Bool {
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil) == SQLITE_OK,
              let probe = Statement(db, "PRAGMA user_version"), probe.step() == SQLITE_ROW else { return false }
        let version = sqlite3_column_int(probe.handle, 0)
        if version == 0 {
            let schema = """
            BEGIN;
            CREATE TABLE IF NOT EXISTS listening (
              video_id TEXT PRIMARY KEY NOT NULL,
              play_count INTEGER NOT NULL DEFAULT 0,
              total_seconds REAL NOT NULL DEFAULT 0,
              first_played REAL NOT NULL,
              last_played REAL NOT NULL
            ) WITHOUT ROWID;
            PRAGMA user_version = \(schemaVersion);
            COMMIT;
            """
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return false
            }
            return true
        }
        // A file from a newer build is left alone rather than misread.
        return version <= schemaVersion
    }
}

/// A prepared statement that finalizes itself. Parameter indexes are 1-based, column indexes 0-based.
private final class Statement {
    let handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(_ db: OpaquePointer, _ sql: String) {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK else {
            sqlite3_finalize(prepared)
            return nil
        }
        handle = prepared
    }

    deinit { sqlite3_finalize(handle) }

    func step() -> Int32 { sqlite3_step(handle) }
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }
    func bind(_ value: String, at index: Int32) { sqlite3_bind_text(handle, index, value, -1, Self.transient) }
    func bind(_ value: Int64, at index: Int32) { sqlite3_bind_int64(handle, index, value) }
    func bind(_ value: Double, at index: Int32) { sqlite3_bind_double(handle, index, value) }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func text(_ column: Int32) -> String? { sqlite3_column_text(handle, column).map { String(cString: $0) } }
}
