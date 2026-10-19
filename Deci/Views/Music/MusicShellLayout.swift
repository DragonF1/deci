// Deci/Views/Music/MusicShellLayout.swift
import SwiftUI

/// The measures of the Music shell that depend on the width of the popover. The popover keeps the size of its
/// setting, so everything is laid out against the real width, not the mock's 510.
nonisolated enum MusicShellLayout {
    /// The side margin of browse screens and of the floating chrome.
    static let pageMargin: CGFloat = 20

    /// The tab bar's distance from the popover bottom.
    static let tabBarBottom: CGFloat = 12

    /// The mini player's bottom edge above the popover bottom: 8 above the tab bar.
    static let miniPlayerBottom: CGFloat = 80

    /// The widest the tab bar gets.
    static let maxTabBarWidth: CGFloat = 286

    /// The height of the fade the content dissolves into behind the chrome.
    static let scrimHeight: CGFloat = 150

    /// The gap between the two Quick picks columns.
    static let quickPickColumnGap: CGFloat = 16

    /// Space under the last row of a browse scroll view, so it clears the chrome with 16 to spare.
    static func bottomInset(hasMiniPlayer: Bool) -> CGFloat {
        hasMiniPlayer ? 140 : 80
    }

    static func tabBarWidth(forWidth width: CGFloat) -> CGFloat {
        min(maxTabBarWidth, max(0, width - 2 * pageMargin))
    }

    /// One tab of a bar `barWidth` wide: three equal tabs inside 4 pt of padding.
    static func tabWidth(forBarWidth barWidth: CGFloat) -> CGFloat {
        max(0, (barWidth - 8) / 3)
    }

    static func miniPlayerWidth(forWidth width: CGFloat) -> CGFloat {
        max(0, width - 2 * pageMargin)
    }
}

/// Which screen the Music shell shows. Browse screens (Home, Library, Search and the pages opened from them) wear
/// the tab bar and the mini player; the three player screens fill the popover and have neither.
nonisolated enum MusicShellScreen: Equatable {
    case browse
    case nowPlaying
    case lyrics
    case queue

    var isPlayer: Bool { self != .browse }

    /// The add-to-playlist picker is a browse screen. Lyrics and Up next are open only from a player screen. Now
    /// Playing needs a loaded track.
    static func resolve(
        isNowPlayingOpen: Bool,
        hasTrack: Bool,
        showsLyrics: Bool,
        showsQueue: Bool,
        showsPicker: Bool
    ) -> MusicShellScreen {
        if showsPicker { return .browse }
        if showsLyrics { return .lyrics }
        if showsQueue { return .queue }
        if isNowPlayingOpen, hasTrack { return .nowPlaying }
        return .browse
    }
}

extension MusicPopupMetrics {
    /// The gap the old layout kept between the gear row and the body.
    static let headerGap: CGFloat = 8

    /// The whole height of the popover. It is what the popover always was: the padding around a gear row, a gap
    /// and the body. The shell draws edge to edge inside it, so the size does not change.
    static func totalHeight(maxContentHeight: CGFloat, contentPadding: CGFloat) -> CGFloat {
        2 * contentPadding + headerHeight + headerGap + bodyHeight(maxContentHeight: maxContentHeight)
    }
}

// MARK: - Bottom inset

private struct MusicBottomInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How far the floating chrome reaches up from the bottom of the popover. A vertical scroll view of the Music
    /// popover ends with this much room, so its last row can scroll clear of the chrome.
    var musicBottomInset: CGFloat {
        get { self[MusicBottomInsetKey.self] }
        set { self[MusicBottomInsetKey.self] = newValue }
    }
}

/// The room at the end of a vertical scroll view of the Music popover.
struct MusicBottomInsetSpacer: View {
    @Environment(\.musicBottomInset) private var inset

    var body: some View {
        Color.clear
            .frame(height: inset)
            .accessibilityHidden(true)
    }
}

// MARK: - Tabs

extension MusicBrowseStore.Tab {
    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .search: "Search"
        }
    }

    /// The tab's icon. Only Home has a filled form; Library and Search stay outlined when selected.
    func symbol(selected: Bool) -> String {
        switch self {
        case .home: selected ? "house.fill" : "house"
        case .library: "square.stack"
        case .search: "magnifyingglass"
        }
    }
}
