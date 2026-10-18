// DeciTests/Music/MusicBackendTestSupport.swift
// Shared fakes and the fixture loader for the YouTube Music backend tests.

import Foundation
import os
@testable import Deci

nonisolated enum MusicFixtures {
    /// Reads DeciTests/Fixtures/Music/<name> relative to this source file.
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func string(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Music/\(name)")
    }
}

/// An in-memory stand-in for the Keychain item. It counts every operation, so a test can say how
/// often the real item would have prompted.
nonisolated final class MemorySecretStore: MusicSecretStore, @unchecked Sendable {
    private struct State {
        var data: Data?
        var loadCount = 0
        var saveCount = 0
        var deleteCount = 0
        var failSaves = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(data: Data? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(data: data))
    }

    var loadCount: Int { state.withLock { $0.loadCount } }
    var saveCount: Int { state.withLock { $0.saveCount } }
    var deleteCount: Int { state.withLock { $0.deleteCount } }
    var failSaves: Bool {
        get { state.withLock { $0.failSaves } }
        set { state.withLock { $0.failSaves = newValue } }
    }

    /// What the item holds right now, without counting as a read.
    var contents: Data? { state.withLock { $0.data } }

    /// The stored jar, decoded; nil when the item is empty or unreadable. Does not count as a read.
    var storedJar: MusicCookieJar? {
        contents.flatMap { try? JSONDecoder().decode(MusicCookieJar.self, from: $0) }
    }

    func load() -> Data? {
        state.withLock { state in
            state.loadCount += 1
            return state.data
        }
    }

    func save(_ data: Data) throws {
        try state.withLock { state in
            if state.failSaves { throw KeychainSecretStore.KeychainError(status: -25308) }
            state.data = data
            state.saveCount += 1
        }
    }

    func delete() {
        state.withLock { state in
            state.data = nil
            state.deleteCount += 1
        }
    }
}

/// The clock the client reads, advanced by hand.
nonisolated final class MutableClock: @unchecked Sendable {
    private let date: OSAllocatedUnfairLock<Date>

    init(_ start: Date = MusicTestJar.now) {
        date = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { date.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// A scheduler that runs nothing by itself: a test moves time forward and the writes that came due
/// run in order, on the calling thread. It shares the clock the client and persister read.
nonisolated final class ManualWriteScheduler: MusicWriteScheduler, @unchecked Sendable {
    private struct Entry {
        let fireAt: Date
        let work: @Sendable () -> Void
        var isCancelled = false
        var hasRun = false
    }

    private let clock: MutableClock
    private let entries = OSAllocatedUnfairLock(initialState: [Entry]())

    init(clock: MutableClock) {
        self.clock = clock
    }

    /// Writes scheduled and neither run nor cancelled.
    var pendingCount: Int { entries.withLock { $0.filter { !$0.isCancelled && !$0.hasRun }.count } }

    /// Seconds from now until the next live entry fires; nil when none is waiting.
    var nextDelay: TimeInterval? {
        entries.withLock { $0.filter { !$0.isCancelled && !$0.hasRun }.map(\.fireAt).min() }
            .map { $0.timeIntervalSince(clock.now) }
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let index = entries.withLock { entries -> Int in
            entries.append(Entry(fireAt: clock.now.addingTimeInterval(delay), work: work))
            return entries.count - 1
        }
        return { [entries] in entries.withLock { $0[index].isCancelled = true } }
    }

    /// Moves the clock forward by `seconds`, running every live entry that comes due on the way, each
    /// at its own time.
    func advance(by seconds: TimeInterval) {
        let target = clock.now.addingTimeInterval(seconds)
        while let due = nextDue(upTo: target) {
            let gap = due.fireAt.timeIntervalSince(clock.now)
            if gap > 0 { clock.advance(by: gap) }
            due.work()
        }
        let rest = target.timeIntervalSince(clock.now)
        if rest > 0 { clock.advance(by: rest) }
    }

    /// Runs every entry that never ran, cancelled ones included: a timer that had already started
    /// when it was cancelled.
    func fireEverything() {
        let work = entries.withLock { entries -> [@Sendable () -> Void] in
            let open = entries.indices.filter { !entries[$0].hasRun }
            for index in open { entries[index].hasRun = true }
            return open.map { entries[$0].work }
        }
        for item in work { item() }
    }

    private func nextDue(upTo target: Date) -> Entry? {
        entries.withLock { entries in
            let candidates = entries.indices.filter { !entries[$0].isCancelled && !entries[$0].hasRun && entries[$0].fireAt <= target }
            guard let index = candidates.min(by: { entries[$0].fireAt < entries[$1].fireAt }) else { return nil }
            entries[index].hasRun = true
            return entries[index]
        }
    }
}

/// A signed-in jar made of obviously fake cookies.
nonisolated enum MusicTestJar {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let farFuture = Date(timeIntervalSince1970: 1_900_000_000)

    static func cookie(
        _ name: String,
        _ value: String,
        domain: String = ".youtube.com",
        path: String = "/",
        expires: Date? = farFuture
    ) -> StoredCookie {
        StoredCookie(name: name, value: value, domain: domain, path: path, expires: expires, isSecure: true, isHTTPOnly: false)
    }

    static func signedInCookies() -> [StoredCookie] {
        [
            cookie("SAPISID", "sapisid-secret"),
            cookie("__Secure-1PAPISID", "one-papisid-secret"),
            cookie("__Secure-3PAPISID", "three-papisid-secret"),
            cookie("SID", "sid-google-only", domain: ".google.com"),
        ]
    }

    static func signedInStore(adding extra: [StoredCookie] = []) -> MemorySecretStore {
        let jar = MusicCookieJar(cookies: signedInCookies() + extra)
        return MemorySecretStore(data: try? JSONEncoder().encode(jar))
    }
}

/// A scripted music.youtube.com: serves the fixtures, records every request, and lets a test
/// change what the next response looks like.
nonisolated final class FakeYouTube: HTTPTransport, @unchecked Sendable {
    struct Config: Sendable {
        var bootstrapHTML = (try? MusicFixtures.string("music-home-bootstrap.html")) ?? ""
        var bootstrapStatus = 200
        var bootstrapHeaders: [String: String] = [:]
        var searchBody = (try? MusicFixtures.data("search-songs.json")) ?? Data()
        var searchStatus = 200
        var searchHeaders: [String: String] = [:]
        /// The radio's first page; a request whose body has a `continuation` gets `nextContinuationBody`.
        var nextBody = (try? MusicFixtures.data("next-radio-first.json")) ?? Data()
        var nextContinuationBody = (try? MusicFixtures.data("next-radio-continuation.json")) ?? Data()
        var nextStatus = 200
        var nextHeaders: [String: String] = [:]
        /// browse answers by the `browseId` in the body; an id with no entry gets `browseDefaultBody`.
        /// A request with a `continuation` in the body or a `ctoken` in the query gets `browseContinuationBody`.
        var browseBodies: [String: Data] = [:]
        var browseDefaultBody = Data("{}".utf8)
        var browseContinuationBody = Data("{}".utf8)
        var browseStatus = 200
        var browseHeaders: [String: String] = [:]
        /// The account menu popup (name, handle, avatar).
        var accountMenuBody = (try? MusicFixtures.data("account-menu.json")) ?? Data()
        var accountMenuStatus = 200
        var accountMenuHeaders: [String: String] = [:]
        var playerBody = (try? MusicFixtures.data("player-ok.json")) ?? Data()
        var playerStatus = 200
        var playerHeaders: [String: String] = [:]
        var playerJS = "var g={};foo({referer:document.location.toString(),signatureTimestamp:20739},r);"
        var playerJSStatus = 200
        var statsStatus = 204
        var delay: Duration?
        /// Holds every request until opened. Unlike `delay` it ignores cancellation, like a slow server would.
        var gate: MusicTestGate?
    }

    private struct State {
        var config = Config()
        var requests: [HTTPRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ configure: (inout Config) -> Void = { _ in }) {
        state.withLockUnchecked { configure(&$0.config) }
    }

    func update(_ change: (inout Config) -> Void) {
        state.withLockUnchecked { change(&$0.config) }
    }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }

    func requests(path: String) -> [HTTPRequest] {
        requests.filter { $0.url.path == path }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let config = state.withLock { state -> Config in
            state.requests.append(request)
            return state.config
        }
        if let delay = config.delay { try await Task.sleep(for: delay) }
        if let gate = config.gate { await gate.wait() }
        let url = request.url
        switch (url.host, url.path) {
        case ("music.youtube.com", "/"):
            return HTTPResponse(statusCode: config.bootstrapStatus, headers: config.bootstrapHeaders, data: Data(config.bootstrapHTML.utf8))
        case ("music.youtube.com", "/youtubei/v1/search"):
            return HTTPResponse(statusCode: config.searchStatus, headers: config.searchHeaders, data: config.searchBody)
        case ("music.youtube.com", "/youtubei/v1/next"):
            let isContinuation = Self.jsonBody(request)["continuation"] != nil
            return HTTPResponse(
                statusCode: config.nextStatus,
                headers: config.nextHeaders,
                data: isContinuation ? config.nextContinuationBody : config.nextBody
            )
        case ("music.youtube.com", "/youtubei/v1/browse"):
            let body = Self.jsonBody(request)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let isContinuation = body["continuation"] != nil || query.contains { $0.name == "ctoken" }
            let browseId = body["browseId"] as? String ?? ""
            return HTTPResponse(
                statusCode: config.browseStatus,
                headers: config.browseHeaders,
                data: isContinuation ? config.browseContinuationBody : config.browseBodies[browseId] ?? config.browseDefaultBody
            )
        case ("music.youtube.com", "/youtubei/v1/account/account_menu"):
            return HTTPResponse(statusCode: config.accountMenuStatus, headers: config.accountMenuHeaders, data: config.accountMenuBody)
        case ("music.youtube.com", "/youtubei/v1/player"):
            return HTTPResponse(statusCode: config.playerStatus, headers: config.playerHeaders, data: config.playerBody)
        case ("music.youtube.com", _) where url.path.hasSuffix("/base.js"):
            return HTTPResponse(statusCode: config.playerJSStatus, headers: [:], data: Data(config.playerJS.utf8))
        case ("music.youtube.com", _) where url.path.hasPrefix("/api/stats/"):
            return HTTPResponse(statusCode: config.statsStatus, headers: [:], data: Data())
        case ("s.youtube.com", _):
            return HTTPResponse(statusCode: config.statsStatus, headers: [:], data: Data())
        default:
            return HTTPResponse(statusCode: 404, headers: [:], data: Data())
        }
    }

    static func jsonBody(_ request: HTTPRequest) -> [String: Any] {
        guard let body = request.body else { return [:] }
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }
}

/// Answers challenges with `SOLVED(<input>)` / `N(<input>)` and remembers what it was asked.
nonisolated final class FakeChallengeSolver: ChallengeSolving, @unchecked Sendable {
    private struct State {
        var requests: [ChallengeRequest] = []
        var rawPlayers: [String] = []
        var failure: MusicError?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// When true the fake asks for the raw player JS, as the real solver does on a cold cache.
    let needsRawPlayer: Bool

    init(needsRawPlayer: Bool = true) {
        self.needsRawPlayer = needsRawPlayer
    }

    var requests: [ChallengeRequest] { state.withLock { $0.requests } }
    var rawPlayers: [String] { state.withLock { $0.rawPlayers } }

    func fail(with error: MusicError?) {
        state.withLock { $0.failure = error }
    }

    func solve(
        _ request: ChallengeRequest,
        rawPlayer: @Sendable () async throws -> String
    ) async throws -> ChallengeSolutions {
        state.withLock { $0.requests.append(request) }
        if let failure = state.withLock({ $0.failure }) { throw failure }
        if needsRawPlayer {
            let js = try await rawPlayer()
            state.withLock { $0.rawPlayers.append(js) }
        }
        return ChallengeSolutions(
            sig: Dictionary(uniqueKeysWithValues: request.sigInputs.map { ($0, "SOLVED(\($0))") }),
            n: Dictionary(uniqueKeysWithValues: request.nInputs.map { ($0, "N(\($0))") })
        )
    }
}

/// Polls until `condition` holds, for at most two seconds.
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A fresh temporary directory for one test.
nonisolated func makeTemporaryDirectory(_ name: String = "deci-music-test") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
