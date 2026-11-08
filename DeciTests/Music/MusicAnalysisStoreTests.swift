// DeciTests/Music/MusicAnalysisStoreTests.swift
// The analysis database: an in-memory store for the logic, temp files under the SSD test folder for persistence.

import Foundation
import SQLite3
import Testing
@testable import Deci

@MainActor
@Suite("MusicAnalysisStore")
struct MusicAnalysisStoreTests {

    private static let id = "4D7u5KF7SP8"

    private static func sample(
        id: String = MusicAnalysisStoreTests.id,
        version: Int = MusicAnalysis.currentVersion,
        itag: Int = 140,
        durationMs: Int = 369_626,
        codec: String = "mp4a.40.2",
        analyzedAt: Double = 1_700_000_000.5
    ) -> MusicAnalysis {
        MusicAnalysis(
            videoId: id,
            version: version,
            format: .init(codec: codec, itag: itag, durationMs: durationMs),
            analyzedAt: Date(timeIntervalSince1970: analyzedAt),
            source: .backgroundCache,
            silenceStart: 0.25,
            silenceEnd: 369.5,
            introEnd: 6.125,
            outroStart: 350.75,
            integratedLUFS: -11.4,
            samplePeakDb: -0.3,
            introLUFS: -18.2,
            outroLUFS: nil,
            energy: [0, 1, 90, 180, 77, 255],
            youtubeLoudnessDb: -6.3,
            youtubePerceptualLoudnessDb: -4.1,
            beatGrid: Data([9, 8, 7]),
            keyInfo: Data([1]),
            userMixPointMs: nil
        )
    }

    /// A fresh folder under the SSD test area, removed by the caller.
    private func makeFolder() -> URL {
        let url = URL(fileURLWithPath: "/Volumes/Storage/_test/deci-2a/store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Round trip

    @Test("Every column survives a put and a get")
    func roundTrip() async throws {
        let store = MusicAnalysisStore(url: nil)
        let entry = Self.sample()
        try await store.put(entry)
        #expect(await store.entry(for: Self.id) == entry)
        #expect(await store.count() == 1)
    }

    @Test("A v5 key payload survives the store and decodes; a v4 row with the same bytes reads as no key")
    func keyInfoBlob() async throws {
        let store = MusicAnalysisStore(url: nil)
        let info = MusicKeyInfo(tonic: 9, isMinor: true, confidence: 0.5, energy: 0.6)
        var row = Self.sample()
        row.keyInfo = info.encode()
        try await store.put(row)
        let back = try #require(await store.entry(for: Self.id))
        #expect(back.keyInfoValue == info)
        var old = back
        old.version = 4
        #expect(old.keyInfoValue == nil)
        var none = back
        none.keyInfo = nil
        #expect(none.keyInfoValue == nil)
        #expect(Self.sample().keyInfoValue == nil, "garbage bytes decode to nil")
    }

    @Test("A real beat grid survives the BLOB, and a v1 row without one still loads and reports staleVersion")
    func beatGridBlob() async throws {
        let store = MusicAnalysisStore(url: nil)
        var entry = Self.sample()
        entry.beatGrid = MusicBeatGridTests.sample().encode()
        try await store.put(entry)
        let back = try #require(await store.entry(for: Self.id))
        #expect(back.usableGrid == MusicBeatGridTests.sample())
        #expect(await store.freshness(of: Self.id, matching: nil) == .fresh)

        var old = Self.sample(version: 1)
        old.beatGrid = nil
        try await store.put(old)
        let row = try #require(await store.entry(for: Self.id))
        #expect(row.version == 1 && row.usableGrid == nil)
        #expect(await store.freshness(of: Self.id, matching: nil) == .staleVersion)
        #expect(await store.staleVideoIds(limit: 10) == [Self.id])
    }

    @Test("A v1 row cannot lend a grid even when the BLOB decodes")
    func v1GridIsIgnored() {
        var entry = Self.sample(version: 1)
        entry.beatGrid = MusicBeatGridTests.sample().encode()
        #expect(entry.usableGrid == nil)
        entry.version = 2
        #expect(entry.usableGrid != nil)
        entry.beatGrid = Data([1, 2, 3])
        #expect(entry.usableGrid == nil)
    }

    @Test("An all-gated song stores a NULL integrated loudness and reads back as minus infinity")
    func gatedLoudness() async throws {
        let store = MusicAnalysisStore(url: nil)
        var entry = Self.sample()
        entry.integratedLUFS = -.infinity
        try await store.put(entry)
        #expect(await store.entry(for: Self.id)?.integratedLUFS == -.infinity)
    }

    @Test("A sample peak of minus infinity (digital silence) is clamped, not lost")
    func silentPeak() async throws {
        let store = MusicAnalysisStore(url: nil)
        var entry = Self.sample()
        entry.samplePeakDb = -.infinity
        try await store.put(entry)
        let peak = try #require(await store.entry(for: Self.id)?.samplePeakDb)
        #expect(peak.isFinite && peak <= -100)
    }

    @Test("An unknown video id reads as nil")
    func unknown() async {
        let store = MusicAnalysisStore(url: nil)
        #expect(await store.entry(for: "AAAAAAAAAAA") == nil)
    }

    @Test("Putting the same id twice replaces the row")
    func putTwiceReplaces() async throws {
        let store = MusicAnalysisStore(url: nil)
        try await store.put(Self.sample(itag: 140))
        var second = Self.sample(itag: 141)
        second.introEnd = 9
        second.beatGrid = nil
        try await store.put(second)
        #expect(await store.count() == 1)
        let stored = try #require(await store.entry(for: Self.id))
        #expect(stored.format.itag == 141)
        #expect(stored.introEnd == 9)
        #expect(stored.beatGrid == nil)
    }

    @Test("A re-analysis keeps the user's mix point")
    func putKeepsMixPoint() async throws {
        let store = MusicAnalysisStore(url: nil)
        try await store.put(Self.sample())
        try await store.setUserMixPoint(videoId: Self.id, ms: 212_000)
        try await store.put(Self.sample(itag: 141))
        let stored = try #require(await store.entry(for: Self.id))
        #expect(stored.userMixPointMs == 212_000)
        #expect(stored.format.itag == 141)

        try await store.setUserMixPoint(videoId: Self.id, ms: nil)
        #expect(await store.entry(for: Self.id)?.userMixPointMs == nil)
    }

    @Test("Setting a mix point for a song with no row does nothing")
    func mixPointWithoutRow() async throws {
        let store = MusicAnalysisStore(url: nil)
        try await store.setUserMixPoint(videoId: Self.id, ms: 5)
        #expect(await store.count() == 0)
    }

    @Test("invalidate deletes the row")
    func invalidate() async throws {
        let store = MusicAnalysisStore(url: nil)
        try await store.put(Self.sample())
        await store.invalidate(videoId: Self.id)
        #expect(await store.entry(for: Self.id) == nil)
        #expect(await store.freshness(of: Self.id, matching: nil) == .missing)
    }

    // MARK: - Freshness

    @Test("Missing, then fresh when the format matches")
    func missingThenFresh() async throws {
        let store = MusicAnalysisStore(url: nil)
        let format = MusicAnalysis.Format(codec: "mp4a.40.2", itag: 140, durationMs: 369_626)
        #expect(await store.freshness(of: Self.id, matching: format) == .missing)
        try await store.put(Self.sample())
        #expect(await store.freshness(of: Self.id, matching: format) == .fresh)
        #expect(await store.freshness(of: Self.id, matching: nil) == .fresh)
    }

    @Test("A different itag, a duration 2 ms off, or another codec is staleFormat")
    func staleFormat() async throws {
        let store = MusicAnalysisStore(url: nil)
        try await store.put(Self.sample())
        func check(_ format: MusicAnalysis.Format) async -> MusicAnalysisStore.Freshness {
            await store.freshness(of: Self.id, matching: format)
        }
        #expect(await check(.init(codec: "mp4a.40.2", itag: 141, durationMs: 369_626)) == .staleFormat)
        #expect(await check(.init(codec: "mp4a.40.2", itag: 140, durationMs: 369_628)) == .staleFormat)
        #expect(await check(.init(codec: "mp4a.40.2", itag: 140, durationMs: 369_624)) == .staleFormat)
        #expect(await check(.init(codec: "opus", itag: 140, durationMs: 369_626)) == .staleFormat)
    }

    @Test("A 1 ms duration difference, itag 0 and an empty or differently cased codec still match")
    func lenientMatches() async throws {
        let store = MusicAnalysisStore(url: nil)
        try await store.put(Self.sample())
        func check(_ format: MusicAnalysis.Format) async -> MusicAnalysisStore.Freshness {
            await store.freshness(of: Self.id, matching: format)
        }
        #expect(await check(.init(codec: "mp4a.40.2", itag: 140, durationMs: 369_627)) == .fresh)
        #expect(await check(.init(codec: "mp4a.40.2", itag: 0, durationMs: 369_626)) == .fresh)
        #expect(await check(.init(codec: "", itag: 251, durationMs: 369_626)) == .staleFormat)
        #expect(await check(.init(codec: "", itag: 0, durationMs: 369_626)) == .fresh)
        #expect(await check(.init(codec: "MP4A.40.2", itag: 140, durationMs: 369_626)) == .fresh)
    }

    @Test("A stored itag of 0 (a downloaded file) matches any itag")
    func storedItagZero() async throws {
        let store = MusicAnalysisStore(url: nil)
        try await store.put(Self.sample(itag: 0))
        #expect(await store.freshness(of: Self.id, matching: .init(codec: "mp4a.40.2", itag: 141, durationMs: 369_626)) == .fresh)
    }

    @Test("An older analysis version is staleVersion, and wins over a format mismatch")
    func staleVersion() async throws {
        let store = MusicAnalysisStore(url: nil)
        try await store.put(Self.sample(version: MusicAnalysis.currentVersion - 1))
        #expect(await store.freshness(of: Self.id, matching: nil) == .staleVersion)
        #expect(await store.freshness(of: Self.id, matching: .init(codec: "opus", itag: 1, durationMs: 1)) == .staleVersion)
        #expect(await store.entry(for: Self.id) != nil)
    }

    @Test("An energy payload with an unknown version counts as staleVersion")
    func unknownPayload() async throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Analysis.sqlite")
        let store = MusicAnalysisStore(url: url)
        try await store.put(Self.sample())

        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "UPDATE analysis SET energy = x'0900000000'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(await store.freshness(of: Self.id, matching: nil) == .staleVersion)
        #expect(await store.entry(for: Self.id) == nil)
    }

    // MARK: - staleVideoIds

    @Test("staleVideoIds lists only old versions, oldest analysis first, up to the limit")
    func staleIds() async throws {
        let store = MusicAnalysisStore(url: nil)
        let old = MusicAnalysis.currentVersion - 1
        try await store.put(Self.sample(id: "AAAAAAAAAAA", version: old, analyzedAt: 300))
        try await store.put(Self.sample(id: "BBBBBBBBBBB", version: old, analyzedAt: 100))
        try await store.put(Self.sample(id: "CCCCCCCCCCC", version: old, analyzedAt: 200))
        try await store.put(Self.sample(id: "DDDDDDDDDDD", analyzedAt: 50))
        #expect(await store.staleVideoIds(limit: 10) == ["BBBBBBBBBBB", "CCCCCCCCCCC", "AAAAAAAAAAA"])
        #expect(await store.staleVideoIds(limit: 2) == ["BBBBBBBBBBB", "CCCCCCCCCCC"])
        #expect(await store.staleVideoIds(limit: 0) == [])
    }

    // MARK: - Files

    @Test("Rows persist across a reopen, and the folder is private to the owner")
    func reopen() async throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Nested/Analysis.sqlite")
        let entry = Self.sample()
        do {
            let store = MusicAnalysisStore(url: url)
            try await store.put(entry)
        }
        let again = MusicAnalysisStore(url: url)
        #expect(await again.isAvailable)
        #expect(await again.entry(for: Self.id) == entry)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? Int ?? 0) & 0o077 == 0)
    }

    @Test("Creating a store touches no file: it opens on first use")
    func opensLazily() async throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        let url = nested.appendingPathComponent("Analysis.sqlite")

        let store = MusicAnalysisStore(url: url)
        #expect(!FileManager.default.fileExists(atPath: nested.path), "init must not open or create anything")

        #expect(await store.isAvailable)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("The file runs in WAL mode with user_version 1")
    func pragmas() async throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Analysis.sqlite")
        let store = MusicAnalysisStore(url: url)
        try await store.put(Self.sample())

        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func text(_ sql: String) -> String {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
                  let raw = sqlite3_column_text(statement, 0) else { return "" }
            return String(cString: raw)
        }
        #expect(text("PRAGMA journal_mode") == "wal")
        #expect(text("PRAGMA user_version") == "1")
    }

    @Test("A garbage file is moved aside and a fresh store works")
    func garbageFile() async throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Analysis.sqlite")
        try Data(repeating: 0x41, count: 4096).write(to: url)

        let store = MusicAnalysisStore(url: url)
        #expect(await store.isAvailable)
        try await store.put(Self.sample())
        #expect(await store.entry(for: Self.id) != nil)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("Analysis.sqlite.unreadable-") })
    }

    @Test("An unwritable location makes the store unavailable: reads are nil and put does not throw")
    func unavailable() async throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocker = folder.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)

        let store = MusicAnalysisStore(url: blocker.appendingPathComponent("sub/Analysis.sqlite"))
        #expect(await store.isAvailable == false)
        try await store.put(Self.sample())
        #expect(await store.entry(for: Self.id) == nil)
        #expect(await store.count() == 0)
        #expect(await store.freshness(of: Self.id, matching: nil) == .missing)
        #expect(await store.staleVideoIds(limit: 5) == [])
        await store.invalidate(videoId: Self.id)
    }

    // MARK: - Hostile ids

    @Test("An id with a quote or a semicolon is rejected and nothing runs")
    func hostileIds() async throws {
        let store = MusicAnalysisStore(url: nil)
        try await store.put(Self.sample())
        for bad in ["x'; DROP TABLE analysis;--", "AAAAAAAAAA'", "AAAAAAAAAA;", "", "short", "../../etc/pw"] {
            await #expect(throws: MusicAnalysisStore.StoreError.invalidVideoId) { try await store.put(Self.sample(id: bad)) }
            #expect(await store.entry(for: bad) == nil)
            #expect(await store.freshness(of: bad, matching: nil) == .missing)
            await #expect(throws: MusicAnalysisStore.StoreError.invalidVideoId) { try await store.setUserMixPoint(videoId: bad, ms: 1) }
            await store.invalidate(videoId: bad)
        }
        #expect(await store.count() == 1)
        #expect(await store.entry(for: Self.id) != nil)
    }

    // MARK: - Volume

    @Test("5000 rows go in as one transaction in well under 5 seconds")
    func bulk() async throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MusicAnalysisStore(url: folder.appendingPathComponent("Analysis.sqlite"))
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let entries = (0..<5000).map { index -> MusicAnalysis in
            let suffix = String(index).padding(toLength: 5, withPad: "_", startingAt: 0)
            return Self.sample(id: "id" + String(alphabet[index % alphabet.count]) + "xxxx" + suffix.prefix(4), analyzedAt: Double(index))
        }
        #expect(Set(entries.map(\.videoId)).count == 5000)
        let start = Date()
        try await store.putAll(entries)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(await store.count() == 5000)
    }

    @Test("A batch with one bad id writes nothing")
    func batchIsAtomic() async throws {
        let store = MusicAnalysisStore(url: nil)
        await #expect(throws: MusicAnalysisStore.StoreError.invalidVideoId) {
            try await store.putAll([Self.sample(), Self.sample(id: "bad id")])
        }
        #expect(await store.count() == 0)
    }
}
