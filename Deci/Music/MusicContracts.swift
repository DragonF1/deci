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
    /// The names in `artist` that have an artist page behind them, in the order they are shown. Empty when the
    /// row's artist runs carry no page (or the source has none), so the line is plain text.
    var artistLinks: [MusicArtistLink] = []

    var id: String { videoId }
}

/// An artist's name under a song with the page it opens.
struct MusicArtistLink: Sendable, Hashable {
    let name: String
    /// The artist's channel id ("UC...").
    let browseId: String

    /// What opens this artist's page. It has no photo: the page's own header shows it.
    var opener: MusicCollection {
        MusicCollection(browseId: browseId, kind: .artist, title: name, subtitle: "", thumbnailURL: nil)
    }

    /// What VoiceOver says for the name's button.
    var openLabel: String { "Open \(name)" }
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
    /// What the watchtime ping reports about the listening since the previous one. Nil sends the one-segment
    /// ping (`st=0`, `et=mediaTime`); a playback ping never has it.
    var details: WatchtimeDetails?
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

/// An album, playlist (mixes included) or artist, as a tile on Home or a row in Library.
/// Opening it browses `browseId`.
struct MusicCollection: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        /// browseId "VL<playlistId>". A mix tile that only has a playlistId is stored as "VL" + it.
        case playlist
        /// browseId "MPRE...".
        case album
        /// browseId "UC...".
        case artist
    }

    let browseId: String
    let kind: Kind
    let title: String
    /// YouTube's own second line, e.g. "Album • Daft Punk • 2013" or "Playlist • 50 songs".
    let subtitle: String
    let thumbnailURL: URL?

    var id: String { browseId }
}

/// One tile or row on a shelf: a song, or something that opens a page.
enum MusicShelfItem: Sendable, Hashable, Identifiable {
    case track(MusicTrack)
    case collection(MusicCollection)

    var id: String {
        switch self {
        case .track(let track): "t:" + track.videoId
        case .collection(let collection): "c:" + collection.browseId
        }
    }
}

/// A titled row of items: "Quick picks", "Listen again", "Mixed for you", an artist's "Albums".
struct MusicShelf: Sendable, Hashable, Identifiable {
    let title: String
    let items: [MusicShelfItem]

    var id: String { title + "|" + (items.first?.id ?? "") }
}

/// Home (browse FEmusic_home): shelves top to bottom, more on scroll.
struct MusicHomePage: Sendable, Equatable {
    let shelves: [MusicShelf]
    /// Token for more shelves; nil when there are no more.
    let continuation: String?
}

/// The library lists Deci shows. Liked songs are the "VLLM" playlist, opened with `page(browseId:)`.
enum MusicLibrarySection: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// FEmusic_liked_playlists
    case playlists
    /// FEmusic_liked_albums
    case albums
    /// FEmusic_library_corpus_track_artists
    case artists

    var id: String { rawValue }
}

/// One page of a library list.
struct MusicCollectionList: Sendable, Equatable {
    let items: [MusicCollection]
    let continuation: String?
}

/// A playlist, album or artist page.
struct MusicBrowsePage: Sendable, Equatable {
    let browseId: String
    let title: String
    /// e.g. "Album • 2013 • 13 songs", or an artist's subscriber line. Nil when the page has none.
    let subtitle: String?
    let thumbnailURL: URL?
    /// The songs listed on the page: a playlist's or album's tracks, an artist's top songs.
    /// Album tracks carry the album's artist and cover when the row itself has none.
    let tracks: [MusicTrack]
    /// Token for more tracks (long playlists); nil when there are no more.
    let continuation: String?
    /// Shelves under the songs (an artist's albums, singles, playlists); empty for playlists and albums.
    let shelves: [MusicShelf]
}

/// Who the session is signed in as, from YouTube's account menu. Shown on the Music tab's account card.
struct MusicAccount: Sendable, Equatable {
    /// The channel or Google account name the menu is headed with.
    let name: String
    /// The "@handle" line, when the channel has one.
    let handle: String?
    /// The avatar, always https.
    let photoURL: URL?
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
    /// Writes cookie changes that were held back to the Keychain, synchronously, on the calling
    /// thread, and retries a sign-out delete that was refused. The quit path calls it; nothing is written
    /// when nothing is waiting, and it returns at once when another thread is already writing.
    func flushCookies()
    /// Whether the session plays as a brand channel (History is kept per channel), or nil when
    /// signed out or the home page doesn't say. Runs the bootstrap if it hasn't run yet.
    func channelIdentity() async -> Bool?
    /// The session's cookies, for the channel picker window to start from.
    func sessionCookies() async -> [StoredCookie]
    /// Name, handle and avatar of the signed-in channel (account menu). Nil when the menu has no
    /// account header. Throws `.signedOut` when YouTube says the session is gone.
    func accountInfo() async throws -> MusicAccount?
    func search(_ query: String) async throws -> [MusicTrack]
    /// Artists matching `query`, for the Artists shelf over the search results.
    func searchArtists(_ query: String) async throws -> [MusicCollection]
    func resolve(videoId: String) async throws -> ResolvedStream
    /// First page of the radio seeded by `seedVideoId` (playlist RDAMVM<seedVideoId>).
    func radio(seedVideoId: String) async throws -> MusicQueuePage
    /// The page after `continuation` of the radio seeded by `seedVideoId`.
    func moreRadio(seedVideoId: String, continuation: String) async throws -> MusicQueuePage
    /// Home shelves (browse FEmusic_home).
    func home() async throws -> MusicHomePage
    /// The shelves after `continuation` on Home.
    func moreHome(continuation: String) async throws -> MusicHomePage
    /// First page of a library list. Throws `.signedOut` when YouTube says the session is gone.
    func library(_ section: MusicLibrarySection) async throws -> MusicCollectionList
    /// The page after `continuation` of a library list.
    func moreLibrary(_ section: MusicLibrarySection, continuation: String) async throws -> MusicCollectionList
    /// A playlist ("VL..."), album ("MPRE...") or artist ("UC...") page.
    func page(browseId: String) async throws -> MusicBrowsePage
    /// The tracks after `continuation` on a playlist page.
    func moreTracks(browseId: String, continuation: String) async throws -> MusicQueuePage
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
