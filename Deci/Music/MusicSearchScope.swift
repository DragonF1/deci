// Deci/Music/MusicSearchScope.swift
import Foundation

/// What the search field of the right column searches on the screen it sits on. Kept apart from the views so each
/// screen is tested: Home and an artist page search YouTube Music; Library, a playlist (Liked music too), an album and
/// Up next filter what is already loaded, live; Lyrics has no search.
nonisolated enum MusicSearchScope: Equatable {
    /// Home and an artist page: search YouTube Music, sent with Return.
    case global
    /// Library, any of its segments.
    case library
    /// A playlist page or Liked music.
    case playlist
    case album
    case queue
    /// Lyrics and the add-to-playlist picker: no magnifier, no field.
    case none

    /// What the empty field says.
    var placeholder: String? {
        switch self {
        case .global: "Search YouTube Music"
        case .library: "Search your library"
        case .playlist: "Search in this playlist"
        case .album: "Search in this album"
        case .queue: "Search the queue"
        case .none: nil
        }
    }

    var showsMagnifier: Bool { self != .none }

    /// Filters what is on screen as it is typed, with no network call.
    var isLocal: Bool {
        switch self {
        case .library, .playlist, .album, .queue: true
        case .global, .none: false
        }
    }

    /// The scope of the screen on top: Up next searches the queue, Lyrics and the picker nothing, and browse depends on
    /// the page open on top of the tab (an artist page searches YouTube Music like Home) or the tab itself.
    @MainActor
    static func resolve(column: MusicRightColumn, tab: MusicBrowseStore.Tab, page: MusicPageKind?) -> MusicSearchScope {
        switch column {
        case .lyrics, .picker:
            return .none
        case .queue:
            return .queue
        case .browse:
            if let page {
                switch page {
                case .album: return .album
                case .playlist, .liked: return .playlist
                case .artist: return .global
                }
            }
            return tab == .library ? .library : .global
        }
    }
}

/// What a filter counts: songs of a page or the queue, or the three kinds of the library.
nonisolated enum MusicSearchNoun: CaseIterable, Hashable {
    case playlist
    case album
    case artist
    case song

    func word(count: Int) -> String {
        let plural = count != 1
        switch self {
        case .playlist: return plural ? "playlists" : "playlist"
        case .album: return plural ? "albums" : "album"
        case .artist: return plural ? "artists" : "artist"
        case .song: return plural ? "songs" : "song"
        }
    }
}

// MARK: - Copy

/// The words of the filtered screens: the count line, the other matches, the hint and the no-results block.
nonisolated enum MusicSearchCopy {
    /// The link of the no-results block, which runs the same query on YouTube Music.
    static let searchYouTubeInstead = "Search YouTube Music instead"
    static let clearFilter = "Clear filter"

    /// "3 OF 42 PLAYLISTS". When the list is only partly loaded the count is of what is loaded, and says so.
    static func countLine(matched: Int, total: Int, noun: MusicSearchNoun, isPartial: Bool) -> String {
        let line = "\(max(matched, 0)) OF \(max(total, 0)) \(noun.word(count: total).uppercased())"
        return isPartial ? line + " LOADED" : line
    }

    /// The line under the filtered queue: "Clear or press esc to show all 4 songs".
    static func clearHint(total: Int, noun: MusicSearchNoun) -> String {
        "Clear or press esc to show all \(max(total, 0)) \(noun.word(count: total))"
    }

    /// The most of a query the no-results title repeats.
    static let quotedLimit = 30

    /// The title and the line under it of a filter that found nothing. `place` is where it looked ("this playlist",
    /// "your library", "the queue"); `beyond` is what to look past ("Late Night Drive", "your library").
    static func noResults(noun: MusicSearchNoun, query: String, place: String, beyond: String) -> (title: String, detail: String) {
        let quoted = quoted(query)
        return (
            "No \(noun.word(count: 2)) match \u{201C}\(quoted)\u{201D} in \(place)",
            "Try another word, or look beyond \(beyond)."
        )
    }

    /// The query as typed, trimmed and cut at `quotedLimit` characters with dots.
    static func quoted(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > quotedLimit else { return trimmed }
        return String(trimmed.prefix(quotedLimit)).trimmingCharacters(in: .whitespaces) + "..."
    }
}

/// The line under a Library filter that says what the query matches in the other segments, and the segment its link
/// goes to.
nonisolated struct MusicOtherMatches: Equatable {
    /// "Also 2 albums and 1 artist match".
    let text: String
    /// The segment the link opens: the one with the most matches, the first of them on a tie.
    let target: MusicSearchNoun

    /// `counts` holds the matches per segment; a segment that is not loaded is left out and not counted. Nil when no
    /// other segment has a match.
    static func resolve(current: MusicSearchNoun, counts: [MusicSearchNoun: Int]) -> MusicOtherMatches? {
        var others: [(noun: MusicSearchNoun, count: Int)] = []
        for noun in MusicSearchNoun.allCases where noun != current && noun != .song {
            if let count = counts[noun], count > 0 { others.append((noun, count)) }
        }
        guard var best = others.first else { return nil }
        for other in others.dropFirst() where other.count > best.count { best = other }
        let parts = others.map { "\($0.count) \($0.noun.word(count: $0.count))" }
        let verb = others.count == 1 && best.count == 1 ? "matches" : "match"
        return MusicOtherMatches(text: "Also " + parts.joined(separator: " and ") + " " + verb, target: best.noun)
    }
}
