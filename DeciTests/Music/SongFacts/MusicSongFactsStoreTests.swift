// DeciTests/Music/SongFacts/MusicSongFactsStoreTests.swift
// The facts cache: hits, misses and their TTLs, a measurement kept beside the lookup, and the repository on top that
// answers a re-open without the network.

import Foundation
import Testing
@testable import Deci

/// Counts what the repository asks of the chain and answers with what it is given.
private nonisolated final class FakeFactsClient: MusicSongFactsLooking, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [MusicSongFactsLookup]
    private var asked: [MusicSongFactsQuery] = []

    init(_ answers: [MusicSongFactsLookup]) { self.answers = answers }

    var queries: [MusicSongFactsQuery] { lock.withLock { asked } }

    func lookup(_ query: MusicSongFactsQuery) async -> MusicSongFactsLookup {
        lock.withLock {
            asked.append(query)
            return answers.count > 1 ? answers.removeFirst() : (answers.first ?? .failed)
        }
    }
}

@Suite("Music song facts store")
struct MusicSongFactsStoreTests {
    private static let dir = "/Volumes/Storage/_test/deci-songdata/stores"

    private func url() throws -> URL {
        try FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: "\(Self.dir)/\(UUID().uuidString).sqlite")
    }

    private func found(bpm: Double? = 171, clock: SongFactsClock) -> MusicSongFacts {
        var facts = MusicSongFacts(fetchedAt: clock.date)
        facts.isrc = "USUG11904206"
        facts.claim(.isrc, .deezer)
        facts.genres = ["pop"]
        facts.claim(.genres, .musicbrainz)
        if let bpm {
            facts.bpm = bpm
            facts.claim(.bpm, .reccobeats)
        }
        return facts
    }

    private func store(_ clock: SongFactsClock, at url: URL? = nil) throws -> MusicSongFactsStore {
        MusicSongFactsStore(url: try url ?? self.url(), now: { clock.now() })
    }

    @Test("a hit round-trips with every field and source, and is fresh for good")
    func hit() async throws {
        let clock = SongFactsClock()
        let store = try store(clock)
        let facts = found(clock: clock)
        await store.putLookup(videoId: "a", .found(facts))
        let record = try #require(await store.record(for: "a"))
        #expect(record.facts == facts)
        #expect(record.outcome == .hit)
        #expect(record.isLookupFresh(at: clock.date.addingTimeInterval(400 * 86_400)))
    }

    @Test("a miss is believed for 30 days and not after")
    func missTTL() async throws {
        let clock = SongFactsClock()
        let store = try store(clock)
        await store.putLookup(videoId: "a", .notFound)
        let record = try #require(await store.record(for: "a"))
        #expect(record.outcome == .miss)
        #expect(record.facts.isEmpty)
        #expect(record.isLookupFresh(at: clock.date.addingTimeInterval(29 * 86_400)))
        #expect(!record.isLookupFresh(at: clock.date.addingTimeInterval(31 * 86_400)))
    }

    @Test("a partial answer is believed for a day")
    func partialTTL() async throws {
        let clock = SongFactsClock()
        let store = try store(clock)
        await store.putLookup(videoId: "a", .partial(found(clock: clock)))
        let record = try #require(await store.record(for: "a"))
        #expect(record.outcome == .partial)
        #expect(record.isLookupFresh(at: clock.date.addingTimeInterval(3_600)))
        #expect(!record.isLookupFresh(at: clock.date.addingTimeInterval(2 * 86_400)))
    }

    @Test("a failed lookup stores nothing")
    func failedStoresNothing() async throws {
        let clock = SongFactsClock()
        let store = try store(clock)
        await store.putLookup(videoId: "a", .failed)
        #expect(await store.record(for: "a") == nil)
        #expect(await store.count() == 0)
    }

    @Test("a measured tempo is stored with the Deci source and is not a lookup")
    func measured() async throws {
        let clock = SongFactsClock()
        let store = try store(clock)
        await store.putMeasured(videoId: "a", bpm: 104.2, confidence: 0.7)
        let record = try #require(await store.record(for: "a"))
        #expect(record.facts.bpm == 104.2)
        #expect(record.facts.bpmConfidence == 0.7)
        #expect(record.facts.source(of: .bpm) == .deci)
        #expect(record.measuredAt != nil)
        #expect(record.lookedUpAt == nil)
        #expect(!record.isLookupFresh(at: clock.date))
    }

    @Test("a measurement with no usable tempo is still marked, so it is not downloaded again")
    func measuredEmpty() async throws {
        let clock = SongFactsClock()
        let store = try store(clock)
        await store.putMeasured(videoId: "a", bpm: nil, confidence: nil)
        let record = try #require(await store.record(for: "a"))
        #expect(record.facts.bpm == nil)
        #expect(record.measuredAt != nil)
    }

    @Test("a failed measurement is remembered for a day, survives a lookup, and a later success clears it")
    func measureFailed() async throws {
        let clock = SongFactsClock()
        let store = try store(clock)
        await store.putMeasureFailed(videoId: "a")
        var record = try #require(await store.record(for: "a"))
        #expect(record.isMeasureFailureRecent(at: clock.date))
        #expect(record.measuredAt == nil)
        #expect(!record.isMeasureFailureRecent(at: clock.date.addingTimeInterval(86_401)))

        await store.putLookup(videoId: "a", .found(found(bpm: nil, clock: clock)))
        record = try #require(await store.record(for: "a"))
        #expect(record.isMeasureFailureRecent(at: clock.date))
        #expect(record.facts.isrc == "USUG11904206")

        await store.putMeasured(videoId: "a", bpm: 100, confidence: 0.5)
        record = try #require(await store.record(for: "a"))
        #expect(record.facts.measureFailedAt == nil)
        #expect(record.measuredAt != nil)
        // A finished measurement is never turned back into a failure.
        await store.putMeasureFailed(videoId: "a")
        #expect(try #require(await store.record(for: "a")).facts.measureFailedAt == nil)
    }

    @Test("a measured tempo outside 30 to 300 is not stored")
    func measuredAbsurd() async throws {
        let store = try store(SongFactsClock())
        await store.putMeasured(videoId: "a", bpm: 1e300, confidence: 1)
        let record = try #require(await store.record(for: "a"))
        #expect(record.facts.bpm == nil)
        #expect(record.measuredAt != nil)
    }

    @Test("a lookup after a measurement keeps Deci's tempo only where no service gave one")
    func lookupAfterMeasure() async throws {
        let clock = SongFactsClock()
        let store = try store(clock)
        await store.putMeasured(videoId: "a", bpm: 104, confidence: 0.7)
        await store.putLookup(videoId: "a", .found(found(bpm: nil, clock: clock)))
        var record = try #require(await store.record(for: "a"))
        #expect(record.facts.bpm == 104)
        #expect(record.facts.source(of: .bpm) == .deci)
        #expect(record.facts.isrc == "USUG11904206")
        #expect(record.measuredAt != nil)

        await store.putLookup(videoId: "a", .found(found(bpm: 171, clock: clock)))
        record = try #require(await store.record(for: "a"))
        #expect(record.facts.bpm == 171)
        #expect(record.facts.source(of: .bpm) == .reccobeats)
    }

    @Test("the cache survives a reopen of the file")
    func persists() async throws {
        let clock = SongFactsClock()
        let file = try url()
        let first = try store(clock, at: file)
        await first.putLookup(videoId: "a", .found(found(clock: clock)))
        let second = try store(clock, at: file)
        #expect(await second.record(for: "a")?.facts.bpm == 171)
        #expect(await second.count() == 1)
        await second.delete(videoId: "a")
        #expect(await second.record(for: "a") == nil)
    }

    @Test("a corrupt file is replaced by an empty cache")
    func corruptFile() async throws {
        let clock = SongFactsClock()
        let file = try url()
        try Data("this is not sqlite".utf8).write(to: file)
        let store = try store(clock, at: file)
        #expect(await store.record(for: "a") == nil)
        await store.putLookup(videoId: "a", .notFound)
        #expect(await store.count() == 1)
    }

    @Test("a store with no file is an in-memory cache")
    func noFile() async {
        let clock = SongFactsClock()
        let store = MusicSongFactsStore(url: nil, now: { clock.now() })
        #expect(await store.record(for: "a") == nil)
        await store.putLookup(videoId: "a", .notFound)
        #expect(await store.count() == 1)
    }

    // MARK: - Repository

    @Test("re-opening reads the cache and never asks the chain again")
    func cacheHitNoNetwork() async throws {
        let clock = SongFactsClock()
        let client = FakeFactsClient([.found(found(clock: clock))])
        let repository = MusicSongFactsRepository(client: client, store: try store(clock), now: { clock.now() })
        #expect(await repository.cached(videoId: "a") == nil)

        _ = await repository.lookup(videoId: "a", query: SongFactsFixtures.query)
        #expect(client.queries.count == 1)

        let cached = try #require(await repository.cached(videoId: "a"))
        #expect(cached.facts?.bpm == 171)
        #expect(cached.lookupIsFresh)
        #expect(cached.measureAttempted == false)
        #expect(client.queries.count == 1)
    }

    @Test("a miss is cached for 30 days, then refreshed")
    func missRefresh() async throws {
        let clock = SongFactsClock()
        let client = FakeFactsClient([.notFound, .found(found(clock: clock))])
        let repository = MusicSongFactsRepository(client: client, store: try store(clock), now: { clock.now() })
        _ = await repository.lookup(videoId: "a", query: SongFactsFixtures.query)

        var cached = try #require(await repository.cached(videoId: "a"))
        #expect(cached.facts == nil)
        #expect(cached.lookupIsFresh)

        clock.advance(days: 31)
        cached = try #require(await repository.cached(videoId: "a"))
        #expect(!cached.lookupIsFresh)

        _ = await repository.lookup(videoId: "a", query: SongFactsFixtures.query)
        #expect(client.queries.count == 2)
        cached = try #require(await repository.cached(videoId: "a"))
        #expect(cached.facts?.bpm == 171)
        #expect(cached.lookupIsFresh)
    }

    @Test("a failed lookup leaves the cache alone")
    func failedKeepsOld() async throws {
        let clock = SongFactsClock()
        let client = FakeFactsClient([.found(found(clock: clock)), .failed])
        let repository = MusicSongFactsRepository(client: client, store: try store(clock), now: { clock.now() })
        _ = await repository.lookup(videoId: "a", query: SongFactsFixtures.query)
        let again = await repository.lookup(videoId: "a", query: SongFactsFixtures.query)
        #expect(again == .failed)
        #expect(await repository.cached(videoId: "a")?.facts?.bpm == 171)
    }

    @Test("a measured song reads as measured with the tempo, and a lookup is still due")
    func measuredReadsBack() async throws {
        let clock = SongFactsClock()
        let client = FakeFactsClient([.notFound])
        let repository = MusicSongFactsRepository(client: client, store: try store(clock), now: { clock.now() })
        await repository.cache.putMeasured(videoId: "a", bpm: 98, confidence: 0.6)
        let cached = try #require(await repository.cached(videoId: "a"))
        #expect(cached.facts?.bpm == 98)
        #expect(cached.measureAttempted)
        #expect(!cached.lookupIsFresh)
    }
}
