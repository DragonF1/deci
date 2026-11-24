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

/// The crossfade icon in the foreground style: a faint line fading out and a full one fading in over it.
struct MusicCrossfadeGlyph: View {
    let fontSize: CGFloat
    let weight: Font.Weight

    nonisolated static let faintOpacity = 0.5

    /// What to fill: `solid` in the foreground style, `faint` in the same at `faintOpacity`. The two never overlap and
    /// neither overlaps itself, so a translucent foreground comes out as one even tone per line.
    struct Outline {
        let solid: Path
        let faint: Path
    }

    /// As wide as the SF Symbols beside it look; in height between the infinity and the shuffle glyph.
    nonisolated static func size(fontSize: CGFloat) -> CGSize {
        CGSize(width: fontSize * 1.22, height: fontSize * 0.74)
    }

    nonisolated static func outline(fontSize: CGFloat, weight: Font.Weight) -> Outline {
        let stroke = fontSize * (weight == .regular ? 0.095 : 0.115)
        let box = CGRect(origin: .zero, size: size(fontSize: fontSize)).insetBy(dx: stroke / 2, dy: stroke / 2)
        /// A fade curve from one left corner to the opposite right one, level at both ends.
        func fade(from start: CGFloat, to end: CGFloat) -> Path {
            Path { path in
                path.move(to: CGPoint(x: box.minX, y: start))
                path.addCurve(
                    to: CGPoint(x: box.maxX, y: end),
                    control1: CGPoint(x: box.midX, y: start),
                    control2: CGPoint(x: box.midX, y: end)
                )
            }
        }
        let round = StrokeStyle(lineWidth: stroke, lineCap: .round)
        let fadeIn = fade(from: box.maxY, to: box.minY)
        let fadeOut = fade(from: box.minY, to: box.maxY)
        return Outline(
            solid: fadeIn.strokedPath(round),
            faint: fadeOut.strokedPath(round).subtracting(fadeIn.strokedPath(StrokeStyle(lineWidth: stroke * 2.6)))
        )
    }

    var body: some View {
        let outline = Self.outline(fontSize: fontSize, weight: weight)
        let size = Self.size(fontSize: fontSize)
        ZStack {
            outline.solid.fill()
            outline.faint.fill().opacity(Self.faintOpacity)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}
