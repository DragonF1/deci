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
    /// Headers AVURLAsset must send with the stream (User-Agent).
    let httpHeaders: [String: String]
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
    func search(_ query: String) async throws -> [MusicTrack]
    func resolve(videoId: String) async throws -> ResolvedStream
    /// First page of the radio seeded by `seedVideoId` (playlist RDAMVM<seedVideoId>).
    func radio(seedVideoId: String) async throws -> MusicQueuePage
    /// The page after `continuation` of the radio seeded by `seedVideoId`.
    func moreRadio(seedVideoId: String, continuation: String) async throws -> MusicQueuePage
    /// Sends the single history ping for one playback session.
    func reportPlayback(trackingURL: URL, cpn: String) async throws
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
