// Deci/Views/Music/MusicStyle.swift
import SwiftUI

/// The tokens of the Music popover: the Mixer's type scale (13 pt rows, 11 pt second lines, small section headers) and
/// its spacing and radii, on the split pane's fixed dark colours. The popup is dark whatever the Mixer wears: its window
/// is forced to dark Aqua and `musicDarkScope` pins the scheme, so `.primary` is white.
enum MusicStyle {

    // MARK: - Colours

    /// The white opacities of the right column: text from the page title down to a track number, the strokes of chips and
    /// buttons, and the fills under the pointer and under a picked segment.
    nonisolated enum Opacity {
        static let title = 0.97
        static let heading = 0.95
        static let row = 0.90
        static let playing = 1.0
        static let sub = 0.50
        static let meta = 0.45
        static let number = 0.40
        static let tileTitle = 0.88
        static let strokeSoft = 0.12
        static let strokeButton = 0.14
        static let rowHover = 0.07
        static let chipSelected = 0.12
        static let segmentTrack = 0.06
        static let segmentSelected = 0.14
        /// An unpicked segment, and the Back row.
        static let idleControl = 0.55
        /// The line under a page's title.
        static let pageSub = 0.70
        static let chevron = 0.30
    }

    enum Palette {
        static func hex(_ value: UInt32, opacity: Double = 1) -> Color {
            Color(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: opacity
            )
        }

        // Text
        static let textSecondary = Color.secondary
        static let textTertiary = DesignTokens.Colors.textTertiary

        // Fills
        static let sliderTrack = DesignTokens.Colors.sliderTrack

        // Lines
        static let lineHairline = Color.primary.opacity(0.08)

        // The split pane: fixed colours, since the Music popup is always dark.
        /// The popup's background, and the ink on the white play button.
        static let popupBackground = hex(0x141416)
        /// The player column's base, under the accent wash.
        static let playerPanel = hex(0x18181B)
        /// The column divider and the hairlines between rows.
        static let hairline = Color.white.opacity(0.07)
        /// The popup's 1 pt outer border.
        static let popupBorder = Color.white.opacity(0.10)
        /// The native style menus (the account card): fill, border and the highlighted row.
        static let menuFill = hex(0x2A2A2D)
        static let menuBorder = Color.white.opacity(0.12)
        static let menuHighlight = hex(0x0A63D8)

        // The right column's Signal look: white at fixed opacities on the near black popup. The numbers are in `Opacity`.
        static let textTitle = Color.white.opacity(Opacity.title)
        static let textHeading = Color.white.opacity(Opacity.heading)
        static let textRow = Color.white.opacity(Opacity.row)
        static let textPlaying = Color.white.opacity(Opacity.playing)
        static let textSub = Color.white.opacity(Opacity.sub)
        static let textMeta = Color.white.opacity(Opacity.meta)
        static let textNumber = Color.white.opacity(Opacity.number)
        static let textTile = Color.white.opacity(Opacity.tileTitle)
        static let strokeSoft = Color.white.opacity(Opacity.strokeSoft)
        static let strokeButton = Color.white.opacity(Opacity.strokeButton)
        static let rowHover = Color.white.opacity(Opacity.rowHover)
        static let chipSelected = Color.white.opacity(Opacity.chipSelected)
        static let segmentTrack = Color.white.opacity(Opacity.segmentTrack)
        static let segmentSelected = Color.white.opacity(Opacity.segmentSelected)
        static let chevron = Color.white.opacity(Opacity.chevron)
        static let textPageSub = Color.white.opacity(Opacity.pageSub)
    }

    // MARK: - Type scale

    /// A size, a weight and a tracking. The system font already tightens itself per size, so a negative tracking only
    /// applies from 24 pt up; a positive one is always kept.
    struct TextStyle: Equatable {
        let size: CGFloat
        let weight: Font.Weight
        let tracking: CGFloat
        /// Digits of one width, for durations and track numbers that line up down a list.
        let mono: Bool

        init(_ size: CGFloat, _ weight: Font.Weight = .regular, tracking: CGFloat = 0, mono: Bool = false) {
            self.size = size
            self.weight = weight
            self.tracking = tracking
            self.mono = mono
        }

        /// The tracking that is applied: negative values only at 24 pt and above.
        var appliedTracking: CGFloat {
            tracking < 0 && size < 24 ? 0 : tracking
        }

        var font: Font {
            let font = Font.system(size: size, weight: weight)
            return mono ? font.monospacedDigit() : font
        }
    }

    /// The Mixer's scale: 13 pt row names, 11 pt second lines and pickers, 10 pt captions. Only a page's name and the
    /// player's song name go a little above it.
    enum Typeface {
        static let heading = TextStyle(13, .semibold)
        static let row = TextStyle(13)
        static let rowMedium = TextStyle(13, .medium)
        static let secondary = TextStyle(11)
        static let secondaryMedium = TextStyle(11, .medium)
        static let button = TextStyle(11, .semibold)
        static let caption = TextStyle(10)
        static let kicker = TextStyle(10, .semibold, tracking: 0.5)
        /// The song in the player column.
        static let playerTitle = TextStyle(14, .semibold)
        /// The hint of an empty player column, and the header's tabs.
        static let emptyTitle = TextStyle(13, .semibold)
        static let tabActive = TextStyle(13, .semibold)
        static let tabInactive = TextStyle(13, .medium)
        /// The player column's small labels: the view buttons, the output device, the times.
        static let columnLabel = TextStyle(10, .medium)
        /// A section's "See all", and a duration that is not set in mono.
        static let seeAll = TextStyle(11)
        /// The durations of Album, Liked and Up next rows, and the track numbers.
        static let mono = TextStyle(11, mono: true)
        /// A detail page's name, the line under it and the chips and segments of the right column.
        static let pageTitle = TextStyle(17, .bold)
        static let pageSub = TextStyle(12, .medium)
        static let chip = TextStyle(11, .medium)
        /// What a loading, empty or failed list says.
        static let stateMessage = TextStyle(12)
        /// The line that says what a song action did.
        static let notice = TextStyle(12, .medium)
        /// The title of a state that has a screen to itself (signed out), and its button.
        static let stateTitle = TextStyle(15, .semibold)
        static let stateButton = TextStyle(12, .semibold)
    }

    // MARK: - Radii

    enum Radius {
        /// The Mixer's button radius: covers, hover rows, small buttons.
        static let small: CGFloat = DesignTokens.Dimensions.buttonRadius
        static let art: CGFloat = DesignTokens.Dimensions.buttonRadius
    }

    // MARK: - Spacing and sizes

    enum Spacing {
        /// The horizontal margin of browse screens: the Mixer's content padding.
        static let page: CGFloat = DesignTokens.Spacing.lg
        /// The gap between a section header and its content.
        static let sectionContent: CGFloat = DesignTokens.Spacing.sm
    }

    enum Size {
        static let pinnedPhoto: CGFloat = 40
        static let pinnedTileWidth: CGFloat = 56
    }
}

// MARK: - View helpers

extension View {
    /// The font and tracking of a Music text style.
    func musicText(_ style: MusicStyle.TextStyle) -> some View {
        font(style.font).tracking(style.appliedTracking)
    }

    /// Reads dark when `isForced`, whatever the window wears: SwiftUI colours resolve in the dark scheme. Not
    /// `.preferredColorScheme`: that flips the whole window and fights the appearance bridge.
    func musicDarkScope(_ isForced: Bool = true) -> some View {
        modifier(MusicDarkScopeModifier(isForced: isForced))
    }
}

private struct MusicDarkScopeModifier: ViewModifier {
    let isForced: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, isForced ? .dark : colorScheme)
    }
}
