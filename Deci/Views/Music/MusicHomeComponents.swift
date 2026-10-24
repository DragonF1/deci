// Deci/Views/Music/MusicHomeComponents.swift
import SwiftUI

// MARK: - Logic

/// How a Home shelf is drawn. A shelf of songs only is the Quick picks list; every other shelf, Listen again first among
/// them, is a row of cover tiles. Kept apart from the view so it is tested.
nonisolated enum MusicHomeSectionStyle: Equatable {
    case quickPicks
    case tiles

    static func styles(for shelves: [MusicShelf]) -> [MusicHomeSectionStyle] {
        shelves.map { shelf in
            if isListenAgain(shelf) { return .tiles }
            return isSongsOnly(shelf) ? .quickPicks : .tiles
        }
    }

    static func isSongsOnly(_ shelf: MusicShelf) -> Bool {
        !shelf.items.isEmpty && shelf.items.allSatisfy { item in
            if case .track = item { return true }
            return false
        }
    }

    /// The shelf the design calls Listen again keeps its tiles, even when it holds songs only.
    static func isListenAgain(_ shelf: MusicShelf) -> Bool {
        shelf.title.localizedCaseInsensitiveContains("listen again")
    }
}

/// The second lines of Home's cards and rows.
nonisolated enum MusicHomeText {
    /// YouTube's own second line uses a bullet ("Album • Daft Punk • 2013"); the design uses a middle dot.
    static func subtitle(_ youtubeSubtitle: String) -> String {
        youtubeSubtitle.replacingOccurrences(of: " \u{2022} ", with: " \u{00B7} ")
    }

    /// The second line of a Library row: the kind first ("Playlist · 42 songs", "Album · artist", "Artist"), then
    /// whatever YouTube says of it. YouTube's line is kept, so an artist keeps its song count and a playlist its owner;
    /// the kind is not repeated when YouTube's line already starts with it as a whole word ("Albums by X" does not).
    static func librarySubtitle(kind: MusicCollection.Kind, youtubeSubtitle: String) -> String {
        let word = switch kind {
        case .playlist: "Playlist"
        case .album: "Album"
        case .artist: "Artist"
        }
        let line = subtitle(youtubeSubtitle).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return word }
        if let found = line.range(of: word, options: [.caseInsensitive, .anchored]),
           line[found.upperBound...].first.map({ !$0.isLetter }) ?? true {
            return line
        }
        return word + " \u{00B7} " + line
    }
}

// MARK: - Headers

/// A section title: 13 pt semibold, and at the trailing end an optional "See all" link in the quiet second line colour.
struct MusicSectionHeader: View {
    let title: String
    /// The link at the trailing end and what it does; both or neither.
    var linkTitle: String?
    var linkAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .musicText(MusicStyle.Typeface.heading)
                .foregroundStyle(MusicStyle.Palette.textHeading)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let linkTitle, let linkAction {
                Button(action: linkAction) {
                    Text(linkTitle)
                        .musicText(MusicStyle.Typeface.seeAll)
                        .foregroundStyle(MusicStyle.Palette.textMeta)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(linkTitle), \(title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MusicStyle.Spacing.page)
    }
}

// MARK: - State cards

/// What a loading, empty or failed list shows where its content would be: plain centred text, no card. `minHeight`
/// keeps it at the height its screen draws it; without one it hugs its content. `margin` is the space on both sides
/// (the page's margin; the lyrics lines area keeps a wider one).
struct MusicStateCard<Content: View>: View {
    var minHeight: CGFloat?
    var margin: CGFloat
    @ViewBuilder let content: Content

    init(minHeight: CGFloat? = nil, margin: CGFloat = MusicStyle.Spacing.page, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.margin = margin
        self.content = content()
    }

    var body: some View {
        VStack(spacing: MusicStyle.Spacing.sectionContent) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.lg)
        .frame(minHeight: minHeight)
        .padding(.horizontal, margin)
    }
}

extension MusicStateCard where Content == MusicStateCardMessage {
    /// A card that says one thing.
    init(message: String, minHeight: CGFloat? = nil, margin: CGFloat = MusicStyle.Spacing.page) {
        self.init(minHeight: minHeight, margin: margin) { MusicStateCardMessage(text: message) }
    }
}

/// What a state card says: 12 pt at half white.
struct MusicStateCardMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .musicText(MusicStyle.Typeface.stateMessage)
            .foregroundStyle(MusicStyle.Palette.textSub)
            .multilineTextAlignment(.center)
    }
}

/// The round badge of a state that has a screen to itself (signed out, empty): a faint filled circle with a hairline
/// ring and a symbol in it at 70% white. With no symbol it is the bare circle, for a spinner laid over it.
struct MusicStateIconCircle: View {
    let symbol: String?
    var size: CGFloat = 52
    var symbolSize: CGFloat = 22

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(Color.white.opacity(MusicStyle.Opacity.pageSub))
            }
        }
        .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(MusicStyle.Opacity.segmentTrack)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A spinner on a state card.
struct MusicLoadingCard: View {
    var body: some View {
        MusicStateCard {
            MusicSpinner()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// A list that failed to load: the warning, the message and a small Retry button.
struct MusicFailedCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        MusicStateCard {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(MusicStyle.Palette.textSub)
                .accessibilityHidden(true)
            MusicStateCardMessage(text: message)
            MusicRetryPill(action: retry)
        }
    }
}

/// The small outlined Retry pill of a failed list: a hairline capsule, no fill.
struct MusicRetryPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                Text("Retry")
                    .musicText(MusicStyle.Typeface.button)
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: 24)
            .overlay(Capsule(style: .continuous).strokeBorder(MusicStyle.Palette.strokeButton, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hover

/// The hover of a tile: the row hover surface behind it, a little wider than the tile. The surface draws
/// `overflow` outside the tile's layout, so a scroll view around tiles has to leave that much room (`MusicHorizontalShelf`).
private struct MusicTileHover: ViewModifier {
    static let overflow = DesignTokens.Spacing.xs

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(Self.overflow)
            .background(
                RoundedRectangle(cornerRadius: MusicBrowseLayout.rowHoverRadius, style: .continuous)
                    .fill(isHovered ? MusicStyle.Palette.rowHover : .clear)
            )
            .padding(-Self.overflow)
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// A sideways row of tiles that starts one page margin in and scrolls under the popover edge. The page padding is
/// inside the scroll, so the first and last tile rest a margin from the edge and the rest slides past it. The tiles'
/// hover surface reaches outside them, which a scroll view can cut off: the scroll gets the same room inside, and its
/// layout is trimmed back by it, so the hover is never cropped and the shelf still takes only the tiles' height.
struct MusicHorizontalShelf<Content: View>: View {
    var spacing: CGFloat = MusicBrowseLayout.tileGap
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) {
                content
            }
            .padding(.horizontal, MusicStyle.Spacing.page)
            .padding(.vertical, MusicTileHover.overflow)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
        .padding(.vertical, -MusicTileHover.overflow)
    }
}

extension View {
    /// A cover gets the hover surface behind it under the pointer.
    func musicTileHover() -> some View {
        modifier(MusicTileHover())
    }
}

// MARK: - Tile menus

/// The right click menu of a playlist, album or artist tile or row: the same words, order and symbols as a song's menu.
/// An album offers Save to playlist, Pin to Home, Go to album and Go to artist; a playlist or mix, Save to playlist and
/// Pin to Home; an artist, Pin to Home and Go to artist. With nothing to offer the tile gets no menu at all.
private struct MusicCollectionMenuModifier: ViewModifier {
    let collection: MusicCollection
    @Environment(\.musicCollectionPin) private var collectionPin
    @Environment(\.musicTrackContext) private var context

    @ViewBuilder
    func body(content: Content) -> some View {
        if let collectionPin, case let actions = collectionPin.actions(collection, context), !actions.isEmpty {
            content.contextMenu {
                MusicTrackMenuItems(actions: actions) { collectionPin.perform($0, collection, context) }
            }
        } else {
            content
        }
    }
}

/// The right click menu of a song tile: the song's own menu, the one its row in Quick picks has. A pinned song's menu
/// holds Unpin from Home in the place of Pin to Home, so the pinned row needs no entry of its own.
private struct MusicTrackMenuModifier: ViewModifier {
    let track: MusicTrack
    @Environment(\.musicTrackMenu) private var menu
    @Environment(\.musicTrackContext) private var context

    @ViewBuilder
    func body(content: Content) -> some View {
        if let menu, case let actions = menu.actions(track, context), !actions.isEmpty {
            content
                .onHover { if $0 { menu.reveal(track, context) } }
                .contextMenu {
                    MusicTrackMenuItems(actions: actions) { menu.perform($0, track, context) }
                }
        } else {
            content
        }
    }
}

extension View {
    func musicCollectionMenu(_ collection: MusicCollection) -> some View {
        modifier(MusicCollectionMenuModifier(collection: collection))
    }

    func musicTrackMenu(_ track: MusicTrack) -> some View {
        modifier(MusicTrackMenuModifier(track: track))
    }
}

// MARK: - Tiles

/// A square cover with a title and a second line, for Listen again and the other tile shelves, and the Albums grid.
/// The cover is 68 pt on Home and 70 pt in the grid and on an artist's shelves.
struct MusicCoverTile: View {
    let title: String
    let subtitle: String
    let thumbnailURL: URL?
    var size: CGFloat = MusicBrowseLayout.homeTile
    var circular = false
    var placeholder = "music.note"
    var isPinned = false
    var isCurrent = false
    var isPlaying = false
    let action: () -> Void

    @Environment(\.musicAccent) private var accent
    @Environment(\.musicHighlightTerms) private var highlightTerms

    var body: some View {
        Button(action: action) {
            VStack(alignment: circular ? .center : .leading, spacing: MusicBrowseLayout.tileTextGap) {
                MusicThumbnail(
                    url: thumbnailURL,
                    size: size,
                    circular: circular,
                    placeholder: placeholder,
                    cornerRadius: MusicStyle.Radius.art
                )
                .overlay {
                    if isCurrent { MusicPlayingOverlay(isPlaying: isPlaying, circular: circular, symbolSize: 18, radius: MusicStyle.Radius.art) }
                }
                .overlay {
                    if circular {
                        Circle().strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                    } else {
                        RoundedRectangle(cornerRadius: MusicStyle.Radius.art, style: .continuous)
                            .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                    }
                }
                .musicPinBadge(isPinned, coverSize: size, circular: circular, diameter: 14, inset: circular ? 6 : 3)

                VStack(alignment: circular ? .center : .leading, spacing: 0) {
                    Text.highlighted(title, terms: highlightTerms, color: accent.solid)
                        .musicText(MusicStyle.Typeface.secondaryMedium)
                        .foregroundStyle(isCurrent ? accent.solid : MusicStyle.Palette.textTile)
                        .lineLimit(1)
                    Text.highlighted(subtitle.isEmpty ? " " : subtitle, terms: highlightTerms, color: accent.solid)
                        .musicText(MusicStyle.Typeface.caption)
                        .foregroundStyle(MusicStyle.Palette.textMeta)
                        .lineLimit(1)
                }
            }
            .frame(width: size, alignment: circular ? .center : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .musicTileHover()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        var text = subtitle.isEmpty ? title : "\(title), \(subtitle)"
        if isPinned { text += ", pinned" }
        if isPlaying { text += ", playing" }
        return text
    }
}

/// A pinned item on Home: a small photo with the name under it, the same size for every kind so the row lines up.
/// An artist's photo is round; a playlist, an album and a song show a rounded square cover.
struct MusicPinnedTile: View {
    let item: MusicPinnedItem
    let action: () -> Void

    var body: some View {
        let circular = item.kind == .artist
        Button(action: action) {
            VStack(spacing: MusicBrowseLayout.tileTextGap) {
                MusicThumbnail(
                    url: item.photoURL,
                    size: MusicStyle.Size.pinnedPhoto,
                    circular: circular,
                    placeholder: item.kind.placeholderSymbol,
                    cornerRadius: circular ? nil : MusicStyle.Radius.small
                )
                Text(item.title)
                    .musicText(MusicStyle.Typeface.caption)
                    .foregroundStyle(MusicStyle.Palette.textTile)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: MusicStyle.Size.pinnedTileWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .musicTileHover()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        guard let subtitle = item.subtitle, !subtitle.isEmpty else { return item.title }
        return "\(item.title), \(MusicHomeText.subtitle(subtitle))"
    }
}

extension MusicPinnedItem.Kind {
    /// The symbol a tile shows until its photo loads.
    var placeholderSymbol: String {
        switch self {
        case .artist: MusicCollection.Kind.artist.placeholderSymbol
        case .playlist: MusicCollection.Kind.playlist.placeholderSymbol
        case .album: MusicCollection.Kind.album.placeholderSymbol
        case .song: "music.note"
        }
    }
}
