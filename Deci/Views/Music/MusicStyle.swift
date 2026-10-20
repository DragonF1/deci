// Deci/Views/Music/MusicStyle.swift
import AppKit
import SwiftUI

/// The tokens of the Music popover: the Mixer's type scale (13 pt rows, 11 pt second lines, small section headers) and
/// its spacing and radii, on the split pane's fixed dark colours. The popup is dark whatever the Mixer wears: its window
/// is forced to dark Aqua and `musicDarkScope` pins the scheme, so `.primary` is white and blur surfaces are the pinned
/// dark blur.
enum MusicStyle {

    // MARK: - Colours

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

        // Surfaces
        static let toast = DesignTokens.dynamicColor(
            name: "musicToast",
            light: NSColor.white.withAlphaComponent(0.92),
            dark: NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 0.96)
        )

        // Accent: the system accent, like the Mixer's sliders and selections.
        static let accent = Color.accentColor
        static let accentFill = Color.accentColor.opacity(0.20)
        static let accentRow = Color.accentColor.opacity(0.10)

        // Text
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let textTertiary = DesignTokens.Colors.textTertiary
        static let textQuaternary = DesignTokens.Colors.textQuaternary

        // Fills
        static let fillControl = Color.primary.opacity(0.10)
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

        static let likedGradient = LinearGradient(
            stops: [
                .init(color: hex(0xFF6E87), location: 0),
                .init(color: hex(0xFA2D48), location: 0.55),
                .init(color: hex(0xB8123D), location: 1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Type scale

    /// A size, a weight and a tracking. The system font already tightens itself per size, so a negative tracking only
    /// applies from 24 pt up; a positive one is always kept.
    struct TextStyle: Equatable {
        let size: CGFloat
        let weight: Font.Weight
        let tracking: CGFloat

        init(_ size: CGFloat, _ weight: Font.Weight = .regular, tracking: CGFloat = 0) {
            self.size = size
            self.weight = weight
            self.tracking = tracking
        }

        /// The tracking that is applied: negative values only at 24 pt and above.
        var appliedTracking: CGFloat {
            tracking < 0 && size < 24 ? 0 : tracking
        }

        var font: Font { .system(size: size, weight: weight) }
    }

    /// The Mixer's scale: 13 pt row names, 11 pt second lines and pickers, 10 pt captions. Only a page's name and the
    /// player's song name go a little above it.
    enum Typeface {
        static let title = TextStyle(16, .bold)
        static let songTitle = TextStyle(15, .semibold)
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
    }

    // MARK: - Radii

    enum Radius {
        /// The Mixer's button radius: covers, hover rows, small buttons.
        static let small: CGFloat = DesignTokens.Dimensions.buttonRadius
        static let art: CGFloat = DesignTokens.Dimensions.buttonRadius
        /// Cards and tiles: the Mixer's row radius.
        static let card: CGFloat = DesignTokens.Dimensions.rowRadius
    }

    // MARK: - Spacing and sizes

    enum Spacing {
        /// The horizontal margin of browse screens: the Mixer's content padding.
        static let page: CGFloat = DesignTokens.Spacing.lg
        /// The gap between a section header and its content.
        static let sectionContent: CGFloat = DesignTokens.Spacing.sm
        /// The gap between two Home sections.
        static let sectionGap: CGFloat = DesignTokens.Spacing.md
        static let shelfGap: CGFloat = DesignTokens.Spacing.sm
        static let pinnedGap: CGFloat = DesignTokens.Spacing.sm
    }

    enum Size {
        /// The header's round and pill buttons: the Mixer's 26 pt.
        static let headerButton: CGFloat = 26
        static let topPickWidth: CGFloat = 120
        static let topPickHeight: CGFloat = 152
        static let coverTile: CGFloat = 76
        static let pinnedPhoto: CGFloat = 40
        static let pinnedTileWidth: CGFloat = 56
        static let quickPickRowHeight: CGFloat = 40
        static let quickPickArt: CGFloat = 32
    }

    // MARK: - Shadows

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let y: CGFloat

        static let glass = Shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        /// Under the small cover in a page's header.
        static let headerArt = Shadow(color: .black.opacity(0.30), radius: 5, y: 3)
    }
}

// MARK: - View helpers

extension View {
    /// The font and tracking of a Music text style.
    func musicText(_ style: MusicStyle.TextStyle) -> some View {
        font(style.font).tracking(style.appliedTracking)
    }

    /// A frosted capsule, card or pill backdrop clipped to `shape`: the system's ultra thin material, or the pinned
    /// dark blur inside a forced-dark scope.
    func musicBlurBackground<S: Shape>(in shape: S) -> some View {
        background { MusicBlurBackground(shape: shape) }
    }

    /// Reads dark when `isForced`, whatever the window wears: SwiftUI colours resolve in the dark scheme and the
    /// glass and blur surfaces switch to their pinned dark variants. The system's own glass and materials follow the
    /// window's NSAppearance, which the Mixer setting owns, so the colour scheme alone does not reach them. Not
    /// `.preferredColorScheme`: that flips the whole window and fights the appearance bridge.
    func musicDarkScope(_ isForced: Bool = true) -> some View {
        modifier(MusicDarkScopeModifier(isForced: isForced))
    }
}

private struct MusicForcedDarkKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside `musicDarkScope`: glass and blur surfaces draw their dark variants.
    var musicForcedDark: Bool {
        get { self[MusicForcedDarkKey.self] }
        set { self[MusicForcedDarkKey.self] = newValue }
    }
}

private struct MusicDarkScopeModifier: ViewModifier {
    let isForced: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, isForced ? .dark : colorScheme)
            .environment(\.musicForcedDark, isForced)
    }
}

/// A dark frosted blur whose NSAppearance is pinned to dark Aqua, so it stays dark under a light window.
struct MusicDarkBlur: NSViewRepresentable {
    /// The pinned view: a HUD material blurring what is behind it inside the window.
    @MainActor
    static func makeEffectView() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func makeNSView(context: Context) -> NSVisualEffectView { Self.makeEffectView() }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The frosted backdrop of a card or capsule: the system's ultra thin material, or the pinned dark blur in a forced-dark
/// scope.
private struct MusicBlurBackground<S: Shape>: View {
    let shape: S
    @Environment(\.musicForcedDark) private var forcedDark

    var body: some View {
        if forcedDark {
            MusicDarkBlur().clipShape(shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}
