// Deci/Views/Music/MusicTrackMenu.swift
import SwiftUI

/// What a song's "..." button and context menu call: which actions a song offers here, and what a pick does. The
/// Music tab sets it; outside it a song row has no menu.
struct MusicTrackMenuHandler: Sendable {
    let actions: @MainActor (MusicTrack, MusicTrackContext) -> [MusicTrackAction]
    let perform: @MainActor (MusicTrackAction, MusicTrack, MusicTrackContext) -> Void
}

private struct MusicTrackMenuKey: EnvironmentKey {
    static let defaultValue: MusicTrackMenuHandler? = nil
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
}

/// A song's actions as menu entries. The "..." button and the context menu share it, so they never differ.
struct MusicTrackMenuItems: View {
    let actions: [MusicTrackAction]
    let perform: (MusicTrackAction) -> Void

    var body: some View {
        ForEach(actions, id: \.self) { action in
            Button {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }
}

/// The "..." button. It is a button of its own, so a click on it opens the menu and never plays the row under it.
struct MusicTrackMoreButton: View {
    let track: MusicTrack
    let actions: [MusicTrackAction]
    let perform: (MusicTrackAction) -> Void
    var tint: Color = DesignTokens.Colors.textSecondary

    var body: some View {
        Menu {
            MusicTrackMenuItems(actions: actions, perform: perform)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Self.width, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("More actions for \(track.title)")
        .help("More actions")
    }

    /// Wide enough for a click, the same as the transport buttons beside it in the player.
    static let width: CGFloat = 22
}

/// The "..." button of the song in the player: always visible, with the same actions as a row and no page.
struct MusicNowPlayingMenu: View {
    let track: MusicTrack
    @Environment(\.musicTrackMenu) private var menu

    var body: some View {
        if let menu {
            let actions = menu.actions(track, .none)
            if !actions.isEmpty {
                MusicTrackMoreButton(
                    track: track,
                    actions: actions,
                    perform: { menu.perform($0, track, .none) },
                    tint: DesignTokens.Colors.textTertiary
                )
            }
        }
    }
}

/// The add-to-playlist panel: it replaces the content area like Up next and Lyrics. It lists the playlists the song
/// can go to, with a check on those that already hold it; a tap saves the song there.
struct MusicPlaylistPickerView: View {
    let picker: MusicTrackActionsStore.Picker
    let onBack: () -> Void
    let onChoose: (MusicPlaylistOption) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            MusicPageTopBar(title: "Save to playlist", onBack: onBack)

            Text(picker.track.title)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)

            content
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch picker.load {
        case .idle, .loading:
            MusicLoadingView()
        case .failed(let message):
            MusicFailedView(message: message, retry: onRetry)
        case .loaded(let options) where options.isEmpty:
            MusicEmptyView(text: "No playlists you can add to.")
        case .loaded(let options):
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(options, id: \.playlistId) { option in
                        MusicPlaylistOptionRow(option: option) { onChoose(option) }
                    }
                }
            }
            .scrollIndicators(.never)
            // A save is out: the list waits for its answer, so a second tap sends nothing more.
            .opacity(picker.isSaving ? 0.5 : 1)
            .allowsHitTesting(!picker.isSaving)
        }
    }
}

/// One playlist in the picker: its cover, its name, and a check when it already holds the song.
private struct MusicPlaylistOptionRow: View {
    let option: MusicPlaylistOption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                MusicThumbnail(url: option.thumbnailURL, size: 32, placeholder: "music.note.list")
                    .accessibilityHidden(true)

                Text(option.title)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: DesignTokens.Spacing.sm)

                if option.containsVideo {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.accentPrimary)
                        .accessibilityHidden(true)
                }
            }
            .hoverableRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.containsVideo ? "\(option.title), already has this song" : option.title)
    }
}

/// The short line that says what a song action did, over the bottom of the content area so nothing moves. It clears
/// itself; a click on it clears it sooner. A failure is in the warning colour.
struct MusicNoticeLine: View {
    let notice: MusicTrackActionsStore.Notice
    let onDismiss: () -> Void

    var body: some View {
        Text(notice.text)
            .font(DesignTokens.Typography.rowDescription)
            .foregroundStyle(notice.isError ? DesignTokens.Colors.mutedIndicator : DesignTokens.Colors.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5))
            )
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.xs)
            .contentShape(Capsule())
            .onTapGesture(perform: onDismiss)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
    }
}
