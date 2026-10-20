// Deci/Views/MenuBar/MusicChipRenderer.swift
// What the Now playing chip's layers are made from: the spec that says what the chip shows, the chip font and how a
// title measures in it, the pill's colour, the cover's music note and the paused pill's play glyph. The layers themselves
// are MusicChipContent's and MusicChipView's; the numbers come from MusicChipLayout.

import AppKit
import CoreText

/// What one look of the chip needs. Equal specs look the same, so the controller changes the chip only when one differs.
nonisolated struct MusicChipSpec: Equatable, Sendable {
    var title: String
    var isPlaying: Bool
    /// The pill's fill before it is darkened for the white text; the accent colour while the cover's is not known.
    var tint: MusicTint
    var hasThumbnail: Bool
    /// Which cover the chip shows, so a new cover under the same title still cross-fades.
    var coverURL: URL?
    /// Whether Reduce Motion is on: the title ends in an ellipsis instead of scrolling, and the width does not animate.
    var reduceMotion: Bool
}

nonisolated enum MusicChipRenderer {
    /// The tint of the system accent colour, for a chip whose cover colour is not known yet.
    @MainActor
    static func accentFallbackTint() -> MusicTint {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return MusicTint(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// The title's font: 12 pt semibold system.
    static var titleFont: NSFont {
        NSFont.systemFont(ofSize: MusicChipLayout.titleFontSize, weight: .semibold)
    }

    /// How wide `title` sets in the chip font, in points, measured the way the text layers set it (CoreText).
    static func titleWidth(_ title: String) -> Double {
        Double(CTLineGetTypographicBounds(line(for: title), nil, nil, nil))
    }

    /// The height of one line of the chip font, in whole points: what a text layer's box needs.
    static var titleLineHeight: Double {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line(for: "Ag"), &ascent, &descent, &leading)
        return Double(ascent + descent + leading).rounded(.up)
    }

    /// The pill's fill: the tint, darkened only as far as white text needs to read on it.
    static func fillColor(for tint: MusicTint) -> CGColor {
        let fill = MusicChipTint.rgb(of: MusicChipTint.readableFill(tint))
        return CGColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1)
    }

    /// The white music note of a chip whose cover is missing, drawn into a `side` pt square at `scale` pixels a point.
    @MainActor
    static func noteImage(side: CGFloat, scale: CGFloat) -> CGImage? {
        whiteSymbolImage(named: "music.note", pointSize: side * 0.62, side: side, scale: scale)
    }

    /// The white play triangle of a paused chip, centred in its square at `scale` pixels a point. The layer that shows it
    /// is nudged right of the pill's middle (`MusicChipLayout.playGlyphNudge`), so the image itself stays centred.
    @MainActor
    static func playGlyphImage(scale: CGFloat) -> CGImage? {
        whiteSymbolImage(
            named: "play.fill",
            pointSize: CGFloat(MusicChipLayout.playGlyphPointSize),
            side: CGFloat(MusicChipLayout.playGlyphSide),
            scale: scale
        )
    }

    /// An SF Symbol in bold white on clear, centred in a `side` pt square drawn at `scale` pixels a point.
    @MainActor
    private static func whiteSymbolImage(named name: String, pointSize: CGFloat, side: CGFloat, scale: CGFloat) -> CGImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let pixels = Int((side * scale).rounded(.up))
        guard pixels > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixels,
                  height: pixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let size = symbol.size
        let target = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
        // A symbol is drawn as a template: filling white over what it drew leaves the symbol in white.
        symbol.draw(in: target)
        NSColor.white.setFill()
        target.fill(using: .sourceIn)
        return context.makeImage()
    }

    private static func line(for title: String) -> CTLine {
        let text = NSAttributedString(string: title, attributes: [.font: titleFont])
        return CTLineCreateWithAttributedString(text as CFAttributedString)
    }
}
