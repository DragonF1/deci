// Deci/Views/Music/MusicPageLogic.swift
import SwiftUI

// The rules of the detail pages (Album, Artist, Playlist, Liked music) kept apart from the views, so they are tested
// without drawing anything: which kind a page is, its measures, which pills it shows, what its hero says, and how
// its colours follow the cover.

/// The four faces a page takes. Liked music is a playlist, but it has its own hero and fixed colours.
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

    /// The part of the hero that shows the cover or the photo. It is clipped there.
    var visualHeight: CGFloat { self == .artist ? 244 : 260 }

    /// The whole hero, the first item of the scroll view: the visual and, over its bottom edge, the title block and
    /// the pills. The artist's hero ends where the body starts.
    var heroHeight: CGFloat { self == .artist ? 246 : 288 }

    /// How far above the bottom of the visual the cover's top edge sits, for a cover as wide as the mock's 510.
    var coverRise: CGFloat { self == .artist ? 414 : 360 }

    /// The cover is as wide as the popover, so every measure of it scales by `width / 510`.
    static let mockWidth: CGFloat = 510

    /// The top edge of the cover in the hero, which is above the popover: only the lower part of it shows.
    func coverTop(width: CGFloat) -> CGFloat {
        visualHeight - coverRise * (width / Self.mockWidth)
    }

    /// The fade that dissolves the cover into the page colour: the colour's opacity at each point of the hero's height.
    var fadeStops: [(location: Double, opacity: Double)] {
        switch self {
        case .album: [(0, 0), (0.45, 0.5), (0.75, 0.94), (1, 1)]
        case .artist: [(0, 0), (0.5, 0.12), (0.82, 0.62), (1, 1)]
        case .playlist, .liked: [(0, 0), (0.4, 0), (0.7, 0.62), (1, 1)]
        }
    }

    /// Where the page colour starts to turn into the darker bottom colour, as a fraction of the popover's height.
    /// A playlist darkens all the way down.
    var backgroundHold: Double {
        switch self {
        case .album, .liked: 0.5
        case .artist: 0.46
        case .playlist: 0
        }
    }

    /// The popover y where the gap between the hero and the first list starts, and how tall that gap is. A sort note
    /// takes the room the playlist's songs are pushed down by.
    static let listGap: CGFloat = 12
    static let sortNoteBlock: CGFloat = 32

    /// The artist's body has this margin on both sides and this gap between its sections.
    static let artistBodyGap: CGFloat = 20
}

// MARK: - Colours

/// The colours a page wears: the page and its darker bottom, the light colour of the Play pill and the accent text,
/// and the ink on the light one. They come from the cover's tint, except on Liked music, which keeps its red.
struct MusicPagePalette: Equatable {
    let page: Color
    let pageBottom: Color
    let light: Color
    let ink: Color
    /// The colour of the line under the title: the light colour, except on Liked music.
    let accentText: Color

    init(tint: MusicTint) {
        page = tint.page
        pageBottom = tint.pageBottom
        light = tint.light
        ink = tint.ink
        accentText = tint.light
    }

    private init(page: Color, pageBottom: Color, light: Color, ink: Color, accentText: Color) {
        self.page = page
        self.pageBottom = pageBottom
        self.light = light
        self.ink = ink
        self.accentText = accentText
    }

    /// Liked music always uses these.
    static let liked = MusicPagePalette(
        page: MusicStyle.Palette.hex(0x4F1B24),
        pageBottom: MusicStyle.Palette.hex(0x200A0F),
        light: MusicStyle.Palette.hex(0xFFB3BE),
        ink: MusicStyle.Palette.hex(0x3A0A12),
        accentText: MusicStyle.Palette.hex(0xFFA3B1)
    )

    /// The Play pill of an artist is the same pale blue on every artist.
    static let artistPlayFill = MusicStyle.Palette.hex(0xBCD9EE)
    static let artistPlayInk = MusicStyle.Palette.hex(0x0E2233)

    /// The palette of a page: the fixed red for Liked music, else the cover's tint, or `fallback` (the tint of the
    /// page's id) until the cover's colour is known.
    static func resolve(kind: MusicPageKind, coverTint: MusicTint?, fallback: MusicTint) -> MusicPagePalette {
        kind == .liked ? .liked : MusicPagePalette(tint: coverTint ?? fallback)
    }
}

// MARK: - Pills

/// The buttons of a page's action row.
enum MusicPagePill: Hashable, Sendable {
    case play
    case shuffle
    case sort
    /// The artist's "Pin to Home" pill.
    case pinHome
    /// The round pin of a playlist or album: it pins to Listen again.
    case pinListenAgain
}

enum MusicPagePills {
    /// The pills a page shows, in order. Play, Shuffle and Sort need songs to act on. An artist's page has no list to
    /// shuffle through, and only playlists sort (an album keeps its order). The Home pin is always there on an artist's
    /// page; the Listen again pin only where YouTube offers one.
    static func pills(kind: MusicPageKind, hasTracks: Bool, canSort: Bool, hasListenAgainPin: Bool) -> [MusicPagePill] {
        var pills: [MusicPagePill] = []
        if hasTracks {
            pills.append(.play)
            if kind != .artist { pills.append(.shuffle) }
            if canSort, kind == .playlist || kind == .liked { pills.append(.sort) }
        }
        switch kind {
        case .artist:
            pills.append(.pinHome)
        case .album, .playlist, .liked:
            if hasListenAgainPin { pills.append(.pinListenAgain) }
        }
        return pills
    }

    /// What the Sort pill shows: "Sort" at rest, the key's name and the direction once a sort is picked.
    struct SortPill: Equatable {
        let label: String
        let symbol: String
        let symbolSize: CGFloat
        let isActive: Bool
    }

    static func sortPill(_ sort: MusicPlaylistSort) -> SortPill {
        if sort.isDefault {
            return SortPill(label: "Sort", symbol: "arrow.up.arrow.down", symbolSize: 16, isActive: false)
        }
        return SortPill(
            label: sort.field.label,
            symbol: sort.ascending ? "arrow.up" : "arrow.down",
            symbolSize: 15,
            isActive: true
        )
    }

    /// The label of the Home pin: it reads "Pinned" once the artist is on Home.
    static func pinLabel(isPinned: Bool) -> String {
        isPinned ? "Pinned" : "Pin to Home"
    }

    static func pinSymbol(isPinned: Bool) -> String {
        isPinned ? "pin.fill" : "pin"
    }

    /// What the Home pin's tooltip says; when Home is full and the artist is not pinned, it says why the pill is dimmed.
    @MainActor
    static func pinHelp(isPinned: Bool, isEnabled: Bool) -> String {
        if isPinned { return "Take this artist off Home." }
        return isEnabled
            ? "Show this artist at the top of Home."
            : "Home can hold \(MusicPinnedArtists.limit) pinned artists. Unpin one to pin another."
    }

    /// What VoiceOver calls the Home pin: the action, which the pill's own "Pinned" is not.
    static func pinAccessibilityLabel(isPinned: Bool, title: String) -> String {
        isPinned ? "Unpin \(title) from Home" : "Pin \(title) to Home"
    }
}

/// The line under a sorted playlist's pills.
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

// MARK: - Hero text

/// The lines of a hero: the title, the accent line under it and a grey meta line.
struct MusicPageHeroText: Equatable {
    let title: String
    let accent: String?
    let meta: String?

    static let likedTitle = "Liked music"
    static let likedAccent = "Auto playlist"

    /// YouTube's second line has a bullet between its parts; the design has a middle dot.
    static func dotted(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: " \u{2022} ", with: " \u{00B7} ")
    }

    /// The hero's lines for a page.
    /// - Album: the album's artist (the first song's) in the accent colour, and YouTube's line (kind, year, number of
    ///   songs) as the meta line, without the artist if YouTube repeats it there.
    /// - Artist: the name alone. YouTube's subscriber line is not shown.
    /// - Liked music: its fixed title, and "Auto playlist · N songs".
    /// - Playlist: YouTube's line ("Playlist · N songs") as the accent line.
    static func resolve(kind: MusicPageKind, title: String, subtitle: String?, firstArtist: String?) -> MusicPageHeroText {
        switch kind {
        case .album:
            let artist = firstArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
            let accent = artist?.isEmpty == false ? artist : nil
            var parts = (dotted(subtitle) ?? "").components(separatedBy: " \u{00B7} ").filter { !$0.isEmpty }
            if let accent { parts.removeAll { $0 == accent } }
            return MusicPageHeroText(
                title: title,
                accent: accent,
                meta: parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
            )
        case .artist:
            return MusicPageHeroText(title: title, accent: nil, meta: nil)
        case .liked:
            return MusicPageHeroText(title: likedTitle, accent: dotted(subtitle) ?? likedAccent, meta: nil)
        case .playlist:
            return MusicPageHeroText(title: title, accent: dotted(subtitle), meta: nil)
        }
    }
}

// MARK: - Scrolling

nonisolated enum MusicPageScroll {
    /// The bar behind the header and the nav row fades in over this many points of scrolling.
    static let barFade: CGFloat = 24

    /// The bar is as tall as the header strip and the nav row under it.
    static let barHeight: CGFloat = 72

    /// How opaque the top bar is at a scroll offset: clear while the hero still reaches under the nav row, solid
    /// `barFade` points after it stops doing so.
    static func barOpacity(offset: CGFloat, heroHeight: CGFloat) -> Double {
        guard offset.isFinite else { return 0 }
        let start = heroHeight - barHeight
        return Double(min(max((offset - start) / barFade, 0), 1))
    }
}

/// The cover the tint store is asked for. It stays the same URL for the whole life of a page, so the page's own
/// picture arriving later does not start a second fetch: the collection's picture if the collection has one, else
/// the page's.
nonisolated enum MusicPageCover {
    static func tintURL(page: URL?, collection: URL?) -> URL? {
        collection ?? page
    }
}
