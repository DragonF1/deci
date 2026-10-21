import Foundation
import os

/// What a call needs from music.youtube.com's home page.
struct InnerTubeSession: Sendable, Equatable {
    let clientVersion: String
    let visitorData: String?
    let playerJSURL: URL?
    /// Whether the page was served to a brand channel; nil when it didn't say.
    var isBrandChannel: Bool?
    /// The brand channel's page id; nil on the account's own channel. Never logged.
    var brandPageId: String?

    var playerHash: String? { playerJSURL.flatMap(InnerTubeParser.playerHash(fromPlayerJSURL:)) }
}

/// The YouTube Music web client (WEB_REMIX, client name 67). It owns the cookie jar: every
/// request goes out with the matching cookies, every Set-Cookie that comes back is merged in and
/// handed to the persister (which decides when the Keychain is written), and nothing else reads or
/// writes the jar. The jar is read from the Keychain once and lives in memory after that.
actor InnerTubeClient {
    /// Used when the home page cannot be read; YouTube accepts older WEB_REMIX versions for a long time.
    static let fallbackClientVersion = "1.20260707.12.00"
    /// The "Songs" filter of YouTube Music search.
    static let songsSearchParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    /// The "Artists" filter of YouTube Music search.
    static let artistsSearchParams = "EgWKAQIgAWoMEA4QChADEAQQCRAF"
    static let sessionLifetime: TimeInterval = 6 * 60 * 60

    private static let emptyPage = MusicQueuePage(tracks: [], continuation: nil)
    private static let homeURL = URL(string: "https://music.youtube.com/")!
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicClient")
    private static let trustedHostSuffixes = ["youtube.com"]

    private let transport: HTTPTransport
    private let persister: MusicJarPersister
    private let now: @Sendable () -> Date
    /// The device's time zone, read for every request. YouTube cuts History into days ("Today", "Yesterday") in the
    /// zone the client context names; without one the days end at UTC midnight.
    private let timeZone: @Sendable () -> TimeZone

    /// Loaded from the secret store on first use, so constructing the client never touches the Keychain.
    private var jar: MusicCookieJar?
    private var cachedSession: (session: InnerTubeSession, fetchedAt: Date)?
    private var bootstrapTask: Task<InnerTubeSession, Error>?
    /// Bumped by every sign-in and sign-out. A response that left under an older epoch belongs to a
    /// session that no longer exists, so it must not merge cookies, persist or fill the cache.
    private var epoch = 0

    init(
        transport: HTTPTransport,
        secretStore: MusicSecretStore,
        now: @escaping @Sendable () -> Date = { Date() },
        scheduler: MusicWriteScheduler = DispatchWriteScheduler(),
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }
    ) {
        self.transport = transport
        self.persister = MusicJarPersister(store: secretStore, now: now, scheduler: scheduler)
        self.now = now
        self.timeZone = timeZone
    }

    // MARK: - Sign-in state

    func isSignedIn() -> Bool {
        currentJar().hasSignInCookies
    }

    /// Keeps only the youtube.com cookies from the sign-in window and stores them. The bootstrap
    /// runs in the background; a failure there is retried by the first real call.
    func signIn(with cookies: [StoredCookie]) throws {
        let relevant = cookies.filter { MusicCookieJar.isYouTubeDomain($0.domain) }
        let newJar = MusicCookieJar(signInCookies: relevant, now: now())
        guard newJar.hasSignInCookies else { throw MusicError.signedOut }
        try persister.saveSignedIn(try JSONEncoder().encode(newJar))
        jar = newJar
        resetSession()
        Task { _ = try? await session() }
    }

    /// Deletes the Keychain item and drops every write the persister was holding back. A delete the Keychain
    /// refuses is logged and retried by `flushNow()`.
    func signOut() {
        persister.discard()
        jar = MusicCookieJar()
        resetSession()
    }

    /// Writes any cookie change that is still held back, and retries a sign-out delete that was refused.
    /// Synchronous and callable from any thread (the quit path runs it on the main thread right before the
    /// process exits); it never waits for the actor, nor for a Keychain call that another thread is in.
    nonisolated func flushNow() {
        persister.flushNow()
    }

    func channelIdentity() async -> Bool? {
        guard currentJar().hasSignInCookies else { return nil }
        return try? await session().isBrandChannel
    }

    func sessionCookies() -> [StoredCookie] {
        currentJar().cookies
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
        defer { if bootstrapTask == task { bootstrapTask = nil } }
        return try await task.value
    }

    private func fetchBootstrap() async throws -> InnerTubeSession {
        let epoch = epoch
        var headers = [
            "User-Agent": MusicAuthHeaders.userAgent,
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        if let cookie = currentJar().cookieHeader(for: Self.homeURL, now: now()) { headers["Cookie"] = cookie }
        let response = try await transport.send(HTTPRequest(url: Self.homeURL, method: "GET", headers: headers))
        absorbCookies(from: response, url: Self.homeURL, epoch: epoch)
        guard (200..<300).contains(response.statusCode) else { throw MusicError.http(response.statusCode) }

        let config = InnerTubeParser.bootstrapConfig(fromHTML: String(decoding: response.data, as: UTF8.self))
        let session = InnerTubeSession(
            clientVersion: config.clientVersion ?? Self.fallbackClientVersion,
            visitorData: config.visitorData,
            playerJSURL: config.playerJSURL,
            isBrandChannel: config.isBrandChannel,
            brandPageId: config.brandPageId
        )
        if (config.clientVersion != nil || config.playerJSURL != nil), !Task.isCancelled, epoch == self.epoch {
            cachedSession = (session, now())
        }
        Self.log.info("bootstrap ok, client \(session.clientVersion, privacy: .public), player \(session.playerHash ?? "none", privacy: .public)")
        let identity = session.isBrandChannel.map { $0 ? "brand channel" : "own channel" } ?? "unknown"
        Self.log.notice("bootstrap identity: \(identity, privacy: .public)")
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
        epoch += 1
        bootstrapTask?.cancel()
        bootstrapTask = nil
        cachedSession = nil
    }

    // MARK: - Calls

    /// Name, handle and avatar of the signed-in channel, from the account menu. Nil when the menu
    /// has no account header.
    func accountInfo() async throws -> MusicAccount? {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let session = try await sessionOrFallback()
        let data = try await post("account/account_menu", session: session, body: [:])
        let account = try InnerTubeParser.accountInfo(from: data)
        // The name, handle and photo are the user's own: only whether the menu had a header is logged.
        Self.log.info("account menu has account \(account != nil, privacy: .public)")
        return account
    }

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

    /// Artists matching `query`. Same guards as `search`; only the count is logged, never the query or a name.
    func searchArtists(_ query: String) async throws -> [MusicCollection] {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let session = try await sessionOrFallback()
        let data = try await post("search", session: session, body: ["query": trimmed, "params": Self.artistsSearchParams])
        let artists = try InnerTubeParser.searchArtists(from: data)
        Self.log.info("artist search returned \(artists.count) rows")
        return artists
    }

    /// The first page of the autoplay queue seeded by `seedVideoId`, starting with the seed itself.
    func radio(seedVideoId: String) async throws -> MusicQueuePage {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let seed = seedVideoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { return Self.emptyPage }
        let session = try await sessionOrFallback()
        let data = try await post("next", session: session, body: [
            "videoId": seed,
            "playlistId": "RDAMVM" + seed,
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ])
        let page = try InnerTubeParser.radioPage(from: data)
        Self.log.info("radio returned \(page.tracks.count) rows")
        return page
    }

    /// The token alone names the radio. Sending the seed along would make YouTube answer a stale
    /// token with the first page again; without it the answer has no continuation and parsing refuses it.
    func moreRadio(continuation: String) async throws -> MusicQueuePage {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let token = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return Self.emptyPage }
        let session = try await sessionOrFallback()
        let data = try await post("next", session: session, body: ["continuation": token])
        let page = try InnerTubeParser.radioContinuationPage(from: data)
        Self.log.info("radio continuation returned \(page.tracks.count) rows")
        return page
    }

    // MARK: - Browse

    static let homeBrowseId = "FEmusic_home"
    static let historyBrowseId = "FEmusic_history"

    static func browseId(for section: MusicLibrarySection) -> String {
        switch section {
        case .playlists: "FEmusic_liked_playlists"
        case .albums: "FEmusic_liked_albums"
        case .artists: "FEmusic_library_corpus_track_artists"
        }
    }

    func home() async throws -> MusicHomePage {
        let data = try await browse(browseId: Self.homeBrowseId)
        let page = try InnerTubeParser.homePage(from: data)
        Self.log.info("home returned \(page.shelves.count) shelves")
        return page
    }

    func moreHome(continuation: String) async throws -> MusicHomePage {
        guard let data = try await browseContinuation(continuation, browseId: Self.homeBrowseId) else {
            return MusicHomePage(shelves: [], continuation: nil)
        }
        let page = try InnerTubeParser.homeContinuationPage(from: data)
        Self.log.info("home continuation returned \(page.shelves.count) shelves")
        return page
    }

    /// The history page has Home's shape (a section list of shelves), so it reads with Home's parser.
    func history() async throws -> MusicHomePage {
        let data = try await browse(browseId: Self.historyBrowseId)
        let page = try InnerTubeParser.homePage(from: data)
        Self.log.info("history returned \(page.shelves.count) shelves")
        return page
    }

    func moreHistory(continuation: String) async throws -> MusicHomePage {
        guard let data = try await browseContinuation(continuation, browseId: Self.historyBrowseId) else {
            return MusicHomePage(shelves: [], continuation: nil)
        }
        let page = try InnerTubeParser.homeContinuationPage(from: data)
        Self.log.info("history continuation returned \(page.shelves.count) shelves")
        return page
    }

    func library(_ section: MusicLibrarySection) async throws -> MusicCollectionList {
        let data = try await browse(browseId: Self.browseId(for: section))
        let list = try InnerTubeParser.libraryPage(from: data)
        Self.log.info("library \(section.rawValue, privacy: .public) returned \(list.items.count) items")
        return list
    }

    func moreLibrary(_ section: MusicLibrarySection, continuation: String) async throws -> MusicCollectionList {
        guard let data = try await browseContinuation(continuation, browseId: Self.browseId(for: section)) else {
            return MusicCollectionList(items: [], continuation: nil)
        }
        let list = try InnerTubeParser.libraryContinuationPage(from: data)
        Self.log.info("library \(section.rawValue, privacy: .public) continuation returned \(list.items.count) items")
        return list
    }

    /// A playlist ("VL..."), album ("MPRE...") or artist ("UC...") page.
    func page(browseId: String) async throws -> MusicBrowsePage {
        let id = browseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MusicError.parse("page has no browse id") }
        let data = try await browse(browseId: id)
        let page = try InnerTubeParser.browsePage(from: data, browseId: id)
        Self.log.info("page returned \(page.tracks.count) rows and \(page.shelves.count) shelves")
        return page
    }

    func moreTracks(browseId: String, continuation: String) async throws -> MusicQueuePage {
        guard let data = try await browseContinuation(continuation, browseId: browseId) else { return Self.emptyPage }
        let page = try InnerTubeParser.tracksContinuationPage(from: data)
        Self.log.info("page continuation returned \(page.tracks.count) rows")
        return page
    }

    // MARK: - Song actions

    /// The playlists the user can add `videoId` to. YouTube Music does not send a flag for the ones that already hold the
    /// song, so the options come back unmarked unless YouTube flags them, and the store checks membership itself. Only the
    /// count is logged.
    func addToPlaylistOptions(videoId: String) async throws -> [MusicPlaylistOption] {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let id = videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }
        let session = try await sessionOrFallback()
        let data = try await post("playlist/get_add_to_playlist", session: session, body: ["videoIds": [id]])
        let options = try InnerTubeParser.addToPlaylistOptions(from: data)
        Self.log.info("add to playlist picker returned \(options.count) playlists")
        return options
    }

    /// The playlists the user can add a whole playlist or album to. Unmarked unless YouTube flags them, as for a song: the
    /// store works out which already hold all of it. The source goes without the "VL" a browse id carries. Only the count
    /// is logged.
    func addToPlaylistOptions(sourcePlaylistId: String) async throws -> [MusicPlaylistOption] {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let id = Self.plainPlaylistId(sourcePlaylistId)
        guard !id.isEmpty else { return [] }
        let session = try await sessionOrFallback()
        let data = try await post("playlist/get_add_to_playlist", session: session, body: ["playlistId": id])
        let options = try InnerTubeParser.addToPlaylistOptions(from: data)
        Self.log.info("add to playlist picker for a playlist returned \(options.count) playlists")
        return options
    }

    /// Adds one song to a playlist. No `dedupeOption`: "DEDUPE_OPTION_SKIP" skips YouTube's duplicate check and adds
    /// the song twice (ytmusicapi sends it only for `duplicates=True`). Without it a song the playlist already holds
    /// is refused, which lands as `.rejected`.
    func addVideo(_ videoId: String, toPlaylist playlistId: String) async throws {
        guard !videoId.isEmpty else { throw MusicError.parse("playlist edit has no video id") }
        let action: [String: Any] = ["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]
        try await editPlaylist(playlistId, action: action, what: "add")
    }

    /// Adds every song of the playlist `sourceId` (an album's "OLAK..." id works too) to a playlist, with one
    /// ACTION_ADD_PLAYLIST. Like the song add it sends no `dedupeOption`.
    func addPlaylist(_ sourceId: String, toPlaylist playlistId: String) async throws {
        let source = Self.plainPlaylistId(sourceId)
        guard !source.isEmpty else { throw MusicError.parse("playlist edit has no source playlist id") }
        let action: [String: Any] = ["action": "ACTION_ADD_PLAYLIST", "addedFullListId": source]
        try await editPlaylist(playlistId, action: action, what: "add playlist")
    }

    /// Removes one row of a playlist, named by its `setVideoId` (the same song twice is two rows).
    func removeVideo(_ videoId: String, setVideoId: String, fromPlaylist playlistId: String) async throws {
        guard !videoId.isEmpty, !setVideoId.isEmpty else { throw MusicError.parse("playlist edit has no video id") }
        let action: [String: Any] = ["action": "ACTION_REMOVE_VIDEO", "setVideoId": setVideoId, "removedVideoId": videoId]
        try await editPlaylist(playlistId, action: action, what: "remove")
    }

    /// One `browse/edit_playlist` call. The playlist id goes without the "VL" a browse id carries. Only whether it
    /// worked is logged, never an id.
    private func editPlaylist(_ playlistId: String, action: [String: Any], what: String) async throws {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let id = Self.plainPlaylistId(playlistId)
        guard !id.isEmpty else { throw MusicError.parse("playlist edit has no playlist id") }
        let session = try await sessionOrFallback()
        let data = try await post("browse/edit_playlist", session: session, body: ["playlistId": id, "actions": [action]])
        let succeeded = try InnerTubeParser.playlistEditSucceeded(in: data)
        Self.log.info("playlist \(what, privacy: .public) succeeded \(succeeded, privacy: .public)")
        guard succeeded else { throw MusicError.rejected }
    }

    // MARK: - Likes

    /// The like state of one song, from the like button in the overlay of a `next` call for it alone. Nil when the answer
    /// has no like button for the song. Only whether a state came back is logged, never an id.
    func likeStatus(videoId: String) async throws -> MusicLikeStatus? {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let id = videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let session = try await sessionOrFallback()
        let data = try await post("next", session: session, body: ["videoId": id, "isAudioOnly": true])
        let status = try InnerTubeParser.likeStatus(from: data, videoId: id)
        Self.log.info("like status known \(status != nil, privacy: .public)")
        return status
    }

    /// Likes, dislikes or takes back the rating of one song. YouTube answers a 2xx with an empty object, so success is
    /// the status alone. Only the kind of rating is logged, never an id.
    func rate(videoId: String, status: MusicLikeStatus) async throws {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let id = videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MusicError.parse("rating has no video id") }
        let endpoint: String
        switch status {
        case .like: endpoint = "like/like"
        case .dislike: endpoint = "like/dislike"
        case .indifferent: endpoint = "like/removelike"
        }
        let session = try await sessionOrFallback()
        _ = try await post(endpoint, session: session, body: ["target": ["videoId": id]])
        Self.log.info("rated a song with \(endpoint, privacy: .public)")
    }

    /// A playlist id as the edit calls take it: trimmed, without the "VL" a browse id carries.
    private static func plainPlaylistId(_ playlistId: String) -> String {
        var id = playlistId.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("VL") { id.removeFirst(2) }
        return id
    }

    private func browse(browseId: String) async throws -> Data {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        let session = try await sessionOrFallback()
        return try await post("browse", session: session, body: ["browseId": browseId])
    }

    /// Old-style tokens go in the query next to the original `browseId` (what ytmusicapi sends);
    /// new-style tokens go alone in the body. Nil for a blank token.
    private func browseContinuation(_ continuation: String, browseId: String) async throws -> Data? {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        guard let token = InnerTubeParser.decodeContinuation(continuation) else { return nil }
        let session = try await sessionOrFallback()
        switch token.style {
        case .body:
            return try await post("browse", session: session, body: ["continuation": token.value])
        case .query:
            // The token is already percent-encoded where it needs to be ("%3D"), so only what a URL
            // cannot hold at all is escaped and an existing escape is left alone.
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~%")
            let encoded = token.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? token.value
            return try await post(
                "browse",
                session: session,
                body: ["browseId": browseId],
                query: "&ctoken=\(encoded)&continuation=\(encoded)"
            )
        }
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

    /// One history ping (playback or watchtime): the tracking URL moved to music.youtube.com plus the
    /// web client's own parameters, sent with the cookies and SAPISIDHASH auth. Returns the status
    /// (200 or 204); any other status throws.
    func reportHistory(_ ping: HistoryPing) async throws -> Int {
        guard currentJar().hasSignInCookies else { throw MusicError.signedOut }
        guard Self.isTrusted(ping.url) else { throw MusicError.parse("tracking url is not an https YouTube url") }
        let session = try await sessionOrFallback()
        let epoch = epoch
        let url = HistoryURLBuilder.url(for: ping, clientVersion: session.clientVersion)
        guard var headers = authenticatedHeaders(for: url, session: session) else { throw MusicError.signedOut }
        headers["Content-Type"] = nil
        let response = try await transport.send(HTTPRequest(url: url, method: "GET", headers: headers))
        absorbCookies(from: response, url: url, epoch: epoch)
        guard response.statusCode == 200 || response.statusCode == 204 else { throw Self.error(for: response.statusCode) }
        return response.statusCode
    }

    // MARK: - Requests

    private func post(_ endpoint: String, session: InnerTubeSession, body: [String: Any], query: String = "") async throws -> Data {
        let epoch = epoch
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false\(query)") else {
            throw MusicError.parse("request url is not valid")
        }
        guard let headers = authenticatedHeaders(for: url, session: session) else { throw MusicError.signedOut }
        // The cookies pick the channel for the page, but browse, library, account and write calls only act
        // as a brand channel when they name it, as ytmusicapi does. Not on player: it answers 401 to that,
        // and streams and History work from the cookies alone.
        let onBehalfOf = endpoint == "player" ? nil : session.brandPageId
        var response = try await send(url, headers: headers, body: body, session: session, onBehalfOf: onBehalfOf)
        absorbCookies(from: response, url: url, epoch: epoch)
        // A 401 would sign the whole session out. One that answers the channel id gets one try without it.
        if response.statusCode == 401, onBehalfOf != nil {
            response = try await send(url, headers: headers, body: body, session: session, onBehalfOf: nil)
            absorbCookies(from: response, url: url, epoch: epoch)
        }
        guard (200..<300).contains(response.statusCode) else { throw Self.error(for: response.statusCode) }
        return response.data
    }

    private func send(
        _ url: URL, headers: [String: String], body: [String: Any], session: InnerTubeSession, onBehalfOf: String?
    ) async throws -> HTTPResponse {
        var context: [String: Any] = ["client": clientContext(session)]
        if let onBehalfOf { context["user"] = ["onBehalfOfUser": onBehalfOf] }
        var payload = body
        payload["context"] = context
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await transport.send(HTTPRequest(url: url, method: "POST", headers: headers, body: data))
    }

    /// The `context.client` of every call, the fields music.youtube.com's own client sends. The zone and its offset
    /// (minutes east of UTC, as at this moment so daylight saving counts) are what put a song played this evening
    /// under "Today" in History instead of "Yesterday".
    private func clientContext(_ session: InnerTubeSession) -> [String: Any] {
        let zone = timeZone()
        var client: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": session.clientVersion,
            "hl": "en",
            "gl": "US",
            "timeZone": zone.identifier,
            "utcOffsetMinutes": zone.secondsFromGMT(for: now()) / 60,
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
        var loaded = persister.load().flatMap { try? JSONDecoder().decode(MusicCookieJar.self, from: $0) } ?? MusicCookieJar()
        loaded.prune(now: now())
        jar = loaded
        return loaded
    }

    /// Merges a response's Set-Cookie headers into the in-memory jar (always) and hands the new jar to the
    /// persister, which writes the Keychain at once only when a sign-in cookie changed.
    private func absorbCookies(from response: HTTPResponse, url: URL, epoch: Int) {
        guard epoch == self.epoch else { return }
        var updated = currentJar()
        let signInBefore = updated.signInSnapshot
        guard updated.merge(headerFields: response.headers, for: url, now: now()) else { return }
        jar = updated
        guard updated.hasSignInCookies else { return }
        do {
            persister.stage(try JSONEncoder().encode(updated), signInChanged: updated.signInSnapshot != signInBefore)
        } catch {
            // The in-memory jar still works for this launch; only the persisted copy is stale.
            Self.log.error("could not encode rotated cookies")
        }
    }

    private static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return trustedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
