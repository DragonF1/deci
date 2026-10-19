// Deci/Views/Music/MusicShelfView.swift
import SwiftUI

/// One titled shelf on Home or an artist page. A shelf of songs only (Quick picks) shows
/// compact song rows; any other shelf scrolls sideways through tiles.
struct MusicShelfView: View {
    let shelf: MusicShelf
    /// videoId of the track in the player, for the playing indicator.
    let nowPlayingId: String?
    let isPlaying: Bool
    let onPlay: (MusicTrack) -> Void
    let onOpen: (MusicCollection) -> Void
    /// Gives each collection tile an "Unpin from Home" context menu item. Only the pinned artists row passes it.
    var onUnpin: ((MusicCollection) -> Void)?
    @Environment(\.musicCollectionPin) private var collectionPin
    @Environment(\.musicTrackMenu) private var trackMenu

    /// Song rows a songs-only shelf shows.
    static let maxSongRows = 6

    /// The pinned artists row shows no badges: every tile on it is pinned, so they would only be noise.
    private var showsPinBadges: Bool { onUnpin == nil }

    /// The shelf's songs when every item is one, else nil.
    private var songs: [MusicTrack]? {
        let tracks = shelf.items.compactMap { item -> MusicTrack? in
            if case .track(let track) = item { return track }
            return nil
        }
        return !tracks.isEmpty && tracks.count == shelf.items.count ? tracks : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            MusicSectionTitle(text: shelf.title)

            if let songs {
                VStack(spacing: 0) {
                    ForEach(Array(songs.prefix(Self.maxSongRows).enumerated()), id: \.offset) { _, track in
                        MusicResultRow(
                            track: track,
                            isCurrent: nowPlayingId == track.videoId,
                            isPlaying: nowPlayingId == track.videoId && isPlaying
                        ) {
                            onPlay(track)
                        }
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 0) {
                        ForEach(Array(shelf.items.enumerated()), id: \.offset) { _, item in
                            tile(for: item)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder
    private func tile(for item: MusicShelfItem) -> some View {
        switch item {
        case .track(let track):
            MusicTile(
                title: track.title,
                subtitle: track.artist,
                thumbnailURL: track.thumbnailURL,
                isCurrent: nowPlayingId == track.videoId,
                isPlaying: nowPlayingId == track.videoId && isPlaying,
                isPinned: showsPinBadges && trackMenu?.isPinned(track) == true
            ) {
                onPlay(track)
            }
        case .collection(let collection):
            let tile = MusicTile(
                title: collection.title,
                subtitle: collection.subtitle,
                thumbnailURL: collection.thumbnailURL,
                circular: collection.kind == .artist,
                placeholder: collection.kind.placeholderSymbol,
                isPinned: showsPinBadges && collectionPin?.isPinned(collection) == true
            ) {
                onOpen(collection)
            }
            let listenAgain = collectionPin?.pin(collection)
            if onUnpin != nil || listenAgain != nil {
                tile.contextMenu {
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
                tile
            }
        }
    }
}

/// A cover with two lines of title and one of subtitle, for sideways shelves.
struct MusicTile: View {
    let title: String
    let subtitle: String
    let thumbnailURL: URL?
    var circular = false
    var placeholder = "music.note"
    var isCurrent = false
    var isPlaying = false
    /// Pinned to Listen again (a song, playlist or album) or to Home (an artist): the cover wears the pin badge.
    var isPinned = false
    let action: () -> Void

    static let coverSize: CGFloat = 96

    var body: some View {
        Button(action: action) {
            VStack(alignment: circular ? .center : .leading, spacing: DesignTokens.Spacing.xxs) {
                MusicThumbnail(url: thumbnailURL, size: Self.coverSize, circular: circular, placeholder: placeholder)
                    .overlay {
                        if isCurrent {
                            MusicPlayingOverlay(isPlaying: isPlaying, circular: circular, symbolSize: 20)
                        }
                    }
                    .musicPinBadge(isPinned, coverSize: Self.coverSize, circular: circular)
                    .padding(.bottom, DesignTokens.Spacing.xxs)
                // Every tile takes two title lines and a subtitle line, short or not: the lazy shelf
                // sizes its height from the first tiles, so a taller tile further along got cut off.
                Text(title)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(isCurrent ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(circular ? .center : .leading)
                Text(subtitle.isEmpty ? " " : subtitle)
                    .font(DesignTokens.Typography.rowDescription)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: Self.coverSize, alignment: circular ? .center : .leading)
            .hoverableRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// The dimmed cover with a speaker on the row or tile that is in the player. The speaker
/// animates while audio plays and holds still while paused.
struct MusicPlayingOverlay: View {
    let isPlaying: Bool
    var circular = false
    var symbolSize: CGFloat = 14
    /// The corner radius of a square cover; the button radius when nil.
    var radius: CGFloat?

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isPlaying)
        }
        .clipShape(MusicCoverShape(circular: circular, radius: radius))
        .accessibilityHidden(true)
    }
}

/// A shelf or list title, in the popup's section header style.
struct MusicSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .sectionHeaderStyle()
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Centered spinner while a list loads.
struct MusicLoadingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Loading")
    }
}

/// A list that failed to load: the message and a Retry button.
struct MusicFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text(message)
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
                .buttonStyle(.plain)
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .glassButtonStyle()
                .contentShape(Rectangle())
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A list that loaded empty.
struct MusicEmptyView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DesignTokens.Typography.rowDescription)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The end of a list that has more. It asks for the next page when it scrolls into view and
/// shows a spinner while that loads. If a load fails it offers Load more instead of retrying
/// on its own.
struct MusicLoadMoreFooter: View {
    let isLoading: Bool
    let loadMore: () -> Void

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading more")
            } else {
                Button("Load more", action: loadMore)
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .onAppear {
            if !isLoading { loadMore() }
        }
    }
}
