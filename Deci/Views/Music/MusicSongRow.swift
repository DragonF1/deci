// Deci/Views/Music/MusicSongRow.swift
import AppKit
import SwiftUI

/// A song row of the redesigned Music popover: a 36 pt cover, the title over "artist · album", a hairline underneath.
/// Under the pointer the row gets the hover fill, slides in by 6 and shows the round "..." button. The Search results
/// use it first; the pages take it over from `MusicResultRow` in the next phase.
struct MusicSongRow: View {
    let track: MusicTrack
    let isCurrent: Bool
    /// True only on the current row while audio plays, so play and pause redraw one row.
    let isPlaying: Bool
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
        HStack(spacing: 12) {
            cover

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .musicText(MusicStyle.Typeface.row13M)
                        .foregroundStyle(isCurrent ? MusicStyle.Palette.accent : .white)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                    subtitle
                }
                Spacer(minLength: 0)
                moreButton(actions: actions, isShown: showsMore)
            }
            .frame(maxHeight: .infinity)
            .padding(.trailing, 4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(MusicStyle.Palette.lineHairline).frame(height: 1)
            }
        }
        .frame(height: Self.height)
        .musicRowHover(showsMore)
        .padding(.horizontal, MusicStyle.Spacing.page)
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

    private var cover: some View {
        MusicThumbnail(url: track.thumbnailURL, size: Self.coverSize, cornerRadius: MusicStyle.Radius.small)
            .overlay {
                if isCurrent { MusicPlayingOverlay(isPlaying: isPlaying, radius: MusicStyle.Radius.small) }
            }
            .overlay(
                RoundedRectangle(cornerRadius: MusicStyle.Radius.small, style: .continuous)
                    .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
            )
            .musicPinBadge(isPinned, coverSize: Self.coverSize)
            .accessibilityHidden(true)
    }

    /// "artist · album": the artist names stay links, the album is plain text and gives way first.
    private var subtitle: some View {
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
            MusicTrackMoreButton(track: track, actions: actions, perform: perform, style: .round)
                .opacity(isShown ? 1 : 0)
                .accessibilityHidden(!isShown)
        }
    }
}
