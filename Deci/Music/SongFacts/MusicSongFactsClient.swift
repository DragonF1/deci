// Deci/Music/SongFacts/MusicSongFactsClient.swift
import Foundation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicSongFacts")

/// What the Song data panel needs from the online side. A protocol so the repository's tests use a stub.
protocol MusicSongFactsLooking: Sendable {
    func lookup(_ query: MusicSongFactsQuery) async -> MusicSongFactsLookup
}

/// Asks free, key-less music data services about one song, in this order, and keeps for each field the first answer:
/// 1. Deezer search (plain `q`), matched by title, artist and length, then the track (ISRC, tempo, release date, explicit)
///    and its album (genres, label).
/// 2. ReccoBeats audio features by ISRC (tempo, key, mode and the feel numbers).
/// 3. MusicBrainz by ISRC, kept by length, then the recording (genres, first release date).
/// 4. TheAudioDB by artist and title, only when ReccoBeats had nothing.
///
/// Nothing leaves but the artist, the title, an ISRC and ids that came from these services: no account data, no
/// cookies, no video id. Every request is https with a short timeout (the transport's), and no reply over 2 MB is read.
/// A step that fails is skipped; the lookup stops at once when the network is down.
actor MusicSongFactsClient: MusicSongFactsLooking {
    static let maximumResponseBytes = 2 * 1024 * 1024
    static let musicBrainzUserAgent = "Deci/1.0 ( https://github.com/DragonF1/deci )"
    /// How far a MusicBrainz recording's length may be from the song's, in milliseconds.
    static let musicBrainzLengthTolerance = 2000
    /// MusicBrainz asks for one request a second; TheAudioDB's free key allows 30 a minute.
    static let musicBrainzInterval: TimeInterval = 1
    static let audioDBInterval: TimeInterval = 2
    /// The longest Retry-After that is waited out (once) before a ReccoBeats request is tried again.
    static let maximumRetryWait: TimeInterval = 10
    /// A host that answered 429 or 503 is left alone this long.
    static let hostCooldown: TimeInterval = 60
    /// The only hosts a request may reach, redirects included.
    static let allowedHosts: Set<String> = ["api.deezer.com", "api.reccobeats.com", "musicbrainz.org", "www.theaudiodb.com"]
    static let maximumGenres = 8
    static let maximumTextLength = 200

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private enum Host: Hashable { case musicBrainz, audioDB }

    /// The lookup in progress.
    private struct Run {
        var facts: MusicSongFacts
        var isrc: String?
        /// The matched Deezer length, else the song's own, in seconds.
        var duration: Double?
        var hasFeatures = false
        /// A step could not be asked or answered (a limit, a failure).
        var trouble = false
        var stopped = false
    }

    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var nextSlot: [Host: Date] = [:]
    /// Per URL host, until when it is skipped (in memory only).
    private var cooldownUntil: [String: Date] = [:]

    init(
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    /// Ephemeral, no cookie jar, URL cache or credential storage, and a 10 s fuse.
    static func live() -> MusicSongFactsClient {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        return MusicSongFactsClient(transport: URLSessionTransport(configuration: config))
    }

    // MARK: - Chain

    func lookup(_ query: MusicSongFactsQuery) async -> MusicSongFactsLookup {
        var run = Run(facts: MusicSongFacts(fetchedAt: now()), duration: query.durationSeconds)
        await deezer(query, &run)
        await recco(&run)
        await musicBrainz(&run)
        if !run.hasFeatures { await audioDB(query, &run) }
        if Task.isCancelled { return .failed }
        if run.facts.isEmpty { return run.trouble ? .failed : .notFound }
        return run.trouble ? .partial(run.facts) : .found(run.facts)
    }

    // MARK: - Deezer

    private func deezer(_ query: MusicSongFactsQuery, _ run: inout Run) async {
        guard !run.stopped, !query.artist.isEmpty || !query.title.isEmpty else { return }
        do {
            let term = Self.escape("\(query.artist) \(query.title)")
            let hits = try MusicSongFactsParsers.deezerSearch(
                try await get("https://api.deezer.com/search?q=\(term)&limit=10"))
            guard let match = MusicSongFactsMatcher.bestMatch(query: query, in: hits) else { return }
            run.duration = Double(match.duration)
            run.facts.deezerId = match.id
            run.facts.claim(.deezerId, .deezer)
            // The search hit already says these; the track call below may say them better.
            fill(&run, \.isrc, Self.isrc(match.isrc), .isrc, .deezer)
            fill(&run, \.explicit, match.explicit, .explicit, .deezer)
            run.isrc = run.facts.isrc

            guard let track = try MusicSongFactsParsers.deezerTrack(try await get("https://api.deezer.com/track/\(match.id)"))
            else { return }
            if run.facts.isrc == nil { fill(&run, \.isrc, Self.isrc(track.isrc), .isrc, .deezer) }
            run.isrc = run.facts.isrc
            fill(&run, \.bpm, track.bpm, .bpm, .deezer)
            fill(&run, \.releaseDate, Self.validReleaseDate(track.releaseDate), .releaseDate, .deezer)
            if let explicit = track.explicit {
                run.facts.explicit = explicit
                run.facts.claim(.explicit, .deezer)
            }
            if let albumId = track.albumId,
               let album = try MusicSongFactsParsers.deezerAlbum(try await get("https://api.deezer.com/album/\(albumId)")) {
                fill(&run, \.label, album.label, .label, .deezer)
                fillGenres(&run, album.genres, .deezer)
            }
        } catch {
            note(error, &run)
        }
    }

    // MARK: - ReccoBeats

    private func recco(_ run: inout Run) async {
        guard !run.stopped, let isrc = run.isrc else { return }
        do {
            let data = try await getRetryingOnce("https://api.reccobeats.com/v1/audio-features?ids=\(isrc)")
            // An id that is not the ISRC asked for is some other song's numbers.
            guard let features = try MusicSongFactsParsers.reccoFeatures(data),
                  features.isrc?.uppercased() == isrc else { return }
            run.hasFeatures = true
            fill(&run, \.bpm, features.tempo, .bpm, .reccobeats)
            if let key = features.key, run.facts.source(of: .key) == nil {
                run.facts.key = key
                run.facts.mode = features.mode
                run.facts.claim(.key, .reccobeats)
            }
            fill(&run, \.energy, features.energy, .energy, .reccobeats)
            fill(&run, \.danceability, features.danceability, .danceability, .reccobeats)
            fill(&run, \.valence, features.valence, .valence, .reccobeats)
            fill(&run, \.acousticness, features.acousticness, .acousticness, .reccobeats)
            fill(&run, \.instrumentalness, features.instrumentalness, .instrumentalness, .reccobeats)
            fill(&run, \.speechiness, features.speechiness, .speechiness, .reccobeats)
            fill(&run, \.liveness, features.liveness, .liveness, .reccobeats)
        } catch {
            note(error, &run)
        }
    }

    // MARK: - MusicBrainz

    private func musicBrainz(_ run: inout Run) async {
        guard !run.stopped, let isrc = run.isrc, let seconds = run.duration else { return }
        do {
            await throttle(.musicBrainz, interval: Self.musicBrainzInterval)
            let recordings = try MusicSongFactsParsers.musicBrainzRecordings(
                try await get(
                    "https://musicbrainz.org/ws/2/isrc/\(isrc)?inc=artist-credits+tags&fmt=json",
                    headers: ["User-Agent": Self.musicBrainzUserAgent]))
            let target = Int((seconds * 1000).rounded())
            let near = recordings
                .compactMap { recording in recording.length.map { (recording, abs($0 - target)) } }
                .filter { $0.1 <= Self.musicBrainzLengthTolerance }
                .min { $0.1 < $1.1 }
            guard let recording = near?.0, Self.isMBID(recording.id) else { return }
            run.facts.mbid = recording.id
            run.facts.claim(.mbid, .musicbrainz)
            fill(&run, \.releaseDate, Self.validReleaseDate(recording.firstReleaseDate), .releaseDate, .musicbrainz)

            await throttle(.musicBrainz, interval: Self.musicBrainzInterval)
            let detail = try MusicSongFactsParsers.musicBrainzDetail(
                try await get(
                    "https://musicbrainz.org/ws/2/recording/\(recording.id)?inc=genres+releases&fmt=json",
                    headers: ["User-Agent": Self.musicBrainzUserAgent]))
            fillGenres(&run, detail.genres, .musicbrainz)
            fill(&run, \.releaseDate, Self.validReleaseDate(detail.firstReleaseDate), .releaseDate, .musicbrainz)
        } catch {
            // A 400 is a request the service will not take; asking again would not help, and nothing is lost.
            if case MusicSongFactsError.http(400) = error {
                logger.notice("songfacts_musicbrainz bad_request")
            } else {
                note(error, &run)
            }
        }
    }

    // MARK: - TheAudioDB

    private func audioDB(_ query: MusicSongFactsQuery, _ run: inout Run) async {
        guard !run.stopped, !query.artist.isEmpty, !query.title.isEmpty else { return }
        do {
            await throttle(.audioDB, interval: Self.audioDBInterval)
            let tracks = try MusicSongFactsParsers.audioDBTracks(
                try await get(
                    "https://www.theaudiodb.com/api/v1/json/123/searchtrack.php?s=\(Self.escape(query.artist))&t=\(Self.escape(query.title))"))
            // When the record names an ISRC it has to be the one Deezer gave.
            let asked = run.isrc
            guard let track = tracks.first(where: { track in
                guard MusicSongFactsMatcher.titlesMatch(query.title, track.title ?? ""),
                      MusicSongFactsMatcher.artistsMatch(query.artist, track.artist ?? "") else { return false }
                guard let theirs = Self.isrc(track.isrc), let asked else { return true }
                return theirs == asked
            }) else { return }
            fill(&run, \.bpm, track.tempo, .bpm, .theaudiodb)
            fill(&run, \.energy, track.energy, .energy, .theaudiodb)
            fill(&run, \.danceability, track.danceability, .danceability, .theaudiodb)
            fillGenres(&run, track.genre.map { [$0] } ?? [], .theaudiodb)
        } catch {
            note(error, &run)
        }
    }

    // MARK: - Filling

    /// Sets the field when nothing has set it yet.
    private func fill<T>(
        _ run: inout Run, _ path: WritableKeyPath<MusicSongFacts, T?>, _ value: T?, _ field: MusicSongFacts.Field,
        _ source: MusicSongFacts.Source
    ) {
        guard let value, run.facts[keyPath: path] == nil else { return }
        run.facts[keyPath: path] = value
        run.facts.claim(field, source)
    }

    private func fillGenres(_ run: inout Run, _ names: [String], _ source: MusicSongFacts.Source) {
        let kept = names.prefix(Self.maximumGenres).map { String($0.prefix(Self.maximumTextLength)) }
        guard run.facts.genres.isEmpty, !kept.isEmpty else { return }
        run.facts.genres = kept
        run.facts.claim(.genres, source)
    }

    /// An ISRC is twelve letters and digits. Anything else (it came from an untrusted reply) is not put in a URL.
    private static func isrc(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let clean = raw.replacingOccurrences(of: "-", with: "").uppercased()
        return clean.range(of: "^[A-Z0-9]{12}$", options: .regularExpression) != nil ? clean : nil
    }

    /// A release date only when it reads YYYY, YYYY-MM or YYYY-MM-DD.
    static func validReleaseDate(_ raw: String?) -> String? {
        guard let raw, raw.range(of: "^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$", options: .regularExpression) != nil else { return nil }
        return raw
    }

    private static func isMBID(_ raw: String) -> Bool {
        raw.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    // MARK: - Requests

    /// A failed step: what to skip and whether the lookup goes on.
    private func note(_ error: any Error, _ run: inout Run) {
        run.trouble = true
        if error is CancellationError { run.stopped = true; return }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled, .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                run.stopped = true
            default:
                break
            }
        }
        logger.notice("songfacts_step_failed kind=\(String(describing: type(of: error)), privacy: .public)")
    }

    /// One slot per interval per host: the next request waits for its turn. The slot is taken before the wait, so
    /// requests that arrive together line up.
    private func throttle(_ host: Host, interval: TimeInterval) async {
        let current = now()
        let start = max(current, nextSlot[host] ?? current)
        nextSlot[host] = start.addingTimeInterval(interval)
        let wait = start.timeIntervalSince(current)
        if wait > 0 { try? await sleep(.milliseconds(Int((wait * 1000).rounded(.up)))) }
    }

    /// ReccoBeats' 429 says how long to wait; a short wait is honoured once and the request repeated.
    private func getRetryingOnce(_ urlString: String) async throws -> Data {
        do {
            return try await get(urlString)
        } catch MusicSongFactsError.rateLimited(let after) {
            guard let after, after <= Self.maximumRetryWait else { throw MusicSongFactsError.rateLimited(retryAfter: after) }
            try await sleep(.milliseconds(Int((max(after, 0) * 1000).rounded(.up))))
            // The wait the service asked for has been served, so its cooldown is over.
            if let host = URL(string: urlString)?.host?.lowercased() { cooldownUntil[host] = nil }
            return try await get(urlString)
        }
    }

    private func get(_ urlString: String, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: urlString), url.scheme == "https" else { throw MusicSongFactsError.malformed }
        let host = url.host?.lowercased() ?? ""
        guard Self.allowedHosts.contains(host) else { throw MusicSongFactsError.malformed }
        // A host that just said to slow down is skipped: the chain moves on.
        if let until = cooldownUntil[host] {
            if until > now() { throw MusicSongFactsError.rateLimited(retryAfter: nil) }
            cooldownUntil[host] = nil
        }
        var sent = headers
        sent["Accept"] = "application/json"
        let response = try await transport.send(HTTPRequest(
            url: url, headers: sent, maximumResponseBytes: Self.maximumResponseBytes, allowedRedirectHosts: Self.allowedHosts))
        guard response.data.count <= Self.maximumResponseBytes else { throw MusicSongFactsError.tooLarge }
        if response.statusCode == 429 || response.statusCode == 503 {
            cooldownUntil[host] = now().addingTimeInterval(Self.hostCooldown)
        }
        switch response.statusCode {
        case 200..<300:
            return response.data
        case 429:
            throw MusicSongFactsError.rateLimited(retryAfter: response.header("Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) })
        default:
            throw MusicSongFactsError.http(response.statusCode)
        }
    }
}
