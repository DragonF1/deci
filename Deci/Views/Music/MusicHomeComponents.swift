// Deci/Views/Music/MusicHomeComponents.swift
import SwiftUI

// MARK: - Logic

/// How a Home shelf is drawn. A shelf of songs only is the two column Quick picks; the first other shelf is the
/// row of Top Picks cards; every shelf after it is a row of cover tiles. Kept apart from the view so it is tested.
nonisolated enum MusicHomeSectionStyle: Equatable {
    case quickPicks
    case topPicks
    case coverTiles

    /// Songs the Quick picks list shows.
    static let maxQuickPicks = 8

    static func styles(for shelves: [MusicShelf]) -> [MusicHomeSectionStyle] {
        var hasTopPicks = false
        return shelves.map { shelf in
            if isSongsOnly(shelf) { return .quickPicks }
            if isListenAgain(shelf) { return .coverTiles }
            if hasTopPicks { return .coverTiles }
            hasTopPicks = true
            return .topPicks
        }
    }

    static func isSongsOnly(_ shelf: MusicShelf) -> Bool {
        !shelf.items.isEmpty && shelf.items.allSatisfy { item in
            if case .track = item { return true }
            return false
        }
    }

    /// The shelf the design calls Listen again keeps its tiles, so the pins made on it stay where the owner put them.
    static func isListenAgain(_ shelf: MusicShelf) -> Bool {
        shelf.title.localizedCaseInsensitiveContains("listen again")
    }

    /// The small uppercase line on a Top Picks card. YouTube gives no reason line, so it names what the card opens.
    static func kicker(for item: MusicShelfItem) -> String {
        switch item {
        case .track: "SONG"
        case .collection(let collection):
            switch collection.kind {
            case .playlist: "PLAYLIST"
            case .album: "ALBUM"
            case .artist: "ARTIST"
            }
        }
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

    /// "artist · album", or whichever of the two there is.
    static func songSubtitle(artist: String, album: String?) -> String {
        [artist, album ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Account card control

/// What a screen header's avatar button does: it opens and closes the account card, which the shell draws.
struct MusicAccountCardControl: Sendable {
    let isOpen: Bool
    let toggle: @MainActor () -> Void
}

private struct MusicAccountCardControlKey: EnvironmentKey {
    static let defaultValue: MusicAccountCardControl? = nil
}

extension EnvironmentValues {
    var musicAccountCard: MusicAccountCardControl? {
        get { self[MusicAccountCardControlKey.self] }
        set { self[MusicAccountCardControlKey.self] = newValue }
    }
}

// MARK: - Headers

/// The large title of a browse screen with the search button and the avatar. It scrolls away with the content.
struct MusicScreenHeader: View {
    let title: String
    let account: MusicAccount?
    /// Nil on Library, which has the avatar only.
    var onSearch: (() -> Void)?

    @Environment(\.musicAccountCard) private var accountCard

    var body: some View {
        HStack(spacing: MusicStyle.Spacing.sectionContent) {
            Text(title)
                .musicText(MusicStyle.Typeface.title1)
                .foregroundStyle(MusicStyle.Palette.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: MusicStyle.Spacing.sectionContent)
            if let onSearch {
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: MusicStyle.Size.screenHeaderButton, height: MusicStyle.Size.screenHeaderButton)
                        .background(Circle().fill(MusicStyle.Palette.fillControl))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
                .help("Search")
            }
            MusicAccountButton(account: account, isOpen: accountCard?.isOpen == true) {
                accountCard?.toggle()
            }
        }
        .padding(.horizontal, MusicStyle.Spacing.page)
        .frame(height: 36)
        .padding(.top, 8)
    }
}

/// A section title: 17 bold, 21 tall.
struct MusicSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .musicText(MusicStyle.Typeface.headline)
            .foregroundStyle(MusicStyle.Palette.textPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
            .padding(.horizontal, MusicStyle.Spacing.page)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - State cards

/// The card a loading, empty or failed list shows where its content would be. `minHeight` keeps a card at the height
/// its screen draws it (Search states are 72); without one it hugs its content.
struct MusicStateCard<Content: View>: View {
    var minHeight: CGFloat?
    @ViewBuilder let content: Content

    init(minHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        VStack(spacing: MusicStyle.Spacing.sectionContent) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .frame(minHeight: minHeight)
        .background(
            RoundedRectangle(cornerRadius: MusicStyle.Radius.stateCard, style: .continuous)
                .fill(MusicStyle.Palette.fillCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MusicStyle.Radius.stateCard, style: .continuous)
                .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
        )
        .padding(.horizontal, MusicStyle.Spacing.page)
    }
}

extension MusicStateCard where Content == MusicStateCardMessage {
    /// A card that says one thing.
    init(message: String, minHeight: CGFloat? = nil) {
        self.init(minHeight: minHeight) { MusicStateCardMessage(text: message) }
    }
}

struct MusicStateCardMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .musicText(MusicStyle.Typeface.body13)
            .foregroundStyle(MusicStyle.Palette.textSung)
            .multilineTextAlignment(.center)
    }
}

/// The spinner of the design: a faint ring with a white arc of a quarter turn that goes round once per 0.8 s. Sizes
/// and line widths in the mock: 11 / 1.2, 15 / 1.6, 20 / 2.2, 22 / 2.4, 30 / 3.3. It has no accessibility label of its
/// own: the card or row that holds it says what is loading.
struct MusicSpinner: View {
    var size: CGFloat = 22
    var lineWidth: CGFloat = 2.4

    private static let period: TimeInterval = 0.8

    /// Flips once on appear; the repeating linear animation does the turning, with no redraw of the view per frame.
    @State private var isTurning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(MusicStyle.Palette.sliderTrack, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(isTurning ? 360 : 0))
                .animation(.linear(duration: Self.period).repeatForever(autoreverses: false), value: isTurning)
        }
        // The ring sits inside its box, as drawn: its diameter is three quarters of the box.
        .frame(width: size * 0.75, height: size * 0.75)
        .frame(width: size, height: size)
        .onAppear { isTurning = true }
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

/// A list that failed to load: the warning, the message and a Retry pill.
struct MusicFailedCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        MusicStateCard {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18))
                .foregroundStyle(MusicStyle.Palette.textSecondary)
                .accessibilityHidden(true)
            MusicStateCardMessage(text: message)
            MusicRetryPill(action: retry)
        }
    }
}

struct MusicRetryPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                Text("Retry")
                    .musicText(MusicStyle.Typeface.button12)
            }
            .foregroundStyle(.white)
            .padding(.init(top: 5, leading: 10, bottom: 5, trailing: 12))
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(MusicStyle.Palette.fillControl3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hover

private struct MusicHoverScale: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.02 : 1)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// The hover of a list row as the design draws it: a rounded fill behind the row and its content nudged 6 in.
private struct MusicRowHover: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .padding(.leading, isHovered ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: MusicStyle.Radius.hoverRow, style: .continuous)
                    .fill(isHovered ? MusicStyle.Palette.fillHover : .clear)
            )
            .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}

extension View {
    /// The row under the pointer (or with the keyboard on it) gets the hover fill, and its content slides in by 6.
    func musicRowHover(_ isHovered: Bool) -> some View {
        modifier(MusicRowHover(isHovered: isHovered))
    }

    /// A cover or card grows by two percent under the pointer.
    func musicHoverScale() -> some View {
        modifier(MusicHoverScale())
    }
}

// MARK: - Tile menus

/// The right click menu of a Home tile: "Pin to Listen again" on a playlist or album, and "Unpin from Home" on a
/// pinned artist. With nothing to offer the tile gets no menu at all, as before.
private struct MusicCollectionMenuModifier: ViewModifier {
    let collection: MusicCollection
    var onUnpin: ((MusicCollection) -> Void)?
    @Environment(\.musicCollectionPin) private var collectionPin

    @ViewBuilder
    func body(content: Content) -> some View {
        let listenAgain = collectionPin?.pin(collection)
        if onUnpin != nil || listenAgain != nil {
            content.contextMenu {
                if let listenAgain, let collectionPin {
                    MusicListenAgainPinItem(toggle: listenAgain) { collectionPin.toggle(collection) }
                }
                if let onUnpin {
                    Button {
                        onUnpin(collection)
                    } label: {
                        Label("Unpin from Home", systemImage: "pin.slash")
                    }
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func musicCollectionMenu(_ collection: MusicCollection, onUnpin: ((MusicCollection) -> Void)? = nil) -> some View {
        modifier(MusicCollectionMenuModifier(collection: collection, onUnpin: onUnpin))
    }
}

// MARK: - Tiles and cards

/// A Top Picks card: the cover over a wash of its colour, with the kind, the title and a second line.
struct MusicTopPickCard: View {
    let kicker: String
    let title: String
    let subtitle: String
    let thumbnailURL: URL?
    /// Picks the colour of the card, the same one every run.
    let tintKey: String
    var isPinned = false
    var isCurrent = false
    var isPlaying = false
    let action: () -> Void

    var body: some View {
        let tint = MusicTint.forKey(tintKey)
        let width = MusicStyle.Size.topPickWidth
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                tint.page
                MusicThumbnail(url: thumbnailURL, size: width, cornerRadius: 0)
                    .overlay {
                        if isCurrent { MusicPlayingOverlay(isPlaying: isPlaying, symbolSize: 24) }
                    }
                LinearGradient(
                    stops: [
                        .init(color: tint.page.opacity(0), location: 0),
                        .init(color: tint.page.opacity(0.92), location: 0.5),
                        .init(color: tint.page, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: 124)
                .offset(y: 104)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kicker)
                        .musicText(MusicStyle.Typeface.kicker)
                        .foregroundStyle(MusicStyle.Palette.textOnCard)
                        .lineLimit(1)
                    Text(title)
                        .musicText(MusicStyle.Typeface.cardTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle.isEmpty ? " " : subtitle)
                        .musicText(MusicStyle.Typeface.caption12)
                        .foregroundStyle(MusicStyle.Palette.textOnCard)
                        .lineLimit(1)
                }
                .frame(width: width - 24, alignment: .leading)
                .offset(x: 12, y: 164)
            }
            .frame(width: width, height: MusicStyle.Size.topPickHeight)
            .clipShape(RoundedRectangle(cornerRadius: MusicStyle.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MusicStyle.Radius.card, style: .continuous)
                    .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
            )
            .musicPinBadge(isPinned, coverSize: width, diameter: 20, inset: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .musicHoverScale()
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

/// A square cover with a title and a second line, for Listen again and the other tile shelves.
struct MusicCoverTile: View {
    let title: String
    let subtitle: String
    let thumbnailURL: URL?
    var circular = false
    var placeholder = "music.note"
    var isPinned = false
    var isCurrent = false
    var isPlaying = false
    let action: () -> Void

    var body: some View {
        let size = MusicStyle.Size.coverTile
        Button(action: action) {
            VStack(alignment: circular ? .center : .leading, spacing: 6) {
                MusicThumbnail(
                    url: thumbnailURL,
                    size: size,
                    circular: circular,
                    placeholder: placeholder,
                    cornerRadius: MusicStyle.Radius.art
                )
                .overlay {
                    if isCurrent { MusicPlayingOverlay(isPlaying: isPlaying, circular: circular, symbolSize: 22, radius: MusicStyle.Radius.art) }
                }
                .overlay {
                    if circular {
                        Circle().strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                    } else {
                        RoundedRectangle(cornerRadius: MusicStyle.Radius.art, style: .continuous)
                            .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                    }
                }
                .musicPinBadge(isPinned, coverSize: size, circular: circular, diameter: 18, inset: circular ? 10 : 4)

                VStack(alignment: circular ? .center : .leading, spacing: 1) {
                    Text(title)
                        .musicText(MusicStyle.Typeface.caption12M)
                        .foregroundStyle(isCurrent ? MusicStyle.Palette.accent : .white)
                        .lineLimit(1)
                    Text(subtitle.isEmpty ? " " : subtitle)
                        .musicText(MusicStyle.Typeface.caption12)
                        .foregroundStyle(MusicStyle.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: size, alignment: circular ? .center : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .musicHoverScale()
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

/// A pinned artist on Home: a round photo with the name under it.
struct MusicPinnedArtistTile: View {
    let collection: MusicCollection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                MusicThumbnail(
                    url: collection.thumbnailURL,
                    size: MusicStyle.Size.pinnedPhoto,
                    circular: true,
                    placeholder: MusicCollection.Kind.artist.placeholderSymbol
                )
                Text(collection.title)
                    .musicText(MusicStyle.Typeface.caption11)
                    .foregroundStyle(MusicStyle.Palette.textTile)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: MusicStyle.Size.pinnedTileWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .musicHoverScale()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(collection.title)
        .accessibilityAddTraits(.isButton)
    }
}

/// One song of Quick picks: a small cover, the title, a second line and the song's "..." menu.
struct MusicQuickPickRow: View {
    let track: MusicTrack
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void

    @Environment(\.musicTrackMenu) private var menu
    @Environment(\.musicTrackContext) private var context

    private var offeredActions: [MusicTrackAction] { menu?.actions(track, context) ?? [] }
    private var isPinned: Bool { menu?.isPinned(track) == true }
    @State private var isHovered = false

    private func perform(_ action: MusicTrackAction) {
        menu?.perform(action, track, context)
    }

    var body: some View {
        let actions = offeredActions
        let size = MusicStyle.Size.quickPickArt
        HStack(spacing: 10) {
            MusicThumbnail(url: track.thumbnailURL, size: size, cornerRadius: MusicStyle.Radius.small)
                .overlay {
                    if isCurrent { MusicPlayingOverlay(isPlaying: isPlaying, radius: MusicStyle.Radius.small) }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: MusicStyle.Radius.small, style: .continuous)
                        .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                )
                .musicPinBadge(isPinned, coverSize: size)
                .accessibilityHidden(true)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .musicText(MusicStyle.Typeface.row14M)
                        .foregroundStyle(isCurrent ? MusicStyle.Palette.accent : .white)
                        .lineLimit(1)
                    Text(MusicHomeText.songSubtitle(artist: track.artist, album: track.album))
                        .musicText(MusicStyle.Typeface.caption12)
                        .foregroundStyle(MusicStyle.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !actions.isEmpty {
                    MusicTrackMoreButton(
                        track: track,
                        actions: actions,
                        perform: perform,
                        tint: MusicStyle.Palette.textSecondary
                    )
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.trailing, 4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(MusicStyle.Palette.lineHairline).frame(height: 1)
            }
        }
        .frame(height: MusicStyle.Size.quickPickRowHeight)
        .background(
            RoundedRectangle(cornerRadius: MusicStyle.Radius.hoverRow, style: .continuous)
                .fill(isHovered ? MusicStyle.Palette.fillHover : .clear)
        )
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .contextMenu {
            MusicTrackMenuItems(actions: actions, perform: perform)
        }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityAction(named: "Play", action)
        .accessibilityAction(.default, action)
        .accessibilityActions {
            ForEach(actions, id: \.self) { action in
                Button(action.title) { perform(action) }
            }
        }
    }

    private var accessibilityText: String {
        var text = "\(track.title), \(track.artist)"
        if isPinned { text += ", pinned" }
        if isPlaying { text += ", playing" }
        return text
    }
}
