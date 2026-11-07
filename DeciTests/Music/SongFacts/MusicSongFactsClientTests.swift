// DeciTests/Music/SongFacts/MusicSongFactsClientTests.swift
// The lookup chain against a stub transport: order, per-field sources, limits, odd replies and what is sent.

import Foundation
import Testing
@testable import Deci

@Suite("Music song facts client")
struct MusicSongFactsClientTests {
    private typealias Fx = SongFactsFixtures

    private func client(_ transport: StubSongFactsTransport, clock: SongFactsClock = SongFactsClock()) -> MusicSongFactsClient {
        MusicSongFactsClient(transport: transport, now: { clock.now() }, sleep: { try await clock.sleep($0) })
    }

    private func facts(_ result: MusicSongFactsLookup) -> MusicSongFacts? {
        switch result {
        case .found(let facts), .partial(let facts): facts
        default: nil
        }
    }

    @Test("the chain asks Deezer, then ReccoBeats, then MusicBrainz, and skips TheAudioDB when ReccoBeats answered")
    func chainOrder() async throws {
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        let result = await client(transport).lookup(Fx.query)
        guard case .found = result else { Issue.record("expected found, got \(result)"); return }
        let hosts = transport.requests.map { "\($0.url.host ?? "")\($0.url.path)" }
        #expect(hosts == [
            "api.deezer.com/search",
            "api.deezer.com/track/908604612",
            "api.deezer.com/album/137217782",
            "api.reccobeats.com/v1/audio-features",
            "musicbrainz.org/ws/2/isrc/USUG11904206",
            "musicbrainz.org/ws/2/recording/\(Fx.mbid)"
        ])
    }

    @Test("each field keeps the source that gave it")
    func perFieldSources() async throws {
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        let found = try #require(facts(await client(transport).lookup(Fx.query)))
        #expect(found.isrc == "USUG11904206")
        #expect(found.source(of: .isrc) == .deezer)
        #expect(found.releaseDate == "2020-03-20")
        #expect(found.source(of: .releaseDate) == .deezer)
        #expect(found.label == "Republic Records")
        #expect(found.source(of: .label) == .deezer)
        #expect(found.genres == ["R&B"])
        #expect(found.source(of: .genres) == .deezer)
        #expect(found.explicit == false)
        #expect(found.deezerId == 908_604_612)
        #expect(found.bpm == 171.005)
        #expect(found.source(of: .bpm) == .reccobeats)
        #expect(found.key == 1)
        #expect(found.mode == 1)
        #expect(found.source(of: .key) == .reccobeats)
        #expect(found.energy == 0.73)
        #expect(found.source(of: .energy) == .reccobeats)
        #expect(found.mbid == Fx.mbid)
        #expect(found.source(of: .mbid) == .musicbrainz)
        #expect(found.usedSources == [.deezer, .reccobeats, .musicbrainz])
    }

    @Test("a Deezer tempo above zero wins over ReccoBeats")
    func deezerTempoFirst() async throws {
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("api.deezer.com/track/", [.success(Fx.ok(Fx.deezerTrack(bpm: 170)))])
        let found = try #require(facts(await client(transport).lookup(Fx.query)))
        #expect(found.bpm == 170)
        #expect(found.source(of: .bpm) == .deezer)
        #expect(found.source(of: .key) == .reccobeats)
    }

    @Test("without ReccoBeats features TheAudioDB fills tempo and feel, and says so")
    func audioDBFallback() async throws {
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("api.reccobeats.com", [.success(Fx.ok(Fx.reccoEmpty))])
        let found = try #require(facts(await client(transport).lookup(Fx.query)))
        #expect(found.bpm == 171)
        #expect(found.source(of: .bpm) == .theaudiodb)
        #expect(found.energy == 0.73)
        #expect(found.source(of: .energy) == .theaudiodb)
        #expect(transport.urls.contains { $0.contains("theaudiodb.com/api/v1/json/123/searchtrack.php?s=The%20Weeknd&t=Blinding%20Lights") })
    }

    @Test("a ReccoBeats row for another ISRC is not used")
    func reccoWrongISRC() async throws {
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("api.reccobeats.com", [.success(Fx.ok(Fx.recco(isrc: "GBAFL9000062", tempo: 90)))])
        let found = try #require(facts(await client(transport).lookup(Fx.query)))
        #expect(found.source(of: .bpm) == .theaudiodb)
        #expect(found.bpm == 171)
    }

    @Test("a TheAudioDB record with another ISRC is rejected")
    func audioDBWrongISRC() async {
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("api.reccobeats.com", [.success(Fx.ok(Fx.reccoEmpty))])
        transport.route("theaudiodb.com", [.success(Fx.ok(Fx.audioDB(isrc: "GBAFL9000062")))])
        let found = facts(await client(transport).lookup(Fx.query))
        #expect(found?.bpm == nil)
        #expect(found?.source(of: .bpm) == nil)
    }

    @Test("a Deezer error code 4 inside a 200 is a failed lookup, nothing more is asked")
    func deezerQuota() async {
        let body = "{\"error\":{\"type\":\"Exception\",\"message\":\"Quota limit exceeded\",\"code\":4}}"
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("api.deezer.com/search", [.success(Fx.ok(body))])
        let result = await client(transport).lookup(Fx.query)
        #expect(result == .failed)
        #expect(transport.requests.count == 2)  // the search, then TheAudioDB's try
    }

    @Test("a ReccoBeats 429 waits out a short Retry-After once and asks again")
    func reccoRetryAfter() async throws {
        let clock = SongFactsClock()
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("api.reccobeats.com", [
            .success(Fx.ok("{}", status: 429, headers: ["Retry-After": "3"])),
            .success(Fx.ok(Fx.recco()))
        ])
        let found = try #require(facts(await client(transport, clock: clock).lookup(Fx.query)))
        #expect(clock.sleeps.contains(3000))
        #expect(transport.urls.filter { $0.contains("reccobeats") }.count == 2)
        #expect(found.source(of: .bpm) == .reccobeats)
    }

    @Test("a long Retry-After is not waited out: the rest is kept and the lookup is partial")
    func reccoLongRetryAfter() async throws {
        let clock = SongFactsClock()
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("api.reccobeats.com", [.success(Fx.ok("{}", status: 429, headers: ["Retry-After": "120"]))])
        let result = await client(transport, clock: clock).lookup(Fx.query)
        guard case .partial(let partial) = result else { Issue.record("expected partial, got \(result)"); return }
        #expect(!clock.sleeps.contains(120_000))
        #expect(transport.urls.filter { $0.contains("reccobeats") }.count == 1)
        #expect(partial.isrc == "USUG11904206")
    }

    @Test("a MusicBrainz 400 is skipped quietly and the lookup is still complete")
    func musicBrainz400() async throws {
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("musicbrainz.org/ws/2/isrc/", [.success(Fx.ok(Fx.musicBrainzError, status: 400))])
        let result = await client(transport).lookup(Fx.query)
        guard case .found(let found) = result else { Issue.record("expected found, got \(result)"); return }
        #expect(found.mbid == nil)
        #expect(found.genres == ["R&B"])
    }

    @Test("MusicBrainz is asked with the app's User-Agent and no genres on the ISRC call")
    func musicBrainzRequest() async {
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        _ = await client(transport).lookup(Fx.query)
        let brainz = transport.requests.filter { $0.url.host == "musicbrainz.org" }
        #expect(brainz.count == 2)
        for request in brainz {
            #expect(request.headers["User-Agent"] == "Deci/1.0 ( https://github.com/DragonF1/deci )")
        }
        #expect(brainz[0].url.absoluteString.contains("inc=artist-credits+tags"))
        #expect(!brainz[0].url.absoluteString.contains("genres"))
        #expect(brainz[1].url.absoluteString.contains("inc=genres+releases"))
    }

    @Test("MusicBrainz is held to one request a second")
    func musicBrainzThrottle() async {
        let clock = SongFactsClock()
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        _ = await client(transport, clock: clock).lookup(Fx.query)
        #expect(clock.sleeps.contains(1000))
    }

    @Test("a recording whose length is off by more than 2 s is not kept")
    func musicBrainzLength() async throws {
        let body = "{\"recordings\":[{\"id\":\"\(Fx.mbid)\",\"length\":210000}]}"
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("musicbrainz.org/ws/2/isrc/", [.success(Fx.ok(body))])
        let found = try #require(facts(await client(transport).lookup(Fx.query)))
        #expect(found.mbid == nil)
        #expect(!transport.urls.contains { $0.contains("/ws/2/recording/") })
    }

    @Test("the network being down stops the lookup at the first request")
    func networkDown() async {
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("api.deezer.com", [.failure(URLError(.notConnectedToInternet))])
        let result = await client(transport).lookup(Fx.query)
        #expect(result == .failed)
        #expect(transport.requests.count == 1)
    }

    @Test("a song the services do not know is not found, and nothing is invented")
    func notFound() async {
        let transport = StubSongFactsTransport([
            ("api.deezer.com/search", Fx.ok("{\"data\":[],\"total\":0}")),
            ("theaudiodb.com", Fx.ok("{\"track\":null}"))
        ])
        #expect(await client(transport).lookup(Fx.query) == .notFound)
    }

    @Test("a hit 3 s off the song's length is not a match")
    func durationOff() async {
        let transport = StubSongFactsTransport([
            ("api.deezer.com/search", Fx.ok(Fx.search(Fx.hit(duration: 203)))),
            ("theaudiodb.com", Fx.ok("{\"track\":null}"))
        ])
        #expect(await client(transport).lookup(Fx.query) == .notFound)
        #expect(!transport.urls.contains { $0.contains("api.deezer.com/track/") })
    }

    @Test("the best ranked passing hit is the one asked about")
    func rankPicksTrack() async {
        let search = Fx.search(Fx.hit(id: 11, rank: 5), Fx.hit(id: 22, rank: 500), Fx.hit(id: 33, rank: 50))
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("api.deezer.com/search", [.success(Fx.ok(search))])
        _ = await client(transport).lookup(Fx.query)
        #expect(transport.urls.contains { $0.hasSuffix("api.deezer.com/track/22") })
    }

    @Test("a reply over 2 MB is not read")
    func tooLarge() async {
        let big = String(repeating: " ", count: MusicSongFactsClient.maximumResponseBytes + 1)
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        transport.route("api.deezer.com/search", [.success(Fx.ok(big))])
        let result = await client(transport).lookup(Fx.query)
        #expect(result == .failed)
    }

    @Test("only the artist, title, ISRC and service ids go out, over https, with no cookies")
    func sendsLittle() async {
        let transport = StubSongFactsTransport(Fx.fullRoutes())
        _ = await client(transport).lookup(Fx.query)
        let allowed: Set<String> = ["api.deezer.com", "api.reccobeats.com", "musicbrainz.org", "www.theaudiodb.com"]
        for request in transport.requests {
            #expect(request.url.scheme == "https")
            #expect(allowed.contains(request.url.host ?? ""))
            #expect(request.method == "GET")
            #expect(request.body == nil)
            let names = Set(request.headers.keys.map { $0.lowercased() })
            #expect(names.isSubset(of: ["accept", "user-agent"]))
        }
        let search = transport.urls.first { $0.contains("/search") } ?? ""
        #expect(search == "https://api.deezer.com/search?q=The%20Weeknd%20Blinding%20Lights&limit=10")
    }

    @Test("special characters in an artist and title are escaped, not sent raw")
    func escaping() async {
        let transport = StubSongFactsTransport([("api.deezer.com/search", Fx.ok("{\"data\":[]}"))])
        let query = MusicSongFactsQuery(artist: "Beyoncé & Jay-Z", title: "Crazy in Love #1 \u{1F525}/?", durationSeconds: 236)
        _ = await client(transport).lookup(query)
        let url = transport.urls.first ?? ""
        #expect(url.hasPrefix("https://api.deezer.com/search?q=Beyonc%C3%A9%20%26%20Jay-Z%20Crazy%20in%20Love%20%231"))
        #expect(!url.contains(" "))
        #expect(!url.dropFirst(40).contains("#"))
    }
}
