// Deci/Music/MusicTrackActions.swift
import Foundation

/// The page a song row sits on, which decides whether Remove from playlist and Go to album make sense for it.
/// Search results, Up next and the player column sit on no page (`.none`).
struct MusicTrackContext: Equatable, Sendable {
    /// The open page's browse id, as the page store knows it ("VL..." for a playlist).
    var pageBrowseId: String?
    /// The page's name, for the "Removed from ..." line.
    var pageTitle: String?
    /// YouTube's own header said the user can change this playlist.
    var pageIsEditable: Bool

    static let none = MusicTrackContext(pageBrowseId: nil, pageTitle: nil, pageIsEditable: false)
}

/// One entry of a song's "..." menu. The menu is text only, in groups with a line between them.
enum MusicTrackAction: Hashable, Sendable {
    case saveToPlaylist
    case removeFromPlaylist
    case pinToListenAgain
    case unpinFromListenAgain
    /// Pin to Home, Unpin from Home, or the refusal while Home is full. The pin is Deci's own, so it needs no token.
    case pinHome(MusicHomePinState)
    case goToAlbum
    case goToArtist

    var title: String {
        switch self {
        case .saveToPlaylist: "Save to playlist"
        case .removeFromPlaylist: "Remove from playlist"
        case .pinToListenAgain: "Pin to Listen again"
        case .unpinFromListenAgain: "Unpin from Listen again"
        case .pinHome(let state): state.title
        case .goToAlbum: "Go to album"
        case .goToArtist: "Go to artist"
        }
    }

    /// Off for the refusal while Home is full.
    var isEnabled: Bool {
        switch self {
        case .pinHome(let state): state.isEnabled
        default: true
        }
    }

    /// The block of the menu the action sits in: what changes the user's library, where to go, and the destructive one.
    enum Group: Int, Comparable, Sendable {
        case library
        case navigate
        case remove

        static func < (lhs: Group, rhs: Group) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var group: Group {
        switch self {
        case .saveToPlaylist, .pinToListenAgain, .unpinFromListenAgain, .pinHome: .library
        case .goToAlbum, .goToArtist: .navigate
        case .removeFromPlaylist: .remove
        }
    }
}

/// Which song actions a row offers. Pure rules, so the row, its context menu and the player column agree and the
/// rules are tested without a view. An action shows only when it can work.
enum MusicTrackActions {
    /// In menu order: save, pin or unpin to Listen again, pin or unpin to Home, then go to album and go to artist, then
    /// remove from playlist last. `home` is where the song stands with the Pinned row on Home; nil leaves the entry out.
    static func available(for track: MusicTrack, in context: MusicTrackContext, home: MusicHomePinState? = nil) -> [MusicTrackAction] {
        var actions: [MusicTrackAction] = [.saveToPlaylist]
        if let toggle = track.listenAgainPin, toggle.nextToken?.isEmpty == false {
            actions.append(toggle.isPinned ? .unpinFromListenAgain : .pinToListenAgain)
        }
        if let home { actions.append(.pinHome(home)) }
        if let album = track.albumBrowseId, !album.isEmpty, album != context.pageBrowseId {
            actions.append(.goToAlbum)
        }
        if artistCollection(for: track, in: context) != nil { actions.append(.goToArtist) }
        if canRemove(track, in: context) { actions.append(.removeFromPlaylist) }
        return actions
    }

    /// The actions cut into the blocks of the menu, in order, with no empty block: a line goes between two blocks.
    static func groups(of actions: [MusicTrackAction]) -> [[MusicTrackAction]] {
        var groups: [[MusicTrackAction]] = []
        var last: MusicTrackAction.Group?
        for action in actions {
            if action.group == last {
                groups[groups.count - 1].append(action)
            } else {
                groups.append([action])
                last = action.group
            }
        }
        return groups
    }

    /// The artist page a song opens: its first credited artist, unless that page is the one the row is on.
    static func artistCollection(for track: MusicTrack, in context: MusicTrackContext) -> MusicCollection? {
        guard let artist = track.artistLinks.first, !artist.browseId.isEmpty,
              artist.browseId != context.pageBrowseId else { return nil }
        return artist.opener
    }

    /// The album page a song opens: its id, and the album's name when the row had one, so the page header has a
    /// title until the page loads. Nil when the song has no album page.
    static func albumCollection(for track: MusicTrack) -> MusicCollection? {
        guard let id = track.albumBrowseId, !id.isEmpty else { return nil }
        let name = track.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return MusicCollection(browseId: id, kind: .album, title: name.isEmpty ? "Album" : name, subtitle: "", thumbnailURL: nil)
    }

    /// Only a playlist page the user can edit, never Liked Music (a like, not a playlist edit), and only a row that
    /// knows its own place in the playlist.
    private static func canRemove(_ track: MusicTrack, in context: MusicTrackContext) -> Bool {
        guard context.pageIsEditable, let setVideoId = track.playlistSetVideoId, !setVideoId.isEmpty,
              let page = context.pageBrowseId, page.hasPrefix("VL"), page != "VLLM" else { return false }
        return true
    }
}
