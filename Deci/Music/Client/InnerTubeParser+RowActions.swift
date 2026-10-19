// Deci/Music/Client/InnerTubeParser+RowActions.swift
// What a row's own menu offers for the song actions (go to album, remove from playlist, pin to Listen again, also
// read off playlist and album tiles, rows and page headers),
// the page-level "can the user edit this playlist" check, the add-to-playlist picker's list, and how the
// playlist edit and feedback responses say they worked.
import Foundation

extension InnerTubeParser {

    /// What a row's menu says about the song actions. Each field is nil when the menu has no such item.
    struct RowOptions: Equatable {
        /// The album's page, from the menu's "Go to album" item.
        var albumBrowseId: String?
        /// The row's place in its playlist, from the menu's "Remove from playlist" item.
        var setVideoId: String?
        /// The "Pin to Listen again" toggle.
        var pin: MusicFeedbackToggle?
    }

    /// The pin toggle's icons: "KEEP" is the pin item (shown while the song is not pinned), "KEEP_OFF" the unpin item.
    /// Words change with the account's language and the icons do not, so the icon is what tells it from the other toggles.
    private static let pinIcon = "KEEP"
    private static let unpinIcon = "KEEP_OFF"
    private static let removeVideoAction = "ACTION_REMOVE_VIDEO"

    // MARK: - Row menu

    static func rowOptions(in renderer: [String: Any]) -> RowOptions {
        let items = menuItems(of: renderer)
        return RowOptions(
            albumBrowseId: items.lazy.compactMap(menuAlbumId(in:)).first,
            setVideoId: items.lazy.compactMap(removeSetVideoId(in:)).first,
            pin: items.lazy.compactMap(pinToggle(in:)).first
        )
    }

    /// A page header's pin toggle. The header nests its menu deeper than a row (inside its buttons), so every toggle
    /// under it is tried; only the pin icons count.
    static func headerPin(in header: [String: Any]) -> MusicFeedbackToggle? {
        var toggles: [[String: Any]] = []
        collect("toggleMenuServiceItemRenderer", in: header, into: &toggles)
        return toggles.lazy.compactMap { pinToggle(in: ["toggleMenuServiceItemRenderer": $0]) }.first
    }

    private static func menuItems(of renderer: [String: Any]) -> [[String: Any]] {
        (path(renderer, "menu", "menuRenderer", "items") as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// The album's page id in a run list (a subtitle segment or a column): the run whose destination is an album.
    static func albumBrowseId(in segment: [[String: Any]]) -> String? {
        for run in segment {
            if let browse = path(run, "navigationEndpoint", "browseEndpoint") as? [String: Any],
               collectionKind(of: browse) == .album,
               let id = string(browse["browseId"]) {
                return id
            }
        }
        return nil
    }

    /// A "Go to album" item: a navigation item that opens an album page, whatever words it carries.
    private static func menuAlbumId(in item: [String: Any]) -> String? {
        guard let browse = path(item["menuNavigationItemRenderer"], "navigationEndpoint", "browseEndpoint") as? [String: Any],
              collectionKind(of: browse) == .album
        else { return nil }
        return string(browse["browseId"])
    }

    /// A "Remove from playlist" item: a service item whose playlist edit removes a video. Carries the row's setVideoId.
    private static func removeSetVideoId(in item: [String: Any]) -> String? {
        let actions = path(item["menuServiceItemRenderer"], "serviceEndpoint", "playlistEditEndpoint", "actions") as? [Any] ?? []
        for case let action as [String: Any] in actions where string(action["action"]) == removeVideoAction {
            if let setVideoId = string(action["setVideoId"]) { return setVideoId }
        }
        return nil
    }

    /// The pin toggle. Which of its two endpoints pins depends on which item YouTube sent: the pin item's default
    /// endpoint pins, the unpin item's toggled endpoint pins. A toggle with no feedback token at all is not offered.
    private static func pinToggle(in item: [String: Any]) -> MusicFeedbackToggle? {
        guard let toggle = item["toggleMenuServiceItemRenderer"] as? [String: Any] else { return nil }
        let icon = string(path(toggle, "defaultIcon", "iconType")) ?? string(path(toggle, "icon", "iconType"))
        let defaultToken = string(path(toggle, "defaultServiceEndpoint", "feedbackEndpoint", "feedbackToken"))
        let toggledToken = string(path(toggle, "toggledServiceEndpoint", "feedbackEndpoint", "feedbackToken"))
        let result: MusicFeedbackToggle
        switch icon {
        case pinIcon:
            result = MusicFeedbackToggle(isPinned: bool(toggle["isToggled"]) ?? false, pinToken: defaultToken, unpinToken: toggledToken)
        case unpinIcon:
            result = MusicFeedbackToggle(isPinned: true, pinToken: toggledToken, unpinToken: defaultToken)
        default:
            return nil
        }
        return result.pinToken == nil && result.unpinToken == nil ? nil : result
    }

    // MARK: - Editable playlists

    /// Whether the user can change this page's songs: a playlist page ("VL...", never Liked Music) that has YouTube's
    /// editable header, or whose rows offer to remove themselves. Albums and artist pages never are.
    static func isEditablePlaylist(root: [String: Any], browseId: String, rows: [[String: Any]]) -> Bool {
        guard browseId.hasPrefix("VL"), browseId != "VLLM" else { return false }
        var headers: [[String: Any]] = []
        collect("musicEditablePlaylistDetailHeaderRenderer", in: root, into: &headers)
        if !headers.isEmpty { return true }
        return rows.contains { row in menuItems(of: row).contains { removeSetVideoId(in: $0) != nil } }
    }

    // MARK: - Add to playlist picker

    /// The playlists of `playlist/get_add_to_playlist`, in YouTube's order. Liked Music (a like, not a playlist edit),
    /// and entries with no id or no title are left out. A user with no playlists gives an empty list.
    static func addToPlaylistOptions(from data: Data) throws -> [MusicPlaylistOption] {
        let root = try jsonObject(data, what: "add to playlist response")
        var renderers: [[String: Any]] = []
        collect("playlistAddToOptionRenderer", in: root, into: &renderers)
        var seen = Set<String>()
        return renderers.compactMap(playlistOption(from:)).filter { seen.insert($0.playlistId).inserted }
    }

    private static func playlistOption(from renderer: [String: Any]) -> MusicPlaylistOption? {
        guard var playlistId = string(renderer["playlistId"]) else { return nil }
        if playlistId.hasPrefix("VL") { playlistId.removeFirst(2) }
        guard !playlistId.isEmpty, playlistId != "LM", let title = text(of: runs(renderer["title"])) else { return nil }
        let groups = renderer["thumbnails"] as? [Any] ?? []
        var candidates: [[String: Any]] = []
        for case let group as [String: Any] in groups {
            candidates += group["thumbnails"] as? [[String: Any]] ?? []
        }
        let best = candidates.max { (int($0["width"]) ?? 0) < (int($1["width"]) ?? 0) }
        return MusicPlaylistOption(
            playlistId: playlistId,
            title: title,
            thumbnailURL: string(best?["url"]).flatMap { URL(string: $0) },
            containsVideo: string(renderer["containsSelectedVideos"]) == "ALL"
        )
    }

    // MARK: - Write responses

    /// `browse/edit_playlist` says `STATUS_SUCCEEDED` when the edit went through. Anything else, or no status, did not.
    static func playlistEditSucceeded(in data: Data) throws -> Bool {
        let root = try jsonObject(data, what: "playlist edit response")
        return string(root["status"]) == "STATUS_SUCCEEDED"
    }

    /// `feedback` answers one entry per token; the call worked when the first one is processed.
    static func feedbackProcessed(in data: Data) throws -> Bool {
        let root = try jsonObject(data, what: "feedback response")
        let first = (root["feedbackResponses"] as? [Any])?.first as? [String: Any]
        return bool(first?["isProcessed"]) == true
    }

    /// A real JSON boolean. The string "true" and the numbers 1 and 0 are not one.
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
