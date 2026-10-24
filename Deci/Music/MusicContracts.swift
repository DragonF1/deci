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
    /// The album's page ("MPRE...") when the row's album run links to one. Nil when the row names no album or
    /// the run carries no page.
    var albumBrowseId: String?
    /// YouTube's id for this row's place in a playlist, which removing the row needs. Nil on rows that are not
    /// playlist items. Public playlists carry it too, so whether the user may edit the playlist is the page's
    /// `isEditable`, not this.
    var playlistSetVideoId: String?
    /// How many times the song was played, as the row's "2B plays" says. Only an artist page's rows and some search
    /// and home rows carry it; nil elsewhere, which sorts last.
    var plays: Int?

    var id: String { videoId }
}

/// Whether the signed-in user likes a song, as YouTube Music keeps it. Liking and disliking are exclusive; `indifferent`
/// is neither.
enum MusicLikeStatus: Sendable, Equatable {
    case like
    case dislike
    case indifferent
}

/// One playlist the user can add a song to, from the "Save to playlist" picker.
struct MusicPlaylistOption: Sendable, Hashable, Identifiable {
    /// The playlist id without the "VL" a browse id carries.
    let playlistId: String
    let title: String
    let thumbnailURL: URL?
    /// Whether the song is already in this playlist.
    let containsVideo: Bool

    var id: String { playlistId }
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
    /// videoDetails.viewCount of the player response; nil when YouTube did not send one.
    let viewCount: Int?
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
        viewCount: Int? = nil,
        httpHeaders: [String: String]
    ) {
        self.videoId = videoId
        self.url = url
        self.itag = itag
        self.durationSeconds = durationSeconds
        self.expiresAt = expiresAt
        self.playbackTrackingURL = playbackTrackingURL
        self.watchtimeTrackingURL = watchtimeTrackingURL
        self.viewCount = viewCount
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
    /// The artists the subtitle links to, in the order shown. Only a Home or shelf tile has them; empty elsewhere.
    var artistLinks: [MusicArtistLink] = []
    /// An album's playlist of songs ("OLAK5uy_..."), the id a whole-album save adds from. Only an album tile that
    /// carries one has it; nil elsewhere.
    var audioPlaylistId: String?
    /// Whether this opens an artist's list of all their songs (the "Show all" of the Top songs), which sorts by Popular,
    /// Album and Plays. The route carries it because an album's "OLAK5uy_" playlist has the same kind of id.
    var isArtistSongs = false

    var id: String { browseId }

    /// The year in the second line: the last " • "-separated part that is exactly four digits in 1900 to 2100 ("Album •
    /// 2013", "Album • 2013 • 13 songs" and a bare "2013" all give 2013). Nil when the line names no year.
    var releaseYear: Int? {
        for part in subtitle.components(separatedBy: "\u{2022}").reversed() {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count == 4, text.allSatisfy({ $0.isASCII && $0.isNumber }),
               let year = Int(text), (1900...2100).contains(year) { return year }
        }
        return nil
    }
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

    var id: String { rawValue }
}

/// One page of a library list.
struct MusicCollectionList: Sendable, Equatable {
    let items: [MusicCollection]
    let continuation: String?
}

/// Where an artist's discography lives: the "MPAD..." page a shelf header opens, and the `params` that pick its albums,
/// singles or the rest, kept exactly as YouTube sent them.
struct MusicDiscographyLink: Sendable, Hashable {
    let browseId: String
    let params: String?
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
    /// Whether the user can change this playlist's songs (their own playlist, not Liked Music or an album).
    var isEditable = false
    /// An album's audio playlist ("OLAK5uy_..."), the playlist its automix is asked of. Nil on every other page, and on
    /// an album whose rows name none.
    var audioPlaylistId: String?
    /// An artist page's list of all their songs ("VL..."), which the Top songs header links to. Nil on every other
    /// page, and on an artist page whose Top songs header names none.
    var allSongsBrowseId: String?
    /// An artist page's discography pages, one for each Albums or Singles shelf that links to one, without repeats.
    /// Release dates are read from them. Empty on every other page.
    var discographyLinks: [MusicDiscographyLink] = []

    /// The playlist a mix page ("RD..." with or without the "VL" prefix) is, or nil for any other id. A curated
    /// "RDCLAK5uy_" playlist is a playlist, not a mix.
    static func mixPlaylistId(ofBrowseId browseId: String) -> String? {
        let id = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
        guard id.hasPrefix("RD"), !id.hasPrefix("RDCLAK5uy") else { return nil }
        return id
    }

    /// The mix playlist this page is, nil when it is not a mix: the queue it starts keeps asking the mix for more.
    var mixPlaylistId: String? { Self.mixPlaylistId(ofBrowseId: browseId) }

    /// The playlist whose automix follows this page: a playlist's own id ("VLLM" gives "LM"), an album's audio playlist.
    /// Nil for a mix, an artist page and anything else, which end in the plain radio.
    var automixPlaylistId: String? {
        if browseId.hasPrefix("MPRE") { return audioPlaylistId.flatMap { $0.isEmpty ? nil : $0 } }
        guard browseId.hasPrefix("VL"), Self.mixPlaylistId(ofBrowseId: browseId) == nil else { return nil }
        let id = String(browseId.dropFirst(2))
        return id.isEmpty ? nil : id
    }
}

/// Where the automix of a playlist continues: the radio playlist YouTube names in the last row of the playlist's
/// queue, and the parameters that go with it.
struct MusicAutomixEndpoint: Sendable, Equatable {
    let playlistId: String
    /// Percent-encoded exactly as YouTube sent it; nil when the endpoint carries none.
    let params: String?
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
    /// A write call (save, remove, pin) came back without the success marker.
    case rejected

    /// A queue page error that retrying will not fix: an unreadable response or a rejected request. A timeout (408) or a
    /// rate limit (429) passes, so those wait for a retry.
    static func endsPaging(_ error: any Error) -> Bool {
        switch error as? MusicError {
        case .parse: true
        case .http(let status): (400..<500).contains(status) && status != 408 && status != 429
        default: false
        }
    }
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
    /// First page of the automix of playlist `playlistId` after `afterVideoId`, the song the playlist ends on. Falls back
    /// to the radio of `afterVideoId` when YouTube names no automix. Continuations are `moreRadio` pages.
    func autoplay(afterVideoId: String, playlistId: String) async throws -> MusicQueuePage
    /// First page of the mix `playlistId` ("RDTMAK5uy_..." and the other RD ids) after `afterVideoId`, the song the mix
    /// page ends on. Unlike the automix there is no fallback: a mix YouTube refuses throws, and the caller decides what
    /// follows. Continuations are `moreRadio` pages.
    func mix(playlistId: String, afterVideoId: String) async throws -> MusicQueuePage
    /// Home shelves (browse FEmusic_home).
    func home() async throws -> MusicHomePage
    /// The shelves after `continuation` on Home.
    func moreHome(continuation: String) async throws -> MusicHomePage
    /// The signed-in account's listening history (browse FEmusic_history): one shelf per day, newest first.
    /// Paused or empty history is an empty page, not an error. Throws `.signedOut` when the session is gone.
    func history() async throws -> MusicHomePage
    /// The days after `continuation` in the history.
    func moreHistory(continuation: String) async throws -> MusicHomePage
    /// First page of a library list. Throws `.signedOut` when YouTube says the session is gone.
    func library(_ section: MusicLibrarySection) async throws -> MusicCollectionList
    /// The page after `continuation` of a library list.
    func moreLibrary(_ section: MusicLibrarySection, continuation: String) async throws -> MusicCollectionList
    /// A playlist ("VL..."), album ("MPRE...") or artist ("UC...") page.
    func page(browseId: String) async throws -> MusicBrowsePage
    /// The tracks after `continuation` on a playlist page.
    func moreTracks(browseId: String, continuation: String) async throws -> MusicQueuePage
    /// The albums on the first page of an artist's discography page ("MPAD..."), picked by `params` as the artist page's
    /// shelf header sent them. Their subtitles carry the release years.
    func discography(browseId: String, params: String?) async throws -> [MusicCollection]
    /// The playlists the user can add `videoId` to. YouTube Music does not send a flag for the ones that already hold the
    /// song, so the options come back unmarked unless YouTube flags them; `MusicTrackActionsStore` checks membership itself.
    func addToPlaylistOptions(videoId: String) async throws -> [MusicPlaylistOption]
    /// The playlists the user can add a whole playlist or album to (`sourcePlaylistId`, a leading "VL" is ignored).
    /// Likewise unmarked unless YouTube flags them: the store works out which already hold all of it.
    func addToPlaylistOptions(sourcePlaylistId: String) async throws -> [MusicPlaylistOption]
    /// Adds `videoId` to the playlist (a leading "VL" is ignored). Throws `.rejected` when YouTube does not say it worked.
    func addToPlaylist(videoId: String, playlistId: String) async throws
    /// Adds every song of the playlist `sourceId` (an album's "OLAK..." id works too) to the playlist `playlistId`. Throws
    /// `.rejected` when YouTube does not say it worked.
    func addPlaylistToPlaylist(sourceId: String, playlistId: String) async throws
    /// Removes one row of the playlist, named by its `setVideoId`. Throws `.rejected` when YouTube does not say it worked.
    func removeFromPlaylist(videoId: String, setVideoId: String, playlistId: String) async throws
    /// Sends one history ping and returns the HTTP status YouTube answered with (200 or 204 when
    /// it took the ping). Throws on any other status, when signed out, or when the URL is not YouTube's.
    func reportHistory(_ ping: HistoryPing) async throws -> Int
    /// The signed-in user's like state of one song, or nil when YouTube sends no like button for it. Throws `.signedOut`
    /// when signed out or the session is gone.
    func likeStatus(videoId: String) async throws -> MusicLikeStatus?
    /// Sets the like state of one song: `.like` and `.dislike` rate it, `.indifferent` takes the rating back. A 2xx answer
    /// is success. Throws `.signedOut` when signed out or the session is gone, `.http` for any other failed status.
    func rate(videoId: String, status: MusicLikeStatus) async throws
    /// The songs YouTube Music suggests after one song ("You might also like"), in its order. Empty when the song has
    /// no related tab or the answer has no song shelf. Throws `.signedOut` when signed out or the session is gone,
    /// `.http` for any other failed status, `.parse` for an answer that is not what was expected.
    func related(videoId: String) async throws -> [MusicTrack]
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
