// Deci/Music/Lyrics/YTMusicLyricsParser.swift
import Foundation

/// Reads the two YouTube Music answers the lyrics client needs: the watch-next answer, for the id of the song's
/// lyrics page, and that page, for timed lyrics or a plain description. Pure functions over JSON, so the client's
/// tests can feed it made-up pages.
///
/// The pages are huge, undocumented and reshuffled by YouTube now and then, so nothing here follows a fixed path:
/// each piece is found by its key wherever it sits (a small recursive search), and anything that is not what it
/// should be is skipped rather than guessed at.
enum YTMusicLyricsParser {
    /// What a lyrics page held: the lyrics and the provider line YouTube prints with them ("Source: ...").
    struct Page: Sendable, Equatable {
        let result: LyricsResult
        let source: String?
    }

    /// Browse ids of lyrics pages start with this. The tab's title is translated and changes, the id does not.
    static let lyricsBrowseIdPrefix = "MPLYt"

    // MARK: - Watch next

    /// The browse id of the lyrics tab, or nil when the song has none (tabs, but no lyrics one, or the tab is greyed
    /// out: an instrumental, a lofi mix). Throws `parse` when the answer is not a JSON object, or is one with no tab at
    /// all: that is an error page or a reshuffled layout, not a song without lyrics, and must not be remembered as one.
    static func lyricsBrowseId(inNext data: Data) throws -> String? {
        let root = try object(from: data)
        let tabs = values(forKey: "tabRenderer", in: root)
        guard !tabs.isEmpty else { throw LyricsError.parse }
        for case let tab as [String: Any] in tabs {
            guard let browseEndpoint = (tab["endpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
                  let browseId = browseEndpoint["browseId"] as? String,
                  browseId.hasPrefix(lyricsBrowseIdPrefix)
            else { continue }
            // A tab that exists but cannot be opened has no lyrics behind it.
            return tab["unselectable"] == nil ? browseId : nil
        }
        return nil
    }

    // MARK: - Lyrics page

    /// The lyrics on a lyrics page: timed lyrics when it has enough of them, else the plain description, else nil.
    /// Throws `parse` when the answer is not a JSON object.
    static func lyrics(inBrowse data: Data) throws -> Page? {
        let root = try object(from: data)
        if let timed = timedLyrics(in: root) { return timed }
        return plainLyrics(in: root)
    }

    /// Timed lines from `timedLyricsData`, a list of `{"lyricLine", "cueRange": {"startTimeMilliseconds", ...}}`.
    /// Lines with no letters or digits (the note symbol YouTube uses for a break) become empty gap lines. A page with
    /// fewer real lines than LRCLIB's own minimum is not trusted. A last gap closes the final line at its cue's end.
    private static func timedLyrics(in root: Any) -> Page? {
        guard let container = firstDictionary(containingKey: "timedLyricsData", in: root),
              let cues = container["timedLyricsData"] as? [Any]
        else { return nil }

        struct Timed { var time: Double; var end: Double?; var text: String; var order: Int }
        var timed: [Timed] = []
        for case let cue as [String: Any] in cues {
            guard let text = cue["lyricLine"] as? String,
                  let range = cue["cueRange"] as? [String: Any],
                  let start = milliseconds(range["startTimeMilliseconds"])
            else { continue }
            timed.append(Timed(
                time: start / 1000,
                end: milliseconds(range["endTimeMilliseconds"]).map { $0 / 1000 },
                text: isSung(text) ? text.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                order: timed.count
            ))
        }
        // Stable: lines that share a start time stay in the order the page gave them.
        timed.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        guard timed.filter({ !$0.text.isEmpty }).count >= LRCLibClient.minimumLines else { return nil }

        var lines = timed.map { LyricLine(time: $0.time, text: $0.text) }
        if let last = timed.last, !last.text.isEmpty, let end = last.end, end > last.time {
            lines.append(LyricLine(time: end, text: ""))
        }
        let source = (container["sourceMessage"] as? String) ?? values(forKey: "sourceMessage", in: root).lazy
            .compactMap { $0 as? String }.first
        return Page(result: .synced(lines), source: source)
    }

    /// The text of a `musicDescriptionShelfRenderer`: its description's runs joined as they are, and the footer's
    /// runs, the provider line. Nil when the shelf is absent or holds fewer non-empty lines than LRCLIB's own minimum
    /// (a blurb or a note is not a song's words).
    private static func plainLyrics(in root: Any) -> Page? {
        for case let shelf as [String: Any] in values(forKey: "musicDescriptionShelfRenderer", in: root) {
            let text = runs(shelf["description"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
            guard lines.count >= LRCLibClient.minimumLines else { continue }
            let footer = runs(shelf["footer"])
            return Page(result: .plain(text), source: footer.isEmpty ? nil : footer)
        }
        return nil
    }

    /// `{"runs": [{"text": ...}, ...]}` joined into one string; empty for anything else.
    private static func runs(_ node: Any?) -> String {
        guard let list = (node as? [String: Any])?["runs"] as? [Any] else { return "" }
        return list.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
    }

    // MARK: - Pieces

    /// A line worth showing: it has a letter or a digit somewhere. "♪", "..." and blanks are breaks.
    private static func isSung(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// A time in milliseconds, which the API sends as a string ("12340") and a test or a later version may send as a
    /// number. Nil for anything that is not a finite number of zero or more.
    private static func milliseconds(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let text as String: number = Double(text.trimmingCharacters(in: .whitespaces))
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID(): number = value.doubleValue
        default: number = nil
        }
        guard let number, number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func object(from data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LyricsError.parse }
        return root
    }

    /// Every value stored under `key`, anywhere in the tree, in the order the walk meets them.
    private static func values(forKey key: String, in node: Any) -> [Any] {
        var found: [Any] = []
        walk(node) { dictionary in
            if let value = dictionary[key] { found.append(value) }
            return false
        }
        return found
    }

    /// The first dictionary in the tree that has `key` with a list under it.
    private static func firstDictionary(containingKey key: String, in node: Any) -> [String: Any]? {
        var match: [String: Any]?
        walk(node) { dictionary in
            guard dictionary[key] is [Any] else { return false }
            match = dictionary
            return true
        }
        return match
    }

    /// Depth-first over dictionaries and lists. `visit` returns true to stop the walk.
    @discardableResult
    private static func walk(_ node: Any, visit: ([String: Any]) -> Bool) -> Bool {
        if let dictionary = node as? [String: Any] {
            if visit(dictionary) { return true }
            for value in dictionary.values {
                if walk(value, visit: visit) { return true }
            }
        } else if let list = node as? [Any] {
            for value in list {
                if walk(value, visit: visit) { return true }
            }
        }
        return false
    }
}
