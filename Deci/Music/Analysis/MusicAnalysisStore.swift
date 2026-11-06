// Deci/Music/Analysis/MusicAnalysisStore.swift
// The analysis database: one SQLite file (system SQLite3, WAL, PRAGMA user_version) behind one actor.
// It never crashes and never blocks playback: an unreadable file is moved aside, and a store that
// cannot open answers nil and drops writes.

import Foundation
import os
import SQLite3

actor MusicAnalysisStore {
    enum Freshness: Equatable, Sendable { case missing, fresh, staleFormat, staleVersion }

    enum StoreError: Error, Equatable {
        case invalidVideoId
        case sqlite(Int32)
    }

    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicAnalysis")
    private static let schemaVersion: Int32 = 1
    /// `<Application Support>/Deci/Analysis/Analysis.sqlite`
    static func liveURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Deci/Analysis/Analysis.sqlite", isDirectory: false)
    }

    /// Owns the connection and closes it when the store goes away.
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer?
        init(_ handle: OpaquePointer?) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }

    private let connection: Connection
    private var db: OpaquePointer? { connection.handle }
    private let now: @Sendable () -> Date
    /// False after an open or migrate failure; reads return nil and writes are dropped.
    var isAvailable: Bool { db != nil }

    /// `url` nil opens an in-memory database (tests).
    init(url: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        let db = Self.open(url: url, now: now)
        connection = Connection(db)
        if let db {
            Self.log.notice("analysis_store_open ok=true rows=\(Self.rowCount(db), privacy: .public)")
        } else {
            Self.log.notice("analysis_store_open ok=false rows=0")
        }
    }

    // MARK: - Public

    func entry(for videoId: String) -> MusicAnalysis? {
        guard let db, MusicDownloadStore.isValidVideoId(videoId) else { return nil }
        guard let statement = Statement(db, "SELECT \(Self.columns) FROM analysis WHERE video_id = ?1") else { return nil }
        statement.bind(videoId, at: 1)
        guard statement.step() == SQLITE_ROW else { return nil }
        return Self.entry(from: statement)
    }

    func freshness(of videoId: String, matching format: MusicAnalysis.Format?) -> Freshness {
        guard let db, MusicDownloadStore.isValidVideoId(videoId),
              let statement = Statement(db, "SELECT analysis_version, codec, itag, duration_ms, energy FROM analysis WHERE video_id = ?1")
        else { return .missing }
        statement.bind(videoId, at: 1)
        guard statement.step() == SQLITE_ROW else { return .missing }
        let version = Int(statement.int(0))
        guard version == MusicAnalysis.currentVersion, MusicAnalysisPayload.decode(statement.data(4)) != nil else {
            return .staleVersion
        }
        guard let format else { return .fresh }
        let stored = MusicAnalysis.Format(codec: statement.text(1) ?? "", itag: Int(statement.int(2)), durationMs: Int(statement.int(3)))
        return stored.matches(format) ? .fresh : .staleFormat
    }

    /// INSERT or update; keeps `user_mix_point_ms` and `user_mix_point_at` of an existing row.
    func put(_ entry: MusicAnalysis) throws {
        try putAll([entry])
    }

    /// Several entries in one transaction: all or none.
    func putAll(_ entries: [MusicAnalysis]) throws {
        guard entries.allSatisfy({ MusicDownloadStore.isValidVideoId($0.videoId) }) else { throw StoreError.invalidVideoId }
        guard let db, !entries.isEmpty else { return }
        try exec(db, "BEGIN IMMEDIATE")
        do {
            guard let statement = Statement(db, Self.upsertSQL) else { throw StoreError.sqlite(sqlite3_errcode(db)) }
            let stamp = now().timeIntervalSince1970
            for entry in entries {
                statement.reset()
                Self.bind(entry, to: statement, stamp: stamp)
                let code = statement.step()
                guard code == SQLITE_DONE else { throw StoreError.sqlite(code) }
            }
            try exec(db, "COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Deletes the row (tests, "re-analyse").
    func invalidate(videoId: String) {
        guard let db, MusicDownloadStore.isValidVideoId(videoId),
              let statement = Statement(db, "DELETE FROM analysis WHERE video_id = ?1") else { return }
        statement.bind(videoId, at: 1)
        _ = statement.step()
    }

    /// Ids whose analysis version is below the current one, oldest analysis first.
    func staleVideoIds(limit: Int) -> [String] {
        guard let db, limit > 0,
              let statement = Statement(db, "SELECT video_id FROM analysis WHERE analysis_version < ?1 ORDER BY analyzed_at ASC, video_id ASC LIMIT ?2")
        else { return [] }
        statement.bind(Int64(MusicAnalysis.currentVersion), at: 1)
        statement.bind(Int64(limit), at: 2)
        var ids: [String] = []
        while statement.step() == SQLITE_ROW { if let id = statement.text(0) { ids.append(id) } }
        return ids
    }

    /// Reserved for a later tier; no UI uses it yet. Does nothing for a song with no row.
    func setUserMixPoint(videoId: String, ms: Int?) throws {
        guard MusicDownloadStore.isValidVideoId(videoId) else { throw StoreError.invalidVideoId }
        guard let db,
              let statement = Statement(db, "UPDATE analysis SET user_mix_point_ms = ?2, user_mix_point_at = ?3 WHERE video_id = ?1")
        else { return }
        statement.bind(videoId, at: 1)
        if let ms {
            statement.bind(Int64(ms), at: 2)
            statement.bind(now().timeIntervalSince1970, at: 3)
        } else {
            statement.bindNull(at: 2)
            statement.bindNull(at: 3)
        }
        let code = statement.step()
        guard code == SQLITE_DONE else { throw StoreError.sqlite(code) }
    }

    func count() -> Int {
        guard let db else { return 0 }
        return Self.rowCount(db)
    }

    // MARK: - Open and migrate

    private static func open(url: URL?, now: @Sendable () -> Date) -> OpaquePointer? {
        guard let url else { return openFile(path: ":memory:") }
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        } catch {
            return nil
        }
        log.notice("analysis_store_reset why=corrupt")
        return openFile(path: url.path)
    }

    /// Opens and migrates; nil (and closed) on any failure.
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
        // The first statement that reads the file is where garbage is detected.
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil) == SQLITE_OK,
              let version = userVersion(db) else { return false }
        if version == 0 {
            let schema = """
            BEGIN;
            CREATE TABLE IF NOT EXISTS analysis (
              video_id TEXT PRIMARY KEY NOT NULL,
              analysis_version INTEGER NOT NULL,
              codec TEXT NOT NULL DEFAULT '',
              itag INTEGER NOT NULL DEFAULT 0,
              duration_ms INTEGER NOT NULL,
              analyzed_at REAL NOT NULL,
              source TEXT NOT NULL,
              silence_start_ms INTEGER NOT NULL,
              silence_end_ms INTEGER NOT NULL,
              intro_end_ms INTEGER NOT NULL,
              outro_start_ms INTEGER NOT NULL,
              integrated_lufs REAL,
              sample_peak_db REAL NOT NULL,
              intro_lufs REAL,
              outro_lufs REAL,
              yt_loudness_db REAL,
              yt_perceptual_db REAL,
              energy BLOB NOT NULL,
              beat_grid BLOB,
              key_info BLOB,
              user_mix_point_ms INTEGER,
              user_mix_point_at REAL
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS analysis_version_idx ON analysis(analysis_version);
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

    private static func userVersion(_ db: OpaquePointer) -> Int32? {
        guard let statement = Statement(db, "PRAGMA user_version"), statement.step() == SQLITE_ROW else { return nil }
        return statement.int32(0)
    }

    private static func rowCount(_ db: OpaquePointer) -> Int {
        guard let statement = Statement(db, "SELECT COUNT(*) FROM analysis"), statement.step() == SQLITE_ROW else { return 0 }
        return Int(statement.int(0))
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw StoreError.sqlite(code) }
    }

    // MARK: - Rows

    private static let columns = """
    video_id, analysis_version, codec, itag, duration_ms, analyzed_at, source, silence_start_ms, silence_end_ms, \
    intro_end_ms, outro_start_ms, integrated_lufs, sample_peak_db, intro_lufs, outro_lufs, yt_loudness_db, \
    yt_perceptual_db, energy, beat_grid, key_info, user_mix_point_ms
    """

    private static let upsertSQL = """
    INSERT INTO analysis (\(columns), user_mix_point_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)
    ON CONFLICT(video_id) DO UPDATE SET
      analysis_version = excluded.analysis_version, codec = excluded.codec, itag = excluded.itag,
      duration_ms = excluded.duration_ms, analyzed_at = excluded.analyzed_at, source = excluded.source,
      silence_start_ms = excluded.silence_start_ms, silence_end_ms = excluded.silence_end_ms,
      intro_end_ms = excluded.intro_end_ms, outro_start_ms = excluded.outro_start_ms,
      integrated_lufs = excluded.integrated_lufs, sample_peak_db = excluded.sample_peak_db,
      intro_lufs = excluded.intro_lufs, outro_lufs = excluded.outro_lufs,
      yt_loudness_db = excluded.yt_loudness_db, yt_perceptual_db = excluded.yt_perceptual_db,
      energy = excluded.energy, beat_grid = excluded.beat_grid, key_info = excluded.key_info
    """

    private static func ms(_ seconds: Double) -> Int64 {
        seconds.isFinite ? Int64((seconds * 1000).rounded()) : 0
    }

    private static func bind(_ entry: MusicAnalysis, to s: Statement, stamp: Double) {
        s.bind(entry.videoId, at: 1)
        s.bind(Int64(entry.version), at: 2)
        s.bind(entry.format.codec, at: 3)
        s.bind(Int64(entry.format.itag), at: 4)
        s.bind(Int64(entry.format.durationMs), at: 5)
        s.bind(entry.analyzedAt.timeIntervalSince1970, at: 6)
        s.bind(entry.source.rawValue, at: 7)
        s.bind(ms(entry.silenceStart), at: 8)
        s.bind(ms(entry.silenceEnd), at: 9)
        s.bind(ms(entry.introEnd), at: 10)
        s.bind(ms(entry.outroStart), at: 11)
        s.bind(finite: entry.integratedLUFS, at: 12)
        s.bind(entry.samplePeakDb.isFinite ? max(entry.samplePeakDb, -200) : -200, at: 13)
        s.bind(finite: entry.introLUFS, at: 14)
        s.bind(finite: entry.outroLUFS, at: 15)
        s.bind(finite: entry.youtubeLoudnessDb, at: 16)
        s.bind(finite: entry.youtubePerceptualLoudnessDb, at: 17)
        s.bind(MusicAnalysisPayload.encode(entry.energy), at: 18)
        s.bind(optional: entry.beatGrid, at: 19)
        s.bind(optional: entry.keyInfo, at: 20)
        if let point = entry.userMixPointMs {
            s.bind(Int64(point), at: 21)
            s.bind(stamp, at: 22)
        } else {
            s.bindNull(at: 21)
            s.bindNull(at: 22)
        }
    }

    /// nil when the energy payload is not one this build can read.
    private static func entry(from s: Statement) -> MusicAnalysis? {
        guard let id = s.text(0), let energy = MusicAnalysisPayload.decode(s.data(17)),
              let source = MusicAnalysis.Source(rawValue: s.text(6) ?? "") else { return nil }
        return MusicAnalysis(
            videoId: id,
            version: Int(s.int(1)),
            format: .init(codec: s.text(2) ?? "", itag: Int(s.int(3)), durationMs: Int(s.int(4))),
            analyzedAt: Date(timeIntervalSince1970: s.double(5)),
            source: source,
            silenceStart: Double(s.int(7)) / 1000,
            silenceEnd: Double(s.int(8)) / 1000,
            introEnd: Double(s.int(9)) / 1000,
            outroStart: Double(s.int(10)) / 1000,
            integratedLUFS: s.optionalDouble(11) ?? -.infinity,
            samplePeakDb: s.double(12),
            introLUFS: s.optionalDouble(13),
            outroLUFS: s.optionalDouble(14),
            energy: energy,
            youtubeLoudnessDb: s.optionalDouble(15),
            youtubePerceptualLoudnessDb: s.optionalDouble(16),
            beatGrid: s.isNull(18) ? nil : s.data(18),
            keyInfo: s.isNull(19) ? nil : s.data(19),
            userMixPointMs: s.isNull(20) ? nil : Int(s.int(20))
        )
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
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func bind(_ value: String, at index: Int32) { sqlite3_bind_text(handle, index, value, -1, Self.transient) }
    func bind(_ value: Int64, at index: Int32) { sqlite3_bind_int64(handle, index, value) }
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
    /// NULL for nil, NaN and infinity.
    func bind(finite value: Double?, at index: Int32) {
        if let value, value.isFinite { bind(value, at: index) } else { bindNull(at: index) }
    }
    func bind(optional value: Data?, at index: Int32) {
        if let value { bind(value, at: index) } else { bindNull(at: index) }
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func int32(_ column: Int32) -> Int32 { sqlite3_column_int(handle, column) }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
    func text(_ column: Int32) -> String? {
        sqlite3_column_text(handle, column).map { String(cString: $0) }
    }
    func data(_ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let raw = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: raw, count: count)
    }
}
