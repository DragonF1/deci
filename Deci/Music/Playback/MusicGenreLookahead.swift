// Deci/Music/Playback/MusicGenreLookahead.swift
// The genre tags of the playing song and the next one, read ahead of the mix so the planner knows what kind of music they are.
// Privacy: what the Song data panel stored is read first (no network). Only when it has nothing, and the caller allows the network,
// the same services the panel uses are asked with the artist and title. A missing answer is not an error: the planner goes by
// tempo and energy. Nothing here ever makes a plan wait.

import Foundation

@MainActor
final class MusicGenreLookahead {
    typealias CacheRead = @Sendable (String) async -> MusicSongFactsCached?
    typealias Lookup = @Sendable (String, MusicSongFactsQuery) async -> MusicSongFactsLookup

    private let readCache: CacheRead
    private let lookup: Lookup
    private var known: [String: [String]] = [:]
    private var requested: Set<String> = []
    /// Songs whose cache had no answer while the network was not allowed: asked again when it is.
    private var waiting: Set<String> = []

    init(readCache: @escaping CacheRead, lookup: @escaping Lookup) {
        self.readCache = readCache
        self.lookup = lookup
    }

    /// The live wiring: the facts the Song data panel uses (one cache, one client, one request a second).
    static func live(facts: MusicSongFactsRepository) -> MusicGenreLookahead {
        MusicGenreLookahead(
            readCache: { await facts.cached(videoId: $0) },
            lookup: { await facts.lookup(videoId: $0, query: $1) }
        )
    }

    /// Genre tags already known for a song, best fitting first; empty when there are none.
    func genres(for videoId: String) -> [String] { known[videoId] ?? [] }

    /// True when a lookup for the song was already started or finished, and there is nothing more to ask now.
    func hasRequested(_ videoId: String, allowNetwork: Bool) -> Bool {
        requested.contains(videoId) && !(allowNetwork && waiting.contains(videoId))
    }

    /// Looks the song up once. Never throws; leaves `genres(for:)` empty on any failure.
    func prepare(videoId: String, query: MusicSongFactsQuery, allowNetwork: Bool) async {
        guard !hasRequested(videoId, allowNetwork: allowNetwork) else { return }
        requested.insert(videoId)
        waiting.remove(videoId)
        if let hit = await readCache(videoId) {
            if let facts = hit.facts { record(facts, for: videoId) }
            // A row stored before every tag was kept is asked for once more; a fresh miss is an answer.
            if hit.lookupIsFresh, hit.facts.map({ $0.tags != nil }) ?? true { return }
        }
        guard allowNetwork else {
            waiting.insert(videoId)
            return
        }
        switch await lookup(videoId, query) {
        case .found(let facts), .partial(let facts): record(facts, for: videoId)
        case .notFound, .failed: break
        }
    }

    private func record(_ facts: MusicSongFacts, for videoId: String) {
        // A lookup that found less than the cache had does not take its tags away.
        let tags = facts.tags ?? facts.genres
        if !tags.isEmpty || known[videoId] == nil { known[videoId] = tags }
    }
}
