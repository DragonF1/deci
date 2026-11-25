// DeciTests/Music/MusicGenreLookaheadTests.swift
// What the genre lookup reads and asks: the cache first, the network once, and nothing when it is not allowed.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music genre lookahead")
struct MusicGenreLookaheadTests {
    private actor Calls {
        var reads: [String] = [], asked: [(String, MusicSongFactsQuery)] = []
        func read(_ id: String) { reads.append(id) }
        func ask(_ id: String, _ query: MusicSongFactsQuery) { asked.append((id, query)) }
    }

    private let calls = Calls()
    private let query = MusicSongFactsQuery(artist: "Artist", title: "Title", durationSeconds: 200)

    private func lookahead(_ cached: MusicSongFactsCached?, _ answer: MusicSongFactsLookup = .notFound) -> MusicGenreLookahead {
        MusicGenreLookahead(
            readCache: { [calls] in await calls.read($0); return cached },
            lookup: { [calls] in await calls.ask($0, $1); return answer }
        )
    }

    private func facts(genres: [String] = [], tags: [String]?) -> MusicSongFacts {
        var facts = MusicSongFacts(fetchedAt: Date(timeIntervalSince1970: 0))
        facts.genres = genres
        facts.tags = tags
        facts.mbid = "x"
        return facts
    }

    private func stored(_ facts: MusicSongFacts?, fresh: Bool = true) -> MusicSongFactsCached {
        MusicSongFactsCached(facts: facts, lookupIsFresh: fresh, measureAttempted: false)
    }

    private func askedCount() async -> Int { await calls.asked.count }

    @Test("fresh tags in the cache are used and nothing is asked")
    func cached() async {
        let l = lookahead(stored(facts(genres: ["Pop"], tags: ["house", "Pop"])))
        await l.prepare(videoId: "v", query: query, allowNetwork: true)
        #expect(l.genres(for: "v") == ["house", "Pop"])
        #expect(await askedCount() == 0)
    }

    @Test("a song nobody looked up yet is asked for once, with its artist and title only")
    func asksOnce() async throws {
        let l = lookahead(nil, .found(facts(tags: ["techno"])))
        #expect(!l.hasRequested("v", allowNetwork: true))
        await l.prepare(videoId: "v", query: query, allowNetwork: true)
        await l.prepare(videoId: "v", query: query, allowNetwork: true)
        #expect(l.hasRequested("v", allowNetwork: true) && l.genres(for: "v") == ["techno"])
        let asked = await calls.asked
        #expect(asked.count == 1)
        let first = try #require(asked.first)
        #expect(first.0 == "v" && first.1 == query)
        #expect(await calls.reads == ["v"])
    }

    @Test("a row from before the tags is asked for again, and its one genre counts until the answer is there")
    func oldRow() async {
        let l = lookahead(stored(facts(genres: ["Rap/Hip Hop"], tags: nil)), .failed)
        await l.prepare(videoId: "v", query: query, allowNetwork: true)
        #expect(await askedCount() == 1)
        #expect(l.genres(for: "v") == ["Rap/Hip Hop"])
    }

    @Test("a fresh miss is an answer, a stale one is asked again")
    func misses() async {
        let fresh = lookahead(stored(nil))
        await fresh.prepare(videoId: "v", query: query, allowNetwork: true)
        #expect(await askedCount() == 0)
        let stale = lookahead(stored(nil, fresh: false), .partial(facts(tags: ["pop"])))
        await stale.prepare(videoId: "v", query: query, allowNetwork: true)
        #expect(await askedCount() == 1)
        #expect(stale.genres(for: "v") == ["pop"])
    }

    @Test("a row that only holds a measured tempo is asked for: the lookup never ran")
    func measuredOnly() async {
        let l = lookahead(stored(facts(tags: nil), fresh: false), .found(facts(tags: ["folk"])))
        await l.prepare(videoId: "v", query: query, allowNetwork: true)
        #expect(l.genres(for: "v") == ["folk"])
    }

    @Test("a lookup that found less does not take the cached tags away")
    func thinnerAnswer() async {
        let l = lookahead(stored(facts(genres: ["Techno"], tags: nil)), .partial(facts(tags: [])))
        await l.prepare(videoId: "v", query: query, allowNetwork: true)
        #expect(l.genres(for: "v") == ["Techno"])
    }

    @Test("offline nothing is asked and the cache is read once, and the song is tried again with the network")
    func offline() async {
        let l = lookahead(nil, .found(facts(tags: ["house"])))
        await l.prepare(videoId: "v", query: query, allowNetwork: false)
        #expect(await askedCount() == 0)
        #expect(l.hasRequested("v", allowNetwork: false) && !l.hasRequested("v", allowNetwork: true) && l.genres(for: "v").isEmpty)
        await l.prepare(videoId: "v", query: query, allowNetwork: false)
        #expect(await calls.reads == ["v"])
        await l.prepare(videoId: "v", query: query, allowNetwork: true)
        #expect(l.genres(for: "v") == ["house"])
    }

    @Test("a failed or empty lookup leaves the genre unknown and is not repeated")
    func failures() async {
        for answer in [MusicSongFactsLookup.failed, .notFound] {
            let l = lookahead(nil, answer)
            await l.prepare(videoId: "v", query: query, allowNetwork: true)
            await l.prepare(videoId: "v", query: query, allowNetwork: true)
            #expect(l.genres(for: "v").isEmpty)
        }
        #expect(await askedCount() == 2)
    }
}
