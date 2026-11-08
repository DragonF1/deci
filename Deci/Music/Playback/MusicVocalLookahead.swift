// Deci/Music/Playback/MusicVocalLookahead.swift
// Tier 3d-4: the sung intervals of the playing song and the next one, read from synced lyrics ahead of the mix so the
// vocal guard can use them. Privacy: the disk cache is read first (no network). On a miss, and only when the caller
// allows the network, it asks YouTube Music for the exact video id, the same host family as playback, and gives up
// after `timeoutSec`. LRCLIB is never asked from here: its lyrics count only when the lyrics panel already cached them.
// A missing answer is not an error: the planner falls back to the structural proxy. Nothing here ever waits for a plan.

import Foundation

@MainActor
final class MusicVocalLookahead {
    typealias CacheRead = @Sendable (String) async -> LyricsAnswer?
    typealias YouTubeFetch = @Sendable (LyricsQuery) async throws -> LyricsAnswer
    typealias CacheStore = @Sendable (LyricsResult, String?, String) async -> Void

    /// How long the YouTube Music request may take before the proxy is used.
    static let defaultTimeoutSec = 3.0

    private let readCache: CacheRead
    private let youtube: YouTubeFetch
    private let store: CacheStore
    private let timeoutSec: Double
    private var resolved: [String: [ClosedRange<Double>]] = [:]
    private var requested: Set<String> = []

    init(
        readCache: @escaping CacheRead, youtube: @escaping YouTubeFetch,
        store: @escaping CacheStore = { _, _, _ in }, timeoutSec: Double = MusicVocalLookahead.defaultTimeoutSec
    ) {
        self.readCache = readCache
        self.youtube = youtube
        self.store = store
        self.timeoutSec = timeoutSec
    }

    /// The live wiring: the app's lyrics disk cache and the YouTube Music client.
    /// The cache and client are the ones the lyrics chain uses (one 429 pause, one cache actor).
    static func live(cache: LyricsDiskCache, client: YTMusicLyricsClient) -> MusicVocalLookahead {
        MusicVocalLookahead(
            readCache: { await cache.cached(videoId: $0) },
            youtube: { try await client.answer(for: $0) },
            store: { result, credit, id in await cache.store(result, credit: credit, videoId: id) }
        )
    }

    /// Intervals already known for a song; nil when unknown (use the proxy).
    func intervals(for videoId: String) -> [ClosedRange<Double>]? { resolved[videoId] }

    /// True when a lookup for the song was already started or finished.
    func hasRequested(_ videoId: String) -> Bool { requested.contains(videoId) }

    /// Looks the song up once. Never throws; leaves `intervals(for:)` nil on any failure.
    func prepare(_ query: LyricsQuery, duration: Double, allowNetwork: Bool) async {
        guard !requested.contains(query.videoId), duration.isFinite, duration > 0 else { return }
        requested.insert(query.videoId)
        if let hit = await readCache(query.videoId) {
            record(hit.result, for: query.videoId, duration: duration)
            return
        }
        guard allowNetwork else {
            requested.remove(query.videoId)
            return
        }
        let timeout = timeoutSec, youtube = youtube
        let answer: LyricsAnswer? = await withTaskGroup(of: LyricsAnswer?.self) { group in
            group.addTask { try? await youtube(query) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let answer else { return }
        switch answer.result {
        case .synced, .instrumental:
            await store(answer.result, answer.credit, query.videoId)
        case .plain, .notFound:
            break
        }
        record(answer.result, for: query.videoId, duration: duration)
    }

    private func record(_ result: LyricsResult, for videoId: String, duration: Double) {
        switch result {
        case .synced(let lines): resolved[videoId] = MusicVocalIntervals.from(lines: lines, duration: duration)
        case .instrumental: resolved[videoId] = []
        case .plain, .notFound: break
        }
    }
}
