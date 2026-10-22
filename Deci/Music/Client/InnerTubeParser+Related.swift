// Deci/Music/Client/InnerTubeParser+Related.swift
import Foundation

extension InnerTubeParser {
    /// The browse ids of the watch-next tabs that hold related songs start with this ("MPTRt_..."); the lyrics tab's
    /// start with "MPLYt".
    static let relatedBrowseIdPrefix = "MPTRt"

    /// The browse id behind the Related tab of a `next` answer. Nil when the answer has no tabs (nothing is related to
    /// such a song), when none of its tabs is a Related tab, or when YouTube greys that tab out (`unselectable`). The
    /// tab is found by its browse id and not its title, which is a translated word. Data that is not JSON throws.
    static func relatedBrowseId(inNext data: Data) throws -> String? {
        let root = try jsonObject(data, what: "watch next response")
        var tabs: [[String: Any]] = []
        collect("tabRenderer", in: root, into: &tabs)
        for tab in tabs {
            guard let browseId = string(path(tab, "endpoint", "browseEndpoint", "browseId")),
                  browseId.hasPrefix(relatedBrowseIdPrefix)
            else { continue }
            return isUnselectable(tab) ? nil : browseId
        }
        return nil
    }

    /// Whether YouTube greys a tab out. The key is absent on a live tab (the real Related tab carries none), `true`
    /// on a dead one, and `false` is a live one too. `null` says nothing, so it counts as live. Any other value is not
    /// something to open a tab by, so it counts as greyed out.
    private static func isUnselectable(_ tab: [String: Any]) -> Bool {
        guard let value = tab["unselectable"], !(value is NSNull) else { return false }
        return (value as? Bool) ?? true
    }

    /// The songs of a Related tab's browse answer: the songs of the first shelf that holds any ("You might also like"
    /// in English), in the first section list that has such a shelf. The shelves of playlists, artists and albums under
    /// it are skipped, and a second shelf of songs ("Other performances") is not merged in, so the list is one coherent
    /// set. A tile among a shelf's songs is dropped. No song shelf at all is an empty list; an answer with no section
    /// list is a parse error.
    static func relatedTracks(from data: Data) throws -> [MusicTrack] {
        let root = try jsonObject(data, what: "related response")
        var lists: [[String: Any]] = []
        collect("sectionListRenderer", in: root, into: &lists)
        guard !lists.isEmpty else { throw MusicError.parse("related response has no shelves") }
        for list in lists {
            for shelf in (list["contents"] as? [[String: Any]] ?? []).compactMap(shelf(from:)) {
                let tracks = shelf.items.compactMap { item -> MusicTrack? in
                    if case .track(let track) = item { return track }
                    return nil
                }
                if !tracks.isEmpty { return tracks }
            }
        }
        return []
    }
}
