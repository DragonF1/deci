// Deci/Views/Music/MusicTrackMenu.swift
import SwiftUI

/// What a song's "..." button and context menu call: which actions a song offers here, and what a pick does. The
/// Music tab sets it; outside it a song row has no menu.
struct MusicTrackMenuHandler: Sendable {
    let actions: @MainActor (MusicTrack, MusicTrackContext) -> [MusicTrackAction]
    let perform: @MainActor (MusicTrackAction, MusicTrack, MusicTrackContext) -> Void
    /// Whether the song is pinned to Home, for the badge on its cover.
    let isPinned: @MainActor (MusicTrack) -> Bool
    /// The pointer reached the song's row, or its menu is about to open: reads the song's rating, so the menu can word
    /// Like and Dislike for it. Reads each song once. A row calls it from its hover or its menu, never from its body.
    var reveal: @MainActor (MusicTrack, MusicTrackContext) -> Void = { _, _ in }
    /// Where the song's download stands, for the glyph or the progress ring at the end of its row. Reads the download
    /// service, so a row that calls it from its body redraws when the state changes.
    var downloadState: @MainActor (MusicTrack) -> MusicDownloadState = { _ in .none }
    /// The song cannot play now: the network is gone (or the account) and it is not downloaded. Its row dims and a tap on it
    /// plays nothing. Reads the store, so a row that calls it from its body redraws when the network goes or returns.
    var isDimmed: @MainActor (MusicTrack) -> Bool = { _ in false }
}

private struct MusicTrackMenuKey: EnvironmentKey {
    static let defaultValue: MusicTrackMenuHandler? = nil
}

/// What the right click menu of a playlist, album or artist tile or row calls: which actions the collection offers here
/// (save to playlist, pin to Home, go to the album, go to the artist), and what a pick does. The Music tab sets it;
/// outside it a tile has no menu.
struct MusicCollectionPinHandler: Sendable {
    let actions: @MainActor (MusicCollection, MusicTrackContext) -> [MusicTrackAction]
    let perform: @MainActor (MusicTrackAction, MusicCollection, MusicTrackContext) -> Void
    /// Whether the tile or row is pinned to Home, so its cover wears the pin badge.
    let isPinned: @MainActor (MusicCollection) -> Bool
}

private struct MusicCollectionPinKey: EnvironmentKey {
    static let defaultValue: MusicCollectionPinHandler? = nil
}

/// The page a row sits on. A page sets it for its own song rows; everywhere else it stays `.none`.
private struct MusicTrackContextKey: EnvironmentKey {
    static let defaultValue = MusicTrackContext.none
}

extension EnvironmentValues {
    var musicTrackMenu: MusicTrackMenuHandler? {
        get { self[MusicTrackMenuKey.self] }
        set { self[MusicTrackMenuKey.self] = newValue }
    }

    var musicTrackContext: MusicTrackContext {
        get { self[MusicTrackContextKey.self] }
        set { self[MusicTrackContextKey.self] = newValue }
    }

    var musicCollectionPin: MusicCollectionPinHandler? {
        get { self[MusicCollectionPinKey.self] }
        set { self[MusicCollectionPinKey.self] = newValue }
    }
}

/// A song's actions as menu entries, text only, with a line between the blocks (queue, library, go to, remove). The "..."
/// button and the context menu share it, so they never differ.
struct MusicTrackMenuItems: View {
    let actions: [MusicTrackAction]
    let perform: (MusicTrackAction) -> Void

    var body: some View {
        let groups = MusicTrackActions.groups(of: actions)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group, id: \.self) { action in
                Button(action.title) { perform(action) }
                    .disabled(!action.isEnabled)
            }
        }
    }
}

/// The "..." button. It is a button of its own, so a click on it opens the menu and never plays the row under it.
struct MusicTrackMoreButton: View {
    /// How the button is drawn: the bare dots of the compact rows, or the 22 pt circle of the song row.
    enum Style {
        case plain
        case round
    }

    let track: MusicTrack
    let actions: [MusicTrackAction]
    let perform: (MusicTrackAction) -> Void
    var tint: Color = DesignTokens.Colors.textSecondary
    var style: Style = .plain

    var body: some View {
        Menu {
            MusicTrackMenuItems(actions: actions, perform: perform)
        } label: {
            switch style {
            case .plain:
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: Self.width, height: 28)
                    .contentShape(Rectangle())
            case .round:
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MusicStyle.Palette.textRow)
                    .frame(width: Self.roundSize, height: Self.roundSize)
                    .background(Circle().fill(MusicStyle.Palette.chipSelected))
                    .contentShape(Circle())
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("More actions for \(track.title)")
        .help("More actions")
    }

    /// Wide enough for a click.
    static let width: CGFloat = 22
    /// The button the song row shows under the pointer.
    static let roundSize: CGFloat = 22
}

/// The short line that says what a song action did, over the bottom of the content area so nothing moves: a small dark
/// pill with a check in the song's accent, 15 pt above the bottom. It clears itself after about 2 s; a click on it clears
/// it sooner. A failure has the warning sign and colour.
struct MusicNoticeLine: View {
    let notice: MusicTrackActionsStore.Notice
    let onDismiss: () -> Void

    @Environment(\.musicAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: notice.isError ? "exclamationmark.triangle" : "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(notice.isError ? DesignTokens.Colors.mutedIndicator : accent.solid)
                .accessibilityHidden(true)
            Text(notice.text)
                .musicText(MusicStyle.Typeface.notice)
                .foregroundStyle(notice.isError ? DesignTokens.Colors.mutedIndicator : Color.white.opacity(0.92))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(shape.fill(MusicStyle.Palette.menuFill))
        .overlay(shape.strokeBorder(MusicStyle.Palette.menuBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
        .padding(.horizontal, MusicStyle.Spacing.page)
        .contentShape(shape)
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
