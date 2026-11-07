// Deci/Music/SongFacts/MusicSongFactsStore.swift
// The song facts cache: one SQLite file (system SQLite3, WAL, PRAGMA user_version) behind one actor, beside the analysis
// database in Application Support/Deci/Analysis and built the same way. It never crashes and never blocks the panel:
// an unreadable file is moved aside, and a store that cannot open answers nil and drops writes.

import Foundation
import os
import SQLite3

/// One cached song: the facts, how the last lookup ended, and whether Deci measured the tempo itself.
struct MusicSongFactsRecord: Sendable, Equatable {
    enum Outcome: String, Sendable {
        /// Found, with every step answered. Kept for good.
        case hit
        /// Found, but a step could not be asked. Asked again after a day.
        case partial
        /// The services know nothing of the song. Asked again after 30 days.
        case miss
        /// The services were never asked (only a measurement is stored).
        case none
    }

    /// How long a miss is believed.
    static let missTTL: TimeInterval = 30 * 86_400
    static let partialTTL: TimeInterval = 86_400

    var facts: MusicSongFacts
    var outcome: Outcome
    var lookedUpAt: Date?
    /// When Deci's own tempo measurement finished, with or without a usable tempo; nil if it never ran to the end.
    var measuredAt: Date?

    /// The cache answers the lookup without the network.
    func isLookupFresh(at now: Date) -> Bool {
        guard let lookedUpAt else { return false }
        switch outcome {
        case .hit: return true
        case .partial: return now.timeIntervalSince(lookedUpAt) < Self.partialTTL
        case .miss: return now.timeIntervalSince(lookedUpAt) < Self.missTTL
        case .none: return false
        }
    }
}

actor MusicSongFactsStore {
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicSongFacts")
    private static let schemaVersion: Int32 = 1

    /// `<Application Support>/Deci/Analysis/SongFacts.sqlite`
    static func liveURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Deci/Analysis/SongFacts.sqlite", isDirectory: false)
    }

    /// Owns the connection and closes it when the store goes away.
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer?
        init(_ handle: OpaquePointer?) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }

    private var connection: Connection?
    private var didOpen = false
    private let url: URL?
    private let now: @Sendable () -> Date
    private var db: OpaquePointer? {
        openIfNeeded()
        return connection?.handle
    }

    /// `url` nil opens an in-memory database (tests). Nothing is opened until the first call that needs it.
    init(url: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    private func openIfNeeded() {
        guard !didOpen else { return }
        didOpen = true
        connection = Connection(Self.open(url: url, now: now))
    }

    // MARK: - Public

    func record(for videoId: String) -> MusicSongFactsRecord? {
        guard let db, MusicDownloadStore.isValidVideoId(videoId),
              let statement = Statement(db, "SELECT outcome, looked_up_at, measured_at, payload FROM facts WHERE video_id = ?1")
        else { return nil }
        statement.bind(videoId, at: 1)
        guard statement.step() == SQLITE_ROW else { return nil }
        return Self.record(from: statement)
    }

    /// Stores what a lookup found. A failed lookup stores nothing. A tempo Deci measured earlier is kept when the
    /// services have none, and the time of that measurement stays.
    func putLookup(videoId: String, _ lookup: MusicSongFactsLookup) {
        let outcome: MusicSongFactsRecord.Outcome
        var facts: MusicSongFacts
        switch lookup {
        case .failed: return
        case .found(let found): outcome = .hit; facts = found
        case .partial(let found): outcome = .partial; facts = found
        case .notFound: outcome = .miss; facts = MusicSongFacts(fetchedAt: now())
        }
        let existing = record(for: videoId)
        if let tempo = existing?.facts.bpm, existing?.facts.source(of: .bpm) == .deci {
            facts.setMeasuredTempo(bpm: tempo, confidence: existing?.facts.bpmConfidence ?? 0)
        }
        write(MusicSongFactsRecord(facts: facts, outcome: outcome, lookedUpAt: now(), measuredAt: existing?.measuredAt), videoId: videoId)
    }

    /// Stores the end of a measurement: the tempo when there is one, and in any case that it ran, so the song is not
    /// downloaded again for it. A tempo from an outside service is never replaced.
    func putMeasured(videoId: String, bpm: Double?, confidence: Double?) {
        var current = record(for: videoId)
            ?? MusicSongFactsRecord(facts: MusicSongFacts(fetchedAt: now()), outcome: .none, lookedUpAt: nil, measuredAt: nil)
        if let bpm, bpm.isFinite, bpm > 0 { current.facts.setMeasuredTempo(bpm: bpm, confidence: confidence ?? 0) }
        current.measuredAt = now()
        write(current, videoId: videoId)
    }

    func delete(videoId: String) {
        guard let db, MusicDownloadStore.isValidVideoId(videoId),
              let statement = Statement(db, "DELETE FROM facts WHERE video_id = ?1") else { return }
        statement.bind(videoId, at: 1)
        _ = statement.step()
    }

    func count() -> Int {
        guard let db, let statement = Statement(db, "SELECT COUNT(*) FROM facts"), statement.step() == SQLITE_ROW else { return 0 }
        return Int(statement.int(0))
    }

    // MARK: - Rows

    private func write(_ record: MusicSongFactsRecord, videoId: String) {
        guard let db, MusicDownloadStore.isValidVideoId(videoId),
              let payload = try? JSONEncoder().encode(record.facts),
              let statement = Statement(db, """
              INSERT INTO facts (video_id, outcome, looked_up_at, measured_at, payload) VALUES (?1, ?2, ?3, ?4, ?5)
              ON CONFLICT(video_id) DO UPDATE SET outcome = excluded.outcome, looked_up_at = excluded.looked_up_at,
                measured_at = excluded.measured_at, payload = excluded.payload
              """) else { return }
        statement.bind(videoId, at: 1)
        statement.bind(record.outcome.rawValue, at: 2)
        if let at = record.lookedUpAt { statement.bind(at.timeIntervalSince1970, at: 3) } else { statement.bindNull(at: 3) }
        if let at = record.measuredAt { statement.bind(at.timeIntervalSince1970, at: 4) } else { statement.bindNull(at: 4) }
        statement.bind(payload, at: 5)
        let code = statement.step()
        if code != SQLITE_DONE { Self.log.error("songfacts_store_write failed code=\(code, privacy: .public)") }
    }

    /// nil when the payload is not one this build can read.
    private static func record(from s: Statement) -> MusicSongFactsRecord? {
        guard let outcome = MusicSongFactsRecord.Outcome(rawValue: s.text(0) ?? ""),
              let facts = try? JSONDecoder().decode(MusicSongFacts.self, from: s.data(3)) else { return nil }
        return MusicSongFactsRecord(
            facts: facts, outcome: outcome,
            lookedUpAt: s.optionalDouble(1).map { Date(timeIntervalSince1970: $0) },
            measuredAt: s.optionalDouble(2).map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: - Open and migrate

    private static func open(url: URL?, now: @Sendable () -> Date) -> OpaquePointer? {
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
            .appendingPathComponent("\(url.lastPathComponent).unreadable-\(Int(now().timeIntervalSince1970))")
        do {
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: url, to: aside)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        } catch {
            return nil
        }
        log.notice("songfacts_store_reset why=corrupt")
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
              let statement = Statement(db, "PRAGMA user_version"), statement.step() == SQLITE_ROW else { return false }
        let version = statement.int32(0)
        if version == 0 {
            let schema = """
            BEGIN;
            CREATE TABLE IF NOT EXISTS facts (
              video_id TEXT PRIMARY KEY NOT NULL,
              outcome TEXT NOT NULL,
              looked_up_at REAL,
              measured_at REAL,
              payload BLOB NOT NULL
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
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(_ db: OpaquePointer, _ sql: String) {
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK else {
            sqlite3_finalize(handle)
            return nil
        }
    }

    deinit { sqlite3_finalize(handle) }

    func step() -> Int32 { sqlite3_step(handle) }
    func bind(_ value: String, at index: Int32) { sqlite3_bind_text(handle, index, value, -1, Self.transient) }
    func bind(_ value: Double, at index: Int32) { sqlite3_bind_double(handle, index, value) }
    func bindNull(at index: Int32) { sqlite3_bind_null(handle, index) }
    func bind(_ value: Data, at index: Int32) {
        value.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                sqlite3_bind_blob(handle, index, base, Int32(value.count), Self.transient)
            } else {
                sqlite3_bind_zeroblob(handle, index, 0)
            }
        }
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func int32(_ column: Int32) -> Int32 { sqlite3_column_int(handle, column) }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(handle, column) }
    func text(_ column: Int32) -> String? { sqlite3_column_text(handle, column).map { String(cString: $0) } }
    func data(_ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let raw = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: raw, count: count)
    }
}
