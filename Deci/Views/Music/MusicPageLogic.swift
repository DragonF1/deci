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

    /// The cover's side in the compact header: art on the left, the title and actions on its right.
    var artSize: CGFloat { 104 }

    /// The header block, the first item of the scroll view: the art with its gaps above and below.
    var heroHeight: CGFloat { artSize + 4 + 12 }

    /// How far down the cover's wash reaches from the top of the content area before it is clear.
    var washDepth: CGFloat { heroHeight + 40 }

    /// An artist's photo is round; every other cover is a rounded square.
    var isRound: Bool { self == .artist }

    /// The gap between the header and the first list, and how tall that gap is when a sort note takes it.
    static let listGap: CGFloat = 4
    static let sortNoteBlock: CGFloat = 24

    /// The gap between an artist's sections.
    static let artistBodyGap: CGFloat = MusicStyle.Spacing.sectionGap
}

// MARK: - Colours

/// The colours a page wears: the page colour and a light one. The header's wash is made from them. They come from the
/// cover's tint, except on Liked music, which keeps its red.
struct MusicPagePalette: Equatable {
    let page: Color
    let light: Color

    init(tint: MusicTint) {
        page = tint.page
        light = tint.light
    }

    private init(page: Color, light: Color) {
        self.page = page
        self.light = light
    }

    /// Liked music always uses these.
    static let liked = MusicPagePalette(
        page: MusicStyle.Palette.hex(0x4F1B24),
        light: MusicStyle.Palette.hex(0xFFB3BE)
    )

    /// The soft wash behind a page's header: the dark page colour on a dark popover, the pale light colour on a light
    /// one, so it reads in both.
    func wash(for scheme: ColorScheme) -> Color {
        scheme == .dark ? page.opacity(0.85) : light.opacity(0.55)
    }

    /// The palette of a page: the fixed red for Liked music, else the cover's tint, or `fallback` (the tint of the
    /// page's id) until the cover's colour is known.
    static func resolve(kind: MusicPageKind, coverTint: MusicTint?, fallback: MusicTint) -> MusicPagePalette {
        kind == .liked ? .liked : MusicPagePalette(tint: coverTint ?? fallback)
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
        let isActive: Bool
    }

    static func sortPill(_ sort: MusicPlaylistSort) -> SortPill {
        if sort.isDefault {
            return SortPill(label: "Sort", symbol: "arrow.up.arrow.down", isActive: false)
        }
        return SortPill(
            label: sort.field.label,
            symbol: sort.ascending ? "arrow.up" : "arrow.down",
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
    /// The nav row's title fades in (and the header's wash out) over this many points of scrolling.
    static let barFade: CGFloat = 24

    /// The nav row with the back button: a Mixer header row.
    static let barHeight: CGFloat = 30

    /// How opaque the nav row's title is at a scroll offset: clear while the header still reaches under the nav row,
    /// solid `barFade` points after it stops doing so.
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
