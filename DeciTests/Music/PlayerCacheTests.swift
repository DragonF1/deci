// DeciTests/Music/PlayerCacheTests.swift
// The per-player-build cache: signatureTimestamp, preprocessed player JS, last-good, pruning.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("PlayerCache")
struct PlayerCacheTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeCache() -> (PlayerCache, URL) {
        let directory = makeTemporaryDirectory("deci-playercache")
        return (PlayerCache(directory: directory.appendingPathComponent("nested/Music")), directory)
    }

    @Test("sts and the preprocessed player round trip, creating the directory on demand")
    func roundTrip() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(cache.sts(forHash: "0229cd64") == nil)
        #expect(cache.preprocessedPlayer(forHash: "0229cd64") == nil)
        cache.saveSTS(20739, forHash: "0229cd64", now: t0)
        cache.savePreprocessed("var x = 1; // 日本語 \u{1F3B5}", forHash: "0229cd64")
        #expect(cache.sts(forHash: "0229cd64") == 20739)
        #expect(cache.preprocessedPlayer(forHash: "0229cd64") == "var x = 1; // 日本語 \u{1F3B5}")
    }

    @Test("Hashes that are not short URL-safe tokens never touch the disk")
    func hashValidation() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        for hash in ["../escape", "a/b", "", "abc", "ab cd", String(repeating: "a", count: 33), "ünïcode1"] {
            cache.saveSTS(1, forHash: hash, now: t0)
            cache.savePreprocessed("x", forHash: hash)
            #expect(cache.sts(forHash: hash) == nil, "\(hash)")
            #expect(cache.preprocessedPlayer(forHash: hash) == nil, "\(hash)")
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path)) == [])
    }

    @Test("A corrupt meta file reads as missing")
    func corruptMeta() throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.saveSTS(5, forHash: "hash0001", now: t0)
        try Data("not json".utf8).write(to: cache.directory.appendingPathComponent("hash0001.json"))
        #expect(cache.sts(forHash: "hash0001") == nil)
    }

    @Test("An empty preprocessed file reads as missing")
    func emptyPreprocessed() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.savePreprocessed("", forHash: "hash0001")
        #expect(cache.preprocessedPlayer(forHash: "hash0001") == nil)
    }

    @Test("removePreprocessed drops only the player file")
    func removePreprocessed() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.saveSTS(5, forHash: "hash0001", now: t0)
        cache.savePreprocessed("x", forHash: "hash0001")
        cache.removePreprocessed(forHash: "hash0001")
        #expect(cache.preprocessedPlayer(forHash: "hash0001") == nil)
        #expect(cache.sts(forHash: "hash0001") == 5)
    }

    @Test("lastGood is the newest entry with both halves, skipping the excluded hash")
    func lastGood() throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.saveSTS(1, forHash: "hash0001", now: t0)
        cache.savePreprocessed("a", forHash: "hash0001")
        cache.saveSTS(2, forHash: "hash0002", now: t0.addingTimeInterval(100))
        cache.savePreprocessed("b", forHash: "hash0002")
        cache.saveSTS(3, forHash: "hash0003", now: t0.addingTimeInterval(200))   // sts only, no player

        let newest = try #require(cache.lastGood())
        #expect(newest.hash == "hash0002")
        #expect(newest.sts == 2)
        let other = try #require(cache.lastGood(excluding: "hash0002"))
        #expect(other.hash == "hash0001")
        #expect(cache.lastGood(excluding: "hash0001")?.hash == "hash0002")
    }

    @Test("lastGood is nil for an empty or missing cache")
    func lastGoodEmpty() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(cache.lastGood() == nil)
    }

    @Test("prune keeps the named hash plus the newest other, and deletes the rest")
    func prune() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, hash) in ["hash0001", "hash0002", "hash0003", "hash0004"].enumerated() {
            cache.saveSTS(index, forHash: hash, now: t0.addingTimeInterval(Double(index) * 100))
            cache.savePreprocessed("p\(index)", forHash: hash)
        }
        cache.prune(keeping: "hash0001")
        #expect(cache.sts(forHash: "hash0001") == 0)
        #expect(cache.sts(forHash: "hash0004") == 3)
        #expect(cache.sts(forHash: "hash0002") == nil)
        #expect(cache.sts(forHash: "hash0003") == nil)
        #expect(cache.preprocessedPlayer(forHash: "hash0003") == nil)
        #expect(cache.preprocessedPlayer(forHash: "hash0001") == "p0")
    }

    @Test("prune on an empty cache is a no-op")
    func pruneEmpty() {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.prune(keeping: "hash0001")
        #expect(cache.sts(forHash: "hash0001") == nil)
    }

    @Test("The live cache lives under Library/Caches/com.abraham.Deci/Music")
    func liveLocation() {
        let path = PlayerCache.live().directory.path
        #expect(path.hasSuffix("/Library/Caches/com.abraham.Deci/Music"))
    }
}
