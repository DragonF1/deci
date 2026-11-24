// Deci/Views/Music/MusicGlyph.swift
import SwiftUI

/// The glyph of a playback control by name: an SF Symbol, or our own drawing for `MusicTransitionMode.crossfadeSymbol`.
struct MusicGlyph: View {
    let name: String
    let fontSize: CGFloat
    let weight: Font.Weight

    /// The name stands for a drawing of ours, not an SF Symbol.
    nonisolated static func isCustom(_ name: String) -> Bool { name == MusicTransitionMode.crossfadeSymbol }

    var body: some View {
        if Self.isCustom(name) {
            MusicCrossfadeGlyph(fontSize: fontSize, weight: weight)
        } else {
            Image(systemName: name).font(.system(size: fontSize, weight: weight))
        }
    }
}

/// The crossfade icon in the foreground style: two clips on a timeline that overlap, one solid and the next an outline.
struct MusicCrossfadeGlyph: View {
    let fontSize: CGFloat
    let weight: Font.Weight

    /// One clip and the space between the two rows, in ems.
    private nonisolated static let clip = CGSize(width: 0.805, height: 0.378)
    private nonisolated static let rowGap: CGFloat = 0.085

    /// As wide as the SF Symbols beside it look; in height between the infinity and the shuffle glyph.
    nonisolated static func size(fontSize: CGFloat) -> CGSize {
        CGSize(width: fontSize * 1.22, height: fontSize * (clip.height * 2 + rowGap))
    }

    /// What to fill. The clips never overlap, so a translucent foreground comes out as one even tone.
    nonisolated static func outline(fontSize: CGFloat, weight: Font.Weight) -> Path {
        let stroke = fontSize * (weight == .regular ? 0.095 : 0.115)
        let frame = size(fontSize: fontSize)
        let clip = CGSize(width: fontSize * clip.width, height: fontSize * clip.height)
        let radius = clip.height * 0.42
        let first = CGRect(origin: .zero, size: clip)
        let second = CGRect(origin: CGPoint(x: frame.width - clip.width, y: frame.height - clip.height), size: clip)
            .insetBy(dx: stroke / 2, dy: stroke / 2)
        var path = Path(roundedRect: first, cornerRadius: radius)
        path.addPath(Path(roundedRect: second, cornerRadius: radius - stroke / 2).strokedPath(StrokeStyle(lineWidth: stroke)))
        return path
    }

    var body: some View {
        let size = Self.size(fontSize: fontSize)
        Self.outline(fontSize: fontSize, weight: weight).fill()
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }
}
