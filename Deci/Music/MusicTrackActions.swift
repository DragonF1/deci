// Deci/Music/MusicTrackActions.swift
import Foundation

/// The page a song row sits on, which decides whether Remove from playlist and Go to album make sense for it.
/// Search results, Up next and the mini player sit on no page (`.none`).
struct MusicTrackContext: Equatable, Sendable {
    /// The open page's browse id, as the page store knows it ("VL..." for a playlist).
    var pageBrowseId: String?
    /// The page's name, for the "Removed from ..." line.
    var pageTitle: String?
    /// YouTube's own header said the user can change this playlist.
    var pageIsEditable: Bool

    static let none = MusicTrackContext(pageBrowseId: nil, pageTitle: nil, pageIsEditable: false)
}

/// One entry of a song's "..." menu.
enum MusicTrackAction: Hashable, Sendable {
    case saveToPlaylist
    case removeFromPlaylist
    case pinToListenAgain
    case unpinFromListenAgain
    case goToAlbum

    var title: String {
        switch self {
        case .saveToPlaylist: "Save to playlist..."
        case .removeFromPlaylist: "Remove from playlist"
        case .pinToListenAgain: "Pin to Listen again"
        case .unpinFromListenAgain: "Unpin from Listen again"
        case .goToAlbum: "Go to album"
        }
    }

    var systemImage: String {
        switch self {
        case .saveToPlaylist: "text.badge.plus"
        case .removeFromPlaylist: "text.badge.minus"
        case .pinToListenAgain: "pin"
        case .unpinFromListenAgain: "pin.slash"
        case .goToAlbum: "square.stack"
        }
    }
}

/// Which song actions a row offers. Pure rules, so the row, its context menu and the mini player agree and the
/// rules are tested without a view. An action shows only when it can work.
enum MusicTrackActions {
    /// In menu order: save, remove, pin or unpin, go to album.
    static func available(for track: MusicTrack, in context: MusicTrackContext) -> [MusicTrackAction] {
        var actions: [MusicTrackAction] = [.saveToPlaylist]
        if canRemove(track, in: context) { actions.append(.removeFromPlaylist) }
        if let toggle = track.listenAgainPin, toggle.nextToken?.isEmpty == false {
            actions.append(toggle.isPinned ? .unpinFromListenAgain : .pinToListenAgain)
        }
        if let album = track.albumBrowseId, !album.isEmpty, album != context.pageBrowseId {
            actions.append(.goToAlbum)
        }
        return actions
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
