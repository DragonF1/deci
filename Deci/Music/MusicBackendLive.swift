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

    func search(_ query: String) async throws -> [MusicTrack] {
        try await client.search(query)
    }

    func resolve(videoId: String) async throws -> ResolvedStream {
        try await resolver.resolve(videoId: videoId)
    }

    func radio(seedVideoId: String) async throws -> MusicQueuePage {
        try await client.radio(seedVideoId: seedVideoId)
    }

    /// The continuation token already carries the seed, so only the token goes out.
    func moreRadio(seedVideoId: String, continuation: String) async throws -> MusicQueuePage {
        try await client.moreRadio(continuation: continuation)
    }

    func reportHistory(_ ping: HistoryPing) async throws -> Int {
        try await client.reportHistory(ping)
    }
}
