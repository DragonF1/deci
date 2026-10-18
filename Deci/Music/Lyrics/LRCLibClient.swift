// Deci/Music/Lyrics/LRCLibClient.swift
import Foundation
import os

/// Lyrics from lrclib.net, a free community service: `/api/get` with the exact track, falling back to
/// `/api/search`, a disk cache in front, and a hard stop on 429.
///
/// Nothing that identifies the listener ever goes out: no cookies, no auth headers, no video id, only the
/// song's title, artist, album and length and a User-Agent that names the app. It goes through `HTTPTransport`
/// so tests can script the service, and the live transport is an ephemeral session with no cookie jar or cache.
actor LRCLibClient: LyricsProviding {
    /// How far a record's length may be from the song's, either way.
    static let durationTolerance: TimeInterval = 2
    /// A record with fewer sung lines than this is the placeholder junk LRCLIB sometimes returns.
    static let minimumLines = 3
    /// The most of a reply that is read: a real record is a few KB, a longer body is not LRCLIB talking.
    static let maximumResponseBytes = 2 * 1024 * 1024

    private static let baseURL = URL(string: "https://lrclib.net/api")!
    private static let defaultWait: TimeInterval = 60
    /// How long a 500, 502 or 504 holds every request back. Short, and kept in memory only.
    private static let serverErrorWait: TimeInterval = 30
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
    private let cache: LyricsDiskCache
    private let userAgent: String
    private let now: @Sendable () -> Date
    private var waitUntil: Date?

    init(
        transport: any HTTPTransport,
        cache: LyricsDiskCache,
        userAgent: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.cache = cache
        self.userAgent = userAgent
        self.now = now
    }

    static func live() -> LRCLibClient {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return LRCLibClient(
            transport: URLSessionTransport(configuration: makeConfiguration()),
            cache: .live(),
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
        // A cached answer needs no network, so it is served even inside a busy window.
        if let hit = await cache.cached(videoId: query.videoId) { return hit }
        try Task.checkCancellation()
        if let until = busyUntil { throw LyricsError.busy(until: until) }

        let result = try await lookup(query)
        try Task.checkCancellation()
        // Without the exact length the match is a guess (the search takes the first usable record), and a guess
        // must not stick for 30 days: the store asks again once the player knows the length.
        if Self.known(query.duration) != nil {
            await cache.store(result, videoId: query.videoId)
        }
        return result
    }

    private func lookup(_ query: LyricsQuery) async throws -> LyricsResult {
        // /api/get answers with one record or a 404, and wants the album and the length to match on.
        if let album = Self.known(query.album), let duration = Self.known(query.duration) {
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

        if let found = try await search(title: query.title, artist: query.artist, duration: query.duration) {
            return found
        }
        // One more try with the packaging taken off the title and only the first artist.
        let title = LyricsTitleCleaner.cleanTitle(query.title)
        let artist = LyricsTitleCleaner.firstArtist(query.artist)
        if title != query.title || artist != query.artist,
           let found = try await search(title: title, artist: artist, duration: query.duration) {
            return found
        }
        return .notFound
    }

    /// The best record within the duration window: synced over plain over instrumental, the closest length
    /// first among equals. Nil when nothing usable is in range.
    private func search(title: String, artist: String, duration: TimeInterval?) async throws -> LyricsResult? {
        guard let data = try await fetch("search", [("track_name", title), ("artist_name", artist)]) else { return nil }
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [Any] else { throw LyricsError.parse }

        let target = Self.known(duration)
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

    /// The body of a 2xx answer, or nil for a 404. A 429 or 503 opens the busy window and throws; a 500, 502 or 504
    /// opens a short backoff window and throws. A body over the size cap is a parse failure.
    private func fetch(_ path: String, _ parameters: [(String, String)]) async throws -> Data? {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        // Encoded by hand: URLComponents leaves "+" and "&" alone, which a server reads as a space and a separator.
        components?.percentEncodedQuery = parameters
            .map { "\(Self.escape($0.0))=\(Self.escape($0.1))" }
            .joined(separator: "&")
        guard let url = components?.url else { throw LyricsError.parse }

        let request = HTTPRequest(url: url, headers: ["User-Agent": userAgent, "Accept": "application/json"])
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }

        Self.log.info("lrclib \(path, privacy: .public) answered \(response.statusCode)")
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

    /// A 429 or 503 opens the window Retry-After names; a 500, 502 or 504 opens a short fixed one. Nil for
    /// every other status. Only memory: nothing about it is written to disk.
    private func openWindow(for response: HTTPResponse) -> LyricsError? {
        let start = now()
        switch response.statusCode {
        case 429, 503:
            let until = start.addingTimeInterval(Self.wait(retryAfter: response.header("Retry-After"), from: start))
            waitUntil = max(waitUntil ?? until, until)
            return .busy(until: until)
        case 500, 502, 504:
            let until = start.addingTimeInterval(Self.serverErrorWait)
            waitUntil = max(waitUntil ?? until, until)
            return .backoff(status: response.statusCode, until: until)
        default:
            return nil
        }
    }

    // MARK: - Pieces

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func known(_ album: String?) -> String? {
        let trimmed = album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func known(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
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

    /// "Wed, 21 Oct 2015 07:28:00 GMT". A formatter per call: this only runs on a 429.
    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
