// Deci/Music/Lyrics/LRCLibClient.swift
import Foundation
import os

/// Lyrics from lrclib.net, a free community service: `/api/get` with the exact track, falling back to
/// `/api/search`, a hard stop on 429, and a quick second and third try when a request fails with a blip (a 5xx that
/// is gone a moment later). The second source of the chain, after YouTube Music; it keeps no disk cache of its own,
/// the chain owns that, but it keeps the busy and server-error windows.
///
/// Nothing that identifies the listener ever goes out: no cookies, no auth headers, no video id, only the
/// song's title, artist, album and length and a User-Agent that names the app. It goes through `HTTPTransport`
/// so tests can script the service, and the live transport is an ephemeral session with no cookie jar or cache.
actor LRCLibClient: LyricsProviding {
    /// The credit line for lyrics that came from here.
    static let credit = "Lyrics from LRCLIB"

    /// How far a record's length may be from the song's, either way.
    static let durationTolerance: TimeInterval = 2
    /// A record with fewer sung lines than this is the placeholder junk LRCLIB sometimes returns.
    static let minimumLines = 3
    /// The most of a reply that is read: a real record is a few KB, a longer body is not LRCLIB talking.
    static let maximumResponseBytes = 2 * 1024 * 1024

    private static let baseURL = URL(string: "https://lrclib.net/api")!
    private static let defaultWait: TimeInterval = 60
    /// How long a 5xx that outlived the inline retries holds every request back. Short, and kept in memory only.
    private static let serverErrorWait: TimeInterval = 15
    /// The waits before the second and the third attempt at a request that met a blip.
    private static let retryDelays: [Duration] = [.seconds(1), .seconds(3)]
    /// A 503 that names a wait of this many seconds or fewer is a blip too; a longer one is a real busy window.
    private static let blipRetryAfter: TimeInterval = 5
    private static let minimumWait: TimeInterval = 1
    private static let maximumWait: TimeInterval = 3600
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicLyrics")

    /// One LRCLIB record, read leniently: a missing or null field is just absent.
    private struct Record {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool
        let plain: String?
        let synced: String?

        init(_ object: [String: Any]) {
            trackName = object["trackName"] as? String
            artistName = object["artistName"] as? String
            duration = object["duration"] as? Double
            instrumental = object["instrumental"] as? Bool ?? false
            plain = object["plainLyrics"] as? String
            synced = object["syncedLyrics"] as? String
        }
    }

    /// What a record is worth showing. Synced beats plain beats instrumental.
    private struct Answer {
        let result: LyricsResult
        let rank: Int
    }

    private let transport: any HTTPTransport
    private let userAgent: String
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var waitUntil: Date?

    init(
        transport: any HTTPTransport,
        userAgent: String,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.userAgent = userAgent
        self.now = now
        self.sleep = sleep
    }

    static func live() -> LRCLibClient {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return LRCLibClient(
            transport: URLSessionTransport(configuration: makeConfiguration()),
            userAgent: userAgent(version: version)
        )
    }

    static func userAgent(version: String?) -> String {
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "Deci/\(trimmed.isEmpty ? "0" : trimmed) (macOS; lyrics via LRCLIB)"
    }

    /// Ephemeral, with no cookie jar, URL cache or credential storage, and a short fuse: lyrics are a nicety.
    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return config
    }

    /// While LRCLIB has asked us to wait, when the wait ends; nil otherwise.
    var busyUntil: Date? {
        guard let waitUntil, waitUntil > now() else { return nil }
        return waitUntil
    }

    // MARK: - Lookup

    func lyrics(for query: LyricsQuery) async throws -> LyricsResult {
        try await answer(for: query).result
    }

    /// Synced and plain lyrics are credited to LRCLIB; an instrumental or a miss has nothing to credit. Without the
    /// exact length the match is a guess (the search takes the first usable record), so the answer says the length
    /// matters: the store asks again once the player knows it, and the chain does not keep the guess for 30 days.
    func answer(for query: LyricsQuery) async throws -> LyricsAnswer {
        try Task.checkCancellation()
        if let until = busyUntil { throw LyricsError.busy(until: until) }

        let result = try await lookup(query)
        try Task.checkCancellation()
        let credit: String?
        switch result {
        case .synced, .plain: credit = Self.credit
        case .instrumental, .notFound: credit = nil
        }
        return LyricsAnswer(result: result, credit: credit, lengthMatters: query.knownDuration == nil)
    }

    private func lookup(_ query: LyricsQuery) async throws -> LyricsResult {
        // /api/get answers with one record or a 404, and wants the album and the length to match on.
        if let album = Self.known(query.album), let duration = query.knownDuration {
            let parameters = [
                ("track_name", query.title),
                ("artist_name", query.artist),
                ("album_name", album),
                ("duration", String(Int(duration.rounded()))),
            ]
            if let data = try await fetch("get", parameters) {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw LyricsError.parse
                }
                // A junk record is not an answer: the search below may know the real one.
                if let answer = Self.answer(for: Record(object)) { return answer.result }
            }
        }

        if let found = try await search(title: query.title, artist: query.artist, duration: query.knownDuration) {
            return found
        }
        // One more try with the packaging taken off the title and only the first artist.
        let title = LyricsTitleCleaner.cleanTitle(query.title)
        let artist = LyricsTitleCleaner.firstArtist(query.artist)
        if title != query.title || artist != query.artist,
           let found = try await search(title: title, artist: artist, duration: query.knownDuration) {
            return found
        }
        return .notFound
    }

    /// The best record within the duration window: synced over plain over instrumental, the closest length
    /// first among equals. Nil when nothing usable is in range.
    private func search(title: String, artist: String, duration target: TimeInterval?) async throws -> LyricsResult? {
        guard let data = try await fetch("search", [("track_name", title), ("artist_name", artist)]) else { return nil }
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [Any] else { throw LyricsError.parse }

        var best: (answer: Answer, distance: Double)?
        for case let object as [String: Any] in objects {
            let record = Record(object)
            // A record of another song that happens to be the right length is not an answer.
            guard LyricsIdentity.matches(
                recordTitle: record.trackName, recordArtist: record.artistName, title: title, artist: artist
            ) else { continue }
            var distance = 0.0
            if let target {
                guard let length = record.duration, abs(length - target) <= Self.durationTolerance else { continue }
                distance = abs(length - target)
            }
            guard let answer = Self.answer(for: record) else { continue }
            if let current = best,
               (answer.rank, -distance) <= (current.answer.rank, -current.distance) { continue }
            best = (answer, distance)
        }
        return best?.answer.result
    }

    // MARK: - Network

    /// The body of a 2xx answer, or nil for a 404. A blip (see `isBlip`) is sent again up to twice more, after 1 s and
    /// then 3 s, before it counts. Then a 429 or a 503 with a long Retry-After opens the busy window and throws; a 5xx
    /// that is still failing opens a short backoff window and throws. A body over the size cap is a parse failure.
    private func fetch(_ path: String, _ parameters: [(String, String)]) async throws -> Data? {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        // Encoded by hand: URLComponents leaves "+" and "&" alone, which a server reads as a space and a separator.
        components?.percentEncodedQuery = parameters
            .map { "\(Self.escape($0.0))=\(Self.escape($0.1))" }
            .joined(separator: "&")
        guard let url = components?.url else { throw LyricsError.parse }

        let request = HTTPRequest(url: url, headers: ["User-Agent": userAgent, "Accept": "application/json"])
        var response = try await send(request, path: path)
        var delays = Self.retryDelays[...]
        while isBlip(response), let delay = delays.popFirst() {
            // A cancelled caller stops here and opens no window: a blip is not a "slow down". The check comes before
            // the wait and after it, because an injected timer may not notice the cancellation.
            try Task.checkCancellation()
            try await sleep(delay)
            try Task.checkCancellation()
            response = try await send(request, path: path)
        }

        // The server's "slow down" counts even when this request was cancelled meanwhile: it was sent, and the
        // next song must not walk straight into the same answer. So the window opens before the cancellation check.
        let refusal = openWindow(for: response)
        try Task.checkCancellation()
        if let refusal { throw refusal }

        switch response.statusCode {
        case 200..<300:
            guard response.data.count <= Self.maximumResponseBytes else { throw LyricsError.parse }
            return response.data
        case 404:
            return nil
        default:
            throw LyricsError.http(response.statusCode)
        }
    }

    private func send(_ request: HTTPRequest, path: String) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        Self.log.info("lrclib \(path, privacy: .public) answered \(response.statusCode)")
        return response
    }

    /// A 500, 502 or 504, or a 503 that names no wait or one of a few seconds: LRCLIB stumbled and is likely fine a
    /// moment later, so the request is worth sending again inline. A 429 is the server asking us to slow down, and a
    /// 503 with a longer Retry-After says how long: neither is retried.
    private func isBlip(_ response: HTTPResponse) -> Bool {
        switch response.statusCode {
        case 500, 502, 504:
            return true
        case 503:
            let header = response.header("Retry-After")?.trimmingCharacters(in: .whitespaces) ?? ""
            return header.isEmpty || Self.wait(retryAfter: header, from: now()) <= Self.blipRetryAfter
        default:
            return false
        }
    }

    /// A 429, or a 503 that is not a blip, opens the window Retry-After names; any other 5xx that is still failing
    /// after the retries (a 500, 502, 504, or a blip of a 503) opens a short fixed one. Nil for every other status.
    /// Only memory: nothing about it is written to disk.
    private func openWindow(for response: HTTPResponse) -> LyricsError? {
        let start = now()
        let status = response.statusCode
        if status == 429 || (status == 503 && !isBlip(response)) {
            let until = start.addingTimeInterval(Self.wait(retryAfter: response.header("Retry-After"), from: start))
            waitUntil = max(waitUntil ?? until, until)
            return .busy(until: until)
        }
        if [500, 502, 503, 504].contains(status) {
            let until = start.addingTimeInterval(Self.serverErrorWait)
            waitUntil = max(waitUntil ?? until, until)
            return .backoff(status: status, until: until)
        }
        return nil
    }

    // MARK: - Pieces

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func known(_ album: String?) -> String? {
        let trimmed = album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func answer(for record: Record) -> Answer? {
        if let text = record.synced {
            let lines = LRCParser.parse(text)
            if LRCParser.sungLineCount(lines) >= minimumLines { return Answer(result: .synced(lines), rank: 3) }
        }
        if let text = record.plain?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let sung = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
            if sung.count >= minimumLines { return Answer(result: .plain(text), rank: 2) }
        }
        return record.instrumental ? Answer(result: .instrumental, rank: 1) : nil
    }

    /// Retry-After is whole seconds or an HTTP date. Anything else waits a minute; the wait is kept between
    /// a second and an hour.
    private static func wait(retryAfter header: String?, from start: Date) -> TimeInterval {
        let value = header?.trimmingCharacters(in: .whitespaces) ?? ""
        let seconds: TimeInterval
        if !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }), let whole = Double(value) {
            seconds = whole
        } else if let date = httpDate(value) {
            seconds = date.timeIntervalSince(start)
        } else {
            seconds = defaultWait
        }
        return min(max(seconds, minimumWait), maximumWait)
    }

    /// "Wed, 21 Oct 2015 07:28:00 GMT". A formatter per call: this only runs on a 429 or a 503.
    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
