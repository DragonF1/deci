// Deci/Views/Music/MusicTrackMenu.swift
import SwiftUI

/// What a song's "..." button and context menu call: which actions a song offers here, and what a pick does. The
/// Music tab sets it; outside it a song row has no menu.
struct MusicTrackMenuHandler: Sendable {
    let actions: @MainActor (MusicTrack, MusicTrackContext) -> [MusicTrackAction]
    let perform: @MainActor (MusicTrackAction, MusicTrack, MusicTrackContext) -> Void
    /// Whether the song is pinned to Listen again or to Home, for the badge on its cover.
    let isPinned: @MainActor (MusicTrack) -> Bool
}

private struct MusicTrackMenuKey: EnvironmentKey {
    static let defaultValue: MusicTrackMenuHandler? = nil
}

/// Pin / Unpin to Listen again and to Home for playlist, album and artist tiles and rows: which way a collection's
/// Listen again toggle faces (nil when YouTube offers none), where it stands with Home (nil when it cannot be pinned
/// there), and what a pick does. The Music tab sets it; outside it a tile has no such items.
struct MusicCollectionPinHandler: Sendable {
    let pin: @MainActor (MusicCollection) -> MusicFeedbackToggle?
    let toggle: @MainActor (MusicCollection) -> Void
    let homePin: @MainActor (MusicCollection) -> MusicHomePinState?
    let toggleHome: @MainActor (MusicCollection) -> Void
    /// Whether the tile or row wears the pin badge: see `wearsPinBadge`.
    let isPinned: @MainActor (MusicCollection) -> Bool

    /// A collection pinned to Listen again or to Home. It does not need an Unpin to be on offer, so a pinned
    /// collection YouTube gives no unpin token for still shows the badge.
    @MainActor
    static func wearsPinBadge(_ collection: MusicCollection, actions: MusicTrackActionsStore, home: MusicPinnedItems) -> Bool {
        actions.isPinnedToListenAgain(collection) || home.isPinned(collection)
    }
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

/// The Listen again item of a playlist or album's right click menu, worded like the song menu's.
struct MusicListenAgainPinItem: View {
    let toggle: MusicFeedbackToggle
    let action: () -> Void

    var body: some View {
        let item: MusicTrackAction = toggle.isPinned ? .unpinFromListenAgain : .pinToListenAgain
        Button(item.title, action: action)
    }
}

/// A song's actions as menu entries, text only, with a line between the blocks (library, go to, remove). The "..."
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

/// The add-to-playlist panel: it replaces the content area like Up next and Lyrics, under the browse header. It lists
/// the playlists the song can go to, with a check on those that already hold it; a tap saves the song there.
struct MusicPlaylistPickerView: View {
    let picker: MusicTrackActionsStore.Picker
    let onBack: () -> Void
    let onChoose: (MusicPlaylistOption) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicBackRow(label: "Back", action: onBack, help: "Close")
                .padding(.top, MusicBrowseLayout.pageTop)
                .padding(.horizontal, MusicStyle.Spacing.page)

            VStack(alignment: .leading, spacing: 2) {
                Text("Save to playlist")
                    .musicText(MusicStyle.Typeface.heading)
                    .foregroundStyle(MusicStyle.Palette.textHeading)
                    .accessibilityAddTraits(.isHeader)
                Text(picker.track.title)
                    .musicText(MusicStyle.Typeface.secondary)
                    .foregroundStyle(MusicStyle.Palette.textMeta)
                    .lineLimit(1)
            }
            .padding(.horizontal, MusicStyle.Spacing.page)
            .padding(.top, 8)
            .padding(.bottom, 8)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch picker.load {
        case .idle, .loading:
            MusicLoadingCard()
                .padding(.top, 40)
        case .failed(let message):
            MusicFailedCard(message: message, retry: onRetry)
                .padding(.top, 40)
        case .loaded(let options) where options.isEmpty:
            MusicStateCard(message: "No playlists you can add to.")
                .padding(.top, 40)
        case .loaded(let options):
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(options, id: \.playlistId) { option in
                        MusicPlaylistOptionRow(option: option) { onChoose(option) }
                    }
                    MusicBottomInsetSpacer()
                }
                .padding(.horizontal, MusicStyle.Spacing.page - MusicPlaylistOptionRow.inset)
            }
            .scrollIndicators(.never)
            // A save is out: the list waits for its answer, so a second tap sends nothing more.
            .opacity(picker.isSaving ? 0.5 : 1)
            .allowsHitTesting(!picker.isSaving)
        }
    }
}

/// One playlist in the picker: a 40 pt row with its 30 pt cover and name, the hover surface of the other rows, and a
/// check in the song's accent when it already holds the song.
private struct MusicPlaylistOptionRow: View {
    let option: MusicPlaylistOption
    let action: () -> Void

    /// The hover surface reaches this far past the content, like a song row's.
    static let inset: CGFloat = 6

    @State private var isHovered = false
    @Environment(\.musicAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MusicThumbnail(url: option.thumbnailURL, size: 30, placeholder: "music.note.list", cornerRadius: MusicStyle.Radius.small)
                    .accessibilityHidden(true)

                Text(option.title)
                    .musicText(MusicStyle.Typeface.rowMedium)
                    .foregroundStyle(MusicStyle.Palette.textRow)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if option.containsVideo {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent.solid)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Self.inset)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: MusicBrowseLayout.rowHoverRadius, style: .continuous)
                    .fill(isHovered ? MusicStyle.Palette.rowHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel(option.containsVideo ? "\(option.title), already has this song" : option.title)
    }
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
