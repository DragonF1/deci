// Deci/Music/SongFacts/MusicSongFactsRepository.swift
import Foundation

/// What the Song data panel reads of the cache: the facts (nil when nothing is known), whether the services need not be
/// asked again, and whether Deci already tried to measure the tempo itself.
struct MusicSongFactsCached: Sendable, Equatable {
    var facts: MusicSongFacts?
    var lookupIsFresh: Bool
    var measureAttempted: Bool
}

/// The online chain and its cache as one thing: reading the cache never touches the network, and a lookup always stores
/// what it learned (a miss too, for 30 days) unless it could not be made.
actor MusicSongFactsRepository {
    private let client: any MusicSongFactsLooking
    private let store: MusicSongFactsStore
    private let now: @Sendable () -> Date

    init(client: any MusicSongFactsLooking, store: MusicSongFactsStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.store = store
        self.now = now
    }

    static func live() -> MusicSongFactsRepository {
        MusicSongFactsRepository(client: MusicSongFactsClient.live(), store: MusicSongFactsStore(url: MusicSongFactsStore.liveURL()))
    }

    /// The store, for the measurement that writes its tempo into it.
    nonisolated var cache: MusicSongFactsStore { store }

    func cached(videoId: String) async -> MusicSongFactsCached? {
        guard let record = await store.record(for: videoId) else { return nil }
        return MusicSongFactsCached(
            facts: record.facts.isEmpty ? nil : record.facts,
            lookupIsFresh: record.isLookupFresh(at: now()),
            measureAttempted: record.measuredAt != nil
        )
    }

    /// Asks the chain and stores the answer. Returns what was learned; a failed lookup stores nothing.
    @discardableResult
    func lookup(videoId: String, query: MusicSongFactsQuery) async -> MusicSongFactsLookup {
        let result = await client.lookup(query)
        if Task.isCancelled { return .failed }
        await store.putLookup(videoId: videoId, result)
        return result
    }
}
