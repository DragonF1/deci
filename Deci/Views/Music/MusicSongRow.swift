// Deci/Views/Music/MusicSongRow.swift
import AppKit
import SwiftUI

/// How a song row is laid out. Home's Quick picks, Search results, playlist and Liked rows, an album's tracks and an
/// artist's top songs are one row with different measures; they live here, apart from the view, so they are tested.
nonisolated enum MusicSongRowLayout: Equatable {
    /// A Search result: a 30 pt cover, "artist · album" under the title.
    case search
    /// A Quick picks, playlist or Up next row: a 30 pt cover, "artist · album" under the title.
    case playlist
    /// An artist's top song: a 30 pt cover and the album under the title.
    case topSong
    /// A Liked music row: like a playlist row, with a heart before the duration, which is set in mono.
    case liked
    /// An album track: its number in place of a cover, the title alone and a mono duration.
    case album(number: Int)

    var height: CGFloat {
        switch self {
        case .search, .playlist, .topSong, .liked: 40
        case .album: 32
        }
    }

    /// The cover's side; nil where the row has none.
    var coverSize: CGFloat? {
        switch self {
        case .search, .playlist, .topSong, .liked: 30
        case .album: nil
        }
    }

    /// The corner radius of the cover.
    var coverRadius: CGFloat { 4 }

    /// The number that leads the row, nil where it has none.
    var number: Int? {
        if case .album(let number) = self { return number }
        return nil
    }

    /// The box the number (or the playing spectrum in its place) is centred in.
    var numberBoxWidth: CGFloat { 18 }
    var numberBoxHeight: CGFloat { 16 }

    /// The gap between the cover (or the number) and the text, and between the text and what trails it.
    var contentGap: CGFloat {
        switch self {
        case .search, .playlist, .topSong, .liked: 12
        case .album: 10
        }
    }

    /// The gap between the title and the line under it.
    var textGap: CGFloat { 1 }

    /// A song that is current reads brighter and a weight heavier; it is not tinted, the spectrum marks it.
    func titleStyle(isCurrent: Bool) -> MusicStyle.TextStyle {
        isCurrent ? MusicStyle.Typeface.rowMedium : MusicStyle.Typeface.row
    }

    func titleColorOpacity(isCurrent: Bool) -> Double {
        isCurrent ? MusicStyle.Opacity.playing : MusicStyle.Opacity.row
    }

    var numberStyle: MusicStyle.TextStyle { MusicStyle.Typeface.mono }

    /// Album and Liked rows set their duration in mono, the other rows in the plain second line size.
    var durationStyle: MusicStyle.TextStyle {
        switch self {
        case .album, .liked: MusicStyle.Typeface.mono
        case .search, .playlist, .topSong: MusicStyle.Typeface.seeAll
        }
    }

    /// The heart a Liked row shows before its duration: 12 pt, in the accent at 90%.
    var showsHeart: Bool { self == .liked }
    var heartSize: CGFloat { 12 }
    var heartOpacity: Double { 0.9 }

    /// The gap between the items at the trailing end: spectrum, heart, duration.
    var trailingGap: CGFloat { 8 }

    /// Space the row keeps on both sides of itself.
    var horizontalPadding: CGFloat { MusicStyle.Spacing.page }

    enum Subtitle: Equatable {
        case none
        case artistAndAlbum
        case album
    }

    var subtitle: Subtitle {
        switch self {
        case .search, .playlist, .liked: .artistAndAlbum
        case .album: .none
        case .topSong: .album
        }
    }

    /// "3:45" for a song of that length; nil while YouTube gives none, so the row shows no duration.
    static func durationText(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return MusicTimeFormat.string(TimeInterval(seconds))
    }
}

/// A song row of the Music popover's right column: the cover, the title over "artist · album", and at the trailing end
/// the duration, which the "..." circle replaces under the pointer. The playing row carries the small spectrum in the
/// accent. Home, Search, the pages and Up next use it; the layout says which measures.
struct MusicSongRow: View {
    let track: MusicTrack
    let isCurrent: Bool
    /// True only on the current row while audio plays, so play and pause redraw one row.
    let isPlaying: Bool
    var layout: MusicSongRowLayout = .search
    let action: () -> Void

    /// Set while Full Keyboard Access has put keyboard focus on the row, so it shows the hover surface.
    @FocusState private var isKeyboardFocused: Bool
    @State private var isHovered = false
    /// True from the moment a menu (the "..." button's or the right click one) opens on this hovered row until any
    /// menu closes. Opening a menu ends the row's hover, but the row keeps its highlight and its "..." button.
    @State private var isMenuOpen = false
    @Environment(\.musicTrackMenu) private var menu
    @Environment(\.musicTrackContext) private var context
    @Environment(\.musicAccent) private var accent
    /// The words of the screen's filter, tinted where they match the title, the artist or the album.
    @Environment(\.musicHighlightTerms) private var highlightTerms

    static let height: CGFloat = 40
    static let coverSize: CGFloat = 30

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
        HStack(spacing: layout.contentGap) {
            if layout.number != nil {
                numberColumn
            }
            if layout.coverSize != nil {
                cover
            }
            VStack(alignment: .leading, spacing: layout.textGap) {
                Text.highlighted(track.title, terms: highlightTerms, color: accent.solid)
                    .musicText(layout.titleStyle(isCurrent: isCurrent))
                    .foregroundStyle(Color.white.opacity(layout.titleColorOpacity(isCurrent: isCurrent)))
                    .lineLimit(1)
                    .accessibilityHidden(true)
                subtitle
            }
            Spacer(minLength: 0)
            trailing(actions: actions, showsMore: showsMore)
        }
        .frame(height: layout.height)
        .padding(.horizontal, MusicBrowseLayout.rowHoverInset)
        .background(
            RoundedRectangle(cornerRadius: MusicBrowseLayout.rowHoverRadius, style: .continuous)
                .fill(showsMore ? MusicStyle.Palette.rowHover : .clear)
        )
        .animation(DesignTokens.Animation.hover, value: showsMore)
        .padding(.horizontal, layout.horizontalPadding - MusicBrowseLayout.rowHoverInset)
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

    /// The track's number, or the small spectrum in its place on the track in the player.
    private var numberColumn: some View {
        Group {
            if isCurrent {
                MusicMiniSpectrumView(isPlaying: isPlaying)
            } else {
                Text(verbatim: String(layout.number ?? 0))
                    .musicText(layout.numberStyle)
                    .foregroundStyle(MusicStyle.Palette.textNumber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: layout.numberBoxWidth, height: layout.numberBoxHeight)
        .accessibilityHidden(true)
    }

    private var cover: some View {
        let size = layout.coverSize ?? Self.coverSize
        let radius = layout.coverRadius
        return MusicThumbnail(url: track.thumbnailURL, size: size, cornerRadius: radius)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
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
                Text.highlighted(album, terms: highlightTerms, color: accent.solid)
                    .musicText(MusicStyle.Typeface.secondary)
                    .foregroundStyle(MusicStyle.Palette.textSub)
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
                font: MusicStyle.Typeface.secondary.font,
                color: MusicStyle.Palette.textSub
            )
            .layoutPriority(1)
            if let album = track.album, !album.isEmpty {
                Text.highlighted(" \u{00B7} " + album, terms: highlightTerms, color: accent.solid)
                    .musicText(MusicStyle.Typeface.secondary)
                    .foregroundStyle(MusicStyle.Palette.textSub)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Trailing end

    /// The spectrum of the playing row, a Liked row's heart, and the duration with the "..." circle over it. The
    /// duration keeps its room while the circle shows, so the text never re-cuts when the pointer arrives.
    @ViewBuilder
    private func trailing(actions: [MusicTrackAction], showsMore: Bool) -> some View {
        HStack(spacing: layout.trailingGap) {
            if isCurrent, layout.number == nil {
                MusicMiniSpectrumView(isPlaying: isPlaying)
            }
            if layout.showsHeart {
                Image(systemName: "heart.fill")
                    .font(.system(size: layout.heartSize))
                    .foregroundStyle(accent.solid.opacity(layout.heartOpacity))
                    .accessibilityHidden(true)
            }
            durationAndMore(actions: actions, showsMore: showsMore)
        }
    }

    @ViewBuilder
    private func durationAndMore(actions: [MusicTrackAction], showsMore: Bool) -> some View {
        let duration = MusicSongRowLayout.durationText(seconds: track.durationSeconds)
        if duration != nil || !actions.isEmpty {
            ZStack(alignment: .trailing) {
                if let duration {
                    Text(duration)
                        .musicText(layout.durationStyle)
                        .foregroundStyle(MusicStyle.Palette.textMeta)
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(showsMore && !actions.isEmpty ? 0 : 1)
                        .accessibilityHidden(true)
                }
                // A button of its own, like the artist names: its click opens the menu and does not play the row. It
                // stays clickable while faded: an open menu can end the row's hover, and the button must not vanish
                // under it.
                if !actions.isEmpty {
                    MusicTrackMoreButton(track: track, actions: actions, perform: perform, style: .round)
                        .opacity(showsMore ? 1 : 0)
                        .accessibilityHidden(!showsMore)
                }
            }
        }
    }
}

extension View {
    /// The hairline between two rows of a list, drawn over the top edge of the lower one and inset by the page margin,
    /// so a list of rows is as tall as its rows.
    func musicRowHairline(_ isShown: Bool) -> some View {
        overlay(alignment: .top) {
            if isShown {
                Rectangle()
                    .fill(MusicStyle.Palette.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, MusicStyle.Spacing.page)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
