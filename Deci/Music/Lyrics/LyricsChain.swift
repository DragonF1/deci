// Deci/Music/Lyrics/LyricsChain.swift
import Foundation
import os

/// The lyrics provider the store uses: the disk cache, then YouTube Music, then LRCLIB, and the best answer of the
/// two. It owns the cache, so a source never has to know whether its answer is kept.
///
/// The order, which is also the ranking: a cache hit; synced lyrics from YouTube Music (the exact video, so LRCLIB is
/// never asked); synced lyrics from LRCLIB; plain lyrics from YouTube Music; plain lyrics from LRCLIB; an instrumental
/// when LRCLIB says so; not found. Synced from any source beats plain from any source, and where both have only plain
/// lyrics, YouTube Music's are for this exact video.
///
/// Failures: one source failing never hides what the other found. A YouTube Music failure falls through to LRCLIB;
/// an LRCLIB failure (busy, backing off, any error) keeps YouTube Music's plain lyrics if it had them, and otherwise
/// is rethrown as it is so the panel reports it, whatever YouTube Music did. A cancellation is thrown at once.
///
/// What is stored, with its credit: anything that came from YouTube Music, whatever length the player knows (it
/// matches the video, not the length); an LRCLIB answer or a "not found" only when the length is known, because
/// without it LRCLIB's match is a guess. Nothing is stored when either source failed: a blip must not turn into a
/// "not found" for 3 days, and a plain answer waiting on a failed LRCLIB should be upgraded to synced by the next try.
actor LyricsChain: LyricsProviding {
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicLyrics")

    private let primary: any LyricsProviding
    private let fallback: any LyricsProviding
    private let cache: LyricsDiskCache

    init(primary: any LyricsProviding, fallback: any LyricsProviding, cache: LyricsDiskCache) {
        self.primary = primary
        self.fallback = fallback
        self.cache = cache
    }

    /// YouTube Music first, LRCLIB second, the shared disk cache in front.
    static func live() -> LyricsChain {
        LyricsChain(primary: YTMusicLyricsClient.live(), fallback: LRCLibClient.live(), cache: .live())
    }

    func lyrics(for query: LyricsQuery) async throws -> LyricsResult {
        try await answer(for: query).result
    }

    func answer(for query: LyricsQuery) async throws -> LyricsAnswer {
        // A cached answer needs no network, so it is served even while a source is paused.
        if let hit = await cache.cached(videoId: query.videoId) {
            Self.log.info("lyrics answered from the cache")
            return hit
        }
        try Task.checkCancellation()

        let youtube = try await attempt(primary, query)
        if case .success(let theirs) = youtube, case .synced = theirs.result {
            Self.log.info("lyrics answered by youtube music")
            return try await finish(Self.settled(theirs), for: query, store: true)
        }
        var youtubePlain: LyricsAnswer?
        var youtubeFailed = false
        switch youtube {
        case .success(let theirs):
            if case .plain = theirs.result { youtubePlain = Self.settled(theirs) }
        case .failure:
            youtubeFailed = true
        }

        switch try await attempt(fallback, query) {
        case .failure(let error):
            // LRCLIB's trouble does not hide plain lyrics already in hand. It is not stored: the next song, or this
            // one asked again, may find LRCLIB well and get synced lyrics.
            guard let youtubePlain else { throw error }
            Self.log.info("lyrics answered by youtube music, lrclib failed")
            return try await finish(youtubePlain, for: query, store: false)
        case .success(let theirs):
            if let youtubePlain, !Self.isSynced(theirs.result) {
                Self.log.info("lyrics answered by youtube music")
                return try await finish(youtubePlain, for: query, store: true)
            }
            // A guess at LRCLIB (no exact length) or a gap at YouTube Music (it failed) is not kept.
            let sound = !youtubeFailed && query.knownDuration != nil
            Self.log.info("lyrics answered by lrclib")
            return try await finish(theirs, for: query, store: sound)
        }
    }

    // MARK: - Pieces

    /// One source's answer, or the error it failed with. A cancellation is not an answer: it is thrown, and a source
    /// that fails after the task was cancelled counts as cancelled too.
    private func attempt(_ source: any LyricsProviding, _ query: LyricsQuery) async throws -> Result<LyricsAnswer, any Error> {
        do {
            let answer = try await source.answer(for: query)
            try Task.checkCancellation()
            return .success(answer)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            Self.log.info("a lyrics source failed")
            return .failure(error)
        }
    }

    /// The answer, written to the cache first when `store` says so. A cancelled lookup writes nothing.
    private func finish(_ answer: LyricsAnswer, for query: LyricsQuery, store: Bool) async throws -> LyricsAnswer {
        try Task.checkCancellation()
        if store { await cache.store(answer.result, credit: answer.credit, videoId: query.videoId) }
        return answer
    }

    /// An answer from YouTube Music, which matches the video and not the length: a length that arrives later changes
    /// nothing, so the store has no reason to ask again.
    private static func settled(_ answer: LyricsAnswer) -> LyricsAnswer {
        LyricsAnswer(result: answer.result, credit: answer.credit, lengthMatters: false)
    }

    private static func isSynced(_ result: LyricsResult) -> Bool {
        if case .synced = result { return true }
        return false
    }
}
