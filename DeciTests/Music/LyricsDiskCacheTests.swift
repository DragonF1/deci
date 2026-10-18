// DeciTests/Music/LyricsDiskCacheTests.swift
// The lyrics disk cache with an injected clock and a temporary directory.

import Foundation
import Testing
@testable import Deci

@Suite("Lyrics disk cache")
struct LyricsDiskCacheTests {

    private static let day: TimeInterval = 86_400

    private func makeCache(maxEntries: Int = 500, clock: MutableClock = MutableClock()) -> (LyricsDiskCache, URL, MutableClock) {
        let directory = makeTemporaryDirectory("deci-lyrics-cache").appendingPathComponent("Lyrics", isDirectory: true)
        let cache = LyricsDiskCache(directory: directory, maxEntries: maxEntries, now: { clock.now })
        return (cache, directory, clock)
    }

    private func files(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - Round trips

    @Test("Each kind of result reads back as it was written")
    func roundTrips() async {
        let (cache, directory, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await cache.store(.synced(LyricsSamples.syncedLines), videoId: "a")
        await cache.store(.plain("First test line\nSecond test line"), videoId: "b")
        await cache.store(.instrumental, videoId: "c")
        await cache.store(.notFound, videoId: "d")
        #expect(await cache.cached(videoId: "a") == .synced(LyricsSamples.syncedLines))
        #expect(await cache.cached(videoId: "b") == .plain("First test line\nSecond test line"))
        #expect(await cache.cached(videoId: "c") == .instrumental)
        #expect(await cache.cached(videoId: "d") == .notFound)
    }

    @Test("Gaps, unicode and emoji survive")
    func awkwardText() async {
        let (cache, directory, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let lines = [LyricLine(time: 1.25, text: "Ça va 🎵"), LyricLine(time: 3, text: ""), LyricLine(time: 4.5, text: "日本語")]
        await cache.store(.synced(lines), videoId: "x")
        #expect(await cache.cached(videoId: "x") == .synced(lines))
    }

    @Test("A video that was never stored is a miss, and the directory is made on the first write")
    func missAndDirectory() async {
        let (cache, directory, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        #expect(await cache.cached(videoId: "nope") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await cache.store(.instrumental, videoId: "a")
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Writing the same video again replaces the entry")
    func overwrite() async {
        let (cache, directory, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await cache.store(.notFound, videoId: "a")
        await cache.store(.plain("First test line"), videoId: "a")
        #expect(await cache.cached(videoId: "a") == .plain("First test line"))
        #expect(files(in: directory).count == 1)
    }

    // MARK: - File names

    @Test("The file name is a hash: no video id in it, stable, one per id")
    func hashedFileName() async {
        let name = LyricsDiskCache.fileName(forVideoId: "dQw4w9WgXcQ")
        #expect(!name.contains("dQw4w9WgXcQ"))
        #expect(name.hasSuffix(".json"))
        #expect(name.dropLast(5).count == 64)
        #expect(name.dropLast(5).allSatisfy { $0.isHexDigit })
        #expect(name == LyricsDiskCache.fileName(forVideoId: "dQw4w9WgXcQ"))
        #expect(name != LyricsDiskCache.fileName(forVideoId: "dQw4w9WgXcR"))
    }

    @Test("Hostile ids stay inside the directory")
    func hostileIds() async {
        let (cache, directory, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await cache.store(.instrumental, videoId: "../../escape")
        await cache.store(.instrumental, videoId: "a/b:c\u{0}d")
        #expect(files(in: directory).count == 2)
        #expect(files(in: directory.deletingLastPathComponent()).count == 1)
    }

    @Test("The live cache lives under Caches/com.abraham.Deci/Music/Lyrics")
    func liveLocation() {
        let path = LyricsDiskCache.liveDirectory().path
        #expect(path.hasSuffix("com.abraham.Deci/Music/Lyrics"))
    }

    // MARK: - Lifetimes

    @Test("Found lyrics last 30 days")
    func foundLifetime() async {
        let (cache, directory, clock) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await cache.store(.synced(LyricsSamples.syncedLines), videoId: "a")
        clock.advance(by: 30 * Self.day - 1)
        #expect(await cache.cached(videoId: "a") != nil)
        clock.advance(by: 2)
        #expect(await cache.cached(videoId: "a") == nil)
    }

    @Test("Instrumental and plain count as found")
    func instrumentalAndPlainAreFound() async {
        let (cache, directory, clock) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await cache.store(.instrumental, videoId: "a")
        await cache.store(.plain("First test line"), videoId: "b")
        clock.advance(by: 10 * Self.day)
        #expect(await cache.cached(videoId: "a") == .instrumental)
        #expect(await cache.cached(videoId: "b") == .plain("First test line"))
    }

    @Test("Not-found lasts 3 days")
    func notFoundLifetime() async {
        let (cache, directory, clock) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await cache.store(.notFound, videoId: "a")
        clock.advance(by: 3 * Self.day - 1)
        #expect(await cache.cached(videoId: "a") == .notFound)
        clock.advance(by: 2)
        #expect(await cache.cached(videoId: "a") == nil)
    }

    @Test("An expired entry is deleted when it is read")
    func expiredIsRemoved() async {
        let (cache, directory, clock) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await cache.store(.notFound, videoId: "a")
        clock.advance(by: 4 * Self.day)
        #expect(await cache.cached(videoId: "a") == nil)
        #expect(files(in: directory).isEmpty)
    }

    // MARK: - Damage

    @Test("A corrupt file is a miss and is removed")
    func corruptFile() async throws {
        let (cache, directory, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await cache.store(.instrumental, videoId: "a")
        let file = try #require(files(in: directory).first)
        try Data("not json {".utf8).write(to: file)
        #expect(await cache.cached(videoId: "a") == nil)
        #expect(files(in: directory).isEmpty)
    }

    @Test("An entry from a future format is a miss")
    func unknownVersion() async throws {
        let (cache, directory, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await cache.store(.instrumental, videoId: "a")
        let file = try #require(files(in: directory).first)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["version"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(await cache.cached(videoId: "a") == nil)
    }

    // MARK: - Pruning

    @Test("Only the newest entries are kept")
    func prunesToTheNewest() async {
        let (cache, directory, clock) = makeCache(maxEntries: 3)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        for id in ["a", "b", "c", "d", "e"] {
            await cache.store(.instrumental, videoId: id)
            clock.advance(by: 60)
        }
        #expect(files(in: directory).count == 3)
        #expect(await cache.cached(videoId: "a") == nil)
        #expect(await cache.cached(videoId: "b") == nil)
        #expect(await cache.cached(videoId: "c") == .instrumental)
        #expect(await cache.cached(videoId: "d") == .instrumental)
        #expect(await cache.cached(videoId: "e") == .instrumental)
    }

    @Test("Rewriting an old entry makes it new again")
    func rewriteRefreshesAge() async {
        let (cache, directory, clock) = makeCache(maxEntries: 2)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await cache.store(.instrumental, videoId: "a")
        clock.advance(by: 60)
        await cache.store(.instrumental, videoId: "b")
        clock.advance(by: 60)
        await cache.store(.notFound, videoId: "a")
        clock.advance(by: 60)
        await cache.store(.instrumental, videoId: "c")
        #expect(await cache.cached(videoId: "b") == nil)
        #expect(await cache.cached(videoId: "a") == .notFound)
        #expect(await cache.cached(videoId: "c") == .instrumental)
    }

    @Test("The default limit is 500 files")
    func defaultLimit() {
        #expect(LyricsDiskCache.defaultMaxEntries == 500)
        #expect(LyricsDiskCache.foundLifetime == 30 * Self.day)
        #expect(LyricsDiskCache.notFoundLifetime == 3 * Self.day)
    }

    @Test("Many writes at once stay within the limit")
    func concurrentWrites() async {
        let (cache, directory, _) = makeCache(maxEntries: 20)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<60 {
                group.addTask { await cache.store(.instrumental, videoId: "v\(index)") }
            }
        }
        #expect(files(in: directory).count <= 20)
    }
}
