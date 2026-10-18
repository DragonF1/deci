// Deci/Music/MusicPinnedArtists.swift
import Foundation
import Observation

/// One pinned artist as settings.json keeps it: what the Home tile draws and the page it opens. The photo is
/// kept as the URL string, so a value that is not a URL cannot cost the listener the rest of their settings.
nonisolated struct MusicPinnedArtist: Codable, Equatable, Sendable {
    let browseId: String
    var title: String
    var thumbnailURL: String?
}

/// One saved pin read on its own, so an entry this build cannot read costs only that entry, not the whole row.
nonisolated struct MusicPinnedArtistEntry: Decodable {
    let artist: MusicPinnedArtist?

    init(from decoder: Decoder) throws {
        artist = try? MusicPinnedArtist(from: decoder)
    }
}

extension MusicPinnedArtist {
    /// The pin for an artist page: the page's title and the photo of the tile that opened it (the round or square
    /// avatar), else the page's own.
    @MainActor
    init(page: MusicBrowsePage, opener: MusicCollection?) {
        self.init(
            browseId: page.browseId,
            title: page.title,
            thumbnailURL: (opener?.thumbnailURL ?? page.thumbnailURL)?.absoluteString
        )
    }

    /// The tile Home draws for it.
    @MainActor
    var collection: MusicCollection {
        MusicCollection(
            browseId: browseId,
            kind: .artist,
            title: title,
            subtitle: "Artist",
            thumbnailURL: thumbnailURL.flatMap { URL(string: $0) }
        )
    }
}

/// The artists pinned to the top of Music Home, oldest first. They belong to the app, not to the account: sign-out
/// and an account switch leave them alone, because an artist is a public channel. The rules (repeats, the cap,
/// refreshed names and photos) live here; `save` hears the whole list after every change so the app can keep it
/// in settings.
@MainActor
@Observable
final class MusicPinnedArtists {
    /// The most artists Home holds.
    static let limit = 20
    static let shelfTitle = "Pinned artists"

    private(set) var artists: [MusicPinnedArtist]

    @ObservationIgnored private let save: @MainActor ([MusicPinnedArtist]) -> Void

    init(artists: [MusicPinnedArtist] = [], save: @escaping @MainActor ([MusicPinnedArtist]) -> Void = { _ in }) {
        // A file edited by hand may hold repeats, blank ids or more than the cap. It is tidied here and not written back.
        var seen = Set<String>()
        self.artists = Array(artists.filter { !$0.browseId.isEmpty && seen.insert($0.browseId).inserted }.prefix(Self.limit))
        self.save = save
    }

    var isFull: Bool { artists.count >= Self.limit }

    func isPinned(_ browseId: String) -> Bool {
        artists.contains { $0.browseId == browseId }
    }

    /// A pinned artist can always be unpinned; a new one needs room.
    func canToggle(_ browseId: String) -> Bool {
        isPinned(browseId) || !isFull
    }

    /// Appends the artist. Refused, with nothing saved, when it is already pinned or Home is full.
    @discardableResult
    func pin(_ artist: MusicPinnedArtist) -> Bool {
        guard !artist.browseId.isEmpty, !isPinned(artist.browseId), !isFull else { return false }
        artists.append(artist)
        save(artists)
        return true
    }

    @discardableResult
    func unpin(_ browseId: String) -> Bool {
        guard let index = artists.firstIndex(where: { $0.browseId == browseId }) else { return false }
        artists.remove(at: index)
        save(artists)
        return true
    }

    /// The page button: pins an artist that is not pinned, unpins one that is.
    func toggle(_ artist: MusicPinnedArtist) {
        if isPinned(artist.browseId) { unpin(artist.browseId) } else { pin(artist) }
    }

    /// An artist's page loaded: keeps the stored title current. A blank title never replaces what is stored, and an
    /// artist that is not pinned is left alone. The photo only fills in a pin that has none: the page that loaded
    /// may have been opened from a small Library row, or carry the wide banner, and neither beats the avatar the
    /// pin was made with.
    @discardableResult
    func refresh(_ latest: MusicPinnedArtist) -> Bool {
        guard let index = artists.firstIndex(where: { $0.browseId == latest.browseId }) else { return false }
        var updated = artists[index]
        if !latest.title.isEmpty { updated.title = latest.title }
        if updated.thumbnailURL?.isEmpty ?? true, let photo = latest.thumbnailURL, !photo.isEmpty {
            updated.thumbnailURL = photo
        }
        guard updated != artists[index] else { return false }
        artists[index] = updated
        save(artists)
        return true
    }

    /// Everything went back to its default. The settings were cleared already, so nothing is written here.
    func settingsDidReset() {
        artists = []
    }

    /// The row at the top of Home. Nil while nothing is pinned, so Home never shows an empty row.
    var shelf: MusicShelf? {
        artists.isEmpty ? nil : MusicShelf(title: Self.shelfTitle, items: artists.map { .collection($0.collection) })
    }
}
