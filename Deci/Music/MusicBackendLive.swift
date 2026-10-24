import Foundation

/// The real YouTube Music backend: InnerTube over HTTPS with the user's own cookies, and a
/// JavaScriptCore solver for stream URLs. Everything else in the music feature talks to this
/// through `MusicBackend`.
actor MusicBackendLive: MusicBackend {
    private let client: InnerTubeClient
    private let resolver: StreamResolver

    init(client: InnerTubeClient, resolver: StreamResolver) {
        self.client = client
        self.resolver = resolver
    }

    /// Wires the production pieces. Builds nothing heavy: the Keychain is read on the first
    /// call that needs the cookies, the network is untouched, and the solver thread starts on
    /// the first stream that needs solving.
    static func live() -> MusicBackendLive {
        let client = InnerTubeClient(transport: URLSessionTransport(), secretStore: KeychainSecretStore())
        let cache = PlayerCache.live()
        let resolver = StreamResolver(client: client, solver: JSChallengeSolver(cache: cache), cache: cache)
        return MusicBackendLive(client: client, resolver: resolver)
    }

    func isSignedIn() async -> Bool {
        await client.isSignedIn()
    }

    func signIn(with cookies: [StoredCookie]) async throws {
        try await client.signIn(with: cookies)
    }

    func signOut() async {
        await client.signOut()
    }

    nonisolated func flushCookies() {
        client.flushNow()
    }

    func channelIdentity() async -> Bool? {
        await client.channelIdentity()
    }

    func sessionCookies() async -> [StoredCookie] {
        await client.sessionCookies()
    }

    func accountInfo() async throws -> MusicAccount? {
        try await client.accountInfo()
    }

    func search(_ query: String) async throws -> [MusicTrack] {
        try await client.search(query)
    }

    func searchArtists(_ query: String) async throws -> [MusicCollection] {
        try await client.searchArtists(query)
    }

    func searchAlbums(_ query: String) async throws -> [MusicCollection] {
        try await client.searchAlbums(query)
    }

    func searchTopResult(_ query: String) async throws -> MusicTrack? {
        try await client.searchTopResult(query)
    }

    func resolve(videoId: String) async throws -> ResolvedStream {
        try await resolver.resolve(videoId: videoId)
    }

    func radio(seedVideoId: String) async throws -> MusicQueuePage {
        try await client.radio(seedVideoId: seedVideoId)
    }

    func autoplay(afterVideoId: String, playlistId: String) async throws -> MusicQueuePage {
        try await client.autoplay(afterVideoId: afterVideoId, playlistId: playlistId)
    }

    func mix(playlistId: String, afterVideoId: String) async throws -> MusicQueuePage {
        try await client.mix(playlistId: playlistId, afterVideoId: afterVideoId)
    }

    /// The continuation token already carries the seed, so only the token goes out.
    func moreRadio(seedVideoId: String, continuation: String) async throws -> MusicQueuePage {
        try await client.moreRadio(continuation: continuation)
    }

    func home() async throws -> MusicHomePage {
        try await client.home()
    }

    func moreHome(continuation: String) async throws -> MusicHomePage {
        try await client.moreHome(continuation: continuation)
    }

    func history() async throws -> MusicHomePage {
        try await client.history()
    }

    func moreHistory(continuation: String) async throws -> MusicHomePage {
        try await client.moreHistory(continuation: continuation)
    }

    func library(_ section: MusicLibrarySection) async throws -> MusicCollectionList {
        try await client.library(section)
    }

    func moreLibrary(_ section: MusicLibrarySection, continuation: String) async throws -> MusicCollectionList {
        try await client.moreLibrary(section, continuation: continuation)
    }

    func page(browseId: String) async throws -> MusicBrowsePage {
        try await client.page(browseId: browseId)
    }

    func moreTracks(browseId: String, continuation: String) async throws -> MusicQueuePage {
        try await client.moreTracks(browseId: browseId, continuation: continuation)
    }

    func discography(browseId: String, params: String?) async throws -> [MusicCollection] {
        try await client.discography(browseId: browseId, params: params)
    }

    func addToPlaylistOptions(videoId: String) async throws -> [MusicPlaylistOption] {
        try await client.addToPlaylistOptions(videoId: videoId)
    }

    func addToPlaylistOptions(sourcePlaylistId: String) async throws -> [MusicPlaylistOption] {
        try await client.addToPlaylistOptions(sourcePlaylistId: sourcePlaylistId)
    }

    func addToPlaylist(videoId: String, playlistId: String) async throws {
        try await client.addVideo(videoId, toPlaylist: playlistId)
    }

    func addPlaylistToPlaylist(sourceId: String, playlistId: String) async throws {
        try await client.addPlaylist(sourceId, toPlaylist: playlistId)
    }

    func removeFromPlaylist(videoId: String, setVideoId: String, playlistId: String) async throws {
        try await client.removeVideo(videoId, setVideoId: setVideoId, fromPlaylist: playlistId)
    }

    func reportHistory(_ ping: HistoryPing) async throws -> Int {
        try await client.reportHistory(ping)
    }

    func likeStatus(videoId: String) async throws -> MusicLikeStatus? {
        try await client.likeStatus(videoId: videoId)
    }

    func rate(videoId: String, status: MusicLikeStatus) async throws {
        try await client.rate(videoId: videoId, status: status)
    }

    func related(videoId: String) async throws -> [MusicTrack] {
        try await client.related(videoId: videoId)
    }
}
