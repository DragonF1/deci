// Deci/Music/MusicPinnedItems.swift
import Foundation
import Observation

/// What a Pin to Home entry says and whether it works right now: pin an item, unpin it, or refuse because Home holds
/// as many as it can.
nonisolated enum MusicHomePinState: Equatable, Hashable, Sendable {
    case canPin
    case pinned
    case full

    var title: String {
        switch self {
        case .canPin: "Pin to Home"
        case .pinned: "Unpin from Home"
        case .full: "Pin to Home (Home is full)"
        }
    }

    /// Off while Home is full and the item is not pinned yet. An unpin is always on.
    var isEnabled: Bool { self != .full }
}

/// What a pinned song needs on top of the shared fields to play like the row it was pinned from: its album, its
/// length and the artist pages its names link to. Saved as one object, so a payload this build cannot read costs the
/// song only these extras.
nonisolated struct MusicPinnedSong: Codable, Equatable, Sendable {
    nonisolated struct Artist: Codable, Equatable, Sendable {
        let name: String
        let browseId: String
    }

    var album: String?
    var albumBrowseId: String?
    var durationSeconds: Int?
    var artists: [Artist]

    init(album: String? = nil, albumBrowseId: String? = nil, durationSeconds: Int? = nil, artists: [Artist] = []) {
        self.album = album
        self.albumBrowseId = albumBrowseId
        self.durationSeconds = durationSeconds
        self.artists = artists
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        album = try? c.decodeIfPresent(String.self, forKey: .album)
        albumBrowseId = try? c.decodeIfPresent(String.self, forKey: .albumBrowseId)
        durationSeconds = try? c.decodeIfPresent(Int.self, forKey: .durationSeconds)
        artists = (try? c.decodeIfPresent([Artist].self, forKey: .artists)) ?? []
    }
}

/// What a pinned album needs on top of the shared fields for its menu to work like the tile it was pinned from: the
/// artists its subtitle links to (Go to artist) and the playlist of its songs (Save to playlist). Saved as one object,
/// so a payload this build cannot read costs the album only these extras. A pin saved before they existed has none, and
/// its menu leaves those entries out.
nonisolated struct MusicPinnedAlbum: Codable, Equatable, Sendable {
    var audioPlaylistId: String?
    var artists: [MusicPinnedSong.Artist]

    init(audioPlaylistId: String? = nil, artists: [MusicPinnedSong.Artist] = []) {
        self.audioPlaylistId = audioPlaylistId
        self.artists = artists
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioPlaylistId = try? c.decodeIfPresent(String.self, forKey: .audioPlaylistId)
        artists = (try? c.decodeIfPresent([MusicPinnedSong.Artist].self, forKey: .artists)) ?? []
    }

    /// Nothing worth keeping.
    var isEmpty: Bool { (audioPlaylistId ?? "").isEmpty && artists.isEmpty }
}

/// One item pinned to Music Home as settings.json keeps it: what the Home tile draws and what a tap opens or plays.
/// The photo is kept as the URL string, so a value that is not a URL cannot cost the listener the rest of their
/// settings.
nonisolated struct MusicPinnedItem: Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case artist
        case playlist
        case album
        case song
    }

    let kind: Kind
    /// A collection's browse id, or a song's video id.
    let id: String
    var title: String
    /// The second line: a song's artists, YouTube's own line for a playlist or an album. Nil for an artist.
    var subtitle: String?
    var thumbnailURL: String?
    /// Only a song has it.
    var song: MusicPinnedSong?
    /// Only an album has it, and only one pinned from a tile that carried them.
    var album: MusicPinnedAlbum?

    init(
        kind: Kind,
        id: String,
        title: String,
        subtitle: String? = nil,
        thumbnailURL: String? = nil,
        song: MusicPinnedSong? = nil,
        album: MusicPinnedAlbum? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnailURL = thumbnailURL
        self.song = song
        self.album = kind == .album ? album : nil
    }

    /// An entry needs its kind, id and title. The rest is optional, and a wrong type there costs only that field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        thumbnailURL = try? c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        if kind == .song {
            song = try? c.decodeIfPresent(MusicPinnedSong.self, forKey: .song)
        } else {
            song = nil
        }
        if kind == .album {
            album = try? c.decodeIfPresent(MusicPinnedAlbum.self, forKey: .album)
        } else {
            album = nil
        }
    }

    /// What tells two pins apart: the kind and the id, so a playlist that shares an id with a pinned artist is not it.
    var key: String { Self.key(kind: kind, id: id) }

    static func key(kind: Kind, id: String) -> String { kind.rawValue + ":" + id }

    var photoURL: URL? { thumbnailURL.flatMap { URL(string: $0) } }
}

/// One saved pin read on its own, so an entry this build cannot read (a kind it does not know, a missing id) costs
/// only that entry, not the whole row.
nonisolated struct MusicPinnedItemEntry: Decodable {
    let item: MusicPinnedItem?

    init(from decoder: Decoder) throws {
        item = try? MusicPinnedItem(from: decoder)
    }
}

/// One artist as the Pinned row was saved before it held more than artists (`musicPinnedArtists`), read on its own
/// and carried over as an artist pin.
nonisolated struct MusicLegacyPinnedArtistEntry: Decodable {
    let item: MusicPinnedItem?

    private enum CodingKeys: String, CodingKey {
        case browseId, title, thumbnailURL
    }

    init(from decoder: Decoder) throws {
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            item = MusicPinnedItem(
                kind: .artist,
                id: try c.decode(String.self, forKey: .browseId),
                title: try c.decode(String.self, forKey: .title),
                thumbnailURL: try? c.decodeIfPresent(String.self, forKey: .thumbnailURL)
            )
        } catch {
            item = nil
        }
    }
}

extension MusicPinnedItem.Kind {
    init(_ kind: MusicCollection.Kind) {
        switch kind {
        case .artist: self = .artist
        case .playlist: self = .playlist
        case .album: self = .album
        }
    }
}

extension MusicPinnedItem {
    /// The pin for a playlist, album or artist tile or row. Nil for Liked music, which belongs to the account and
    /// has no cover of its own, and for a tile with no id.
    @MainActor
    init?(collection: MusicCollection) {
        guard !collection.browseId.isEmpty, collection.browseId != MusicBrowseStore.likedMusic.browseId else { return nil }
        let kind = Kind(collection.kind)
        self.init(
            kind: kind,
            id: collection.browseId,
            title: collection.title,
            subtitle: kind == .artist ? nil : Self.line(collection.subtitle),
            thumbnailURL: collection.thumbnailURL?.absoluteString,
            album: Self.albumExtras(of: collection)
        )
    }

    /// The pin for the page just opened: the page's title and the photo of the tile that opened it, the square or
    /// round avatar of an artist, else the page's own. An album's or a playlist's cover is the page's, as its header
    /// draws it, else the tile's. Nil for Liked music.
    @MainActor
    init?(page: MusicBrowsePage, opener: MusicCollection) {
        guard !page.browseId.isEmpty, page.browseId != MusicBrowseStore.likedMusic.browseId else { return nil }
        let kind = Kind(opener.kind)
        let photo = kind == .artist ? (opener.thumbnailURL ?? page.thumbnailURL) : (page.thumbnailURL ?? opener.thumbnailURL)
        self.init(
            kind: kind,
            id: page.browseId,
            title: page.title.isEmpty ? opener.title : page.title,
            subtitle: kind == .artist ? nil : Self.line(opener.subtitle) ?? Self.line(page.subtitle ?? ""),
            thumbnailURL: photo?.absoluteString,
            album: Self.albumExtras(of: opener)
        )
    }

    /// The pin for a song row. Nil for a row with no video id.
    @MainActor
    init?(track: MusicTrack) {
        guard !track.videoId.isEmpty else { return nil }
        self.init(
            kind: .song,
            id: track.videoId,
            title: track.title,
            subtitle: Self.line(track.artist),
            thumbnailURL: track.thumbnailURL?.absoluteString,
            song: MusicPinnedSong(
                album: track.album,
                albumBrowseId: track.albumBrowseId,
                durationSeconds: track.durationSeconds,
                artists: track.artistLinks.map { MusicPinnedSong.Artist(name: $0.name, browseId: $0.browseId) }
            )
        )
    }

    /// What an album tile carries for its menu; nil for any other kind, and for a tile that carries neither extra.
    private static func albumExtras(of collection: MusicCollection) -> MusicPinnedAlbum? {
        guard collection.kind == .album else { return nil }
        let extras = MusicPinnedAlbum(
            audioPlaylistId: collection.audioPlaylistId,
            artists: collection.artistLinks.map { MusicPinnedSong.Artist(name: $0.name, browseId: $0.browseId) }
        )
        return extras.isEmpty ? nil : extras
    }

    private static func line(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the Home tile draws and what a tap does with it: a song plays, anything else opens its page.
    @MainActor
    var shelfItem: MusicShelfItem {
        switch kind {
        case .song:
            .track(MusicTrack(
                videoId: id,
                title: title,
                artist: subtitle ?? "",
                album: song?.album,
                durationSeconds: song?.durationSeconds,
                thumbnailURL: photoURL,
                artistLinks: (song?.artists ?? []).map { MusicArtistLink(name: $0.name, browseId: $0.browseId) },
                albumBrowseId: song?.albumBrowseId
            ))
        case .artist:
            .collection(MusicCollection(browseId: id, kind: .artist, title: title, subtitle: "Artist", thumbnailURL: photoURL))
        case .playlist:
            .collection(MusicCollection(browseId: id, kind: .playlist, title: title, subtitle: subtitle ?? "", thumbnailURL: photoURL))
        case .album:
            .collection(MusicCollection(
                browseId: id,
                kind: .album,
                title: title,
                subtitle: subtitle ?? "",
                thumbnailURL: photoURL,
                artistLinks: (album?.artists ?? []).map { MusicArtistLink(name: $0.name, browseId: $0.browseId) },
                audioPlaylistId: album?.audioPlaylistId
            ))
        }
    }
}

/// The items pinned to the top of Music Home, oldest first: artists, playlists, albums and songs. They belong to the
/// app, not to the account: sign-out and an account switch leave them alone. The rules (repeats, the cap, refreshed
/// names and photos) live here; `save` hears the whole list after every change so the app can keep it in settings.
@MainActor
@Observable
final class MusicPinnedItems {
    /// The most items Home holds, all kinds together.
    static let limit = 30
    static let shelfTitle = "Pinned"

    private(set) var items: [MusicPinnedItem]

    @ObservationIgnored private let save: @MainActor ([MusicPinnedItem]) -> Void

    init(items: [MusicPinnedItem] = [], save: @escaping @MainActor ([MusicPinnedItem]) -> Void = { _ in }) {
        // A file edited by hand may hold repeats, blank ids or more than the cap. It is tidied here and not written back.
        var seen = Set<String>()
        self.items = Array(items.filter { !$0.id.isEmpty && seen.insert($0.key).inserted }.prefix(Self.limit))
        self.save = save
    }

    var isFull: Bool { items.count >= Self.limit }

    /// Nothing is pinned, so Home shows no row.
    var isEmpty: Bool { items.isEmpty }

    func isPinned(_ item: MusicPinnedItem) -> Bool {
        items.contains { $0.key == item.key }
    }

    func isPinned(_ collection: MusicCollection) -> Bool {
        let key = MusicPinnedItem.key(kind: .init(collection.kind), id: collection.browseId)
        return items.contains { $0.key == key }
    }

    func isPinned(_ track: MusicTrack) -> Bool {
        let key = MusicPinnedItem.key(kind: .song, id: track.videoId)
        return items.contains { $0.key == key }
    }

    /// A pinned item can always be unpinned; a new one needs room.
    func canToggle(_ item: MusicPinnedItem) -> Bool {
        isPinned(item) || !isFull
    }

    /// What the item's Pin to Home entry says and whether it is on.
    func state(for item: MusicPinnedItem) -> MusicHomePinState {
        isPinned(item) ? .pinned : (isFull ? .full : .canPin)
    }

    /// Appends the item. Refused, with nothing saved, when it is already pinned or Home is full.
    @discardableResult
    func pin(_ item: MusicPinnedItem) -> Bool {
        guard !item.id.isEmpty, !isPinned(item), !isFull else { return false }
        items.append(item)
        save(items)
        return true
    }

    @discardableResult
    func unpin(_ item: MusicPinnedItem) -> Bool {
        guard let index = items.firstIndex(where: { $0.key == item.key }) else { return false }
        items.remove(at: index)
        save(items)
        return true
    }

    /// The Pin to Home entry: pins an item that is not pinned, unpins one that is.
    func toggle(_ item: MusicPinnedItem) {
        if isPinned(item) { unpin(item) } else { pin(item) }
    }

    /// A playlist's, an album's or an artist's page loaded: keeps the stored title current. A blank title never
    /// replaces what is stored, and an item that is not pinned is left alone. The photo only fills in a pin that has
    /// none: the page that loaded may have been opened from a small Library row, or carry the wide banner, and
    /// neither beats the cover or avatar the pin was made with.
    @discardableResult
    func refresh(_ latest: MusicPinnedItem) -> Bool {
        guard let index = items.firstIndex(where: { $0.key == latest.key }) else { return false }
        var updated = items[index]
        if !latest.title.isEmpty { updated.title = latest.title }
        if updated.thumbnailURL?.isEmpty ?? true, let photo = latest.thumbnailURL, !photo.isEmpty {
            updated.thumbnailURL = photo
        }
        guard updated != items[index] else { return false }
        items[index] = updated
        save(items)
        return true
    }

    /// Everything went back to its default. The settings were cleared already, so nothing is written here.
    func settingsDidReset() {
        items = []
    }
}
