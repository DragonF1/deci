// Deci/Music/Lyrics/LyricsModels.swift
import Foundation

/// One timed line of synced lyrics. Empty text is an instrumental gap, shown as a note.
struct LyricLine: Sendable, Equatable, Hashable {
    let time: TimeInterval
    let text: String
}

/// What LRCLIB knows about a song.
enum LyricsResult: Sendable, Equatable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
}

/// What identifies a song to LRCLIB. `videoId` is only the cache key: it is never sent.
struct LyricsQuery: Sendable, Equatable {
    let videoId: String
    let title: String
    let artist: String
    let album: String?
    /// The exact length the player knows, in seconds; nil when it does not know.
    let duration: TimeInterval?
}

enum LyricsError: Error, Sendable, Equatable {
    /// LRCLIB asked us to wait (429, or 503 while overloaded): no request goes out before `until`.
    case busy(until: Date)
    case http(Int)
    /// A 200 whose body was not what the API documents.
    case parse
}

/// Where lyrics come from. The live one is `LRCLibClient`; the store only knows this seam.
protocol LyricsProviding: Sendable {
    func lyrics(for query: LyricsQuery) async throws -> LyricsResult
}
