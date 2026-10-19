// DeciTests/Music/LyricsChainTests.swift
// The provider the store uses: a disk cache, then YouTube Music, then LRCLIB. Which answer wins, what a failing source
// does to the other, what is cached and what is not, and the credit that rides along. The first suites use scripted
// legs; the last runs the two real clients over scripted servers. Made-up lyrics only.

import Foundation
import Testing
@testable import Deci

private nonisolated let ytmCredit = "Lyrics from Test Provider via YouTube Music"
private nonisolated let lrclibCredit = "Lyrics from LRCLIB"
private nonisolated let day: TimeInterval = 86_400

private nonisolated let ytmLines = [
    LyricLine(time: 2, text: "Line one"),
    LyricLine(time: 4, text: "Line two"),
    LyricLine(time: 6, text: "Line three"),
    LyricLine(time: 8, text: ""),
]
private nonisolated let ytmPlain = "Line one\nLine two\nLine three"
private nonisolated let lrclibLines = LyricsSamples.syncedLines
private nonisolated let lrclibPlain = LyricsSamples.plain

/// Every failure the chain has to carry from one leg or the other.
private nonisolated let failures: [LyricsError] = [
    .busy(until: Date(timeIntervalSince1970: 5_000)),
    .backoff(status: 503, until: Date(timeIntervalSince1970: 5_000)),
    .http(500),
    .parse,
]

private struct Rig {
    let chain: LyricsChain
    let ytm: FakeLyricsProvider
    let lrclib: FakeLyricsProvider
    let cache: LyricsDiskCache
    let clock: MutableClock
    let directory: URL

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    /// The cache's own file for a video, for the tests that read or damage it.
    func file(_ videoId: String = "vid1") -> URL {
        directory.appendingPathComponent("Lyrics").appendingPathComponent(LyricsDiskCache.fileName(forVideoId: videoId))
    }

    var requestCount: Int { ytm.queries.count + lrclib.queries.count }
}

private func makeRig() -> Rig {
    let clock = MutableClock()
    let directory = makeTemporaryDirectory("deci-chain")
    let cache = LyricsDiskCache(directory: directory.appendingPathComponent("Lyrics", isDirectory: true), now: { clock.now })
    let ytm = FakeLyricsProvider()
    let lrclib = FakeLyricsProvider()
    return Rig(
        chain: LyricsChain(primary: ytm, fallback: lrclib, cache: cache),
        ytm: ytm, lrclib: lrclib, cache: cache, clock: clock, directory: directory
    )
}

// MARK: - Which answer wins

@Suite("Lyrics chain: sources")
struct LyricsChainSourceTests {

    @Test("Synced lyrics from YouTube Music are the answer and LRCLIB is never asked")
    func ytmSyncedShortCircuits() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        rig.ytm.setCredit(ytmCredit, for: "vid1")
        rig.lrclib.setResult(.synced(lrclibLines), for: "vid1")
        let answer = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(answer.result == .synced(ytmLines))
        #expect(answer.credit == ytmCredit)
        #expect(rig.ytm.queries.count == 1)
        #expect(rig.lrclib.queries.isEmpty)
    }

    @Test("YouTube Music's answer does not depend on the length, so a late length changes nothing")
    func ytmAnswerIsFinal() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        #expect(try await rig.chain.answer(for: LyricsSamples.query(duration: nil)).lengthMatters == false)
        rig.ytm.setResult(.plain(ytmPlain), for: "vid2")
        #expect(try await rig.chain.answer(for: LyricsSamples.query(videoId: "vid2", duration: nil)).lengthMatters == false)
    }

    @Test("Plain from YouTube Music and synced from LRCLIB: synced from any source wins")
    func lrclibSyncedBeatsYtmPlain() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.plain(ytmPlain), for: "vid1")
        rig.ytm.setCredit(ytmCredit, for: "vid1")
        rig.lrclib.setResult(.synced(lrclibLines), for: "vid1")
        rig.lrclib.setCredit(lrclibCredit, for: "vid1")
        let answer = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(answer.result == .synced(lrclibLines))
        #expect(answer.credit == lrclibCredit)
        #expect(rig.ytm.queries.count == 1)
        #expect(rig.lrclib.queries.count == 1)
    }

    @Test("Plain from YouTube Music and nothing synced at LRCLIB: YouTube Music's plain lyrics", arguments: [
        LyricsResult.notFound, .instrumental, .plain(lrclibPlain),
    ])
    func ytmPlainBeatsTheRest(lrclib: LyricsResult) async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.plain(ytmPlain), for: "vid1")
        rig.ytm.setCredit(ytmCredit, for: "vid1")
        rig.lrclib.setResult(lrclib, for: "vid1")
        rig.lrclib.setCredit(lrclibCredit, for: "vid1")
        let answer = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(answer.result == .plain(ytmPlain))
        #expect(answer.credit == ytmCredit)
        #expect(answer.lengthMatters == false)
    }

    @Test("Nothing at YouTube Music: LRCLIB's synced, plain and instrumental answers stand, with LRCLIB's credit", arguments: [
        LyricsResult.synced(lrclibLines), .plain(lrclibPlain), .instrumental,
    ])
    func lrclibAnswersWhenYtmHasNothing(lrclib: LyricsResult) async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.lrclib.setResult(lrclib, for: "vid1")
        rig.lrclib.setCredit(lrclibCredit, for: "vid1")
        let answer = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(answer.result == lrclib)
        #expect(answer.credit == lrclibCredit)
        #expect(rig.ytm.queries.count == 1)
        #expect(rig.lrclib.queries.count == 1)
    }

    @Test("Neither source knows the song: not found, with no credit")
    func bothHaveNothing() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let answer = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(answer.result == .notFound)
        #expect(answer.credit == nil)
    }

    @Test("A leg that has no answer for the chain to use, like an instrumental from YouTube Music, is skipped")
    func ytmInstrumentalIsIgnored() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.instrumental, for: "vid1")
        rig.lrclib.setResult(.plain(lrclibPlain), for: "vid1")
        #expect(try await rig.chain.answer(for: LyricsSamples.query()).result == .plain(lrclibPlain))
    }

    @Test("Both sources get the same query")
    func sameQuery() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let query = LyricsSamples.query(videoId: "vidQ", title: "Some Title", artist: "Some Artist", album: nil, duration: 123.5)
        _ = try await rig.chain.answer(for: query)
        #expect(rig.ytm.queries == [query])
        #expect(rig.lrclib.queries == [query])
    }

    @Test("lyrics(for:) is the answer without the credit")
    func lyricsIsTheResult() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        #expect(try await rig.chain.lyrics(for: LyricsSamples.query()) == .synced(ytmLines))
    }
}

// MARK: - Failures

@Suite("Lyrics chain: failures")
struct LyricsChainFailureTests {

    @Test("LRCLIB that is busy, backing off or failing does not hide YouTube Music's plain lyrics", arguments: failures)
    func lrclibFailureKeepsYtmPlain(error: LyricsError) async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.plain(ytmPlain), for: "vid1")
        rig.ytm.setCredit(ytmCredit, for: "vid1")
        rig.lrclib.setError(error, for: "vid1")
        let answer = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(answer.result == .plain(ytmPlain))
        #expect(answer.credit == ytmCredit)
    }

    @Test("A network failure at LRCLIB does not hide YouTube Music's plain lyrics either")
    func lrclibNetworkFailureKeepsYtmPlain() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.plain(ytmPlain), for: "vid1")
        rig.lrclib.setError(URLError(.notConnectedToInternet), for: "vid1")
        #expect(try await rig.chain.answer(for: LyricsSamples.query()).result == .plain(ytmPlain))
    }

    @Test("LRCLIB's failure is thrown as it is when YouTube Music had nothing", arguments: failures)
    func lrclibFailureIsRethrown(error: LyricsError) async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.lrclib.setError(error, for: "vid1")
        await #expect(throws: error) { try await rig.chain.answer(for: LyricsSamples.query()) }
    }

    @Test("A network failure at LRCLIB is thrown as it is when YouTube Music had nothing")
    func lrclibNetworkFailureIsRethrown() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.lrclib.setError(URLError(.timedOut), for: "vid1")
        await #expect(throws: URLError.self) { try await rig.chain.answer(for: LyricsSamples.query()) }
    }

    @Test("When both sources fail, LRCLIB's failure is the one thrown", arguments: failures)
    func bothFail(error: LyricsError) async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setError(LyricsError.http(418), for: "vid1")
        rig.lrclib.setError(error, for: "vid1")
        await #expect(throws: error) { try await rig.chain.answer(for: LyricsSamples.query()) }
    }

    @Test("A failure at YouTube Music falls through to LRCLIB, whose lyrics are used", arguments: failures)
    func ytmFailureFallsThrough(error: LyricsError) async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setError(error, for: "vid1")
        rig.lrclib.setResult(.synced(lrclibLines), for: "vid1")
        rig.lrclib.setCredit(lrclibCredit, for: "vid1")
        let answer = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(answer.result == .synced(lrclibLines))
        #expect(answer.credit == lrclibCredit)
    }

    @Test("A network failure at YouTube Music falls through to LRCLIB too")
    func ytmNetworkFailureFallsThrough() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setError(URLError(.cannotConnectToHost), for: "vid1")
        rig.lrclib.setResult(.plain(lrclibPlain), for: "vid1")
        #expect(try await rig.chain.answer(for: LyricsSamples.query()).result == .plain(lrclibPlain))
    }

    @Test("A failure at YouTube Music and not found at LRCLIB is not found")
    func ytmFailureThenNotFound() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setError(LyricsError.busy(until: Date(timeIntervalSince1970: 5_000)), for: "vid1")
        #expect(try await rig.chain.answer(for: LyricsSamples.query()).result == .notFound)
    }

    @Test("A cancellation at YouTube Music is thrown at once and LRCLIB is not asked")
    func cancellationAtYtm() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setError(CancellationError(), for: "vid1")
        await #expect(throws: CancellationError.self) { try await rig.chain.answer(for: LyricsSamples.query()) }
        #expect(rig.lrclib.queries.isEmpty)
    }

    @Test("A cancellation at LRCLIB is thrown even when YouTube Music had plain lyrics")
    func cancellationAtLrclib() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.plain(ytmPlain), for: "vid1")
        rig.lrclib.setError(CancellationError(), for: "vid1")
        await #expect(throws: CancellationError.self) { try await rig.chain.answer(for: LyricsSamples.query()) }
    }

    @Test("A cancelled lookup throws and writes nothing, even when the answer came back")
    func cancelledWritesNothing() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let gate = MusicTestGate()
        rig.ytm.setGate(gate, for: "vid1")
        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        let chain = rig.chain
        let task = Task { try await chain.answer(for: LyricsSamples.query()) }
        #expect(await eventually { rig.ytm.queries.count == 1 })
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await rig.cache.cached(videoId: "vid1") == nil)
        #expect(rig.lrclib.queries.isEmpty)
    }
}

// MARK: - The cache

@Suite("Lyrics chain: cache")
struct LyricsChainCacheTests {

    @Test("A cached answer is served with no request to either source, even while both would fail")
    func hitSendsNothing() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        rig.ytm.setCredit(ytmCredit, for: "vid1")
        let first = try await rig.chain.answer(for: LyricsSamples.query())
        rig.ytm.setError(LyricsError.http(500), for: "vid1")
        rig.lrclib.setError(LyricsError.busy(until: Date(timeIntervalSince1970: 5_000)), for: "vid1")
        let second = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(second.result == first.result)
        #expect(rig.ytm.queries.count == 1)
        #expect(rig.lrclib.queries.isEmpty)
    }

    @Test("A cache hit is final: its length no longer matters")
    func hitIsFinal() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.lrclib.setResult(.synced(lrclibLines), for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query(duration: 200))
        #expect(try await rig.chain.answer(for: LyricsSamples.query(duration: nil)).lengthMatters == false)
    }

    @Test("The credit comes back from the cache with the lyrics", arguments: [
        (LyricsResult.synced(ytmLines), ytmCredit),
        (LyricsResult.plain(ytmPlain), ytmCredit),
        (LyricsResult.synced(ytmLines), nil),
    ] as [(LyricsResult, String?)])
    func creditRoundTrips(result: LyricsResult, credit: String?) async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(result, for: "vid1")
        rig.ytm.setCredit(credit, for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query())
        let hit = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(hit.result == result)
        #expect(hit.credit == credit)
        #expect(rig.ytm.queries.count == 1)
    }

    @Test("LRCLIB's credit comes back from the cache too")
    func lrclibCreditRoundTrips() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.lrclib.setResult(.plain(lrclibPlain), for: "vid1")
        rig.lrclib.setCredit(lrclibCredit, for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query())
        let hit = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(hit.result == .plain(lrclibPlain))
        #expect(hit.credit == lrclibCredit)
        #expect(rig.lrclib.queries.count == 1)
    }

    @Test("The credit survives a new chain over the same directory")
    func creditSurvivesAChain() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        rig.ytm.setCredit(ytmCredit, for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query())

        let other = LyricsChain(primary: FakeLyricsProvider(), fallback: FakeLyricsProvider(), cache: rig.cache)
        let hit = try await other.answer(for: LyricsSamples.query())
        #expect(hit.result == .synced(ytmLines))
        #expect(hit.credit == ytmCredit)
    }

    @Test("A YouTube Music answer is stored whatever length the player knows", arguments: [nil, 0, -3, 200] as [TimeInterval?])
    func ytmIsStoredWithoutALength(duration: TimeInterval?) async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        rig.ytm.setCredit(ytmCredit, for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query(duration: duration))
        let stored = await rig.cache.cached(videoId: "vid1")
        #expect(stored?.result == .synced(ytmLines), "duration \(String(describing: duration))")
        #expect(stored?.credit == ytmCredit)
    }

    @Test("YouTube Music's plain lyrics are stored whatever length the player knows", arguments: [nil, 200] as [TimeInterval?])
    func ytmPlainIsStoredWithoutALength(duration: TimeInterval?) async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.plain(ytmPlain), for: "vid1")
        rig.ytm.setCredit(ytmCredit, for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query(duration: duration))
        #expect(await rig.cache.cached(videoId: "vid1")?.result == .plain(ytmPlain))
    }

    @Test("A lookup that got YouTube Music's lyrics with no length costs no request when the length arrives")
    func lateLengthIsFree() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query(duration: nil))
        _ = try await rig.chain.answer(for: LyricsSamples.query(duration: 213.4))
        #expect(rig.requestCount == 1)
    }

    @Test("An LRCLIB answer found with no known length is not stored: it may be a guess", arguments: [
        LyricsResult.synced(lrclibLines), .plain(lrclibPlain), .instrumental, .notFound,
    ])
    func lrclibWithoutALengthIsNotStored(result: LyricsResult) async throws {
        for duration in [nil, 0, -3] as [TimeInterval?] {
            let rig = makeRig()
            defer { rig.cleanUp() }
            rig.lrclib.setResult(result, for: "vid1")
            _ = try await rig.chain.answer(for: LyricsSamples.query(duration: duration))
            #expect(await rig.cache.cached(videoId: "vid1") == nil, "duration \(String(describing: duration))")
            _ = try await rig.chain.answer(for: LyricsSamples.query(duration: duration))
            #expect(rig.lrclib.queries.count == 2)
        }
    }

    @Test("An LRCLIB answer found with a known length is stored, with its credit", arguments: [
        LyricsResult.synced(lrclibLines), .plain(lrclibPlain), .instrumental, .notFound,
    ])
    func lrclibWithALengthIsStored(result: LyricsResult) async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.lrclib.setResult(result, for: "vid1")
        rig.lrclib.setCredit(lrclibCredit, for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query(duration: 200))
        let stored = await rig.cache.cached(videoId: "vid1")
        #expect(stored?.result == result)
        #expect(stored?.credit == lrclibCredit)
    }

    @Test("Synced lyrics from LRCLIB over YouTube Music's plain are stored as LRCLIB's, with a length")
    func lrclibSyncedOverYtmPlainIsStored() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.plain(ytmPlain), for: "vid1")
        rig.ytm.setCredit(ytmCredit, for: "vid1")
        rig.lrclib.setResult(.synced(lrclibLines), for: "vid1")
        rig.lrclib.setCredit(lrclibCredit, for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query(duration: 200))
        let stored = await rig.cache.cached(videoId: "vid1")
        #expect(stored?.result == .synced(lrclibLines))
        #expect(stored?.credit == lrclibCredit)
    }

    @Test("Nothing is stored when YouTube Music failed: a blip must not cache not found for 3 days", arguments: failures)
    func ytmFailureIsNeverStored(error: LyricsError) async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setError(error, for: "vid1")
        #expect(try await rig.chain.answer(for: LyricsSamples.query()).result == .notFound)
        #expect(await rig.cache.cached(videoId: "vid1") == nil)
        _ = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(rig.ytm.queries.count == 2)
        #expect(rig.lrclib.queries.count == 2)
    }

    @Test("Nothing is stored when YouTube Music failed, even if LRCLIB found synced lyrics")
    func ytmFailureWithLrclibFoundIsNotStored() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setError(LyricsError.http(500), for: "vid1")
        rig.lrclib.setResult(.synced(lrclibLines), for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(await rig.cache.cached(videoId: "vid1") == nil)
    }

    @Test("Nothing is stored when LRCLIB failed, even if YouTube Music had plain lyrics", arguments: failures)
    func lrclibFailureIsNeverStored(error: LyricsError) async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.plain(ytmPlain), for: "vid1")
        rig.lrclib.setError(error, for: "vid1")
        _ = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(await rig.cache.cached(videoId: "vid1") == nil)
        // The next lookup asks again, and LRCLIB, now well, can upgrade the plain lyrics to synced ones.
        rig.lrclib.setError(nil, for: "vid1")
        rig.lrclib.setResult(.synced(lrclibLines), for: "vid1")
        #expect(try await rig.chain.answer(for: LyricsSamples.query()).result == .synced(lrclibLines))
    }

    @Test("A failure is never stored when no source had anything", arguments: failures)
    func failureIsNeverStored(error: LyricsError) async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.lrclib.setError(error, for: "vid1")
        _ = try? await rig.chain.answer(for: LyricsSamples.query())
        #expect(await rig.cache.cached(videoId: "vid1") == nil)
    }

    @Test("A different video is a different entry")
    func keyIsTheVideo() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.synced(ytmLines), for: "a")
        rig.ytm.setResult(.synced(ytmLines), for: "b")
        _ = try await rig.chain.answer(for: LyricsSamples.query(videoId: "a"))
        _ = try await rig.chain.answer(for: LyricsSamples.query(videoId: "b"))
        #expect(rig.ytm.queries.count == 2)
    }

    @Test("Not found is stored for 3 days, then asked for again")
    func notFoundExpires() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let query = LyricsSamples.query()
        #expect(try await rig.chain.answer(for: query).result == .notFound)
        #expect(try await rig.chain.answer(for: query).result == .notFound)
        #expect(rig.requestCount == 2)

        rig.clock.advance(by: 3 * day + 1)
        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        #expect(try await rig.chain.answer(for: query).result == .synced(ytmLines))
        #expect(rig.requestCount == 3)
    }

    @Test("Found lyrics are stored for 30 days, then asked for again")
    func foundExpires() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        let query = LyricsSamples.query()
        _ = try await rig.chain.answer(for: query)
        rig.clock.advance(by: 29 * day)
        _ = try await rig.chain.answer(for: query)
        #expect(rig.ytm.queries.count == 1)
        rig.clock.advance(by: 2 * day)
        _ = try await rig.chain.answer(for: query)
        #expect(rig.ytm.queries.count == 2)
    }

    @Test("A version 1 file, from before YouTube Music, is ignored and replaced")
    func versionOneIsIgnored() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        // What the old client wrote for a song it could not find: it would block YouTube Music for 3 days.
        let stale: [String: Any] = ["version": 1, "storedAt": rig.clock.now.timeIntervalSince1970, "kind": "notFound"]
        try FileManager.default.createDirectory(at: rig.file().deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: stale).write(to: rig.file())

        rig.ytm.setResult(.synced(ytmLines), for: "vid1")
        rig.ytm.setCredit(ytmCredit, for: "vid1")
        let answer = try await rig.chain.answer(for: LyricsSamples.query())
        #expect(answer.result == .synced(ytmLines))
        #expect(rig.ytm.queries.count == 1)

        let rewritten = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: rig.file())) as? [String: Any])
        #expect(rewritten["version"] as? Int == 2)
        #expect(rewritten["credit"] as? String == ytmCredit)
    }

    @Test("A version 1 file holding found lyrics is ignored too")
    func versionOneFoundIsIgnored() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let stale: [String: Any] = [
            "version": 1, "storedAt": rig.clock.now.timeIntervalSince1970, "kind": "plain", "text": "Old line one\nOld line two",
        ]
        try FileManager.default.createDirectory(at: rig.file().deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: stale).write(to: rig.file())
        rig.ytm.setResult(.plain(ytmPlain), for: "vid1")
        #expect(try await rig.chain.answer(for: LyricsSamples.query()).result == .plain(ytmPlain))
    }
}

// MARK: - The two real clients

/// The chain over `YTMusicLyricsClient` and `LRCLibClient`, each over its own scripted server: what the live app does,
/// and the cache coverage that used to live in the LRCLIB client's own tests.
@Suite("Lyrics chain: real clients")
struct LyricsChainRealClientTests {

    private struct Real {
        let chain: LyricsChain
        let ytm: FakeYTMusic
        let lrclib: FakeLRCLib
        let ytmClient: YTMusicLyricsClient
        let lrclibClient: LRCLibClient
        let cache: LyricsDiskCache
        let clock: MutableClock
        let sleeper: FakeSleeper
        let directory: URL

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeReal(
        ytm: FakeYTMusic = FakeYTMusic(next: [.ok(YTSamples.next(browseId: nil))]),
        lrclib: FakeLRCLib = FakeLRCLib(),
        clock: MutableClock = MutableClock()
    ) -> Real {
        let directory = makeTemporaryDirectory("deci-chain-real")
        let cache = LyricsDiskCache(directory: directory.appendingPathComponent("Lyrics", isDirectory: true), now: { clock.now })
        let sleeper = FakeSleeper(gated: false)
        let ytmClient = YTMusicLyricsClient(transport: ytm, now: { clock.now })
        let lrclibClient = LRCLibClient(
            transport: lrclib, userAgent: "Deci/9.9.9 (macOS; lyrics via LRCLIB)", now: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )
        return Real(
            chain: LyricsChain(primary: ytmClient, fallback: lrclibClient, cache: cache),
            ytm: ytm, lrclib: lrclib, ytmClient: ytmClient, lrclibClient: lrclibClient,
            cache: cache, clock: clock, sleeper: sleeper, directory: directory
        )
    }

    private func cut(_ name: String, lines: Int = 6) -> String {
        LyricsSamples.syncedBody(lines: lines, prefix: name)
    }

    private func firstText(_ result: LyricsResult) -> String? {
        if case .synced(let lines) = result { return lines.first?.text }
        return nil
    }

    // MARK: - Source order

    @Test("Timed lyrics from YouTube Music never touch LRCLIB, and the credit names the provider")
    func ytmSyncedNeverReachesLrclib() async throws {
        let real = makeReal(ytm: FakeYTMusic(android: [.ok(YTSamples.timedBrowse(YTSamples.fourCues))]))
        defer { real.cleanUp() }
        let answer = try await real.chain.answer(for: YTSamples.query())
        guard case .synced(let lines) = answer.result else {
            Issue.record("expected synced lyrics")
            return
        }
        #expect(lines.first == LyricLine(time: 1, text: "Line one", end: 3))
        #expect(answer.credit == ytmCredit)
        #expect(real.lrclib.requests.isEmpty)
    }

    @Test("Plain from YouTube Music and a synced record at LRCLIB: LRCLIB's synced lyrics, with LRCLIB's credit")
    func lrclibSyncedBeatsYtmPlain() async throws {
        let real = makeReal(
            ytm: FakeYTMusic(android: [.ok(YTSamples.plainBrowse(YTSamples.plainText))]),
            lrclib: FakeLRCLib(get: [.record(LyricsSamples.record())])
        )
        defer { real.cleanUp() }
        let answer = try await real.chain.answer(for: YTSamples.query())
        #expect(answer.result == .synced(LyricsSamples.syncedLines))
        #expect(answer.credit == lrclibCredit)
    }

    @Test("Plain from YouTube Music and nothing at LRCLIB: YouTube Music's plain lyrics")
    func ytmPlainWhenLrclibHasNothing() async throws {
        let real = makeReal(ytm: FakeYTMusic(android: [.ok(YTSamples.plainBrowse(YTSamples.plainText))]))
        defer { real.cleanUp() }
        let answer = try await real.chain.answer(for: YTSamples.query())
        #expect(answer.result == .plain(YTSamples.plainText))
        #expect(answer.credit == ytmCredit)
    }

    @Test("LRCLIB's credit is its name")
    func lrclibCreditIsItsName() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.record(LyricsSamples.record())]))
        defer { real.cleanUp() }
        #expect(try await real.chain.answer(for: YTSamples.query()).credit == "Lyrics from LRCLIB")
        #expect(try await real.chain.answer(for: YTSamples.query()).credit == "Lyrics from LRCLIB")
    }

    @Test("A 429 from YouTube Music sends the lookup on to LRCLIB, and the next song skips YouTube Music for a minute")
    func ytmCooldownSkipsTheNextSong() async throws {
        let real = makeReal(
            ytm: FakeYTMusic(next: [.status(429)]),
            lrclib: FakeLRCLib(get: [.record(LyricsSamples.record())])
        )
        defer { real.cleanUp() }
        #expect(try await real.chain.answer(for: YTSamples.query()).result == .synced(LyricsSamples.syncedLines))
        #expect(real.ytm.requests.count == 1)

        let other = LyricsSamples.query(videoId: "vid00000002")
        #expect(try await real.chain.answer(for: other).result == .synced(LyricsSamples.syncedLines))
        #expect(real.ytm.requests.count == 1)
        #expect(real.lrclib.getRequests.count == 2)

        real.clock.advance(by: 61)
        _ = try await real.chain.answer(for: LyricsSamples.query(videoId: "vid00000003"))
        #expect(real.ytm.requests.count == 2)
    }

    @Test("A hung YouTube Music sends the lookup on to LRCLIB, and the next songs skip it for 15 s")
    func ytmTimeoutSkipsTheNextSongs() async throws {
        let real = makeReal(
            ytm: FakeYTMusic(next: [.fail(.timedOut)]),
            lrclib: FakeLRCLib(get: [.record(LyricsSamples.record())])
        )
        defer { real.cleanUp() }
        #expect(try await real.chain.answer(for: YTSamples.query()).result == .synced(LyricsSamples.syncedLines))
        for id in ["vid00000002", "vid00000003"] {
            #expect(try await real.chain.answer(for: LyricsSamples.query(videoId: id)).result == .synced(LyricsSamples.syncedLines))
        }
        #expect(real.ytm.requests.count == 1)
        #expect(real.lrclib.getRequests.count == 3)
        // YouTube Music was down for these, so nothing was kept: a not-found would have hidden its lyrics for days.
        #expect(await real.cache.cached(videoId: YTSamples.videoId) == nil)

        real.clock.advance(by: 15)
        _ = try await real.chain.answer(for: LyricsSamples.query(videoId: "vid00000004"))
        #expect(real.ytm.requests.count == 2)
    }

    @Test("A /next answer with no tab at all is a failure to the chain: LRCLIB is asked, and nothing is cached")
    func ytmUnreadableNextIsNotCached() async throws {
        let real = makeReal(ytm: FakeYTMusic(next: [.ok(Data("{}".utf8))]))
        defer { real.cleanUp() }
        #expect(try await real.chain.answer(for: YTSamples.query()).result == .notFound)
        #expect(real.lrclib.requests.isEmpty == false)
        #expect(await real.cache.cached(videoId: YTSamples.videoId) == nil)
    }

    @Test("An Android page that fails does not hide the web page's plain lyrics from the chain")
    func androidFailureStillGivesWebPlain() async throws {
        let real = makeReal(ytm: FakeYTMusic(
            android: [.status(404)],
            web: [.ok(YTSamples.plainBrowse(YTSamples.plainText))]
        ))
        defer { real.cleanUp() }
        let answer = try await real.chain.answer(for: YTSamples.query())
        #expect(answer.result == .plain(YTSamples.plainText))
        #expect(answer.credit == ytmCredit)
    }

    @Test("LRCLIB busy keeps YouTube Music's plain lyrics, and its window still holds the next song back")
    func lrclibBusyKeepsYtmPlain() async throws {
        let real = makeReal(
            ytm: FakeYTMusic(next: [.ok(YTSamples.next()), .ok(YTSamples.next(browseId: nil))], android: [.ok(YTSamples.plainBrowse(YTSamples.plainText))]),
            lrclib: FakeLRCLib(get: [.status(429, headers: ["Retry-After": "30"])])
        )
        defer { real.cleanUp() }
        let answer = try await real.chain.answer(for: YTSamples.query())
        #expect(answer.result == .plain(YTSamples.plainText))
        #expect(await real.lrclibClient.busyUntil == real.clock.now.addingTimeInterval(30))

        // YouTube Music has nothing for the next song, so the busy window is what the store has to show.
        let until = real.clock.now.addingTimeInterval(30)
        await #expect(throws: LyricsError.busy(until: until)) {
            try await real.chain.answer(for: LyricsSamples.query(videoId: "vid00000002"))
        }
        #expect(real.lrclib.requests.count == 1)
    }

    // MARK: - Ported from the LRCLIB client: what is stored and what is not

    @Test("A record in the duration window by another artist is not the song, and not found is stored")
    func wrongArtistIsStoredAsNotFound() async throws {
        let other = LyricsSamples.record(artist: "Somebody Else", duration: 200, synced: cut("Wrong"))
        let real = makeReal(lrclib: FakeLRCLib(search: [.results([other])]))
        defer { real.cleanUp() }
        let query = LyricsSamples.query(videoId: YTSamples.videoId, album: nil, duration: 200)
        #expect(try await real.chain.answer(for: query).result == .notFound)
        #expect(await real.cache.cached(videoId: YTSamples.videoId)?.result == .notFound)
    }

    @Test("A busy answer is not stored")
    func busyIsNotStored() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.status(429, headers: ["Retry-After": "5"])]))
        defer { real.cleanUp() }
        _ = try? await real.chain.answer(for: LyricsSamples.query())
        #expect(await real.cache.cached(videoId: "vid1") == nil)
    }

    @Test(
        "A server error that outlives the retries is not stored, and the window holds the next song back",
        arguments: [500, 502, 503, 504]
    )
    func serverErrorIsNotStored(status: Int) async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.status(status)]))
        defer { real.cleanUp() }
        let until = real.clock.now.addingTimeInterval(15)
        await #expect(throws: LyricsError.backoff(status: status, until: until)) {
            try await real.chain.answer(for: LyricsSamples.query(videoId: "a"))
        }
        #expect(real.lrclib.requests.count == 3)
        #expect(await real.cache.cached(videoId: "a") == nil)

        real.clock.advance(by: 10)
        await #expect(throws: LyricsError.busy(until: until)) {
            try await real.chain.answer(for: LyricsSamples.query(videoId: "b"))
        }
        #expect(real.lrclib.requests.count == 3)

        real.clock.advance(by: 6)
        real.lrclib.setGet(.record(LyricsSamples.record()))
        #expect(try await real.chain.answer(for: LyricsSamples.query(videoId: "b")).result == .synced(LyricsSamples.syncedLines))
        #expect(real.lrclib.requests.count == 4)
    }

    @Test("A transient status that recovers on the second attempt is stored like any other answer", arguments: [500, 502, 503, 504])
    func transientRecoveryIsStored(status: Int) async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.status(status), .record(LyricsSamples.record())]))
        defer { real.cleanUp() }
        #expect(try await real.chain.answer(for: LyricsSamples.query()).result == .synced(LyricsSamples.syncedLines))
        #expect(real.sleeper.requested == [.seconds(1)])
        #expect(await real.cache.cached(videoId: "vid1")?.result == .synced(LyricsSamples.syncedLines))
    }

    @Test("Other HTTP errors are reported with their status and not stored")
    func httpErrorsAreNotStored() async throws {
        for status in [400, 401, 403, 501, 505] {
            let real = makeReal(lrclib: FakeLRCLib(get: [.status(status)]))
            defer { real.cleanUp() }
            await #expect(throws: LyricsError.http(status)) {
                try await real.chain.answer(for: LyricsSamples.query())
            }
            #expect(await real.cache.cached(videoId: "vid1") == nil)
            #expect(await real.lrclibClient.busyUntil == nil)
        }
    }

    @Test("A network failure is thrown as it is and not stored, and the next call goes out again")
    func networkFailureIsNotStored() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.fail(.notConnectedToInternet)]))
        defer { real.cleanUp() }
        await #expect(throws: URLError.self) {
            try await real.chain.answer(for: LyricsSamples.query())
        }
        #expect(await real.cache.cached(videoId: "vid1") == nil)
        real.lrclib.setGet(.record(LyricsSamples.record()))
        #expect(try await real.chain.answer(for: LyricsSamples.query()).result == .synced(LyricsSamples.syncedLines))
    }

    @Test("A body that is not JSON is a parse error and not stored")
    func garbageBodyIsNotStored() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.ok(Data("<html>oops</html>".utf8))]))
        defer { real.cleanUp() }
        await #expect(throws: LyricsError.parse) {
            try await real.chain.answer(for: LyricsSamples.query())
        }
        #expect(await real.cache.cached(videoId: "vid1") == nil)
    }

    @Test("A body over the LRCLIB cap is a failure, never parsed or stored")
    func oversizedBodyIsNotStored() async throws {
        let big = Data("[]".utf8) + Data(repeating: UInt8(ascii: " "), count: LRCLibClient.maximumResponseBytes)
        let real = makeReal(lrclib: FakeLRCLib(search: [.ok(big)]))
        defer { real.cleanUp() }
        await #expect(throws: LyricsError.parse) {
            try await real.chain.answer(for: LyricsSamples.query(album: nil))
        }
        #expect(await real.cache.cached(videoId: "vid1") == nil)
    }

    @Test("A cancelled lookup throws and writes nothing")
    func cancelledLookupWritesNothing() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.record(LyricsSamples.record())]))
        defer { real.cleanUp() }
        let gate = MusicTestGate()
        real.lrclib.setGate(gate)
        let chain = real.chain
        let task = Task { try await chain.answer(for: LyricsSamples.query()) }
        #expect(await eventually { !real.lrclib.requests.isEmpty })
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await real.cache.cached(videoId: "vid1") == nil)
    }

    @Test("An LRCLIB answer found with no known length is not stored, so the exact length can be used later")
    func unknownLengthIsNotStored() async throws {
        for duration in [nil, 0, -3] as [TimeInterval?] {
            let real = makeReal(lrclib: FakeLRCLib(search: [.results([LyricsSamples.record(synced: cut("Found"))])]))
            defer { real.cleanUp() }
            let query = LyricsSamples.query(album: nil, duration: duration)
            #expect(firstText(try await real.chain.answer(for: query).result) == "Found 0")
            #expect(await real.cache.cached(videoId: "vid1") == nil, "duration \(String(describing: duration)) was stored")
            _ = try await real.chain.answer(for: query)
            #expect(real.lrclib.searchRequests.count == 2)
        }
    }

    @Test("With a known length the same lookup is stored")
    func knownLengthIsStored() async throws {
        let real = makeReal(lrclib: FakeLRCLib(search: [.results([LyricsSamples.record(synced: cut("Found"))])]))
        defer { real.cleanUp() }
        _ = try await real.chain.answer(for: LyricsSamples.query(album: nil, duration: 200))
        #expect(await real.cache.cached(videoId: "vid1") != nil)
    }

    @Test("A second lookup of the same video is served from disk with no request to either server")
    func hitSendsNothing() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.record(LyricsSamples.record())]))
        defer { real.cleanUp() }
        let first = try await real.chain.answer(for: LyricsSamples.query())
        let ytmSent = real.ytm.requests.count
        let second = try await real.chain.answer(for: LyricsSamples.query())
        #expect(first.result == second.result)
        #expect(real.lrclib.requests.count == 1)
        #expect(real.ytm.requests.count == ytmSent)
    }

    @Test("The cache is shared by a new chain over the same directory")
    func cacheSurvivesAChain() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.record(LyricsSamples.record())]))
        defer { real.cleanUp() }
        _ = try await real.chain.answer(for: LyricsSamples.query())
        let freshYtm = FakeYTMusic()
        let freshLrclib = FakeLRCLib()
        let other = LyricsChain(
            primary: YTMusicLyricsClient(transport: freshYtm, now: { real.clock.now }),
            fallback: LRCLibClient(transport: freshLrclib, userAgent: "Deci/9.9.9 (macOS; lyrics via LRCLIB)", now: { real.clock.now }),
            cache: real.cache
        )
        #expect(try await other.answer(for: LyricsSamples.query()).result == .synced(LyricsSamples.syncedLines))
        #expect(freshYtm.requests.isEmpty)
        #expect(freshLrclib.requests.isEmpty)
    }

    @Test("A cache hit is still served inside LRCLIB's busy window")
    func hitServedWhileBusy() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.record(LyricsSamples.record()), .status(429, headers: ["Retry-After": "30"])]))
        defer { real.cleanUp() }
        _ = try await real.chain.answer(for: LyricsSamples.query(videoId: "a"))
        _ = try? await real.chain.answer(for: LyricsSamples.query(videoId: "b"))
        #expect(try await real.chain.answer(for: LyricsSamples.query(videoId: "a")).result == .synced(LyricsSamples.syncedLines))
        #expect(real.lrclib.requests.count == 2)
    }

    @Test("A cache hit is still served inside LRCLIB's server-error window")
    func hitServedDuringBackoff() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.record(LyricsSamples.record()), .status(500)]))
        defer { real.cleanUp() }
        _ = try await real.chain.answer(for: LyricsSamples.query(videoId: "a"))
        _ = try? await real.chain.answer(for: LyricsSamples.query(videoId: "b"))
        #expect(try await real.chain.answer(for: LyricsSamples.query(videoId: "a")).result == .synced(LyricsSamples.syncedLines))
        // One request for "a", three attempts for "b", and none for the cache hit.
        #expect(real.lrclib.requests.count == 4)
    }

    @Test("A server-error window is kept in memory only: a new client over the same cache is not held")
    func backoffWindowIsNotPersisted() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.status(500)]))
        defer { real.cleanUp() }
        _ = try? await real.chain.answer(for: LyricsSamples.query())
        let fresh = FakeLRCLib(get: [.record(LyricsSamples.record())])
        let other = LyricsChain(
            primary: YTMusicLyricsClient(transport: FakeYTMusic(next: [.ok(YTSamples.next(browseId: nil))]), now: { real.clock.now }),
            fallback: LRCLibClient(transport: fresh, userAgent: "Deci/9.9.9 (macOS; lyrics via LRCLIB)", now: { real.clock.now }),
            cache: real.cache
        )
        #expect(try await other.answer(for: LyricsSamples.query()).result == .synced(LyricsSamples.syncedLines))
        #expect(fresh.requests.count == 1)
    }

    @Test("Not found is stored for 3 days, then the lookup is made again")
    func notFoundIsStoredForThreeDays() async throws {
        let real = makeReal(lrclib: FakeLRCLib(get: [.notFound], search: [.empty]))
        defer { real.cleanUp() }
        let query = LyricsSamples.query()
        #expect(try await real.chain.answer(for: query).result == .notFound)
        let sent = real.lrclib.requests.count
        #expect(try await real.chain.answer(for: query).result == .notFound)
        #expect(real.lrclib.requests.count == sent)

        real.clock.advance(by: 3 * day + 1)
        real.lrclib.setGet(.record(LyricsSamples.record()))
        #expect(try await real.chain.answer(for: query).result == .synced(LyricsSamples.syncedLines))
        #expect(real.lrclib.requests.count == sent + 1)
    }
}
