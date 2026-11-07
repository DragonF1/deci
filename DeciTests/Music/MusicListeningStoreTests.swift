// DeciTests/Music/MusicListeningStoreTests.swift
// The local listening history: the play threshold as a pure function, the SQLite store on a temp database, and the
// panel's YOUR LISTENING rows.

import Foundation
import SQLite3
import Testing
@testable import Deci

@MainActor
@Suite("MusicListeningRules")
struct MusicListeningRulesTests {
    @Test("a play is 30 s heard, or half of a song shorter than a minute", arguments: [
        (29.5, 200.0, false),
        (30.0, 200.0, true),
        (45.0, 200.0, true),
        (14.5, 30.0, false),
        (15.0, 30.0, true),
        (9.9, 20.0, false),
        (10.0, 20.0, true),
        (30.0, 61.0, true),
        (29.0, 61.0, false),
        (0.0, 0.0, false)
    ])
    func threshold(heard: Double, duration: Double, expected: Bool) {
        #expect(MusicListeningRules.countsAsPlay(heardSeconds: heard, durationSeconds: duration) == expected)
    }

    @Test("an unknown or bad length falls back to 30 s, and bad heard time is never a play")
    func badInputs() {
        #expect(!MusicListeningRules.countsAsPlay(heardSeconds: 29, durationSeconds: nil))
        #expect(MusicListeningRules.countsAsPlay(heardSeconds: 30, durationSeconds: nil))
        #expect(MusicListeningRules.countsAsPlay(heardSeconds: 30, durationSeconds: .nan))
        #expect(MusicListeningRules.countsAsPlay(heardSeconds: 30, durationSeconds: -5))
        #expect(!MusicListeningRules.countsAsPlay(heardSeconds: .nan, durationSeconds: 100))
        #expect(!MusicListeningRules.countsAsPlay(heardSeconds: .infinity, durationSeconds: 100))
        #expect(!MusicListeningRules.countsAsPlay(heardSeconds: -3, durationSeconds: 100))
    }
}

@MainActor
@Suite("MusicListeningStore")
struct MusicListeningStoreTests {
    private static let a = "dQw4w9WgXcQ"
    private static let b = "4D7u5KF7SP8"

    private static func tempURL() -> URL {
        URL(fileURLWithPath: "/Volumes/Storage/_test/deci-p4/listening-\(UUID().uuidString)/Listening.sqlite")
    }

    private static func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

    @Test("a song nobody noted has no row")
    func missing() async {
        let store = MusicListeningStore(url: nil)
        #expect(await store.entry(for: Self.a) == nil)
        #expect(await store.count() == 0)
    }

    @Test("notes for one song merge into one row: plays, seconds, first and last time")
    func merge() async throws {
        let store = MusicListeningStore(url: nil)
        store.note(videoId: Self.a, seconds: 100, countsAsPlay: true, at: Self.date(1000))
        store.note(videoId: Self.a, seconds: 10, countsAsPlay: false, at: Self.date(2000))
        store.note(videoId: Self.a, seconds: 50, countsAsPlay: true, at: Self.date(500))
        let row = try #require(await store.entry(for: Self.a))
        #expect(row.playCount == 2)
        #expect(row.totalSeconds == 160)
        #expect(row.firstPlayed == Self.date(500))
        #expect(row.lastPlayed == Self.date(2000))
        #expect(await store.count() == 1)
    }

    @Test("a later flush adds to the stored row and keeps the first time")
    func accumulatesAcrossFlushes() async throws {
        let store = MusicListeningStore(url: nil)
        store.note(videoId: Self.a, seconds: 60, countsAsPlay: true, at: Self.date(100))
        await store.flush()
        store.note(videoId: Self.a, seconds: 40, countsAsPlay: true, at: Self.date(900))
        let row = try #require(await store.entry(for: Self.a))
        #expect(row.playCount == 2)
        #expect(row.totalSeconds == 100)
        #expect(row.firstPlayed == Self.date(100))
        #expect(row.lastPlayed == Self.date(900))
    }

    @Test("a skipped song keeps its seconds with no play")
    func skippedSong() async throws {
        let store = MusicListeningStore(url: nil)
        store.note(videoId: Self.b, seconds: 12.5, countsAsPlay: false, at: Self.date(0))
        let row = try #require(await store.entry(for: Self.b))
        #expect(row.playCount == 0)
        #expect(row.totalSeconds == 12.5)
    }

    @Test("a bad id, under a second and a non-finite time leave nothing")
    func ignoredNotes() async {
        let store = MusicListeningStore(url: nil)
        store.note(videoId: "a", seconds: 100, countsAsPlay: true, at: Self.date(0))
        store.note(videoId: "", seconds: 100, countsAsPlay: true, at: Self.date(0))
        store.note(videoId: "x'; DROP TABLE listening;--", seconds: 100, countsAsPlay: true, at: Self.date(0))
        store.note(videoId: Self.a, seconds: 0.4, countsAsPlay: false, at: Self.date(0))
        store.note(videoId: Self.a, seconds: .nan, countsAsPlay: false, at: Self.date(0))
        store.note(videoId: Self.a, seconds: -9, countsAsPlay: false, at: Self.date(0))
        await store.flush()
        #expect(await store.count() == 0)
        #expect(await store.entry(for: "not an id") == nil)
    }

    @Test("rows survive a reopen of the file")
    func roundTrip() async throws {
        let url = Self.tempURL()
        let first = MusicListeningStore(url: url)
        first.note(videoId: Self.a, seconds: 200, countsAsPlay: true, at: Self.date(10))
        first.note(videoId: Self.b, seconds: 31, countsAsPlay: true, at: Self.date(20))
        await first.flush()

        let second = MusicListeningStore(url: url)
        let rowA = try #require(await second.entry(for: Self.a))
        #expect(rowA.playCount == 1)
        #expect(rowA.totalSeconds == 200)
        #expect(rowA.firstPlayed == Self.date(10))
        #expect(rowA.lastPlayed == Self.date(10))
        #expect(await second.count() == 2)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a flush that cannot begin (the file is locked) keeps the batch and writes it once the lock is gone")
    func lockedFileKeepsBatch() async throws {
        let url = Self.tempURL()
        let store = MusicListeningStore(url: url, debounce: .seconds(600))
        store.note(videoId: Self.a, seconds: 60, countsAsPlay: true, at: Self.date(100))
        await store.flush()

        var blocker: OpaquePointer?
        #expect(sqlite3_open(url.path, &blocker) == SQLITE_OK)
        #expect(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        store.note(videoId: Self.b, seconds: 40, countsAsPlay: true, at: Self.date(200))
        await store.flush()
        // Noted while the batch was out: merged with it, not lost.
        store.note(videoId: Self.b, seconds: 5, countsAsPlay: false, at: Self.date(300))
        sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil)
        sqlite3_close(blocker)

        let row = try #require(await store.entry(for: Self.b))
        #expect(row.playCount == 1)
        #expect(row.totalSeconds == 45)
        #expect(row.firstPlayed == Self.date(200))
        #expect(row.lastPlayed == Self.date(300))
        #expect(try #require(await store.entry(for: Self.a)).totalSeconds == 60)
    }

    @Test("notes reach the file by themselves after the debounce, not before")
    func debounce() async throws {
        let url = Self.tempURL()
        let store = MusicListeningStore(url: url, debounce: .milliseconds(150))
        store.note(videoId: Self.a, seconds: 90, countsAsPlay: true, at: Self.date(0))
        #expect(await store.count() == 0, "held in memory, nothing written yet")
        for _ in 0..<100 where await store.count() == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await store.count() == 1)
    }

    @Test("flushNow writes what is held")
    func flushNow() async {
        let store = MusicListeningStore(url: nil)
        store.note(videoId: Self.a, seconds: 90, countsAsPlay: true, at: Self.date(0))
        store.flushNow()
        #expect(await store.count() == 1)
    }

    @Test("a file that is not a database is set aside and the store starts over")
    func corruptFile() async throws {
        let url = Self.tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not sqlite, not even close, just text".utf8).write(to: url)
        let store = MusicListeningStore(url: url)
        store.note(videoId: Self.a, seconds: 60, countsAsPlay: true, at: Self.date(0))
        #expect(try #require(await store.entry(for: Self.a)).playCount == 1)
    }

    @Test("many songs at once land in one write")
    func manySongs() async {
        let store = MusicListeningStore(url: nil)
        for index in 0..<2000 {
            store.note(videoId: String(format: "song%07d", index), seconds: 60, countsAsPlay: true, at: Self.date(Double(index)))
        }
        await store.flush()
        #expect(await store.count() == 2000)
    }
}

@MainActor
@Suite("MusicSongData listening rows")
struct MusicSongDataListeningRowsTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(plays: Int = 3, seconds: Double = 725, last: Double = -3 * 3600, first: Double = -40 * 86_400) -> MusicListeningEntry {
        MusicListeningEntry(
            videoId: "dQw4w9WgXcQ", playCount: plays, totalSeconds: seconds,
            firstPlayed: now.addingTimeInterval(first), lastPlayed: now.addingTimeInterval(last)
        )
    }

    @Test("a song with a row has Plays, Time listened, Last played and First played")
    func rows() {
        let section = MusicSongDataRows.listeningSection(entry(), now: now, timeZone: TimeZone(identifier: "UTC")!)
        #expect(section.title == "Your listening")
        #expect(section.note == nil)
        #expect(section.rows.map(\.label) == ["Plays", "Time listened", "Last played", "First played"])
        #expect(section.rows[0].value == "3")
        #expect(section.rows[1].value == "12m 5s")
        #expect(section.rows[2].value == "3 hours ago")
        // 1_700_000_000 is 2023-11-14 22:13 UTC; 40 days earlier is Oct 5 in UTC.
        #expect(section.rows[3].value == "Oct 5, 2023")
        #expect(section.rows[0].isNumeric && section.rows[1].isNumeric)
        #expect(!section.rows[2].isNumeric && !section.rows[3].isNumeric)
    }

    @Test("a song with no row says so in one plain line")
    func empty() {
        let section = MusicSongDataRows.listeningSection(nil, now: now)
        #expect(section.rows.isEmpty)
        #expect(section.note == "Not played since Deci started counting")
    }

    @Test("time listened is compact hours, minutes and seconds", arguments: [
        (0.0, "0s"), (0.4, "0s"), (45.0, "45s"), (60.0, "1m"), (125.0, "2m 5s"), (3600.0, "1h"),
        (3605.0, "1h 5s"), (3725.0, "1h 2m 5s"), (90_061.0, "25h 1m 1s"), (.nan, "0s"), (-5.0, "0s")
    ])
    func listened(seconds: Double, expected: String) {
        #expect(MusicSongDataRows.listenedText(seconds) == expected)
    }

    @Test("a play a moment ago says Just now, and a row with no plays still shows its time")
    func recentAndUnplayed() {
        let section = MusicSongDataRows.listeningSection(entry(plays: 0, seconds: 8, last: -20), now: now)
        #expect(section.rows[0].value == "0")
        #expect(section.rows[1].value == "8s")
        #expect(section.rows[2].value == "Just now")
    }

    @Test("the store hands the song's row to the panel and drops it when another song opens")
    func panelStore() async {
        let backend = FakeMusicBackend()
        let store = MusicSongDataStore(backend: backend)
        let row = entry()
        store.sources = MusicSongDataStore.Sources(
            heldStream: { _ in nil }, analysis: { _ in nil }, isOffline: { false },
            listening: { $0 == row.videoId ? row : nil }
        )
        store.show(MusicSamples.track("dQw4w9WgXcQ", title: "One"))
        for _ in 0..<200 where store.listening == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(store.listening == row)
        store.show(MusicSamples.track("4D7u5KF7SP8", title: "Two"))
        #expect(store.listening == nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(store.listening == nil)
        store.close()
        #expect(store.listening == nil)
    }
}
