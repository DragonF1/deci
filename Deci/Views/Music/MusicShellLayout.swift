// Deci/Views/Music/MusicShellLayout.swift
import SwiftUI

/// The measures of the Music shell that depend on the width of the popover. The popover keeps the size of its
/// setting, so everything is laid out against the real width.
nonisolated enum MusicShellLayout {
    /// The side margin of browse screens: the Mixer's content padding.
    static let pageMargin: CGFloat = 16

    /// The gap between the mini player and the bottom edge of the popover, and its side margin.
    static let miniPlayerMargin: CGFloat = 10

    /// The mini player's bottom edge above the popover bottom.
    static let miniPlayerBottom: CGFloat = miniPlayerMargin

    /// The height of the fade the last rows dissolve in, over the mini player. Its top is a little above the player.
    static let scrimHeight: CGFloat = 64

    /// The gap between the two Quick picks columns.
    static let quickPickColumnGap: CGFloat = 12

    /// How far the mini player reaches up from the bottom edge: its height and the gap under it.
    static var miniPlayerFootprint: CGFloat { MusicStyle.Size.miniPlayerHeight + miniPlayerBottom }

    /// Room kept between the last row and the mini player.
    static let miniPlayerClearance: CGFloat = 12

    /// Space under the last row of a browse scroll view: the mini player's footprint and some clearance, so the last row
    /// scrolls clear of the player. Without a player, the page margin.
    static func bottomInset(hasMiniPlayer: Bool) -> CGFloat {
        hasMiniPlayer ? miniPlayerFootprint + miniPlayerClearance : pageMargin
    }

    /// The mini player is as wide as the popover less its side margin on each side.
    static func miniPlayerWidth(forWidth width: CGFloat) -> CGFloat {
        max(0, width - 2 * miniPlayerMargin)
    }
}

/// Which screen the Music shell shows. Browse screens (Home, Library, Search and the pages opened from them) wear the
/// mini player; the three player screens fill the popover and have none.
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
    /// The gap between the header row and the body, as in the Mixer.
    static let headerGap: CGFloat = 8

    /// The gap between the header's trailing buttons (avatar, gear).
    static let headerButtonGap: CGFloat = 8

    /// The whole height of the popover: the padding around a header row, a gap and the body. The shell draws edge to
    /// edge inside it, so the size does not change.
    static func totalHeight(maxContentHeight: CGFloat, contentPadding: CGFloat) -> CGFloat {
        2 * contentPadding + headerHeight + headerGap + bodyHeight(maxContentHeight: maxContentHeight)
    }

    /// Where the body starts: under the padding, the header row and the gap. A screen that draws a backdrop behind the
    /// header reaches up by this much.
    static func contentTop(contentPadding: CGFloat) -> CGFloat {
        contentPadding + headerHeight + headerGap
    }

    /// The distance from the popover's trailing edge to the avatar's: the padding, the gear and the gap between them.
    static func avatarTrailingInset(contentPadding: CGFloat) -> CGFloat {
        contentPadding + MusicStyle.Size.headerButton + headerButtonGap
    }

    /// Where the account card hangs: just under the avatar, which is centred in the header row.
    static func accountCardTop(contentPadding: CGFloat) -> CGFloat {
        contentPadding + (headerHeight + MusicStyle.Size.headerButton) / 2 + 6
    }
}

private struct MusicContentTopKey: EnvironmentKey {
    static let defaultValue: CGFloat = 56
}

extension EnvironmentValues {
    /// Where the body of the Music popup starts (`MusicPopupMetrics.contentTop`): the signed-in screens leave this
    /// much room for the header row, and a backdrop that covers the header reaches up by it.
    var musicContentTop: CGFloat {
        get { self[MusicContentTopKey.self] }
        set { self[MusicContentTopKey.self] = newValue }
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
