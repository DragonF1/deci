// Deci/Music/MusicTrackActions.swift
import Foundation

/// The page a song row sits on, which decides whether Remove from playlist and Go to album make sense for it.
/// Search results and the player column sit on no page (`.none`); an Up next row sits on `.upNext`.
struct MusicTrackContext: Equatable, Sendable {
    /// The open page's browse id, as the page store knows it ("VL..." for a playlist).
    var pageBrowseId: String?
    /// The page's name, for the "Removed from ..." line.
    var pageTitle: String?
    /// YouTube's own header said the user can change this playlist.
    var pageIsEditable: Bool
    /// The row is one of Up next's, so it also offers Remove from queue.
    var isUpNext = false

    /// The row sits on the user's Liked music page, whose songs are all liked: the library page "VLLM", YouTube's own
    /// browse id for it, or its playlist id.
    var isLikedMusic: Bool {
        guard let pageBrowseId else { return false }
        return Self.likedMusicIds.contains(pageBrowseId)
    }

    private static let likedMusicIds: Set<String> = ["VLLM", "FEmusic_liked_videos", "LM"]

    static let none = MusicTrackContext(pageBrowseId: nil, pageTitle: nil, pageIsEditable: false)
    static let upNext = MusicTrackContext(pageBrowseId: nil, pageTitle: nil, pageIsEditable: false, isUpNext: true)
}

/// One entry of a song's "..." menu. The menu is text only, in groups with a line between them.
enum MusicTrackAction: Hashable, Sendable {
    case playNext
    case addToQueue
    case removeFromQueue
    case saveToPlaylist
    case removeFromPlaylist
    /// Pin to Home, Unpin from Home, or the refusal while Home is full. The pin is Deci's own.
    case pinHome(MusicHomePinState)
    /// Save the song's audio on this Mac, so it plays from the file.
    case download
    /// Delete the song's download, or stop it while it is queued or running.
    case removeDownload
    /// Like, or Remove like when the song is liked. A song only: an album, playlist or artist has no like here.
    case like(removing: Bool)
    /// Dislike, or Remove dislike when the song is disliked.
    case dislike(removing: Bool)
    case goToAlbum
    case goToArtist
    /// The Related panel for the song, or for the first song of an album, playlist, mix or artist.
    case related

    var title: String {
        switch self {
        case .playNext: "Play next"
        case .addToQueue: "Add to queue"
        case .removeFromQueue: "Remove from queue"
        case .saveToPlaylist: "Save to playlist"
        case .removeFromPlaylist: "Remove from playlist"
        case .pinHome(let state): state.title
        case .download: "Download"
        case .removeDownload: "Remove download"
        case .like(let removing): removing ? "Remove like" : "Like"
        case .dislike(let removing): removing ? "Remove dislike" : "Dislike"
        case .goToAlbum: "Go to album"
        case .goToArtist: "Go to artist"
        case .related: "Related songs"
        }
    }

    /// The action needs YouTube Music: the account, a page, a rating or a playlist. Offline, or signed out, these have
    /// nothing to talk to. Play next and Add to queue are not on the list (a downloaded song plays from its file), nor
    /// are the download entries and Remove from queue, which touch only this Mac.
    var isOnlineOnly: Bool {
        switch self {
        case .saveToPlaylist, .removeFromPlaylist, .pinHome, .like, .dislike, .goToAlbum, .goToArtist, .related: true
        case .playNext, .addToQueue, .removeFromQueue, .download, .removeDownload: false
        }
    }

    /// Off for the refusal while Home is full.
    var isEnabled: Bool {
        switch self {
        case .pinHome(let state): state.isEnabled
        default: true
        }
    }

    /// What Like, Remove like, Dislike and Remove dislike set the song to: they set it, they do not toggle it. Nil for
    /// every other action.
    var ratingStatus: MusicLikeStatus? {
        switch self {
        case .like(let removing): removing ? .indifferent : .like
        case .dislike(let removing): removing ? .indifferent : .dislike
        default: nil
        }
    }

    /// The block of the menu the action sits in: what changes the play order, what changes the user's library, how the
    /// user rates the song, where to go, and the destructive one.
    enum Group: Int, Comparable, Sendable {
        case queue
        case library
        case rate
        case navigate
        case remove

        static func < (lhs: Group, rhs: Group) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var group: Group {
        switch self {
        case .playNext, .addToQueue: .queue
        case .saveToPlaylist, .pinHome, .download, .removeDownload: .library
        case .like, .dislike: .rate
        case .goToAlbum, .goToArtist, .related: .navigate
        case .removeFromPlaylist, .removeFromQueue: .remove
        }
    }
}

/// Which song actions a row offers. Pure rules, so the row, its context menu and the player column agree and the
/// rules are tested without a view. An action shows only when it can work.
enum MusicTrackActions {
    /// In menu order: play next and add to queue, save, pin or unpin to Home, like and dislike, then go to album, go to
    /// artist and related songs, then remove from playlist and remove from queue last. `home` is where the song stands
    /// with the Pinned row on Home; nil leaves the entry out. The queue entries show only when the caller offers them
    /// (not for the song that is playing), and Remove from queue only on an Up next row. Like and Dislike show only
    /// when the user `canRate` (signed in) and the song has an id to rate; `likeStatus` is what is known of the song,
    /// nil while it is unknown, and it turns the entry that is on into its Remove. Related songs shows for any song
    /// that has an id to ask about. `download` is the song's download state; nil leaves both download entries out, and
    /// so does an id that cannot be downloaded. Download shows when nothing is downloaded or the last try failed, Remove
    /// download when the song is queued, downloading or downloaded. `downloadHeldByCollectionOnly` is a song that a
    /// downloaded playlist or album lists and that was not downloaded on its own: while it is queued, downloading or
    /// downloaded it offers neither entry (the page's pill removes it); one not yet fetched, or that failed, still
    /// offers Download. `limited` is a Music tab that has only this Mac to work with, offline or signed out: every entry
    /// that needs YouTube Music is left out (`isOnlineOnly`), and so are Play next and Add to queue unless the song
    /// `playsOffline` (it is downloaded, so it plays from its file). Download, Remove download and Remove from queue stay.
    static func available(
        for track: MusicTrack, in context: MusicTrackContext, home: MusicHomePinState? = nil, offersQueue: Bool = false,
        canRate: Bool = false, likeStatus: MusicLikeStatus? = nil, download: MusicDownloadState? = nil,
        downloadHeldByCollectionOnly: Bool = false, limited: Bool = false, playsOffline: Bool = false
    ) -> [MusicTrackAction] {
        var actions: [MusicTrackAction] = offersQueue ? [.playNext, .addToQueue, .saveToPlaylist] : [.saveToPlaylist]
        if let home { actions.append(.pinHome(home)) }
        if let download, MusicDownloadStore.isValidVideoId(track.videoId) {
            switch download {
            case .none, .failed: actions.append(.download)
            case .queued, .downloading, .downloaded:
                if !downloadHeldByCollectionOnly { actions.append(.removeDownload) }
            }
        }
        if canRate, hasId(track) {
            actions.append(.like(removing: likeStatus == .like))
            actions.append(.dislike(removing: likeStatus == .dislike))
        }
        if let album = track.albumBrowseId, !album.isEmpty, album != context.pageBrowseId {
            actions.append(.goToAlbum)
        }
        if artistCollection(for: track, in: context) != nil { actions.append(.goToArtist) }
        if hasId(track) { actions.append(.related) }
        if canRemove(track, in: context) { actions.append(.removeFromPlaylist) }
        if offersQueue, context.isUpNext { actions.append(.removeFromQueue) }
        guard limited else { return actions }
        return actions.filter { action in
            if action.isOnlineOnly { return false }
            switch action {
            case .playNext, .addToQueue: return playsOffline
            default: return true
            }
        }
    }

    /// The entries of an album, playlist or artist tile, in the song menu's order and words. An album: save the whole
    /// album, pin, go to the album, go to its artist. A playlist or mix: save and pin. An artist: pin, go to the artist.
    /// All three end with Related songs, which starts from the first song of the page; a tile with no page id has none.
    /// Save shows only for what has a playlist to add from (`playlistSourceId`). Go to album and Go to artist hide on
    /// the page they would open. `home` is where the tile stands with the Pinned row on Home; nil leaves the entry out.
    /// A `limited` Music tab (offline or signed out) offers a tile nothing: every entry needs YouTube Music.
    static func available(
        for collection: MusicCollection, in context: MusicTrackContext, home: MusicHomePinState? = nil, limited: Bool = false
    ) -> [MusicTrackAction] {
        guard !limited else { return [] }
        var actions: [MusicTrackAction] = []
        if playlistSourceId(for: collection) != nil { actions.append(.saveToPlaylist) }
        if let home { actions.append(.pinHome(home)) }
        if collection.kind == .album, collection.browseId != context.pageBrowseId { actions.append(.goToAlbum) }
        if artistCollection(for: collection, in: context) != nil { actions.append(.goToArtist) }
        if !collection.browseId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { actions.append(.related) }
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

    /// The song has an id to rate or to ask for related songs by.
    private static func hasId(_ track: MusicTrack) -> Bool {
        !track.videoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The artist page a song opens: its first credited artist, unless that page is the one the row is on.
    static func artistCollection(for track: MusicTrack, in context: MusicTrackContext) -> MusicCollection? {
        guard let artist = track.artistLinks.first, !artist.browseId.isEmpty,
              artist.browseId != context.pageBrowseId else { return nil }
        return artist.opener
    }

    /// The artist page a tile opens: an album's first linked artist, an artist's own page. Nil for a playlist or mix,
    /// for an album with no artist link, and for the page the tile is on.
    static func artistCollection(for collection: MusicCollection, in context: MusicTrackContext) -> MusicCollection? {
        switch collection.kind {
        case .artist:
            return collection.browseId.isEmpty || collection.browseId == context.pageBrowseId ? nil : collection
        case .album:
            guard let artist = collection.artistLinks.first, !artist.browseId.isEmpty,
                  artist.browseId != context.pageBrowseId else { return nil }
            return artist.opener
        case .playlist:
            return nil
        }
    }

    /// The album page an album tile opens: the tile itself, with its name and cover. Nil for any other kind.
    static func albumCollection(for collection: MusicCollection) -> MusicCollection? {
        collection.kind == .album && !collection.browseId.isEmpty ? collection : nil
    }

    /// The playlist a whole-tile save adds from. A playlist or mix: its browse id without the "VL". An album: the
    /// playlist of its songs, when the tile carried one (its own browse id is not a playlist). Nil for an artist, for
    /// Liked music (a like, not a playlist) and for an id with nothing after the "VL".
    static func playlistSourceId(for collection: MusicCollection) -> String? {
        switch collection.kind {
        case .playlist:
            var id = collection.browseId
            if id.hasPrefix("VL") { id.removeFirst(2) }
            return id.isEmpty || id == "LM" ? nil : id
        case .album:
            guard let id = collection.audioPlaylistId, !id.isEmpty else { return nil }
            return id
        case .artist:
            return nil
        }
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
