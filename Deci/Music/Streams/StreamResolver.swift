import Foundation
import os

/// Turns a video id into a playable audio stream: player call, format pick, signature and `n`
/// solving, URL assembly.
actor StreamResolver {
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicStreams")
    private static let defaultLifetime: TimeInterval = 3600

    private let client: InnerTubeClient
    private let solver: ChallengeSolving
    private let cache: PlayerCache
    private let now: @Sendable () -> Date

    init(client: InnerTubeClient, solver: ChallengeSolving, cache: PlayerCache, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.solver = solver
        self.cache = cache
        self.now = now
    }

    /// A player build to solve against: its hash, the signatureTimestamp to ask for, and the raw
    /// JS when this resolve had to download it.
    private struct PlayerSource {
        let hash: String
        let sts: Int
        let jsURL: URL?
        let downloadedJS: String?
    }

    func resolve(videoId: String) async throws -> ResolvedStream {
        guard await client.isSignedIn() else { throw MusicError.signedOut }
        let session = try await client.session()
        guard let jsURL = session.playerJSURL, let hash = session.playerHash else {
            throw MusicError.parse("the home page named no player")
        }
        let source = try await playerSource(hash: hash, jsURL: jsURL)

        let response = try await client.player(videoId: videoId, signatureTimestamp: source.sts)
        guard response.status == "OK" else { throw Self.error(for: response) }
        guard let format = FormatPicker.pick(from: response.formats) else { throw MusicError.noAudioFormat }

        let plan = try StreamURLBuilder.plan(for: format)
        var solutions = ChallengeSolutions(sig: [:], n: [:])
        if plan.needsSolving {
            let client = client
            let (downloaded, sourceURL) = (source.downloadedJS, source.jsURL)
            solutions = try await solver.solve(plan.challengeRequest(playerHash: source.hash)) {
                if let downloaded { return downloaded }
                guard let sourceURL else { throw MusicError.solver("the player is not cached and has no source") }
                return try await client.playerJS(at: sourceURL)
            }
        }
        let built = try StreamURLBuilder.build(plan, solutions: solutions)
        cache.prune(keeping: source.hash)

        let expiresAt = built.expiresAt
            ?? now().addingTimeInterval(response.expiresInSeconds.map(TimeInterval.init) ?? Self.defaultLifetime)
        let duration = format.approxDurationMs.map { $0 / 1000 } ?? response.lengthSeconds.map(Double.init)
        Self.log.info("resolved itag \(format.itag) host \(built.url.host ?? "?", privacy: .public) expires \(expiresAt.timeIntervalSince1970, privacy: .public)")
        return ResolvedStream(
            videoId: videoId,
            url: built.url,
            itag: format.itag,
            durationSeconds: duration,
            expiresAt: expiresAt,
            playbackTrackingURL: response.playbackTrackingURL,
            watchtimeTrackingURL: response.watchtimeTrackingURL,
            httpHeaders: ["User-Agent": MusicAuthHeaders.userAgent]
        )
    }

    /// LOGIN_REQUIRED means the session died, unless the reason names an age gate or a private
    /// video: signing in again would not lift those, so they stay a plain unplayable track.
    private static func error(for response: PlayerResponse) -> MusicError {
        let reason = response.reason ?? response.status
        let isTrackGate = reason.range(of: #"\b(age|private)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        return response.status == "LOGIN_REQUIRED" && !isTrackGate ? .signedOut : .unplayable(reason)
    }

    /// The cached signatureTimestamp when this build was seen before; otherwise one download of the
    /// player JS. If that download fails, the last player that worked is used instead.
    private func playerSource(hash: String, jsURL: URL) async throws -> PlayerSource {
        if let sts = cache.sts(forHash: hash) {
            return PlayerSource(hash: hash, sts: sts, jsURL: jsURL, downloadedJS: nil)
        }
        do {
            let js = try await client.playerJS(at: jsURL)
            guard let sts = InnerTubeParser.signatureTimestamp(fromPlayerJS: js) else {
                throw MusicError.parse("the player JS has no signatureTimestamp")
            }
            cache.saveSTS(sts, forHash: hash, now: now())
            return PlayerSource(hash: hash, sts: sts, jsURL: jsURL, downloadedJS: js)
        } catch {
            try Task.checkCancellation()
            guard let good = cache.lastGood(excluding: hash) else { throw error }
            Self.log.error("player \(hash, privacy: .public) unavailable, falling back to \(good.hash, privacy: .public)")
            return PlayerSource(hash: good.hash, sts: good.sts, jsURL: nil, downloadedJS: nil)
        }
    }
}
