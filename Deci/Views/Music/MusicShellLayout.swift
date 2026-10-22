// Deci/Views/Music/MusicShellLayout.swift
import SwiftUI

/// What fills the right column. Browse is the tabs and the pages opened from them (search results sit over it);
/// Lyrics, Up next and Related each take the column in place of it. The save to playlist menu floats over the popup
/// instead.
nonisolated enum MusicRightColumn: Equatable {
    case browse
    case lyrics
    case queue
    case related

    /// The panels are never on together, since turning one on turns the others off; if two ever were, Lyrics wins, then
    /// Up next, then Related.
    static func resolve(showsLyrics: Bool, showsQueue: Bool, showsRelated: Bool) -> MusicRightColumn {
        if showsLyrics { return .lyrics }
        if showsQueue { return .queue }
        if showsRelated { return .related }
        return .browse
    }

    /// Which header the column wears. Lyrics, Up next and Related have their own; browse wears
    /// Home, Library, History, the magnifier and the avatar.
    enum Header: Equatable {
        case browse
        case lyrics
        case queue
        case related
    }

    var header: Header {
        switch self {
        case .lyrics: .lyrics
        case .queue: .queue
        case .related: .related
        case .browse: .browse
        }
    }

    /// Lyrics, Up next and Related sit on an accent wash; browse is plain.
    var hasWash: Bool {
        switch self {
        case .lyrics, .queue, .related: true
        case .browse: false
        }
    }
}

/// The three tabs of the right column's header: Home, Library and History. Search is not one: the magnifier opens a
/// field in the header, and the tab it was opened on stays highlighted.
nonisolated enum MusicHeaderTab: CaseIterable, Equatable {
    case home
    case library
    case history

    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .history: "History"
        }
    }

    /// The browse tab this one opens.
    var browseTab: MusicBrowseStore.Tab {
        switch self {
        case .home: .home
        case .library: .library
        case .history: .history
        }
    }

    /// The tab to highlight: each browse tab and the pages opened from it is its own header tab.
    static func resolve(tab: MusicBrowseStore.Tab) -> MusicHeaderTab {
        switch tab {
        case .home: .home
        case .library: .library
        case .history: .history
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

    /// The least space between the times and the view count under the spectrum, so the two never read as one run. A row
    /// without that much room shows a shorter count.
    static let timesRowGap: CGFloat = 8

    /// The gap between the spectrum and the times row under it.
    static let spectrumBlockSpacing: CGFloat = 6

    /// The player column's gap between its blocks (the song, the spectrum and times, the transport, the view buttons).
    static let playerColumnSpacing: CGFloat = 10

    /// The space between the times row and the transport, which holds the strip of Like and Dislike. The spectrum takes
    /// whatever the column leaves, so it ends this much (and its own 6 pt gap and the times) above the transport.
    static let timesToTransport: CGFloat = 23

    /// The strip of Like and Dislike: a 12 pt glyph in a box 12 wide and 12 high. It is out of the layout, behind the
    /// transport, and ends `rateStripLift` over the transport's boxes. The times' digits then end 12 pt over the icons
    /// and the icons 12 pt over Previous and Next, the same gap on both sides and about half the 22 pt from Next down
    /// to Up next.
    static let rateGlyphSize: CGFloat = 12
    static let rateStripHeight: CGFloat = 12
    static let rateStripLift: CGFloat = 2

    /// Each icon's hit area, 24 wide and 20 high, centred on its box. It reaches `rateReachX` and `rateReachY` past the
    /// box, out of the layout; above the strip the reach ends where the times row does, and below it the reach runs
    /// into the transport's boxes, which are in front and so keep their own clicks.
    static let rateHitWidth: CGFloat = 24
    static let rateHitHeight: CGFloat = 20
    static var rateReachX: CGFloat { (rateHitWidth - rateGlyphSize) / 2 }
    static var rateReachY: CGFloat { (rateHitHeight - rateStripHeight) / 2 }

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

    /// The least the open search field is wide before inactive tabs make room for it: its width beside the Home and
    /// Library tabs in the compact popup, when there were two tabs.
    static let openFieldMinWidth: CGFloat = 154

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

/// The transport row's layout rule. Five boxes stand in a row (Shuffle, Previous, play and pause, Next and Loop), with
/// the row's spare width shared equally by the four Spacers between them. The row is built from these measures, and so
/// is what is placed against its glyphs (the strip of Like and Dislike above it), so the two cannot drift apart. Pure.
nonisolated enum MusicTransportMetrics {
    /// The boxes, left to right.
    enum Slot: Int, CaseIterable {
        case shuffle
        case previous
        case playPause
        case next
        case loop
    }

    /// The width the design draws each glyph in.
    static func box(_ slot: Slot) -> CGFloat {
        switch slot {
        case .shuffle, .loop: 13
        case .previous, .next: 16
        case .playPause: 32
        }
    }

    /// The row's height, which is the play and pause button's.
    static let height: CGFloat = 32

    /// How bright Shuffle and Loop are while off, and the strip's icons while they are not the song's rating.
    static let restingGlyphOpacity = 0.50

    /// The room between two neighbouring boxes: the width the five boxes leave, over the four gaps. A row with no room
    /// to spare has no gap.
    static func gap(width: CGFloat = MusicPopupMetrics.playerColumnContentWidth) -> CGFloat {
        guard width.isFinite else { return 0 }
        let boxes = Slot.allCases.reduce(CGFloat(0)) { $0 + box($1) }
        return max(0, (width - boxes) / CGFloat(Slot.allCases.count - 1))
    }

    /// The middle of a glyph's box, from the row's leading edge.
    static func centreX(of slot: Slot, width: CGFloat = MusicPopupMetrics.playerColumnContentWidth) -> CGFloat {
        let spacing = gap(width: width)
        var left: CGFloat = 0
        for earlier in Slot.allCases where earlier.rawValue < slot.rawValue {
            left += box(earlier) + spacing
        }
        return left + box(slot) / 2
    }

    /// Like's middle: halfway between the centres of Shuffle and Previous.
    static func likeCentreX(width: CGFloat = MusicPopupMetrics.playerColumnContentWidth) -> CGFloat {
        (centreX(of: .shuffle, width: width) + centreX(of: .previous, width: width)) / 2
    }

    /// Dislike's middle: halfway between the centres of Next and Loop.
    static func dislikeCentreX(width: CGFloat = MusicPopupMetrics.playerColumnContentWidth) -> CGFloat {
        (centreX(of: .next, width: width) + centreX(of: .loop, width: width)) / 2
    }
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
