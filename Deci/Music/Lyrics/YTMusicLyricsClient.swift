// Deci/Music/Lyrics/YTMusicLyricsClient.swift
import Foundation
import os

/// Lyrics from YouTube Music itself, for the exact video that plays: the lyrics tab of the song's own watch page, so
/// there is no title matching to get wrong. The first source the chain asks.
///
/// Three kinds of request, all unauthenticated: `/next` with the video id (the web client), to find the song's lyrics
/// page; `/browse` of that page as the Android Music client, which is the one that answers with timed lyrics; and,
/// when that page holds none, `/browse` as the web client, whose page has the plain description. A song with no lyrics
/// tab costs one request, a song with timed lyrics two.
///
/// Nothing that identifies the listener goes out: no cookies, no auth headers, no visitor data. The only thing sent
/// about the song is its video id. It goes through `HTTPTransport` so tests can script the service, and the live
/// transport is an ephemeral session with no cookie jar or cache of its own, apart from the app's other clients. That
/// session follows a redirect only inside music.youtube.com, so a 307 or 308 cannot carry the request body elsewhere.
/// A 429 pauses this source for a minute, and a 5xx, a timeout or a connection error for 15 seconds (so a hung server
/// costs one wait, not one per track), both in memory only. Failures throw; the chain falls through to LRCLIB.
actor YTMusicLyricsClient: LyricsProviding {
    /// The most of a reply that is read. A lyrics page is tens of KB, the watch-next answer a few hundred.
    static let maximumResponseBytes = 4 * 1024 * 1024
    /// The longest provider name the credit line shows; a longer one is cut.
    static let maximumProviderLength = 40
    /// The most Unicode scalars the provider name may hold: a character can carry any number of combining marks.
    static let maximumProviderScalars = 80
    /// How long a 429 holds this source back.
    static let cooldown: TimeInterval = 60
    /// How long a server error, a timeout or a connection failure holds it back: short, because these pass.
    static let errorCooldown: TimeInterval = 15

    /// One of the two YouTube Music clients we speak as: its name and version go in the body and the headers.
    private struct Profile {
        let name: String
        let version: String
        /// The number YouTube Music gives the client in `X-YouTube-Client-Name`.
        let number: String
        let userAgent: String
    }

    private static let web = Profile(
        name: "WEB_REMIX", version: InnerTubeClient.fallbackClientVersion, number: "67",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Safari/605.1.15"
    )
    private static let android = Profile(
        name: "ANDROID_MUSIC", version: "7.21.50", number: "21",
        userAgent: "com.google.android.apps.youtube.music/7.21.50 (Linux; U; Android 14) gzip"
    )

    private static let origin = "https://music.youtube.com"
    private static let baseURL = URL(string: "https://music.youtube.com/youtubei/v1")!
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicLyrics")

    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var waitUntil: Date?

    init(transport: any HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    static func live() -> YTMusicLyricsClient {
        YTMusicLyricsClient(transport: LiveTransport(configuration: makeConfiguration()))
    }

    /// Ephemeral, with no cookie jar, URL cache or credential storage, and a short fuse: lyrics are a nicety. This is
    /// its own session, never the signed-in one.
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

    /// While a 429 or a failure has paused this source, when the pause ends; nil otherwise.
    var busyUntil: Date? {
        guard let waitUntil, waitUntil > now() else { return nil }
        return waitUntil
    }

    // MARK: - Lookup

    func lyrics(for query: LyricsQuery) async throws -> LyricsResult {
        try await answer(for: query).result
    }

    /// Nothing found is an answer, not an error, and what YouTube Music says does not depend on the length the
    /// player knows. A tab with no lyrics (an instrumental, a lofi mix) is "nothing found" too, never `.instrumental`:
    /// the tab being empty does not say the song has no words.
    func answer(for query: LyricsQuery) async throws -> LyricsAnswer {
        let next = try await post("next", body: ["videoId": query.videoId, "isAudioOnly": true], as: Self.web)
        guard let browseId = try YTMusicLyricsParser.lyricsBrowseId(inNext: next) else { return Self.nothing }

        // Android first: its page carries the timed lyrics, and so the plain description too when that is all it has,
        // which is then returned at once. Only a page with no lyrics at all sends the lookup on to the web page.
        // A failure on the Android page (a refusal, a page that is not JSON) does not end the lookup either: it is kept,
        // the web page is still tried, and if that finds nothing the kept failure is thrown, so a song YouTube Music
        // may well have lyrics for is never remembered as one without. A cancellation or a 429 ends it at once.
        var failure: (any Error)?
        do {
            if let answer = try await lyricsAnswer(browseId: browseId, as: Self.android) { return answer }
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let error as LyricsError {
            if case .busy = error { throw error }
            failure = error
        } catch {
            failure = error
        }

        do {
            if let answer = try await lyricsAnswer(browseId: browseId, as: Self.web) { return answer }
        } catch where failure == nil || error is CancellationError {
            // Nothing went wrong before, so this is the failure of the lookup; a cancellation always is.
            throw error
        } catch {
            // The second look is best effort once the first has failed: the first failure stands.
        }
        if let failure { throw failure }
        return Self.nothing
    }

    /// The lyrics on the lyrics page as one client sees it, or nil when that page has none.
    private func lyricsAnswer(browseId: String, as profile: Profile) async throws -> LyricsAnswer? {
        let page = try await post("browse", body: ["browseId": browseId], as: profile)
        guard let lyrics = try YTMusicLyricsParser.lyrics(inBrowse: page) else { return nil }
        return LyricsAnswer(result: lyrics.result, credit: Self.credit(forSource: lyrics.source), lengthMatters: false)
    }

    private static let nothing = LyricsAnswer(result: .notFound, credit: nil, lengthMatters: false)

    // MARK: - Credit

    /// "Lyrics from <provider> via YouTube Music". The provider is YouTube's own "Source: ..." line with the word
    /// Source and the colon taken off, spaces collapsed, control characters dropped and the name cut to a length that
    /// fits the panel, in characters and in scalars. With no provider it is "Lyrics from YouTube Music".
    static func credit(forSource source: String?) -> String {
        var name = (source ?? "").split(whereSeparator: \.isWhitespace)
            .map { printable(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if name.lowercased().hasPrefix("source:") { name = String(name.dropFirst("source:".count)) }
        name = capped(name.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Lyrics from YouTube Music" : "Lyrics from \(name) via YouTube Music"
    }

    /// The first `maximumProviderLength` characters, as long as they stay within `maximumProviderScalars` scalars. A
    /// character is never cut in two: the one that would pass the scalar cap, and all after it, are left out.
    private static func capped(_ text: String) -> String {
        var result = ""
        var scalars = 0
        for character in text.prefix(maximumProviderLength) {
            scalars += character.unicodeScalars.count
            guard scalars <= maximumProviderScalars else { break }
            result.append(character)
        }
        return result
    }

    /// The text without control and invisible format characters (a bidirectional override has no place in a credit).
    private static func printable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where ![.control, .format].contains(scalar.properties.generalCategory) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    // MARK: - Redirects

    /// The redirect itself when it stays on https music.youtube.com (the default port, no user), else nil. A 307 or a
    /// 308 repeats the POST with its body, so one that leaves the host is refused: the 3xx then becomes the answer,
    /// which is a failure like any other.
    static func permittedRedirect(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "music.youtube.com",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443
        else { return nil }
        return request
    }

    // MARK: - Network

    /// One POST. A 429 opens the 60 s pause and throws `busy`, even when the caller was cancelled meanwhile (the
    /// request was sent, so the next song must not walk into the same answer). A 5xx, or a timeout or other network
    /// failure, opens the 15 s pause and throws as it is; the calls that follow within it throw `busy` at once, without
    /// sending anything. Any other non-2xx status throws `http`; a body over the cap throws `parse`.
    private func post(_ endpoint: String, body: [String: Any], as profile: Profile) async throws -> Data {
        if let until = busyUntil { throw LyricsError.busy(until: until) }
        try Task.checkCancellation()

        let response: HTTPResponse
        do {
            response = try await transport.send(try Self.request(endpoint, body: body, as: profile))
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            Self.log.info("youtube music lyrics \(endpoint, privacy: .public) failed with a network error")
            pause(for: Self.errorCooldown)
            try Task.checkCancellation()
            throw error
        }
        Self.log.info("youtube music lyrics \(endpoint, privacy: .public) answered \(response.statusCode)")

        if response.statusCode == 429 {
            let until = pause(for: Self.cooldown)
            try Task.checkCancellation()
            throw LyricsError.busy(until: until)
        }
        if (500..<600).contains(response.statusCode) { pause(for: Self.errorCooldown) }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw LyricsError.http(response.statusCode) }
        guard response.data.count <= Self.maximumResponseBytes else { throw LyricsError.parse }
        return response.data
    }

    /// Holds this source back for `seconds`, or for what is left of a longer pause already open. Returns when it ends.
    @discardableResult
    private func pause(for seconds: TimeInterval) -> Date {
        let until = now().addingTimeInterval(seconds)
        waitUntil = max(waitUntil ?? until, until)
        return until
    }

    /// The request for one endpoint as one client: its context in the body, its name, version and user agent in the
    /// headers, and no Cookie, no Authorization and nothing else that would say who is listening.
    private static func request(_ endpoint: String, body: [String: Any], as profile: Profile) throws -> HTTPRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = "prettyPrint=false"
        guard let url = components?.url else { throw LyricsError.parse }

        var full = body
        full["context"] = ["client": ["clientName": profile.name, "clientVersion": profile.version, "hl": "en", "gl": "US"]]
        guard let data = try? JSONSerialization.data(withJSONObject: full, options: [.sortedKeys]) else {
            throw LyricsError.parse
        }
        return HTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Origin": origin,
                "X-YouTube-Client-Name": profile.number,
                "X-YouTube-Client-Version": profile.version,
                "User-Agent": profile.userAgent,
            ],
            body: data
        )
    }
}

/// Refuses every redirect that leaves https music.youtube.com. Used by this client's own session only.
final class YTMusicRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // The completion-handler form: the async variant crashes the Swift 6.x ObjC thunk lowering.
        completionHandler(YTMusicLyricsClient.permittedRedirect(request))
    }
}

/// The live transport: a session of its own (see `makeConfiguration()`) that answers redirects with the guard above.
/// The shared `URLSessionTransport` lets a redirect go to any https host, which a body-carrying POST must not.
private struct LiveTransport: HTTPTransport {
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(
            for: URLSessionTransport.urlRequest(for: request),
            delegate: YTMusicRedirectGuard()
        )
        guard let http = response as? HTTPURLResponse else { throw LyricsError.http(0) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, data: data)
    }
}
