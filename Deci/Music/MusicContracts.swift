import Foundation

// The boundary between the YouTube Music backend (Auth, Client, Solver,
// Streams) and the player/UI side. The live backend is
// `actor MusicBackendLive: MusicBackend` with `static func live() -> MusicBackendLive`.

/// A song row from search, home or library.
struct MusicTrack: Sendable, Hashable, Identifiable {
    let videoId: String
    let title: String
    /// Artists joined for display, e.g. "Daft Punk, Pharrell Williams".
    let artist: String
    let album: String?
    let durationSeconds: Int?
    let thumbnailURL: URL?

    var id: String { videoId }
}

/// A playable audio stream for one track, valid until `expiresAt`.
struct ResolvedStream: Sendable, Equatable {
    let videoId: String
    let url: URL
    let itag: Int
    let durationSeconds: Double?
    let expiresAt: Date
    /// playbackTracking.videostatsPlaybackUrl.baseUrl, used for the history ping.
    let playbackTrackingURL: URL?
    /// playbackTracking.videostatsWatchtimeUrl.baseUrl, used for the watchtime ping that follows it.
    let watchtimeTrackingURL: URL?
    /// Headers AVURLAsset must send with the stream (User-Agent).
    let httpHeaders: [String: String]

    init(
        videoId: String,
        url: URL,
        itag: Int,
        durationSeconds: Double?,
        expiresAt: Date,
        playbackTrackingURL: URL?,
        watchtimeTrackingURL: URL? = nil,
        httpHeaders: [String: String]
    ) {
        self.videoId = videoId
        self.url = url
        self.itag = itag
        self.durationSeconds = durationSeconds
        self.expiresAt = expiresAt
        self.playbackTrackingURL = playbackTrackingURL
        self.watchtimeTrackingURL = watchtimeTrackingURL
        self.httpHeaders = httpHeaders
    }
}

/// One ping that puts a play into the account's YouTube Music history. A session sends the
/// playback ping and then the watchtime ping, both with the same `cpn`.
struct HistoryPing: Sendable, Equatable {
    enum Kind: Sendable, Hashable {
        /// videostatsPlaybackUrl: marks the song as played.
        case playback
        /// videostatsWatchtimeUrl: reports how much of it was watched.
        case watchtime
    }

    let kind: Kind
    /// The tracking URL exactly as the player response gave it.
    let url: URL
    /// The session's client playback nonce, see `CPN`.
    let cpn: String
    /// Position in the song, in seconds, when the ping goes out.
    let mediaTime: TimeInterval
}

/// One cookie from the Google sign-in, as stored in the Keychain.
struct StoredCookie: Codable, Sendable, Hashable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
}

extension StoredCookie {
    init(_ cookie: HTTPCookie) {
        self.init(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expires: cookie.expiresDate,
            isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly
        )
    }

    /// Back to an HTTPCookie, to seed the channel picker's web view with the current session.
    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { properties[.expires] = expires }
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}

/// One page of a radio (autoplay) queue from the `next` endpoint.
struct MusicQueuePage: Sendable, Equatable {
    /// Tracks in play order. A fresh radio starts with the seed track itself.
    let tracks: [MusicTrack]
    /// Token for the following page; nil when YouTube has no more.
    let continuation: String?
}

enum MusicError: Error, Sendable, Equatable {
    case signedOut
    case http(Int)
    case parse(String)
    /// playabilityStatus was not OK; carries YouTube's reason.
    case unplayable(String)
    case noAudioFormat
    case solver(String)
}

/// Everything the player/UI side needs from the YouTube Music backend.
protocol MusicBackend: Sendable {
    func isSignedIn() async -> Bool
    /// Saves the cookies harvested from the sign-in window and bootstraps the session.
    func signIn(with cookies: [StoredCookie]) async throws
    /// Wipes the Keychain jar and any cached session state.
    func signOut() async
    /// Whether the session plays as a brand channel (History is kept per channel), or nil when
    /// signed out or the home page doesn't say. Runs the bootstrap if it hasn't run yet.
    func channelIdentity() async -> Bool?
    /// The session's cookies, for the channel picker window to start from.
    func sessionCookies() async -> [StoredCookie]
    func search(_ query: String) async throws -> [MusicTrack]
    func resolve(videoId: String) async throws -> ResolvedStream
    /// First page of the radio seeded by `seedVideoId` (playlist RDAMVM<seedVideoId>).
    func radio(seedVideoId: String) async throws -> MusicQueuePage
    /// The page after `continuation` of the radio seeded by `seedVideoId`.
    func moreRadio(seedVideoId: String, continuation: String) async throws -> MusicQueuePage
    /// Sends one history ping and returns the HTTP status YouTube answered with (200 or 204 when
    /// it took the ping). Throws on any other status, when signed out, or when the URL is not YouTube's.
    func reportHistory(_ ping: HistoryPing) async throws -> Int
}

/// Client playback nonce: 16 chars from A-Za-z0-9-_, one per playback session.
enum CPN {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return make(using: &generator)
    }

    static func make<G: RandomNumberGenerator>(using generator: inout G) -> String {
        String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }
}
