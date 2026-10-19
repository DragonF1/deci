// Deci/Music/Lyrics/LyricsModels.swift
import Foundation

/// A run of a line's text with the moment it starts being sung: one word of an enhanced LRC line ("<00:05.40>up ").
/// The text keeps its own spacing, so the words of a line joined are exactly the line's text.
struct LyricWord: Sendable, Equatable, Hashable {
    let time: TimeInterval
    let text: String
}

/// One timed line of synced lyrics. Empty text is an instrumental gap, shown as a note.
///
/// `end` and `words` are the timing a source may add beyond the line's start: YouTube Music says when each line stops,
/// and some LRCLIB files carry a start for every word. A line with neither is fine: the view estimates the words.
struct LyricLine: Sendable, Equatable, Hashable {
    let time: TimeInterval
    let text: String
    /// When the line stops being sung, for a source that says. Nil: the line runs until the next one starts.
    let end: TimeInterval?
    /// When each word starts, for a source that says. Nil: estimated from the line's own timing when it is shown.
    let words: [LyricWord]?

    init(time: TimeInterval, text: String, end: TimeInterval? = nil, words: [LyricWord]? = nil) {
        self.time = time
        self.text = text
        self.end = end
        self.words = words
    }
}

/// What a lyrics source knows about a song.
enum LyricsResult: Sendable, Equatable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
}

/// What identifies a song to a lyrics source. `videoId` is the disk cache's key, and the only thing YouTube Music is
/// asked with (it matches the exact video); LRCLIB never sees it and is asked with the title, artist, album and length.
struct LyricsQuery: Sendable, Equatable {
    let videoId: String
    let title: String
    let artist: String
    let album: String?
    /// The exact length the player knows, in seconds; nil when it does not know.
    let duration: TimeInterval?

    /// The length when it is a real one (finite and above zero), else nil: the player reports 0 until it knows.
    var knownDuration: TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }
}

/// What a source answered, and where from.
struct LyricsAnswer: Sendable, Equatable {
    let result: LyricsResult
    /// The line shown under the lyrics ("Lyrics from LRCLIB"). Nil when there is nothing to credit: no lyrics, an
    /// instrumental, or a source that does not name itself.
    let credit: String?
    /// The answer may be a guess that the exact length would improve, so the store asks again once the player learns
    /// it. A source whose answer does not depend on the length (YouTube Music matches the video, a disk hit is final)
    /// says false, and the store keeps what it has.
    let lengthMatters: Bool

    init(result: LyricsResult, credit: String?, lengthMatters: Bool = true) {
        self.result = result
        self.credit = credit
        self.lengthMatters = lengthMatters
    }
}

enum LyricsError: Error, Sendable, Equatable {
    /// A source asked us to wait (LRCLIB: a 429, or a 503 with a Retry-After of over 5 s; YouTube Music: a 429, which
    /// pauses it for a minute, or the 15 s pause after a failure, for the calls that come within it): no request goes
    /// out to it before `until`.
    case busy(until: Date)
    /// A 500, 502, 504 or 503 that was still failing after the client's inline retries: LRCLIB is struggling. Like
    /// `busy` it holds every request back until `until` (about 15 s, in memory only), but the panel reports it as a
    /// failure and asks again by itself once the window has passed.
    case backoff(status: Int, until: Date)
    case http(Int)
    /// A 200 whose body was not what the API documents.
    case parse
}

/// Where lyrics come from. The live one is `LyricsChain` (a disk cache, YouTube Music, then LRCLIB); the store only
/// knows this seam. `answer(for:)` is `lyrics(for:)` with the credit and the length flag: a provider that only has the
/// older method gets an answer with no credit and a flag that says the length matters.
protocol LyricsProviding: Sendable {
    func lyrics(for query: LyricsQuery) async throws -> LyricsResult
    func answer(for query: LyricsQuery) async throws -> LyricsAnswer
}

extension LyricsProviding {
    func answer(for query: LyricsQuery) async throws -> LyricsAnswer {
        LyricsAnswer(result: try await lyrics(for: query), credit: nil)
    }
}

/// A provider that has no lyrics for anything and never touches the network. The default for a `MusicService` built
/// without a lyrics store (tests, previews), so only the app's own wiring ever reaches a lyrics server.
struct NoLyricsProvider: LyricsProviding {
    func lyrics(for query: LyricsQuery) async throws -> LyricsResult { .notFound }
}
