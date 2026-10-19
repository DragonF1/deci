// Deci/Views/Music/MusicSongRow.swift
import AppKit
import SwiftUI

/// How a song row is laid out. Search results, album tracks, playlist and Liked rows and an artist's top songs are one
/// row with different measures; they live here, apart from the view, so they are tested.
nonisolated enum MusicSongRowLayout: Equatable {
    /// A Search result: 36 pt cover, "artist · album" under the title.
    case search
    /// An album track: the number of the track in place of a cover, and the title alone.
    case album(number: Int)
    /// A playlist or Liked music row: 40 pt cover, "artist · album" under the title.
    case playlist
    /// An artist's top song: a number, a 40 pt cover and the album under the title.
    case topSong(number: Int)

    var height: CGFloat {
        switch self {
        case .search, .album: 44
        case .playlist: 52
        case .topSong: 48
        }
    }

    /// The cover's side; nil where the row has none.
    var coverSize: CGFloat? {
        switch self {
        case .search: 36
        case .album: nil
        case .playlist, .topSong: 40
        }
    }

    /// The number that leads the row, nil where it has none.
    var number: Int? {
        switch self {
        case .album(let number), .topSong(let number): number
        case .search, .playlist: nil
        }
    }

    /// The width of the number column, and the gap after it.
    var numberWidth: CGFloat { self.isAlbum ? 28 : 14 }
    var numberGap: CGFloat { self.isAlbum ? 8 : 10 }

    /// The gap between the cover (or the number) and the text.
    var coverGap: CGFloat {
        switch self {
        case .search, .playlist: 12
        case .album, .topSong: 10
        }
    }

    var titleStyle: MusicStyle.TextStyle {
        switch self {
        case .search: MusicStyle.Typeface.row13M
        case .album, .playlist: MusicStyle.Typeface.row15
        case .topSong: MusicStyle.Typeface.row14M
        }
    }

    var numberStyle: MusicStyle.TextStyle {
        self.isAlbum ? MusicStyle.TextStyle(13) : MusicStyle.TextStyle(13, .semibold)
    }

    var numberOpacity: Double { self.isAlbum ? 0.45 : 0.5 }

    /// The space after the text, before the row's edge.
    var trailingPadding: CGFloat { self.isAlbum ? 8 : 4 }

    /// Space the row keeps on both sides of itself. A top song sits in a grid that has its own margin.
    var horizontalPadding: CGFloat {
        switch self {
        case .search, .playlist: MusicStyle.Spacing.page
        case .album: 16
        case .topSong: 0
        }
    }

    /// The glyph that stands in for the round "..." button while the pointer is elsewhere; Search shows nothing.
    var showsIdleEllipsis: Bool { self != .search }

    /// A row that is playing wears the accent title, except on an album, whose playing track is marked in the number's place.
    var accentsCurrentTitle: Bool {
        if case .album = self { return false }
        return true
    }

    enum Subtitle: Equatable {
        case none
        case artistAndAlbum
        case album
    }

    var subtitle: Subtitle {
        switch self {
        case .search, .playlist: .artistAndAlbum
        case .album: .none
        case .topSong: .album
        }
    }

    private var isAlbum: Bool {
        if case .album = self { return true }
        return false
    }
}

/// A song row of the redesigned Music popover: the cover, the title over "artist · album", a hairline underneath.
/// Under the pointer the row gets the hover fill, slides in by 6 and shows the round "..." button. Search results and
/// the pages use it; the layout says which measures.
struct MusicSongRow: View {
    let track: MusicTrack
    let isCurrent: Bool
    /// True only on the current row while audio plays, so play and pause redraw one row.
    let isPlaying: Bool
    var layout: MusicSongRowLayout = .search
    /// The colour of the playing indicator of an album track: the page's light tint.
    var playingColor: Color = .white
    let action: () -> Void

    /// Set while Full Keyboard Access has put keyboard focus on the row, so it shows the hover surface.
    @FocusState private var isKeyboardFocused: Bool
    @State private var isHovered = false
    /// True from the moment a menu (the "..." button's or the right click one) opens on this hovered row until any
    /// menu closes. Opening a menu ends the row's hover, but the row keeps its highlight and its "..." button.
    @State private var isMenuOpen = false
    @Environment(\.musicTrackMenu) private var menu
    @Environment(\.musicTrackContext) private var context

    static let height: CGFloat = 44
    static let coverSize: CGFloat = 36

    private var offeredActions: [MusicTrackAction] { menu?.actions(track, context) ?? [] }

    /// Pinned to Listen again, as last left this session: the cover wears the pin badge.
    private var isPinned: Bool { menu?.isPinned(track) == true }

    private func perform(_ action: MusicTrackAction) {
        menu?.perform(action, track, context)
    }

    private var accessibilityText: String {
        var text = "\(track.title), \(track.artist)"
        if isPinned { text += ", pinned" }
        if isPlaying { text += ", playing" }
        return text
    }

    var body: some View {
        let actions = offeredActions
        let showsMore = isHovered || isMenuOpen || isKeyboardFocused
        // The row plays on a tap. It is not one Button, because the artist names inside it are buttons of their
        // own, and a button nested in another button's label is unreliable for clicks and for VoiceOver.
        HStack(spacing: layout.number != nil && layout.coverSize == nil ? layout.numberGap : layout.coverGap) {
            if layout.number != nil {
                numberColumn
            }
            if layout.coverSize != nil {
                cover
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .musicText(layout.titleStyle)
                        .foregroundStyle(isCurrent && layout.accentsCurrentTitle ? MusicStyle.Palette.accent : .white)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                    subtitle
                }
                Spacer(minLength: 0)
                moreButton(actions: actions, isShown: showsMore)
            }
            .frame(maxHeight: .infinity)
            .padding(.trailing, layout.trailingPadding)
            .overlay(alignment: .bottom) {
                Rectangle().fill(MusicStyle.Palette.lineHairline).frame(height: 1)
            }
        }
        .frame(height: layout.height)
        .musicRowHover(showsMore)
        .padding(.horizontal, layout.horizontalPadding)
        .onHover { isHovered = $0 }
        // Tracking begins while the pointer is still on the row (the hover ends after the menu window is up), so
        // only the row the menu was opened from takes it. Every end of tracking clears it, and so does the row leaving.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            if isHovered { isMenuOpen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isMenuOpen = false
        }
        .onDisappear { isMenuOpen = false }
        .contentShape(Rectangle())
        // The same actions as the "..." button, for a right click anywhere on the row.
        .contextMenu {
            MusicTrackMenuItems(actions: actions, perform: perform)
        }
        // A name's own button takes its click first; a click anywhere else on the row plays.
        .onTapGesture(perform: action)
        // What the Button gave the row: reachable with Full Keyboard Access only (a plain Tab stays on the search
        // field and the popup's arrow keys), and Space or Return plays. A key goes to the row only while it has
        // focus, so typing in the search field never reaches it.
        .focusable(interactions: .activate)
        .focused($isKeyboardFocused)
        .onKeyPress(keys: [.space, .return], phases: .down) { _ in
            action()
            return .handled
        }
        // A container, so each artist name inside stays its own button for VoiceOver; the row plays by its action.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityAction(named: "Play", action)
        .accessibilityAction(.default, action)
        // The "..." button hides until the pointer or the keyboard is on the row; VoiceOver gets the actions here.
        .accessibilityActions {
            ForEach(actions, id: \.self) { action in
                Button(action.title) { perform(action) }
            }
        }
    }

    /// The track's number, or the playing indicator in its place on the track in the player.
    private var numberColumn: some View {
        Group {
            if isCurrent, layout.coverSize == nil {
                MusicPlayingBars(isPlaying: isPlaying, color: playingColor)
            } else {
                Text(verbatim: String(layout.number ?? 0))
                    .musicText(layout.numberStyle)
                    .foregroundStyle(Color.white.opacity(layout.numberOpacity))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: layout.numberWidth)
        .accessibilityHidden(true)
    }

    private var cover: some View {
        let size = layout.coverSize ?? Self.coverSize
        return MusicThumbnail(url: track.thumbnailURL, size: size, cornerRadius: MusicStyle.Radius.small)
            .overlay {
                if isCurrent { MusicPlayingOverlay(isPlaying: isPlaying, radius: MusicStyle.Radius.small) }
            }
            .overlay(
                RoundedRectangle(cornerRadius: MusicStyle.Radius.small, style: .continuous)
                    .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
            )
            .musicPinBadge(isPinned, coverSize: size)
            .accessibilityHidden(true)
    }

    /// "artist · album": the artist names stay links, the album is plain text and gives way first. A top song shows
    /// its album, or its artists when YouTube names none; an album track has no second line.
    @ViewBuilder
    private var subtitle: some View {
        switch layout.subtitle {
        case .none:
            EmptyView()
        case .artistAndAlbum:
            artistAndAlbum
        case .album:
            if let album = track.album, !album.isEmpty {
                Text(album)
                    .musicText(MusicStyle.Typeface.caption12)
                    .foregroundStyle(MusicStyle.Palette.textSecondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            } else {
                artistAndAlbum
            }
        }
    }

    private var artistAndAlbum: some View {
        HStack(spacing: 0) {
            MusicArtistLine(
                artist: track.artist,
                links: track.artistLinks,
                hidesPlainTextFromVoiceOver: true,
                font: MusicStyle.Typeface.caption12.font,
                color: MusicStyle.Palette.textSecondary
            )
            .layoutPriority(1)
            if let album = track.album, !album.isEmpty {
                Text(" \u{00B7} " + album)
                    .musicText(MusicStyle.Typeface.caption12)
                    .foregroundStyle(MusicStyle.Palette.textSecondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Its room is kept whether or not it shows, so the text never re-cuts when the pointer arrives. A button of its
    /// own, like the artist names: its click opens the menu and does not play the row. It stays clickable while faded:
    /// an open menu can end the row's hover, and the button must not vanish under it.
    @ViewBuilder
    private func moreButton(actions: [MusicTrackAction], isShown: Bool) -> some View {
        if actions.isEmpty {
            Color.clear.frame(width: MusicTrackMoreButton.roundSize, height: MusicTrackMoreButton.roundSize)
        } else {
            ZStack {
                MusicTrackMoreButton(track: track, actions: actions, perform: perform, style: .round)
                    .opacity(isShown ? 1 : 0)
                    .accessibilityHidden(!isShown)
                // The rows of the pages show the dots at rest; the round button takes their place under the pointer.
                if layout.showsIdleEllipsis, !isShown {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundStyle(MusicStyle.Palette.textSecondary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
