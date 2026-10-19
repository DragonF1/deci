// Deci/Views/Music/MusicStyle.swift
import AppKit
import SwiftUI

/// The tokens of the Music popover. It wears the Mixer's look: the same glass background, the same adaptive colours
/// (`.primary` at an opacity, so light and dark both work), the Mixer's type scale (13 pt rows, 11 pt second lines,
/// small section headers) and its spacing and radii. The player screens force a dark scheme locally
/// (`musicDarkScope`), over the dark cover backdrop, where `.primary` is white and the glass is the pinned dark blur.
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
        /// The mini player's glass tint.
        static let glassFill = DesignTokens.dynamicColor(
            name: "musicGlassFill",
            light: NSColor.white.withAlphaComponent(0.45),
            dark: NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 0.55)
        )
        static let cardGlassFill = DesignTokens.dynamicColor(
            name: "musicCardGlassFill",
            light: NSColor.white.withAlphaComponent(0.85),
            dark: NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 0.82)
        )

        // Accent: the system accent, like the Mixer's sliders and selections.
        static let accent = Color.accentColor
        static let accentFill = Color.accentColor.opacity(0.20)
        static let accentRow = Color.accentColor.opacity(0.10)
        static let destructive = Color(nsColor: .systemRed)

        // Text
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let textTertiary = DesignTokens.Colors.textTertiary
        static let textQuaternary = DesignTokens.Colors.textQuaternary
        /// The artist under the title on the player screens.
        static let playerSubtitle = Color.primary.opacity(0.62)

        // Fills
        static let fillControl = Color.primary.opacity(0.10)
        static let sliderTrack = DesignTokens.Colors.sliderTrack

        // Lines
        static let lineHairline = Color.primary.opacity(0.08)
        static let lineGlass = DesignTokens.Colors.glassBorder
        static let dimModal = DesignTokens.dynamicColor(
            name: "musicDimModal",
            light: NSColor.black.withAlphaComponent(0.20),
            dark: NSColor.black.withAlphaComponent(0.45)
        )

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
        static let miniPlayerHeight: CGFloat = 42
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
        /// Under the cover of Now Playing.
        static let npArt = Shadow(color: .black.opacity(0.40), radius: 14, y: 8)
        /// Under the small cover in the Lyrics and Up next header.
        static let headerArt = Shadow(color: .black.opacity(0.30), radius: 5, y: 3)
    }
}

// MARK: - View helpers

extension View {
    /// The font and tracking of a Music text style.
    func musicText(_ style: MusicStyle.TextStyle) -> some View {
        font(style.font).tracking(style.appliedTracking)
    }

    /// One glass surface of the Music popover. On macOS 26 and later it is the system glass tinted with `fill`; on
    /// earlier systems a frosted blur under the fill. Inside a forced-dark scope (`musicDarkScope`) it is always the
    /// pinned dark blur, whatever appearance the window wears. The stroke and the shadow are drawn on all of them.
    func musicGlass<S: InsettableShape>(
        in shape: S,
        fill: Color = MusicStyle.Palette.glassFill,
        stroke: Color? = MusicStyle.Palette.lineGlass,
        shadow: MusicStyle.Shadow? = .glass
    ) -> some View {
        modifier(MusicGlassModifier(shape: shape, fill: fill, stroke: stroke, shadow: shadow))
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

private struct MusicGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    let stroke: Color?
    let shadow: MusicStyle.Shadow?
    @Environment(\.musicForcedDark) private var forcedDark

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                if let stroke {
                    shape.strokeBorder(stroke, lineWidth: 1)
                }
            }
            .shadow(color: shadow?.color ?? .clear, radius: shadow?.radius ?? 0, y: shadow?.y ?? 0)
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if #available(macOS 26, *), !forcedDark {
            content.glassEffect(.regular.tint(fill), in: shape)
        } else {
            content.background {
                MusicBlurBackground(shape: shape)
                shape.fill(fill)
            }
        }
    }
}
