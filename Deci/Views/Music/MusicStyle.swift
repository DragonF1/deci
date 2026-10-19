// Deci/Views/Music/MusicStyle.swift
import SwiftUI

/// The design tokens of the Music popover: colours, type scale, radii, spacing and shadows, in one place.
/// The Music popover is dark only, so none of these adapt to the appearance setting.
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
        static let base = hex(0x1C1C1E)
        static let elevated = hex(0x2C2C2E)
        static let toast = hex(0x3A3A3C)
        static let navButton = hex(0x1C1C1E, opacity: 0.35)
        static let glassFill = hex(0x2C2C2E, opacity: 0.55)
        static let glassFillHover = hex(0x2C2C2E, opacity: 0.65)
        static let cardGlassFill = hex(0x2C2C2E, opacity: 0.78)
        static let menuGlassFill = hex(0x2C2C2E, opacity: 0.94)

        // Accent
        static let accent = hex(0xFA2D48)
        static let accentFill = hex(0xFA2D48, opacity: 0.22)
        static let accentRow = hex(0xFA2D48, opacity: 0.10)
        static let destructive = hex(0xFF453A)

        // Text
        static let textPrimary = Color.white
        static let textSung = Color.white.opacity(0.65)
        static let textSecondary = Color.white.opacity(0.55)
        static let textSecondaryAlt = Color.white.opacity(0.60)
        static let textOnCard = Color.white.opacity(0.72)
        static let textTertiary = Color.white.opacity(0.45)
        static let textQuaternary = Color.white.opacity(0.35)
        static let textPlaceholder = Color.white.opacity(0.40)
        static let textTile = Color.white.opacity(0.85)
        static let textTab = Color.white.opacity(0.80)

        // Fills
        static let fillCard = Color.white.opacity(0.05)
        static let fillTrack = Color.white.opacity(0.07)
        static let fillHover = Color.white.opacity(0.08)
        static let fillControl = Color.white.opacity(0.10)
        static let fillControl2 = Color.white.opacity(0.12)
        static let fillControl3 = Color.white.opacity(0.14)
        static let fillSelected = Color.white.opacity(0.16)
        static let fillActive = Color.white.opacity(0.24)
        static let sliderTrack = Color.white.opacity(0.22)

        // Lines
        static let lineHairline = Color.white.opacity(0.08)
        static let lineDivider = Color.white.opacity(0.10)
        static let lineGlass = Color.white.opacity(0.12)
        static let lineGlyphTile = Color.white.opacity(0.18)
        static let lineBadge = Color.white.opacity(0.30)
        static let lineFocus = Color.white.opacity(0.60)
        static let dimModal = Color.black.opacity(0.50)

        static let avatarGradient = LinearGradient(
            colors: [hex(0xFF9F0A), hex(0xBF5AF2)], startPoint: .topLeading, endPoint: .bottomTrailing
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

    /// A size, a weight and the tracking as drawn in the mock. The system font already tightens itself per size,
    /// so a negative tracking only applies from 24 pt up; a positive one is always kept.
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

    enum Typeface {
        static let display = TextStyle(40, .bold, tracking: -1.0)
        static let title1 = TextStyle(26, .bold, tracking: -0.6)
        static let title2 = TextStyle(24, .bold, tracking: -0.5)
        static let title3 = TextStyle(20, .semibold, tracking: -0.4)
        static let headline = TextStyle(17, .bold, tracking: -0.3)
        static let lyric = TextStyle(17, .bold, tracking: -0.5)
        static let body17 = TextStyle(17, .regular, tracking: -0.2)
        static let name17 = TextStyle(17, .semibold, tracking: -0.3)
        static let cardTitle = TextStyle(16, .bold, tracking: -0.3)
        static let row15 = TextStyle(15, .regular, tracking: -0.2)
        static let row15M = TextStyle(15, .medium, tracking: -0.2)
        static let row15SB = TextStyle(15, .semibold, tracking: -0.2)
        static let subtitle15 = TextStyle(15, .semibold)
        static let status15 = TextStyle(15, .medium)
        static let row14M = TextStyle(14, .medium, tracking: -0.2)
        static let body14 = TextStyle(14, .regular)
        static let button14 = TextStyle(14, .semibold)
        static let callout = TextStyle(13, .semibold)
        static let miniTitle = TextStyle(13, .semibold, tracking: -0.1)
        static let row13M = TextStyle(13, .medium, tracking: -0.1)
        static let body13 = TextStyle(13, .regular)
        static let caption12 = TextStyle(12)
        static let caption12M = TextStyle(12, .medium)
        static let segment = TextStyle(12, .medium, tracking: -0.1)
        static let button12 = TextStyle(12, .semibold)
        static let caption11 = TextStyle(11, .medium)
        static let caption11R = TextStyle(11)
        static let tab = TextStyle(10, .semibold)
        static let kicker = TextStyle(10, .semibold, tracking: 0.5)
        static let badge10 = TextStyle(10, .semibold, tracking: 0.2)
    }

    // MARK: - Radii

    enum Radius {
        static let small: CGFloat = 6
        static let art: CGFloat = 8
        static let hoverRow: CGFloat = 8
        static let card: CGFloat = 12
        static let stateCard: CGFloat = 14
        static let popover: CGFloat = 16
        static let pill: CGFloat = 18
        static let tab: CGFloat = 22
        static let chrome: CGFloat = 26
    }

    // MARK: - Spacing and sizes

    enum Spacing {
        /// The horizontal margin of browse screens.
        static let page: CGFloat = 20
        /// The gap between a section header and its content.
        static let sectionContent: CGFloat = 8
        /// The gap between two Home sections.
        static let sectionGap: CGFloat = 16
        static let shelfGap: CGFloat = 12
        static let pinnedGap: CGFloat = 10
        static let searchArtistGap: CGFloat = 14
    }

    enum Size {
        static let headerButton: CGFloat = 24
        static let screenHeaderButton: CGFloat = 32
        static let miniPlayerHeight: CGFloat = 52
        static let tabBarHeight: CGFloat = 52
        static let tabWidth: CGFloat = 92
        static let tabHeight: CGFloat = 44
        static let topPickWidth: CGFloat = 176
        static let topPickHeight: CGFloat = 228
        static let coverTile: CGFloat = 112
        static let pinnedPhoto: CGFloat = 48
        static let pinnedTileWidth: CGFloat = 66
        static let quickPickRowHeight: CGFloat = 48
        static let quickPickArt: CGFloat = 40
    }

    // MARK: - Shadows

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let y: CGFloat

        static let glass = Shadow(color: .black.opacity(0.35), radius: 14, y: 10)
        static let button = Shadow(color: .black.opacity(0.30), radius: 12, y: 8)
        /// Under the raised segment of a segmented control only.
        static let segment = Shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    }
}

// MARK: - View helpers

extension View {
    /// The font and tracking of a Music text style.
    func musicText(_ style: MusicStyle.TextStyle) -> some View {
        font(style.font).tracking(style.appliedTracking)
    }

    /// One glass surface of the Music popover. On macOS 26 and later it is the system glass tinted with `fill`; on
    /// earlier systems an ultra thin material under the fill. The stroke and the shadow are drawn on both.
    func musicGlass<S: InsettableShape>(
        in shape: S,
        fill: Color = MusicStyle.Palette.glassFill,
        stroke: Color? = MusicStyle.Palette.lineGlass,
        shadow: MusicStyle.Shadow? = .glass
    ) -> some View {
        modifier(MusicGlassModifier(shape: shape, fill: fill, stroke: stroke, shadow: shadow))
    }
}

private struct MusicGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    let stroke: Color?
    let shadow: MusicStyle.Shadow?

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
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(fill), in: shape)
        } else {
            content.background {
                shape.fill(.ultraThinMaterial)
                shape.fill(fill)
            }
        }
    }
}
