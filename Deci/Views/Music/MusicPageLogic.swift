// Deci/Views/Music/MusicPageLogic.swift
import SwiftUI

// The rules of the detail pages (Album, Artist, Playlist, Liked music) kept apart from the views, so they are tested
// without drawing anything: which kind a page is, which buttons it shows, what its header says, and the ink on the
// white Play button.

/// The four faces a page takes. Liked music is a playlist, but it has its own art and header text.
enum MusicPageKind: Equatable, Sendable {
    case album
    case artist
    case playlist
    case liked

    /// The kind of the page a collection opens. Liked music is told by its browse id.
    @MainActor
    static func resolve(kind: MusicCollection.Kind, browseId: String) -> MusicPageKind {
        switch kind {
        case .album: .album
        case .artist: .artist
        case .playlist: browseId == MusicBrowseStore.likedMusic.browseId ? .liked : .playlist
        }
    }

    /// An artist's photo is round; every other cover is a rounded square.
    var isRound: Bool { self == .artist }

    /// The row an album's, a playlist's or Liked music's song `index` (from 0) is drawn as: an album numbers its
    /// tracks, Liked music adds the heart, the rest are plain rows with a cover.
    func rowLayout(at index: Int) -> MusicSongRowLayout {
        switch self {
        case .album: .album(number: index + 1)
        case .liked: .liked
        case .artist, .playlist: .playlist
        }
    }
}

// MARK: - Ink on a fill

/// The ink for text and icons on a solid fill of a colour the app does not choose, like the system accent: white, which
/// is what the Mac puts on its blue, graphite, green and orange buttons, or black where white would all but vanish
/// (the yellow accent).
enum MusicInk: Equatable, Sendable {
    case white
    case black

    /// White keeps the fill until its contrast ratio against it (WCAG 2) falls under this.
    static let whiteContrastFloor = 2.0

    var color: Color { self == .white ? .white : .black }

    /// The ink for a fill given by its sRGB components (0 to 1). Anything out of range is clamped, and a component that
    /// is not a number counts as 0.
    static func onFill(red: Double, green: Double, blue: Double) -> MusicInk {
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let whiteContrast = 1.05 / (luminance + 0.05)
        return whiteContrast < whiteContrastFloor ? .black : .white
    }

    private static func linear(_ component: Double) -> Double {
        guard component.isFinite else { return 0 }
        let value = min(max(component, 0), 1)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

// MARK: - Pills

/// The buttons of a page's action row.
enum MusicPagePill: Hashable, Sendable {
    case play
    case shuffle
    /// The round button with the menu of the page's own actions.
    case more
}

/// One entry of the page's "..." menu. Only what the app can really do is here: pin to Home (an artist, a playlist
/// or an album).
enum MusicPageMenuItem: Hashable, Sendable {
    case pinHome(MusicHomePinState)

    var title: String {
        switch self {
        case .pinHome(let state): state.title
        }
    }

    /// Off while Home is full and this page is not pinned yet.
    var isEnabled: Bool {
        switch self {
        case .pinHome(let state): state.isEnabled
        }
    }
}

enum MusicPagePills {
    /// The pills a page shows, in order. Play and Shuffle need songs to act on, and an artist's page has no list to
    /// shuffle through. The round menu button is there only when the page has an action to put in it.
    static func pills(kind: MusicPageKind, hasTracks: Bool, hasMenuItems: Bool) -> [MusicPagePill] {
        var pills: [MusicPagePill] = []
        if hasTracks {
            pills.append(.play)
            if kind != .artist { pills.append(.shuffle) }
        }
        if hasMenuItems { pills.append(.more) }
        return pills
    }

    /// The page's menu: the Home pin. `home` is nil where Home cannot hold the page (Liked Music, which belongs to
    /// the account and has no cover of its own), and that pin is then left out. So is the pin of an artist's songs
    /// list, which a pinned tile would reopen as a plain playlist.
    static func menuItems(kind: MusicPageKind, home: MusicHomePinState?, isArtistSongs: Bool = false) -> [MusicPageMenuItem] {
        var items: [MusicPageMenuItem] = []
        if kind != .liked, !isArtistSongs, let home {
            items.append(.pinHome(home))
        }
        return items
    }
}

/// The "Top songs" header of an artist's page and its "Show all" link to the artist's list of all their songs.
enum MusicTopSongsHeader {
    static let title = "Top songs"
    static let linkTitle = "Show all"

    /// What the link opens: the artist's songs list, marked as such and titled "<Artist> songs". Nil, so no link, when
    /// the page is not an artist's or names no such list.
    static func opener(for page: MusicBrowsePage, kind: MusicPageKind) -> MusicCollection? {
        guard kind == .artist, let browseId = page.allSongsBrowseId, !browseId.isEmpty else { return nil }
        let name = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return MusicCollection(
            browseId: browseId,
            kind: .playlist,
            title: name.isEmpty ? "Songs" : "\(name) songs",
            subtitle: "",
            thumbnailURL: page.thumbnailURL,
            isArtistSongs: true
        )
    }
}

/// The line under a sorted page's sort bar.
enum MusicSortNote: Equatable {
    case none
    /// The sort waits for the rest of the songs.
    case loadingAll
    /// The sort covers only the start of a long playlist.
    case limited(Int)

    static func resolve(isLoadingAll: Bool, sortLimit: Int?) -> MusicSortNote {
        if isLoadingAll { return .loadingAll }
        if let sortLimit { return .limited(sortLimit) }
        return .none
    }

    static func limitText(_ count: Int) -> String {
        count == 1 ? "First song" : "First \(count) songs"
    }
}

// MARK: - Header text

/// The lines of a page's header, beside its art: a small uppercase kicker, the title, a line under it and a grey meta
/// line. Every line but the kicker and the title may be absent.
struct MusicPageHeroText: Equatable {
    let kicker: String
    let title: String
    let sub: String?
    let meta: String?

    static let likedTitle = "Liked music"
    static let likedSub = "Songs you like on YouTube Music"
    static let madeByYou = "Made by you"

    private static let separator = " \u{00B7} "

    /// The title a page's header shows: an artist's songs list takes the title of the link that opened it ("Daft Punk
    /// songs"), which names the artist whatever the list calls itself; every other page keeps its own.
    static func shownTitle(pageTitle: String, opener: MusicCollection) -> String {
        guard opener.isArtistSongs else { return pageTitle }
        let title = opener.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? pageTitle : title
    }

    /// YouTube's second line has a bullet between its parts; the design has a middle dot.
    static func dotted(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: " \u{2022} ", with: separator)
    }

    /// The parts of YouTube's second line, trimmed, without empty ones.
    static func parts(_ text: String?) -> [String] {
        (dotted(text) ?? "").components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The header's lines for a page.
    /// - Album: its kind (ALBUM, SINGLE or EP, as YouTube says), the album's artist (the first song's), then the year,
    ///   the number of songs and the length.
    /// - Artist: ARTIST, the subscriber line YouTube gives, and the number of albums.
    /// - Playlist: PLAYLIST, "Made by you" on one the user can edit, else its owner, then the count and the length.
    /// - Liked music: AUTO PLAYLIST, its fixed title and line, then the count and the length.
    ///
    /// `songCount`, `totalSeconds` and `albumCount` are only given when the app knows them for certain (the whole list
    /// is loaded, every song has a length); a count or a length YouTube's own line already has is not repeated.
    static func resolve(
        kind: MusicPageKind,
        title: String,
        subtitle: String?,
        firstArtist: String?,
        isEditable: Bool,
        songCount: Int?,
        totalSeconds: Int?,
        albumCount: Int?
    ) -> MusicPageHeroText {
        var rest = parts(subtitle)
        switch kind {
        case .album:
            var kicker = "ALBUM"
            if let first = rest.first, isKindWord(first, ["Album", "Single", "EP"]) {
                kicker = first.uppercased()
                rest.removeFirst()
            }
            let artist = firstArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sub = artist?.isEmpty == false ? artist : nil
            if let sub { rest.removeAll { $0 == sub } }
            return MusicPageHeroText(
                kicker: kicker,
                title: title,
                sub: sub,
                meta: meta(rest, songCount: songCount, totalSeconds: totalSeconds)
            )
        case .artist:
            if let first = rest.first, isKindWord(first, ["Artist"]) { rest.removeFirst() }
            let audience = rest.first { part in
                let lower = part.lowercased()
                return lower.contains("subscriber") || lower.contains("listener") || lower.contains("audience")
            }
            let albums = albumCount.flatMap { $0 > 0 ? "\($0) \($0 == 1 ? "album" : "albums")" : nil }
            return MusicPageHeroText(kicker: "ARTIST", title: title, sub: audience ?? rest.first, meta: albums)
        case .playlist, .liked:
            if let first = rest.first, isKindWord(first, ["Playlist", "Auto playlist"]) { rest.removeFirst() }
            let ownerParts = rest.prefix { $0.first?.isNumber != true }
            rest.removeFirst(ownerParts.count)
            let owner = ownerParts.isEmpty ? nil : ownerParts.joined(separator: separator)
            let counted = meta(rest, songCount: songCount, totalSeconds: totalSeconds)
            if kind == .liked {
                return MusicPageHeroText(kicker: "AUTO PLAYLIST", title: likedTitle, sub: likedSub, meta: counted)
            }
            return MusicPageHeroText(
                kicker: "PLAYLIST",
                title: title,
                sub: isEditable ? madeByYou : owner,
                meta: counted
            )
        }
    }

    /// The parts YouTube gave, then the count and the length where it gave none.
    private static func meta(_ given: [String], songCount: Int?, totalSeconds: Int?) -> String? {
        var parts = given
        if let songCount, songCount > 0, !parts.contains(where: mentionsCount) {
            parts.append("\(songCount) \(songCount == 1 ? "song" : "songs")")
        }
        if let totalSeconds, totalSeconds > 0, !parts.contains(where: mentionsLength) {
            parts.append(MusicPageDuration.text(seconds: totalSeconds))
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    private static func isKindWord(_ part: String, _ words: [String]) -> Bool {
        words.contains { part.caseInsensitiveCompare($0) == .orderedSame }
    }

    private static func mentionsCount(_ part: String) -> Bool {
        let lower = part.lowercased()
        return lower.contains("song") || lower.contains("track")
    }

    private static func mentionsLength(_ part: String) -> Bool {
        let lower = part.lowercased()
        return lower.contains("hour") || lower.contains("minute") || lower.contains(" min") || lower.contains(" hr")
    }

    /// The albums an artist's page lists: the size of its Albums shelf, nil when it has none.
    static func albumCount(in shelves: [MusicShelf]) -> Int? {
        let albums = shelves.first { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Albums") == .orderedSame }
        guard let albums else { return nil }
        let count = albums.items.filter { item in
            if case .collection = item { return true }
            return false
        }.count
        return count > 0 ? count : nil
    }
}

/// A page's total length as the header says it.
nonisolated enum MusicPageDuration {
    /// "38 min", "1 hr", "2 hr 31 min": whole minutes, rounded, at least one.
    static func text(seconds: Int) -> String {
        let minutes = max(1, (max(seconds, 0) + 30) / 60)
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// The sum of the songs' lengths, or nil while it would be a guess: the list is not all loaded, it is empty, or a
    /// song has no length.
    static func total(of durations: [Int?], isComplete: Bool) -> Int? {
        guard isComplete, !durations.isEmpty else { return nil }
        var total = 0
        for duration in durations {
            guard let duration, duration > 0 else { return nil }
            total += duration
        }
        return total
    }
}
