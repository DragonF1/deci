// Deci/Views/Music/MusicShellLayout.swift
import SwiftUI

/// What fills the right column. Browse is Home, Library and the pages opened from them (search results sit over it);
/// Lyrics and Up next each take the column in place of it. The save to playlist menu floats over the popup instead.
nonisolated enum MusicRightColumn: Equatable {
    case browse
    case lyrics
    case queue

    static func resolve(showsLyrics: Bool, showsQueue: Bool) -> MusicRightColumn {
        if showsLyrics { return .lyrics }
        if showsQueue { return .queue }
        return .browse
    }

    /// Which header the column wears. Lyrics and Up next have their own, with a Browse pill that goes back; browse wears
    /// Home, Library, the magnifier and the avatar.
    enum Header: Equatable {
        case browse
        case lyrics
        case queue
    }

    var header: Header {
        switch self {
        case .lyrics: .lyrics
        case .queue: .queue
        case .browse: .browse
        }
    }

    /// Lyrics and Up next sit on an accent wash; browse is plain.
    var hasWash: Bool {
        switch self {
        case .lyrics, .queue: true
        case .browse: false
        }
    }
}

/// The two tabs of the right column's header. Search is not one: the magnifier opens a field in the header, and the
/// tab it was opened on stays highlighted.
nonisolated enum MusicHeaderTab: CaseIterable, Equatable {
    case home
    case library

    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        }
    }

    /// The browse tab this one opens.
    var browseTab: MusicBrowseStore.Tab {
        switch self {
        case .home: .home
        case .library: .library
        }
    }

    /// The tab to highlight: Library and the pages opened from it are Library; everything else is Home.
    static func resolve(tab: MusicBrowseStore.Tab) -> MusicHeaderTab {
        switch tab {
        case .home: .home
        case .library: .library
        }
    }
}

/// The geometry of the Music popup: a split pane inside a 1 pt border. The player column on the left is 170 pt wide, a
/// 1 pt divider follows, and the right column takes the rest. It is 520 pt tall at every popup size; the width is the
/// popup size setting's.
nonisolated enum MusicPopupMetrics {
    static let height: CGFloat = 520
    static let cornerRadius: CGFloat = 12
    static let borderWidth: CGFloat = 1

    static let playerColumnWidth: CGFloat = 170
    static let playerColumnPadding: CGFloat = 14
    static let dividerWidth: CGFloat = 1

    /// What the player column's content gets: the cover, the spectrum and the transport are this wide.
    static var playerColumnContentWidth: CGFloat { playerColumnWidth - 2 * playerColumnPadding }

    /// The right column's own header, and the padding around it and the content under it.
    static let headerHeight: CGFloat = 32
    static let rightPaddingTop: CGFloat = 8
    static let rightPaddingSide: CGFloat = 16
    static let rightPaddingBottom: CGFloat = 14

    /// The accent wash behind Lyrics and Up next: this opacity at the top of the column, nothing at 90% of its height.
    static let panelWashOpacity = 0.10
    static let panelWashEnd: CGFloat = 0.9

    /// Lyrics fills the column with 20 pt at the sides (the rows' own 8 pt padding is part of it) and 8 under the header.
    static let lyricsPaddingSide: CGFloat = 20
    static let lyricsPaddingTop: CGFloat = 8

    /// The avatar in the header.
    static let avatarSize: CGFloat = 22

    /// The gap between the avatar and the account card under it.
    static let accountCardGap: CGFloat = 6

    /// The right column's width in a popup `popupWidth` wide: what the border, the player column and the divider leave.
    static func rightColumnWidth(popupWidth: CGFloat) -> CGFloat {
        max(0, popupWidth - 2 * borderWidth - playerColumnWidth - dividerWidth)
    }

    /// The width of the header and of the content under it.
    static func rightColumnContentWidth(popupWidth: CGFloat) -> CGFloat {
        max(0, rightColumnWidth(popupWidth: popupWidth) - 2 * rightPaddingSide)
    }

    /// The top edge of the right column's header: under the border and the padding.
    static var headerTop: CGFloat { borderWidth + rightPaddingTop }

    /// Where the account card hangs from the popup's top: the header's top, down to the bottom of the avatar (which is
    /// centred in the header), and the gap.
    static var accountCardTop: CGFloat { headerTop + (headerHeight + avatarSize) / 2 + accountCardGap }

    /// The distance from the popup's trailing edge to the card's, which ends where the avatar does.
    static var accountCardTrailing: CGFloat { borderWidth + rightPaddingSide }
}

// MARK: - Bottom inset

private struct MusicBottomInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How far floating chrome reaches up from the bottom of the right column. A vertical scroll view of the Music
    /// popup ends with this much room, so its last row can scroll clear of it.
    var musicBottomInset: CGFloat {
        get { self[MusicBottomInsetKey.self] }
        set { self[MusicBottomInsetKey.self] = newValue }
    }
}

/// The room at the end of a vertical scroll view of the Music popup.
struct MusicBottomInsetSpacer: View {
    @Environment(\.musicBottomInset) private var inset

    var body: some View {
        Color.clear
            .frame(height: inset)
            .accessibilityHidden(true)
    }
}
