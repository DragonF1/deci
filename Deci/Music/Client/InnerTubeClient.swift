import Foundation
import os

/// What a call needs from music.youtube.com's home page.
struct InnerTubeSession: Sendable, Equatable {
    let clientVersion: String
    let visitorData: String?
    let playerJSURL: URL?

    var playerHash: String? { playerJSURL.flatMap(InnerTubeParser.playerHash(fromPlayerJSURL:)) }
}

/// The YouTube Music web client (WEB_REMIX, client name 67). It owns the cookie jar: every
/// request goes out with the matching cookies, every Set-Cookie that comes back is merged in and
/// persisted, and nothing else reads or writes the jar.
actor InnerTubeClient {
    /// Used when the home page cannot be read; YouTube accepts older WEB_REMIX versions for a long time.
    static let fallbackClientVersion = "1.20260707.12.00"
    /// The "Songs" filter of YouTube Music search.
    static let songsSearchParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    static let sessionLifetime: TimeInterval = 6 * 60 * 60

    private static let homeURL = URL(string: "https://music.youtube.com/")!
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicClient")
    private static let signInSuffixes = ["google.com", "youtube.com"]
    private static let trustedHostSuffixes = ["youtube.com"]

    private let transport: HTTPTransport
    private let secretStore: MusicSecretStore
    private let now: @Sendable () -> Date

    /// Loaded from the secret store on first use, so constructing the client never touches the Keychain.
    private var jar: MusicCookieJar?
    private var cachedSession: (session: InnerTubeSession, fetchedAt: Date)?
    private var bootstrapTask: Task<InnerTubeSession, Error>?

    init(transport: HTTPTransport, secretStore: MusicSecretStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.secretStore = secretStore
        self.now = now
    }

    // MARK: - Sign-in state

    func isSignedIn() -> Bool {
        currentJar().hasSignInCookies
    }

    /// Keeps the Google and YouTube cookies from the sign-in window, stores them, and bootstraps.
    func signIn(with cookies: [StoredCookie]) async throws {
        let relevant = cookies.filter { Self.isSignInDomain($0.domain) }
        let newJar = MusicCookieJar(signInCookies: relevant, now: now())
        guard newJar.hasSignInCookies else { throw MusicError.signedOut }
        try secretStore.save(try JSONEncoder().encode(newJar))
        jar = newJar
        resetSession()
        // Best effort: a failure here is retried by the first real call.
        _ = try? await session()
    }

    func signOut() {
        secretStore.delete()
        jar = MusicCookieJar()
        resetSession()
    }

    // MARK: - Session

    /// The home page's client version, visitor id and player JS URL, refreshed every six hours.
    func session() async throws -> InnerTubeSession {
        if let cached = cachedSession, now().timeIntervalSince(cached.fetchedAt) < Self.sessionLifetime {
            return cached.session
        }
        if let task = bootstrapTask { return try await task.value }
        let task = Task { try await self.fetchBootstrap() }
        bootstrapTask = task
        defer { bootstrapTask = nil }
        return try await task.value
    }

    private func fetchBootstrap() async throws -> InnerTubeSession {
        var headers = [
            "User-Agent": MusicAuthHeaders.userAgent,
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        if let cookie = currentJar().cookieHeader(for: Self.homeURL, now: now()) { headers["Cookie"] = cookie }
        let response = try await transport.send(HTTPRequest(url: Self.homeURL, method: "GET", headers: headers))
        absorbCookies(from: response, url: Self.homeURL)
        guard (200..<300).contains(response.statusCode) else { throw MusicError.http(response.statusCode) }

        let config = InnerTubeParser.bootstrapConfig(fromHTML: String(decoding: response.data, as: UTF8.self))
        let session = InnerTubeSession(
            clientVersion: config.clientVersion ?? Self.fallbackClientVersion,
            visitorData: config.visitorData,
            playerJSURL: config.playerJSURL
        )
        if config.clientVersion != nil || config.playerJSURL != nil {
            cachedSession = (session, now())
        }
        Self.log.info("bootstrap ok, client \(session.clientVersion, privacy: .public), player \(session.playerHash ?? "none", privacy: .public)")
        return session
    }

    /// The real session, or a bare one when the home page is unreachable: search and playback
    /// calls do not need the page to work.
    private func sessionOrFallback() async throws -> InnerTubeSession {
        do {
            return try await session()
        } catch {
            try Task.checkCancellation()
            Self.log.error("bootstrap failed, using the built-in client version")
            return InnerTubeSession(clientVersion: Self.fallbackClientVersion, visitorData: nil, playerJSURL: nil)
        }
    }

    private func resetSession() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        cachedSession = nil
    }

    // MARK: - Calls

    func search(_ query: String) async throws -> [MusicTrack] {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let session = try await sessionOrFallback()
        let data = try await post("search", session: session, body: ["query": trimmed, "params": Self.songsSearchParams])
        let tracks = try InnerTubeParser.searchTracks(from: data)
        Self.log.info("search returned \(tracks.count) rows")
        return tracks
    }

    func player(videoId: String, signatureTimestamp: Int) async throws -> PlayerResponse {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let session = try await sessionOrFallback()
        let data = try await post("player", session: session, body: [
            "videoId": videoId,
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": signatureTimestamp]],
            "racyCheckOk": true,
            "contentCheckOk": true,
        ])
        return try InnerTubeParser.playerResponse(from: data)
    }

    /// The player JS is public: no cookies, no Authorization.
    func playerJS(at url: URL) async throws -> String {
        guard Self.isTrusted(url) else { throw MusicError.parse("player url is not an https YouTube url") }
        let response = try await transport.send(HTTPRequest(
            url: url,
            method: "GET",
            headers: ["User-Agent": MusicAuthHeaders.userAgent, "Accept": "*/*"]
        ))
        guard (200..<300).contains(response.statusCode) else { throw MusicError.http(response.statusCode) }
        return String(decoding: response.data, as: UTF8.self)
    }

    /// The single history ping: the tracking URL plus the web client's own parameters.
    func reportPlayback(trackingURL: URL, cpn: String) async throws {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        guard Self.isTrusted(trackingURL) else { throw MusicError.parse("tracking url is not an https YouTube url") }
        let session = try await sessionOrFallback()
        let url = HistoryURLBuilder.url(trackingURL: trackingURL, cpn: cpn, clientVersion: session.clientVersion)
        guard var headers = authenticatedHeaders(for: url, session: session) else { throw MusicError.signedOut }
        headers["Content-Type"] = nil
        let response = try await transport.send(HTTPRequest(url: url, method: "GET", headers: headers))
        absorbCookies(from: response, url: url)
        guard response.statusCode == 200 || response.statusCode == 204 else { throw Self.error(for: response.statusCode) }
    }

    // MARK: - Requests

    private func post(_ endpoint: String, session: InnerTubeSession, body: [String: Any]) async throws -> Data {
        let url = URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!
        guard let headers = authenticatedHeaders(for: url, session: session) else { throw MusicError.signedOut }
        var payload = body
        payload["context"] = ["client": clientContext(session)]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = try await transport.send(HTTPRequest(url: url, method: "POST", headers: headers, body: data))
        absorbCookies(from: response, url: url)
        guard (200..<300).contains(response.statusCode) else { throw Self.error(for: response.statusCode) }
        return response.data
    }

    private func clientContext(_ session: InnerTubeSession) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": session.clientVersion,
            "hl": "en",
            "gl": "US",
        ]
        if let visitorData = session.visitorData { client["visitorData"] = visitorData }
        return client
    }

    private func authenticatedHeaders(for url: URL, session: InnerTubeSession) -> [String: String]? {
        MusicAuthHeaders.apiHeaders(
            jar: currentJar(),
            url: url,
            clientVersion: session.clientVersion,
            visitorData: session.visitorData,
            now: now()
        )
    }

    private static func error(for status: Int) -> MusicError {
        status == 401 ? .signedOut : .http(status)
    }

    // MARK: - Cookies

    private func currentJar() -> MusicCookieJar {
        if let jar { return jar }
        var loaded = secretStore.load().flatMap { try? JSONDecoder().decode(MusicCookieJar.self, from: $0) } ?? MusicCookieJar()
        loaded.prune(now: now())
        jar = loaded
        return loaded
    }

    private func absorbCookies(from response: HTTPResponse, url: URL) {
        var updated = currentJar()
        guard updated.merge(headerFields: response.headers, for: url, now: now()) else { return }
        jar = updated
        do {
            try secretStore.save(try JSONEncoder().encode(updated))
        } catch {
            // The in-memory jar still works for this launch; only the persisted copy is stale.
            Self.log.error("could not persist rotated cookies")
        }
    }

    private static func isSignInDomain(_ domain: String) -> Bool {
        let bare = domain.lowercased().drop { $0 == "." }
        return signInSuffixes.contains { bare == $0 || bare.hasSuffix("." + $0) }
    }

    private static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return trustedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
