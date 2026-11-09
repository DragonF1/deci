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
    /// How long a candidate's player call, and each probe request, may take before it counts as a timeout.
    private let candidateTimeout: Duration
    private let probeTimeout: Duration

    init(
        client: InnerTubeClient,
        solver: ChallengeSolving,
        cache: PlayerCache,
        now: @escaping @Sendable () -> Date = { Date() },
        candidateTimeout: Duration = .seconds(5),
        probeTimeout: Duration = .seconds(3)
    ) {
        self.client = client
        self.solver = solver
        self.cache = cache
        self.now = now
        self.candidateTimeout = candidateTimeout
        self.probeTimeout = probeTimeout
    }

    /// A player build to solve against: its hash, the signatureTimestamp to ask for, and the raw
    /// JS when this resolve had to download it.
    private struct PlayerSource {
        let hash: String
        let sts: Int
        let jsURL: URL?
        let downloadedJS: String?
    }

    /// How long a client whose call or probe failed is left out of the chain.
    static let skipDuration: TimeInterval = 30 * 60

    /// The client that last passed its probe, tried first next time.
    private var preferred: StreamClient?
    private var skippedUntil: [StreamClient: Date] = [:]

    /// A client's formats built into a URL, with everything the stream needs from that client.
    private struct Built {
        let client: StreamClient
        let format: PlayerFormat
        let url: URL
        let expiresAt: Date?
        let expiresInSeconds: Int?
    }

    /// Why a candidate was passed over. Only the whole-client signals start the skip window; a per-video status, a
    /// transport error or a timeout says nothing about the next song.
    private enum Failure: Error {
        /// The player call answered an HTTP error status.
        case playerHTTP(Int)
        /// The player call answered a playability status other than OK; `wholeClient` for a LOGIN_REQUIRED that is not an
        /// age gate or a private video.
        case playerStatus(String, wholeClient: Bool)
        case noFormat, solver
        case probe(Int?)
        /// A transport error, a timeout ("timeout") or an unreadable answer.
        case transient(String)

        var why: String {
            switch self {
            case .playerHTTP(let status): "player http \(status)"
            case .playerStatus(let status, _): "player status \(status)"
            case .noFormat: "no format"
            case .solver: "solver"
            case .probe(let status): status.map { "probe http \($0)" } ?? "probe error"
            case .transient(let reason): reason
            }
        }

        var startsSkip: Bool {
            switch self {
            case .playerHTTP: true
            case .playerStatus(_, let wholeClient): wholeClient
            case .probe(let status): status == 401 || status == 403
            case .noFormat, .solver, .transient: false
            }
        }
    }

    /// Whether `skippedUntil` currently leaves `client` out of the chain.
    func isSkipped(_ client: StreamClient) -> Bool {
        (skippedUntil[client] ?? .distantPast) > now()
    }

    func resolve(videoId: String) async throws -> ResolvedStream {
        guard await client.isSignedIn() else { throw MusicError.signedOut }
        let session = try await client.session()
        guard let jsURL = session.playerJSURL, let hash = session.playerHash else {
            throw MusicError.parse("the home page named no player")
        }
        let source = try await playerSource(hash: hash, jsURL: jsURL)

        // WEB_REMIX stays the source of the status, tracking URLs and loudness; the first candidate asks for formats
        // at the same time so the extra call costs little latency.
        let order = candidateOrder()
        let client = client
        let sts = source.sts
        async let webCall = client.player(videoId: videoId, signatureTimestamp: sts)
        async let firstCall: Result<PlayerResponse, Error>? = Self.streamPlayer(client, order.first, videoId, sts, candidateTimeout)
        let response = try await webCall
        guard response.status == "OK" else { throw Self.error(for: response) }

        var winner: Built?
        var lastBuilt: Built?
        var firstResult = await firstCall
        for kind in order {
            do {
                let result: Result<PlayerResponse, Error>
                if let early = firstResult {
                    result = early
                    firstResult = nil
                } else {
                    result = await Self.fetchResult(kind, client, videoId, sts, candidateTimeout)
                }
                let candidate = try Self.unwrap(result)
                let built = try await build(kind, response: candidate, source: source)
                lastBuilt = built
                try await probe(built)
                winner = built
                preferred = kind
                skippedUntil[kind] = nil
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                Self.logFailure(kind, error)
                if (error as? Failure)?.startsSkip == true {
                    skippedUntil[kind] = now().addingTimeInterval(Self.skipDuration)
                    if preferred == kind { preferred = nil }
                }
            }
        }

        if winner == nil {
            do {
                // Last resort: no probe, its answer would only be logged.
                let built = try await build(.webRemix, response: response, source: source)
                lastBuilt = built
                winner = built
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // Nothing built from WEB_REMIX: the last URL a client did build is still better than none.
                guard let lastBuilt else { throw error }
                winner = lastBuilt
            }
            if winner?.client == .webRemix { preferred = nil }
        }
        guard let winner else { throw MusicError.noAudioFormat }
        cache.prune(keeping: source.hash)

        let format = winner.format
        let expiresAt = winner.expiresAt
            ?? now().addingTimeInterval((winner.expiresInSeconds ?? response.expiresInSeconds).map(TimeInterval.init) ?? Self.defaultLifetime)
        let duration = format.approxDurationMs.map { $0 / 1000 } ?? response.lengthSeconds.map(Double.init)
        Self.log.info("resolved client \(winner.client.rawValue, privacy: .public) itag \(format.itag) host \(winner.url.host ?? "?", privacy: .public) expires \(expiresAt.timeIntervalSince1970, privacy: .public)")
        return ResolvedStream(
            videoId: videoId,
            url: winner.url,
            itag: format.itag,
            durationSeconds: duration,
            expiresAt: expiresAt,
            playbackTrackingURL: response.playbackTrackingURL,
            watchtimeTrackingURL: response.watchtimeTrackingURL,
            viewCount: response.viewCount,
            httpHeaders: ["User-Agent": winner.client.userAgent],
            audioCodec: format.codecs,
            loudnessDb: response.loudnessDb,
            perceptualLoudnessDb: response.perceptualLoudnessDb,
            bitrate: format.bitrate,
            audioSampleRate: format.audioSampleRate,
            audioChannels: format.audioChannels,
            contentLength: format.contentLength
        )
    }

    // MARK: - Client chain

    /// VISIONOS then TV, with the client that last passed first and any client in its skip window left out.
    private func candidateOrder() -> [StreamClient] {
        let at = now()
        var order = StreamClient.preferredOrder.filter { (skippedUntil[$0] ?? .distantPast) <= at }
        // Never skip the whole chain: with every client in its window, the one whose window ends soonest goes first.
        if order.isEmpty {
            order = StreamClient.preferredOrder.sorted { (skippedUntil[$0] ?? .distantPast) < (skippedUntil[$1] ?? .distantPast) }
        }
        if let preferred, let index = order.firstIndex(of: preferred) {
            order.remove(at: index)
            order.insert(preferred, at: 0)
        }
        return order
    }

    private static func streamPlayer(
        _ client: InnerTubeClient, _ kind: StreamClient?, _ videoId: String, _ sts: Int, _ timeout: Duration
    ) async -> Result<PlayerResponse, Error>? {
        guard let kind else { return nil }
        return await fetchResult(kind, client, videoId, sts, timeout)
    }

    private static func fetchResult(
        _ kind: StreamClient, _ client: InnerTubeClient, _ videoId: String, _ sts: Int, _ timeout: Duration
    ) async -> Result<PlayerResponse, Error> {
        do {
            return .success(try await withDeadline(timeout) {
                try await client.streamPlayer(client: kind, videoId: videoId, signatureTimestamp: sts)
            })
        } catch {
            return .failure(error)
        }
    }

    private static func unwrap(_ result: Result<PlayerResponse, Error>) throws -> PlayerResponse {
        let response: PlayerResponse
        do {
            response = try result.get()
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch MusicError.http(let status) {
            throw Failure.playerHTTP(status)
        } catch MusicError.signedOut {
            throw Failure.playerHTTP(401)
        } catch is MusicError {
            throw Failure.transient("parse")
        } catch {
            throw Failure.transient("transport")
        }
        guard response.status == "OK" else {
            let wholeClient = response.status == "LOGIN_REQUIRED" && !isTrackGate(response.reason ?? response.status)
            throw Failure.playerStatus(response.status, wholeClient: wholeClient)
        }
        return response
    }

    private enum Race<T: Sendable>: Sendable { case value(T), timedOut }

    /// Runs `operation` against a deadline. A timeout is `Failure.transient("timeout")`; a cancelled caller gets the
    /// cancellation, never a timeout.
    private static func withDeadline<T: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: Race<T>.self) { group in
            group.addTask { .value(try await operation()) }
            group.addTask {
                try await Task.sleep(for: limit)
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            switch first {
            case .value(let value): return value
            case .timedOut: throw Failure.transient("timeout")
            }
        }
    }

    /// Picks the format, solves what its plan needs and builds the URL.
    private func build(_ kind: StreamClient, response: PlayerResponse, source: PlayerSource) async throws -> Built {
        // VISIONOS plays from the direct url alone: a format with only a signatureCipher is no format.
        let formats = kind.needsDirectURL ? response.formats.filter { $0.url?.isEmpty == false } : response.formats
        guard let format = FormatPicker.pick(from: formats) else {
            throw kind == .webRemix ? MusicError.noAudioFormat : Failure.noFormat
        }
        do {
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
            return Built(
                client: kind, format: format, url: built.url, expiresAt: built.expiresAt, expiresInSeconds: response.expiresInSeconds
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if kind == .webRemix { throw error }
            throw Failure.solver
        }
    }

    /// Two ranged GETs: the first byte and the last byte of the file, since a URL can serve its first stretch and refuse
    /// the rest. Both must answer 206. A file of one byte or less, or of unknown size, gets the first byte only.
    private func probe(_ built: Built) async throws {
        let last = Self.contentLength(of: built).map { $0 - 1 }
        async let head = probeOnce(built, range: "bytes=0-0")
        async let tail: Result<Int, Failure>? = {
            guard let last, last > 0 else { return nil }
            return await probeOnce(built, range: "bytes=\(last)-\(last)")
        }()
        let results = [await head, await tail].compactMap { $0 }
        try Task.checkCancellation()
        let failures: [Failure] = results.compactMap { result in
            switch result {
            case .success(206): nil
            case .success(let status): .probe(status)
            case .failure(let failure): failure
            }
        }
        if let failure = failures.first(where: \.startsSkip) ?? failures.first { throw failure }
    }

    /// The file's size: the format's contentLength, else the `clen` on the address.
    private static func contentLength(of built: Built) -> Int? {
        if let length = built.format.contentLength { return length }
        return URLComponents(url: built.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "clen" }?.value.flatMap(Int.init)
    }

    private func probeOnce(_ built: Built, range: String) async -> Result<Int, Failure> {
        let client = client
        let (url, userAgent) = (built.url, built.client.userAgent)
        do {
            let status = try await Self.withDeadline(probeTimeout) {
                await client.probeStream(url: url, userAgent: userAgent, range: range)
            }
            return status.map { .success($0) } ?? .failure(.probe(nil))
        } catch {
            return .failure((error as? Failure) ?? .probe(nil))
        }
    }

    private static func logFailure(_ kind: StreamClient, _ error: Error) {
        let why = (error as? Failure)?.why ?? "player"
        log.notice("stream_client_failed client=\(kind.rawValue, privacy: .public) why=\(why, privacy: .public)")
    }

    /// LOGIN_REQUIRED means the session died, unless the reason names an age gate or a private
    /// video: signing in again would not lift those, so they stay a plain unplayable track.
    private static func error(for response: PlayerResponse) -> MusicError {
        let reason = response.reason ?? response.status
        return response.status == "LOGIN_REQUIRED" && !isTrackGate(reason) ? .signedOut : .unplayable(reason)
    }

    /// An age gate or a private video: signing in again would not lift it.
    private static func isTrackGate(_ reason: String) -> Bool {
        reason.range(of: #"\b(age|private)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
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
