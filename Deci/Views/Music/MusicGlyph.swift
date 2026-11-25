// Deci/Views/Music/MusicGlyph.swift
import SwiftUI

/// The glyph of a playback control by name: an SF Symbol, or our own drawing for `MusicTransitionMode.crossfadeSymbol` and
/// `MusicShuffleMode.flowSymbol`.
struct MusicGlyph: View {
    let name: String
    let fontSize: CGFloat
    let weight: Font.Weight

    /// The name stands for a drawing of ours, not an SF Symbol.
    nonisolated static func isCustom(_ name: String) -> Bool {
        name == MusicTransitionMode.crossfadeSymbol || name == MusicShuffleMode.flowSymbol
    }

    var body: some View {
        switch name {
        case MusicTransitionMode.crossfadeSymbol: MusicCrossfadeGlyph(fontSize: fontSize, weight: weight)
        case MusicShuffleMode.flowSymbol: MusicFlowShuffleGlyph(fontSize: fontSize, weight: weight)
        default: Image(systemName: name).font(.system(size: fontSize, weight: weight))
        }
    }
}

/// The Flow Shuffle icon in the foreground style: the shuffle glyph with a sparkle past its top right corner. The sparkle
/// takes no room in the layout, so the arrows stay where they are when the button goes from Shuffle to Flow Shuffle.
struct MusicFlowShuffleGlyph: View {
    let fontSize: CGFloat
    let weight: Font.Weight

    nonisolated static let sparkleSymbol = "sparkle"

    /// What puts arrows and sparkle together in the middle, for a place with an edge close around the glyph.
    nonisolated static func centering(fontSize: CGFloat) -> CGSize { CGSize(width: -fontSize * 0.21, height: fontSize * 0.16) }

    var body: some View {
        Image(systemName: MusicShuffleMode.symbol)
            .font(.system(size: fontSize, weight: weight))
            .overlay(alignment: .topTrailing) {
                Image(systemName: Self.sparkleSymbol)
                    .font(.system(size: fontSize * 0.52, weight: .bold))
                    .offset(x: fontSize * 0.34, y: -fontSize * 0.30)
            }
            .accessibilityHidden(true)
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
