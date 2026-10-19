// DeciTests/Music/LRCLibClientTests.swift
// The LRCLIB client against a scripted lrclib.net: request shapes, the get-then-search flow, the
// duration window, the cleaned-title retry, the 429 window, the inline retries of 5xx blips and the credit. The disk
// cache is the chain's now (LyricsChainTests). Made-up lyrics only.

import Foundation
import Testing
@testable import Deci

@Suite("LRCLIB client")
struct LRCLibClientTests {

    private static let userAgent = "Deci/9.9.9 (macOS; lyrics via LRCLIB)"
    private struct Rig {
        let client: LRCLibClient
        let transport: FakeLRCLib
        let clock: MutableClock
        /// Stands in for the wait between inline retries: records it and returns at once.
        let sleeper: FakeSleeper
    }

    /// `sleep` replaces the recording sleeper for a test that needs the wait to do something (move the clock, block).
    private func makeRig(
        _ transport: FakeLRCLib = FakeLRCLib(),
        clock: MutableClock = MutableClock(),
        sleeper: FakeSleeper = FakeSleeper(gated: false),
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) -> Rig {
        let wait: @Sendable (Duration) async throws -> Void = sleep ?? { try await sleeper.sleep($0) }
        let client = LRCLibClient(transport: transport, userAgent: Self.userAgent, now: { clock.now }, sleep: wait)
        return Rig(client: client, transport: transport, clock: clock, sleeper: sleeper)
    }

    private func cut(_ name: String, lines: Int = 6) -> String {
        LyricsSamples.syncedBody(lines: lines, prefix: name)
    }

    private func firstText(_ result: LyricsResult) -> String? {
        if case .synced(let lines) = result { return lines.first?.text }
        return nil
    }

    // MARK: - Request shape

    @Test("/api/get carries track, artist, album and the duration in whole seconds")
    func getRequestShape() async throws {
        let rig = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record())]))
        _ = try await rig.client.lyrics(for: LyricsSamples.query(duration: 213.4))
        let request = try #require(rig.transport.getRequests.first)
        #expect(request.url.scheme == "https")
        #expect(request.url.host == "lrclib.net")
        #expect(request.url.path == "/api/get")
        #expect(request.method == "GET")
        #expect(request.body == nil)
        #expect(FakeLRCLib.query(request) == [
            "track_name": "Test Song", "artist_name": "Test Artist", "album_name": "Test Album", "duration": "213",
        ])
    }

    @Test("Special characters in the query are escaped")
    func queryEscaping() async throws {
        let rig = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record())]))
        let query = LyricsSamples.query(title: "Rock & Roll? 100% #1", artist: "A+B / C", album: "Ça va 🎵")
        _ = try await rig.client.lyrics(for: query)
        let sent = FakeLRCLib.query(try #require(rig.transport.getRequests.first))
        #expect(sent["track_name"] == "Rock & Roll? 100% #1")
        #expect(sent["artist_name"] == "A+B / C")
        #expect(sent["album_name"] == "Ça va 🎵")
    }

    @Test("Every request names the app and sends nothing that identifies the listener")
    func noCredentialsEver() async throws {
        let rig = makeRig(FakeLRCLib(get: [.notFound], search: [.empty, .empty]))
        let query = LyricsSamples.query(title: "Test Song (Official Video)", artist: "Main Artist, Guest")
        _ = try await rig.client.lyrics(for: query)
        let requests = rig.transport.requests
        #expect(requests.count == 3)
        for request in requests {
            #expect(request.headers["User-Agent"] == Self.userAgent)
            let names = Set(request.headers.keys.map { $0.lowercased() })
            #expect(names.isSubset(of: ["user-agent", "accept"]), "unexpected headers: \(names)")
            #expect(request.body == nil)
            #expect(request.method == "GET")
            #expect(request.url.host == "lrclib.net")
            #expect(request.url.user == nil)
        }
    }

    @Test("The User-Agent is Deci/<version> (macOS; lyrics via LRCLIB)")
    func userAgentFormat() {
        #expect(LRCLibClient.userAgent(version: "1.2.3") == "Deci/1.2.3 (macOS; lyrics via LRCLIB)")
        #expect(LRCLibClient.userAgent(version: nil) == "Deci/0 (macOS; lyrics via LRCLIB)")
        #expect(LRCLibClient.userAgent(version: "  ") == "Deci/0 (macOS; lyrics via LRCLIB)")
    }

    @Test("The session is ephemeral with no cookies, cache or credentials, and a 10 s timeout")
    func sessionConfiguration() {
        let config = LRCLibClient.makeConfiguration()
        #expect(config.timeoutIntervalForRequest == 10)
        #expect(config.timeoutIntervalForResource <= 15)
        #expect(config.httpCookieStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.urlCache == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(config.waitsForConnectivity == false)
        #expect(config.identifier == nil)
    }

    // MARK: - /api/get

    @Test("A good /api/get record is the answer, with no search")
    func getHit() async throws {
        let rig = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record())]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query())
        #expect(result == .synced(LyricsSamples.syncedLines))
        #expect(rig.transport.searchRequests.isEmpty)
    }

    @Test("A record with only plain lyrics is plain")
    func getPlainOnly() async throws {
        let rig = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record(synced: nil))]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query())
        #expect(result == .plain(LyricsSamples.plain))
    }

    @Test("Synced text with no usable line falls back to the plain text")
    func unusableSyncedFallsBackToPlain() async throws {
        let rig = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record(synced: "[ar:Test Artist]\nnot lrc at all"))]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query())
        #expect(result == .plain(LyricsSamples.plain))
    }

    @Test("An instrumental record is instrumental")
    func getInstrumental() async throws {
        let rig = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record(instrumental: true, plain: nil, synced: nil))]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query()) == .instrumental)
    }

    @Test("A 404 from /api/get falls back to /api/search")
    func getNotFoundSearches() async throws {
        let rig = makeRig(FakeLRCLib(get: [.notFound], search: [.results([LyricsSamples.record(synced: cut("Found"))])]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query())
        #expect(firstText(result) == "Found 0")
        #expect(rig.transport.getRequests.count == 1)
        #expect(rig.transport.searchRequests.count == 1)
    }

    @Test("An unknown album goes straight to search")
    func noAlbumSearches() async throws {
        let rig = makeRig(FakeLRCLib(search: [.results([LyricsSamples.record(synced: cut("Found"))])]))
        for album in [nil, "", "   "] as [String?] {
            _ = try await rig.client.lyrics(for: LyricsSamples.query(videoId: "id-\(album ?? "nil")", album: album))
        }
        #expect(rig.transport.getRequests.isEmpty)
        #expect(rig.transport.searchRequests.count == 3)
    }

    @Test("An unknown duration cannot use /api/get either")
    func noDurationSearches() async throws {
        for duration in [nil, 0, -5] as [TimeInterval?] {
            let rig = makeRig(FakeLRCLib(search: [.results([LyricsSamples.record(synced: cut("Found"))])]))
            let result = try await rig.client.lyrics(for: LyricsSamples.query(duration: duration))
            #expect(firstText(result) == "Found 0")
            #expect(rig.transport.getRequests.isEmpty)
        }
    }

    @Test("A junk /api/get record (one short line) is not shown when a search finds the real one")
    func weakGetRecordYieldsToSearch() async throws {
        let junk = LyricsSamples.record(plain: "abcde", synced: "[00:00.00]abcde")
        let rig = makeRig(FakeLRCLib(get: [.record(junk)], search: [.results([LyricsSamples.record(synced: cut("Real"))])]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query())
        #expect(firstText(result) == "Real 0")
        #expect(rig.transport.searchRequests.count == 1)
    }

    @Test("A junk record with nothing better behind it is not found")
    func weakGetRecordAlone() async throws {
        let junk = LyricsSamples.record(plain: "abcde", synced: "[00:00.00]abcde")
        let rig = makeRig(FakeLRCLib(get: [.record(junk)], search: [.empty, .empty]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query()) == .notFound)
    }

    // MARK: - /api/search

    @Test("Search sends the track and artist and nothing else")
    func searchRequestShape() async throws {
        let rig = makeRig(FakeLRCLib(search: [.results([LyricsSamples.record()])]))
        _ = try await rig.client.lyrics(for: LyricsSamples.query(album: nil))
        let request = try #require(rig.transport.searchRequests.first)
        #expect(request.url.path == "/api/search")
        #expect(FakeLRCLib.query(request) == ["track_name": "Test Song", "artist_name": "Test Artist"])
    }

    @Test("Search takes the record within 2 s of the duration and prefers synced lyrics")
    func searchPicksByDurationAndSynced() async throws {
        let results = [
            LyricsSamples.record(id: 1, duration: 215, synced: cut("Far cut")),
            LyricsSamples.record(id: 2, duration: 201, synced: nil),
            LyricsSamples.record(id: 3, duration: 199, synced: cut("Near cut")),
        ]
        let rig = makeRig(FakeLRCLib(search: [.results(results)]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query(album: nil))
        #expect(firstText(result) == "Near cut 0")
    }

    @Test("With no synced record in range, plain lyrics are used")
    func searchFallsBackToPlain() async throws {
        let results = [
            LyricsSamples.record(id: 1, duration: 215, synced: cut("Far cut")),
            LyricsSamples.record(id: 2, duration: 201, plain: "Plain one\nPlain two\nPlain three\nPlain four", synced: nil),
        ]
        let rig = makeRig(FakeLRCLib(search: [.results(results)]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query(album: nil))
        #expect(result == .plain("Plain one\nPlain two\nPlain three\nPlain four"))
    }

    @Test(
        "The window is 2 s either way, inclusive",
        arguments: [(198.0, true), (202.0, true), (200.0, true), (197.9, false), (202.1, false), (260.0, false)]
    )
    func durationWindow(recordDuration: Double, accepted: Bool) async throws {
        let rig = makeRig(FakeLRCLib(search: [.results([LyricsSamples.record(duration: recordDuration, synced: cut("Cut"))])]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query(album: nil, duration: 200))
        #expect((result != .notFound) == accepted)
    }

    @Test("Without a duration the first usable record is taken")
    func searchWithoutDuration() async throws {
        let results = [LyricsSamples.record(id: 1, duration: 500, synced: cut("First cut")), LyricsSamples.record(id: 2, synced: cut("Second cut"))]
        let rig = makeRig(FakeLRCLib(search: [.results(results)]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query(album: nil, duration: nil))
        #expect(firstText(result) == "First cut 0")
    }

    @Test("A record with real lyrics beats an instrumental one")
    func lyricsBeatInstrumental() async throws {
        let results = [
            LyricsSamples.record(id: 1, instrumental: true, plain: nil, synced: nil),
            LyricsSamples.record(id: 2, synced: cut("Sung")),
        ]
        let rig = makeRig(FakeLRCLib(search: [.results(results)]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query(album: nil))
        #expect(firstText(result) == "Sung 0")
    }

    @Test("Only an instrumental record in range makes the song instrumental")
    func instrumentalFromSearch() async throws {
        let results = [
            LyricsSamples.record(id: 1, duration: 300, synced: cut("Far cut")),
            LyricsSamples.record(id: 2, instrumental: true, plain: nil, synced: nil),
        ]
        let rig = makeRig(FakeLRCLib(search: [.results(results)]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query(album: nil)) == .instrumental)
    }

    @Test("A one-line junk record loses to a real plain one")
    func searchSkipsWeakRecords() async throws {
        let results = [
            LyricsSamples.record(id: 1, plain: "abcde", synced: "[00:00.00]abcde"),
            LyricsSamples.record(id: 2, plain: "Plain one\nPlain two\nPlain three", synced: nil),
        ]
        let rig = makeRig(FakeLRCLib(search: [.results(results)]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query(album: nil))
        #expect(result == .plain("Plain one\nPlain two\nPlain three"))
    }

    @Test("Records with no lyrics at all are skipped")
    func searchSkipsEmptyRecords() async throws {
        let results = [LyricsSamples.record(id: 1, plain: nil, synced: nil), LyricsSamples.record(id: 2, plain: "", synced: "")]
        let rig = makeRig(FakeLRCLib(search: [.results(results), .results(results)]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query(album: nil)) == .notFound)
    }

    // MARK: - Identity of search hits

    @Test("A record in the duration window by another artist is not the song")
    func wrongArtistIsSkipped() async throws {
        let other = LyricsSamples.record(artist: "Somebody Else", duration: 200, synced: cut("Wrong"))
        let rig = makeRig(FakeLRCLib(search: [.results([other])]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query(title: "Test Song", artist: "Test Artist", album: nil))
        #expect(result == .notFound)
    }

    @Test("A generic title by another artist loses to the right one further down the list")
    func rightArtistWins() async throws {
        let results = [
            LyricsSamples.record(id: 1, track: "Stay", artist: "Somebody Else", duration: 200, synced: cut("Wrong")),
            LyricsSamples.record(id: 2, track: "Stay", artist: "Test Artist", duration: 201, synced: cut("Right")),
        ]
        let rig = makeRig(FakeLRCLib(search: [.results(results)]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query(title: "Stay", artist: "Test Artist", album: nil))
        #expect(firstText(result) == "Right 0")
    }

    @Test("A record by the right artist with a different title is skipped")
    func wrongTitleIsSkipped() async throws {
        let other = LyricsSamples.record(track: "Another Song", artist: "Test Artist", synced: cut("Wrong"))
        let rig = makeRig(FakeLRCLib(search: [.results([other])]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query(album: nil)) == .notFound)
    }

    @Test("A record whose title only adds (Remastered 2011) still matches")
    func remasteredRecordMatches() async throws {
        let record = LyricsSamples.record(track: "Test Song (Remastered 2011)", synced: cut("Found"))
        let rig = makeRig(FakeLRCLib(search: [.results([record])]))
        let result = try await rig.client.lyrics(for: LyricsSamples.query(album: nil))
        #expect(firstText(result) == "Found 0")
    }

    @Test("Feat. and & variants of the artist still match")
    func artistVariantsMatch() async throws {
        let record = LyricsSamples.record(artist: "Test Artist & Guest Person", synced: cut("Found"))
        let rig = makeRig(FakeLRCLib(search: [.results([record])]))
        let query = LyricsSamples.query(artist: "Test Artist feat. Someone", album: nil)
        #expect(firstText(try await rig.client.lyrics(for: query)) == "Found 0")
    }

    @Test("A wrong-artist record is skipped on the cleaned retry too")
    func retryChecksIdentity() async throws {
        let other = LyricsSamples.record(artist: "Somebody Else", synced: cut("Wrong"))
        let rig = makeRig(FakeLRCLib(search: [.empty, .results([other])]))
        let query = LyricsSamples.query(title: "Test Song (Official Video)", album: nil)
        #expect(try await rig.client.lyrics(for: query) == .notFound)
        #expect(rig.transport.searchRequests.count == 2)
    }

    @Test("An identity miss is not an instrumental answer either")
    func wrongArtistInstrumentalIsSkipped() async throws {
        let other = LyricsSamples.record(artist: "Somebody Else", instrumental: true, plain: nil, synced: nil)
        let rig = makeRig(FakeLRCLib(search: [.results([other])]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query(album: nil)) == .notFound)
    }

    // MARK: - Cleaned retry

    @Test("When search finds nothing, it retries once with the cleaned title and the first artist")
    func cleanedRetry() async throws {
        let rig = makeRig(FakeLRCLib(search: [.empty, .results([LyricsSamples.record(artist: "Main Artist", synced: cut("Found"))])]))
        let query = LyricsSamples.query(title: "Test Song (feat. Guest) [Remastered]", artist: "Main Artist, Guest", album: nil)
        let result = try await rig.client.lyrics(for: query)
        #expect(firstText(result) == "Found 0")
        let searches = rig.transport.searchRequests.map(FakeLRCLib.query)
        #expect(searches.count == 2)
        #expect(searches[0] == ["track_name": "Test Song (feat. Guest) [Remastered]", "artist_name": "Main Artist, Guest"])
        #expect(searches[1] == ["track_name": "Test Song", "artist_name": "Main Artist"])
    }

    @Test("The retry happens once, even when it finds nothing")
    func cleanedRetryIsOnce() async throws {
        let rig = makeRig(FakeLRCLib(search: [.empty]))
        let query = LyricsSamples.query(title: "Test Song (Official Video)", artist: "Main Artist & Guest", album: nil)
        #expect(try await rig.client.lyrics(for: query) == .notFound)
        #expect(rig.transport.searchRequests.count == 2)
    }

    @Test("Nothing to clean means no second search")
    func noRetryWhenAlreadyClean() async throws {
        let rig = makeRig(FakeLRCLib(search: [.empty]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query(album: nil)) == .notFound)
        #expect(rig.transport.searchRequests.count == 1)
    }

    @Test("A retry that answers with a record out of range is still not found")
    func retryRespectsTheWindow() async throws {
        let rig = makeRig(FakeLRCLib(search: [.empty, .results([LyricsSamples.record(duration: 400, synced: cut("Far"))])]))
        let query = LyricsSamples.query(title: "Test Song (Lyrics)", album: nil)
        #expect(try await rig.client.lyrics(for: query) == .notFound)
    }

    // MARK: - Busy window

    @Test("429 reads Retry-After in seconds, answers busy and sends nothing until then")
    func busyInSeconds() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(429, headers: ["Retry-After": "30"])]))
        let until = rig.clock.now.addingTimeInterval(30)
        await #expect(throws: LyricsError.busy(until: until)) {
            try await rig.client.lyrics(for: LyricsSamples.query(videoId: "a"))
        }
        #expect(rig.transport.requests.count == 1)
        #expect(await rig.client.busyUntil == until)

        // Inside the window another song sends nothing at all.
        rig.clock.advance(by: 10)
        await #expect(throws: LyricsError.busy(until: until)) {
            try await rig.client.lyrics(for: LyricsSamples.query(videoId: "b"))
        }
        #expect(rig.transport.requests.count == 1)

        // Past it the client asks again.
        rig.clock.advance(by: 21)
        rig.transport.setGet(.record(LyricsSamples.record()))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query(videoId: "b")) == .synced(LyricsSamples.syncedLines))
        #expect(rig.transport.requests.count == 2)
        #expect(await rig.client.busyUntil == nil)
    }

    @Test("Retry-After as an HTTP date")
    func busyWithHTTPDate() async throws {
        // Wed, 21 Oct 2015 07:28:00 GMT
        let target = Date(timeIntervalSince1970: 1_445_412_480)
        let clock = MutableClock(target.addingTimeInterval(-90))
        let rig = makeRig(FakeLRCLib(get: [.status(429, headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"])]), clock: clock)
        await #expect(throws: LyricsError.busy(until: target)) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
    }

    @Test("A missing, empty or unreadable Retry-After means 60 s")
    func busyDefault() async throws {
        let headers: [[String: String]] = [[:], ["Retry-After": ""], ["Retry-After": "soon"], ["Retry-After": "-5x"]]
        for header in headers {
            let rig = makeRig(FakeLRCLib(get: [.status(429, headers: header)]))
            let until = rig.clock.now.addingTimeInterval(60)
            await #expect(throws: LyricsError.busy(until: until)) {
                try await rig.client.lyrics(for: LyricsSamples.query())
            }
        }
    }

    @Test("The Retry-After header name is matched case-insensitively")
    func busyHeaderCase() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(429, headers: ["retry-after": "12"])]))
        await #expect(throws: LyricsError.busy(until: rig.clock.now.addingTimeInterval(12))) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
    }

    @Test("The wait is at least a second and at most an hour")
    func busyBounds() async throws {
        for (header, expected) in [("0", 1.0), ("99999", 3600.0)] {
            let rig = makeRig(FakeLRCLib(get: [.status(429, headers: ["Retry-After": header])]))
            await #expect(throws: LyricsError.busy(until: rig.clock.now.addingTimeInterval(expected))) {
                try await rig.client.lyrics(for: LyricsSamples.query())
            }
        }
    }

    @Test("A date already in the past still waits a second")
    func busyDateInThePast() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(429, headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"])]))
        await #expect(throws: LyricsError.busy(until: rig.clock.now.addingTimeInterval(1))) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
    }

    @Test("429 on the search step is busy too, and is never retried in a loop")
    func busyOnSearch() async throws {
        let rig = makeRig(FakeLRCLib(get: [.notFound], search: [.status(429, headers: ["Retry-After": "5"])]))
        await #expect(throws: LyricsError.busy(until: rig.clock.now.addingTimeInterval(5))) {
            try await rig.client.lyrics(for: LyricsSamples.query(title: "Test Song (Lyrics)"))
        }
        #expect(rig.transport.requests.count == 2)
    }

    @Test("A 503 with a short Retry-After is retried inline, then backs off instead of going busy")
    func overloadedIsBusy() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(503, headers: ["Retry-After": "1"], body: #"{"name":"ServerOverloaded"}"#)]))
        await #expect(throws: LyricsError.backoff(status: 503, until: rig.clock.now.addingTimeInterval(15))) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
        #expect(rig.transport.requests.count == 3)
    }

    @Test("A 503 whose Retry-After is over 5 s is busy for that long and is not retried")
    func overloadedWithLongRetryAfterIsBusy() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(503, headers: ["Retry-After": "120"])]))
        let until = rig.clock.now.addingTimeInterval(120)
        await #expect(throws: LyricsError.busy(until: until)) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
        #expect(rig.transport.requests.count == 1)
        #expect(rig.sleeper.requested.isEmpty)
        #expect(await rig.client.busyUntil == until)
    }

    @Test(
        "A 503 is a blip, retried inline, with no Retry-After or one of 5 s or less; a longer or unreadable one is busy",
        arguments: [
            (nil, true), ("", true), ("0", true), ("1", true), ("5", true),
            ("6", false), ("30", false), ("soon", false), ("Wed, 21 Oct 2015 07:28:00 GMT", true),
        ] as [(String?, Bool)]
    )
    func overloadedRetryAfterBoundary(header: String?, retried: Bool) async throws {
        let headers = header.map { ["Retry-After": $0] } ?? [:]
        let rig = makeRig(FakeLRCLib(get: [.status(503, headers: headers)]))
        await #expect(throws: LyricsError.self) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
        #expect(rig.transport.requests.count == (retried ? 3 : 1), "Retry-After \(String(describing: header))")
    }

    @Test("A 429 that arrives on a cancelled request still opens the busy window")
    func busyAfterCancellation() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(429, headers: ["Retry-After": "30"])]))
        let gate = MusicTestGate()
        rig.transport.setGate(gate)
        let client = rig.client
        let task = Task { try await client.lyrics(for: LyricsSamples.query(videoId: "a")) }
        #expect(await eventually { !rig.transport.requests.isEmpty })
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }

        let until = rig.clock.now.addingTimeInterval(30)
        #expect(await rig.client.busyUntil == until)
        // The next song sends nothing inside the window.
        await #expect(throws: LyricsError.busy(until: until)) {
            try await rig.client.lyrics(for: LyricsSamples.query(videoId: "b"))
        }
        #expect(rig.transport.requests.count == 1)
    }

    @Test("A 503 that arrives on a cancelled request opens the window too")
    func overloadedAfterCancellation() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(503, headers: ["Retry-After": "7"])]))
        let gate = MusicTestGate()
        rig.transport.setGate(gate)
        let client = rig.client
        let task = Task { try await client.lyrics(for: LyricsSamples.query()) }
        #expect(await eventually { !rig.transport.requests.isEmpty })
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await rig.client.busyUntil == rig.clock.now.addingTimeInterval(7))
    }

    @Test("A cancelled request that got a good answer opens no window")
    func cancelledSuccessOpensNoWindow() async throws {
        let rig = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record())]))
        let gate = MusicTestGate()
        rig.transport.setGate(gate)
        let client = rig.client
        let task = Task { try await client.lyrics(for: LyricsSamples.query()) }
        #expect(await eventually { !rig.transport.requests.isEmpty })
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await rig.client.busyUntil == nil)
    }

    // MARK: - Server errors back off

    @Test(
        "After the inline retries a 500, 502, 504 or a 503 with no Retry-After opens a 15 s window, reported with its status",
        arguments: [500, 502, 503, 504]
    )
    func serverErrorBacksOff(status: Int) async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(status)]))
        let until = rig.clock.now.addingTimeInterval(15)
        await #expect(throws: LyricsError.backoff(status: status, until: until)) {
            try await rig.client.lyrics(for: LyricsSamples.query(videoId: "a"))
        }
        #expect(rig.transport.requests.count == 3)
        #expect(await rig.client.busyUntil == until)

        // Inside the window another song sends nothing; it is told to wait.
        rig.clock.advance(by: 10)
        await #expect(throws: LyricsError.busy(until: until)) {
            try await rig.client.lyrics(for: LyricsSamples.query(videoId: "b"))
        }
        #expect(rig.transport.requests.count == 3)

        // Past it the client asks again.
        rig.clock.advance(by: 6)
        rig.transport.setGet(.record(LyricsSamples.record()))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query(videoId: "b")) == .synced(LyricsSamples.syncedLines))
        #expect(rig.transport.requests.count == 4)
    }

    @Test("A Retry-After on a 500 is ignored: the window is 15 s")
    func serverErrorIgnoresRetryAfter() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(500, headers: ["Retry-After": "900"])]))
        await #expect(throws: LyricsError.backoff(status: 500, until: rig.clock.now.addingTimeInterval(15))) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
    }

    @Test("A server error on the search step is retried and backs off too")
    func serverErrorOnSearch() async throws {
        let rig = makeRig(FakeLRCLib(get: [.notFound], search: [.status(502)]))
        await #expect(throws: LyricsError.backoff(status: 502, until: rig.clock.now.addingTimeInterval(15))) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
        #expect(rig.transport.getRequests.count == 1)
        #expect(rig.transport.searchRequests.count == 3)
    }

    // MARK: - Inline retries of transient errors

    @Test("A transient status is retried and the second attempt can succeed, with a 1 s wait and no window", arguments: [500, 502, 503, 504])
    func transientRecoversOnTheSecondAttempt(status: Int) async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(status), .record(LyricsSamples.record())]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query()) == .synced(LyricsSamples.syncedLines))
        #expect(rig.transport.requests.count == 2)
        #expect(rig.sleeper.requested == [.seconds(1)])
        #expect(await rig.client.busyUntil == nil)
    }

    @Test("The third attempt is waited for 3 s and can succeed")
    func transientRecoversOnTheThirdAttempt() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(503), .status(500), .record(LyricsSamples.record())]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query()) == .synced(LyricsSamples.syncedLines))
        #expect(rig.transport.requests.count == 3)
        #expect(rig.sleeper.requested == [.seconds(1), .seconds(3)])
        #expect(await rig.client.busyUntil == nil)
    }

    @Test("A retry sends the same request again")
    func retrySendsTheSameRequest() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(502), .record(LyricsSamples.record())]))
        _ = try await rig.client.lyrics(for: LyricsSamples.query())
        let sent = rig.transport.requests
        #expect(sent.count == 2)
        #expect(sent[0] == sent[1])
    }

    @Test("The search step retries too, and a get that missed is not repeated")
    func transientOnSearchRecovers() async throws {
        let rig = makeRig(FakeLRCLib(
            get: [.notFound],
            search: [.status(503), .results([LyricsSamples.record(synced: cut("Found"))])]
        ))
        let result = try await rig.client.lyrics(for: LyricsSamples.query())
        #expect(firstText(result) == "Found 0")
        #expect(rig.transport.getRequests.count == 1)
        #expect(rig.transport.searchRequests.count == 2)
        #expect(rig.sleeper.requested == [.seconds(1)])
    }

    @Test("Three failed attempts in all, 1 s then 3 s apart, then a 15 s backoff", arguments: [500, 502, 503, 504])
    func transientGivesUpAfterThreeAttempts(status: Int) async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(status)]))
        let until = rig.clock.now.addingTimeInterval(15)
        await #expect(throws: LyricsError.backoff(status: status, until: until)) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
        #expect(rig.transport.requests.count == 3)
        #expect(rig.sleeper.requested == [.seconds(1), .seconds(3)])
        #expect(await rig.client.busyUntil == until)
    }

    @Test("The window starts when the last attempt fails, not when the first did")
    func windowStartsAfterTheLastAttempt() async throws {
        let clock = MutableClock()
        let start = clock.now
        let rig = makeRig(FakeLRCLib(get: [.status(500)]), clock: clock, sleep: { duration in
            clock.advance(by: Double(duration.components.seconds))
        })
        await #expect(throws: LyricsError.backoff(status: 500, until: start.addingTimeInterval(1 + 3 + 15))) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
    }

    @Test(
        "A 429 is never retried inline, whatever its Retry-After: it stays busy for the window it names",
        arguments: [(nil, 60.0), ("2", 2.0), ("90", 90.0)] as [(String?, TimeInterval)]
    )
    func tooManyRequestsIsNotRetried(header: String?, seconds: TimeInterval) async throws {
        let headers = header.map { ["Retry-After": $0] } ?? [:]
        let rig = makeRig(FakeLRCLib(get: [.status(429, headers: headers), .record(LyricsSamples.record())]))
        await #expect(throws: LyricsError.busy(until: rig.clock.now.addingTimeInterval(seconds))) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
        #expect(rig.transport.requests.count == 1)
        #expect(rig.sleeper.requested.isEmpty)
    }

    @Test("Other errors and a 404 are not retried either", arguments: [400, 403, 404, 501, 505])
    func otherStatusesAreNotRetried(status: Int) async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(status), .record(LyricsSamples.record())], search: [.empty]))
        _ = try? await rig.client.lyrics(for: LyricsSamples.query())
        #expect(rig.transport.getRequests.count == 1)
        #expect(rig.sleeper.requested.isEmpty)
    }

    @Test("A cancel during the retry wait throws and opens no window, even when the timer ignores cancellation")
    func cancellationDuringTheRetryWait() async throws {
        let sleeper = FakeSleeper()
        let rig = makeRig(FakeLRCLib(get: [.status(503)]), sleeper: sleeper)
        let client = rig.client
        let task = Task { try await client.lyrics(for: LyricsSamples.query(videoId: "a")) }
        #expect(await eventually { sleeper.requested.count == 1 })
        task.cancel()
        await sleeper.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(rig.transport.requests.count == 1)
        #expect(await rig.client.busyUntil == nil)

        // Nothing holds the next song back.
        rig.transport.setGet(.record(LyricsSamples.record()))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query(videoId: "b")) == .synced(LyricsSamples.syncedLines))
    }

    @Test("A cancel during a timer that honours it opens no window and sends no more")
    func cancellationLeavesTheTimerEarly() async throws {
        let waiting = FakeSleeper(gated: false)
        let rig = makeRig(FakeLRCLib(get: [.status(500)]), sleep: { duration in
            try await waiting.sleep(duration)
            try await Task.sleep(for: .seconds(60))
        })
        let client = rig.client
        let task = Task { try await client.lyrics(for: LyricsSamples.query()) }
        #expect(await eventually { waiting.requested.count == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(rig.transport.requests.count == 1)
        #expect(await rig.client.busyUntil == nil)
    }

    @Test("A request cancelled before its transient answer arrives does not wait or retry")
    func cancelledBeforeTheTransientAnswer() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(502)]))
        let gate = MusicTestGate()
        rig.transport.setGate(gate)
        let client = rig.client
        let task = Task { try await client.lyrics(for: LyricsSamples.query()) }
        #expect(await eventually { !rig.transport.requests.isEmpty })
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(rig.transport.requests.count == 1)
        #expect(rig.sleeper.requested.isEmpty)
        #expect(await rig.client.busyUntil == nil)
    }

    @Test("The backoff window lives in memory only: a new client is not held")
    func serverErrorWindowIsNotPersisted() async throws {
        let rig = makeRig(FakeLRCLib(get: [.status(500)]))
        _ = try? await rig.client.lyrics(for: LyricsSamples.query())
        let fresh = FakeLRCLib(get: [.record(LyricsSamples.record())])
        let other = LRCLibClient(transport: fresh, userAgent: Self.userAgent, now: { rig.clock.now })
        #expect(try await other.lyrics(for: LyricsSamples.query()) == .synced(LyricsSamples.syncedLines))
        #expect(fresh.requests.count == 1)
    }

    // MARK: - Failures

    @Test("Other HTTP errors are reported with their status and open no window")
    func httpErrors() async throws {
        for status in [400, 401, 403, 501, 505] {
            let rig = makeRig(FakeLRCLib(get: [.status(status)]))
            await #expect(throws: LyricsError.http(status)) {
                try await rig.client.lyrics(for: LyricsSamples.query())
            }
            #expect(await rig.client.busyUntil == nil)
        }
    }

    @Test("A network failure is thrown as it is, and the next call goes out again")
    func networkFailure() async throws {
        let rig = makeRig(FakeLRCLib(get: [.fail(.notConnectedToInternet)]))
        await #expect(throws: URLError.self) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
        // The next call goes out again.
        rig.transport.setGet(.record(LyricsSamples.record()))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query()) == .synced(LyricsSamples.syncedLines))
    }

    @Test("A body that is not JSON is a parse error")
    func garbageBody() async throws {
        let rig = makeRig(FakeLRCLib(get: [.ok(Data("<html>oops</html>".utf8))]))
        await #expect(throws: LyricsError.parse) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
    }

    @Test("A search body that is not a list is a parse error")
    func searchBodyShape() async throws {
        let rig = makeRig(FakeLRCLib(search: [.ok(Data("{}".utf8))]))
        await #expect(throws: LyricsError.parse) {
            try await rig.client.lyrics(for: LyricsSamples.query(album: nil))
        }
    }

    @Test("A cancelled lookup throws")
    func cancellation() async throws {
        let rig = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record())]))
        let gate = MusicTestGate()
        rig.transport.setGate(gate)
        let client = rig.client
        let task = Task { try await client.lyrics(for: LyricsSamples.query()) }
        #expect(await eventually { !rig.transport.requests.isEmpty })
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: - Response size

    /// A valid empty search answer padded with blanks to exactly `bytes` bytes.
    private func paddedList(bytes: Int) -> Data {
        Data("[]".utf8) + Data(repeating: UInt8(ascii: " "), count: bytes - 2)
    }

    @Test("A body of exactly 2 MB is read")
    func bodyAtTheCap() async throws {
        #expect(LRCLibClient.maximumResponseBytes == 2 * 1024 * 1024)
        let rig = makeRig(FakeLRCLib(search: [.ok(paddedList(bytes: LRCLibClient.maximumResponseBytes))]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query(album: nil)) == .notFound)
    }

    @Test("A body over 2 MB is a failure, never parsed")
    func bodyOverTheCap() async throws {
        let rig = makeRig(FakeLRCLib(search: [.ok(paddedList(bytes: LRCLibClient.maximumResponseBytes + 1))]))
        await #expect(throws: LyricsError.parse) {
            try await rig.client.lyrics(for: LyricsSamples.query(album: nil))
        }
        #expect(rig.transport.searchRequests.count == 1)
    }

    @Test("An oversized /api/get body is a failure too")
    func getBodyOverTheCap() async throws {
        let rig = makeRig(FakeLRCLib(get: [.ok(Data(repeating: UInt8(ascii: " "), count: LRCLibClient.maximumResponseBytes + 1))]))
        await #expect(throws: LyricsError.parse) {
            try await rig.client.lyrics(for: LyricsSamples.query())
        }
    }

    // MARK: - Credit, length and no cache

    @Test("Synced and plain answers are credited to LRCLIB; instrumental and not found have no credit")
    func credit() async throws {
        #expect(LRCLibClient.credit == "Lyrics from LRCLIB")
        let synced = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record())]))
        #expect(try await synced.client.answer(for: LyricsSamples.query()).credit == "Lyrics from LRCLIB")
        let plain = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record(synced: nil))]))
        #expect(try await plain.client.answer(for: LyricsSamples.query()).credit == "Lyrics from LRCLIB")
        let instrumental = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record(instrumental: true, plain: nil, synced: nil))]))
        let instrumentalAnswer = try await instrumental.client.answer(for: LyricsSamples.query())
        #expect(instrumentalAnswer.result == .instrumental)
        #expect(instrumentalAnswer.credit == nil)
        let missing = makeRig()
        let missingAnswer = try await missing.client.answer(for: LyricsSamples.query())
        #expect(missingAnswer.result == .notFound)
        #expect(missingAnswer.credit == nil)
    }

    @Test("lyrics(for:) is the answer without the credit")
    func lyricsIsTheAnswersResult() async throws {
        let rig = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record())]))
        #expect(try await rig.client.lyrics(for: LyricsSamples.query()) == .synced(LyricsSamples.syncedLines))
    }

    @Test("An answer found without the exact length is a guess worth redoing; with it, it is final")
    func lengthMatters() async throws {
        let rig = makeRig(FakeLRCLib(search: [.results([LyricsSamples.record(synced: cut("Found"))])]))
        for duration in [nil, 0, -3] as [TimeInterval?] {
            let blind = try await rig.client.answer(for: LyricsSamples.query(album: nil, duration: duration))
            #expect(blind.lengthMatters == true, "duration \(String(describing: duration))")
        }
        let exact = try await rig.client.answer(for: LyricsSamples.query(album: nil, duration: 200))
        #expect(exact.lengthMatters == false)
    }

    @Test("The client keeps nothing: the same lookup is sent again, since the chain owns the cache")
    func noCacheOfItsOwn() async throws {
        let rig = makeRig(FakeLRCLib(get: [.record(LyricsSamples.record())]))
        _ = try await rig.client.lyrics(for: LyricsSamples.query())
        _ = try await rig.client.lyrics(for: LyricsSamples.query())
        #expect(rig.transport.requests.count == 2)
    }

    @Test("live() builds a client that is not holding anything back")
    func liveBuilds() async {
        #expect(await LRCLibClient.live().busyUntil == nil)
    }
}
