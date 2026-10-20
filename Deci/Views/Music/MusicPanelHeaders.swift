// Deci/Views/Music/MusicPanelHeaders.swift
import SwiftUI

// The headers of the two panels that take the right column in place of browse: Lyrics and Up next. Each is 32 pt tall
// like the browse header, has no tabs and no avatar, and ends in the Browse pill that gives the column back.

/// The wash behind Lyrics and Up next: the song's accent at 0.10 at the top of the column, gone by 90% of its height.
struct MusicPanelWash: View {
    let isOn: Bool

    @Environment(\.musicAccent) private var accent

    var body: some View {
        accent.solid.opacity(MusicPopupMetrics.panelWashOpacity)
            .mask(
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: MusicPopupMetrics.panelWashEnd)
                )
            )
            .opacity(isOn ? 1 : 0)
            // The accent glides to a new song's colour, and the wash fades in and out with the panel.
            .animation(.easeInOut(duration: 0.4), value: accent)
            .animation(DesignTokens.Animation.quick, value: isOn)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The outlined "Browse" pill at the trailing end of a panel header.
struct MusicBrowsePill: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Browse")
                .musicText(MusicStyle.Typeface.chip)
                .foregroundStyle(Color.white.opacity(isHovered ? MusicStyle.Opacity.row : MusicStyle.Opacity.pageSub))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 23)
                .overlay(Capsule(style: .continuous).strokeBorder(MusicStyle.Palette.strokeSoft, lineWidth: 1))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel("Browse")
        .help("Back to browsing")
    }
}

/// The 32 pt bar both headers sit in, 8 pt below the popup's top edge.
private struct MusicPanelHeaderBar<Content: View>: View {
    let sidePadding: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .frame(height: MusicPopupMetrics.headerHeight)
        .padding(.horizontal, sidePadding)
        .padding(.top, MusicPopupMetrics.rightPaddingTop)
    }
}

// MARK: - Lyrics

/// "Lyrics", the title of the song, a "Not synced" tag over plain lyrics, and Browse. No magnifier: Lyrics has no search
/// to open.
struct MusicLyricsHeader: View {
    let store: MusicLyricsStore
    let onBrowse: () -> Void

    var body: some View {
        MusicPanelHeaderBar(sidePadding: MusicPopupMetrics.lyricsPaddingSide) {
            Text(MusicLyricsCaption.title)
                .musicText(MusicStyle.Typeface.heading)
                .foregroundStyle(MusicStyle.Palette.textHeading)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            if let title = store.track?.title {
                Text(title)
                    .musicText(MusicStyle.Typeface.secondary)
                    .foregroundStyle(MusicStyle.Palette.textMeta)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let tag = MusicLyricsCaption.tag(for: store.state) {
                MusicNotSyncedTag(text: tag)
            }
            Spacer(minLength: 0)
            MusicBrowsePill(action: onBrowse)
        }
    }
}

/// The small outlined tag beside the title of plain lyrics.
private struct MusicNotSyncedTag: View {
    let text: String

    var body: some View {
        Text(text)
            .musicText(MusicStyle.TextStyle(10, .medium))
            .foregroundStyle(Color.white.opacity(0.60))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Up next

/// "Up next", the magnifier, the three playback toggles in one group, and Browse. The magnifier still opens the global
/// search, as in the browse header.
struct MusicQueueHeader: View {
    let service: MusicService
    let navigation: MusicSearchNavigation

    var body: some View {
        MusicPanelHeaderBar(sidePadding: MusicPopupMetrics.rightPaddingSide) {
            Text("Up next")
                .musicText(MusicStyle.Typeface.heading)
                .foregroundStyle(MusicStyle.Palette.textHeading)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            MusicSearchButton(isOpen: navigation.isSearchOpen) { navigation.toggleSearch() }
            MusicPlaybackToggles(service: service)
            MusicBrowsePill { navigation.closePanel() }
        }
    }
}

/// Shuffle, Loop and Autoplay in one rounded group. A toggle that is on has the accent for its icon and a soft accent fill.
struct MusicPlaybackToggles: View {
    let service: MusicService

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MusicPlaybackToggle.allCases, id: \.self) { toggle in
                MusicPlaybackToggleButton(
                    title: toggle.title(loop: service.loopMode),
                    symbol: toggle.symbol(loop: service.loopMode),
                    isOn: toggle.isOn(shuffle: service.isShuffleOn, loop: service.loopMode, autoplay: service.isAutoplayOn)
                ) { perform(toggle) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(MusicStyle.Opacity.segmentTrack)))
    }

    private func perform(_ toggle: MusicPlaybackToggle) {
        switch toggle {
        case .shuffle: service.setShuffle(!service.isShuffleOn)
        case .loop: service.cycleLoopMode()
        case .autoplay: service.setAutoplay(!service.isAutoplayOn)
        }
    }
}

private struct MusicPlaybackToggleButton: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    @Environment(\.musicAccent) private var accent
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isOn ? accent.solid : Color.white.opacity(isHovered ? 0.75 : 0.50))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? accent.solid.opacity(0.18) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(title)
    }
}
