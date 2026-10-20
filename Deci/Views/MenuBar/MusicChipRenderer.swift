// Deci/Views/MenuBar/MusicChipRenderer.swift
// Draws the Now playing chip as one non-template image for the Music status item's button. A drawing handler image, so
// it is crisp at any backing scale and no ImageRenderer is involved. The numbers come from MusicChipLayout.

import AppKit

/// What one drawing of the chip needs. Equal specs draw the same picture, so the controller redraws only when one changes.
nonisolated struct MusicChipSpec: Equatable, Sendable {
    var title: String
    var isPlaying: Bool
    /// The pill's fill before it is darkened for the white text; the accent colour while the cover's is not known.
    var tint: MusicTint
    var hasThumbnail: Bool
}

nonisolated enum MusicChipRenderer {
    /// A decoded cover that crosses into the drawing handler. A CGImage is immutable.
    private struct ThumbnailBox: @unchecked Sendable {
        let image: CGImage?
    }

    /// The tint of the system accent colour, for a chip whose cover colour is not known yet.
    @MainActor
    static func accentFallbackTint() -> MusicTint {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return MusicTint(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// The chip as an image sized to its title. Not a template: the pill keeps its colour in a light or a dark menu bar.
    static func image(for spec: MusicChipSpec, thumbnail: CGImage?) -> NSImage {
        let natural = naturalTitleWidth(spec.title)
        let size = NSSize(width: MusicChipLayout.width(naturalTitleWidth: natural), height: MusicChipLayout.height)
        let box = ThumbnailBox(image: thumbnail)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(spec, thumbnail: box.image, naturalTitleWidth: natural, in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = MusicChipLayout.accessibilityLabel(title: spec.title, isPlaying: spec.isPlaying)
        return image
    }

    /// How wide the title is set, before the 96 pt limit.
    static func naturalTitleWidth(_ title: String) -> Double {
        Double(NSAttributedString(string: title, attributes: [.font: titleFont]).size().width)
    }

    private static var titleFont: NSFont {
        NSFont.systemFont(ofSize: MusicChipLayout.titleFontSize, weight: .semibold)
    }

    // MARK: - Drawing

    private static func draw(_ spec: MusicChipSpec, thumbnail: CGImage?, naturalTitleWidth: Double, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let alpha = CGFloat(MusicChipLayout.contentAlpha(isPlaying: spec.isPlaying))

        // The pill.
        let fill = MusicChipTint.rgb(of: MusicChipTint.readableFill(spec.tint))
        let pill = NSBezierPath(
            roundedRect: rect,
            xRadius: MusicChipLayout.cornerRadius,
            yRadius: MusicChipLayout.cornerRadius
        )
        NSColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1).setFill()
        pill.fill()

        // The cover, round: the picture filling the circle, or a music note on grey.
        let thumbSide = MusicChipLayout.thumbnailSize
        let thumbRect = CGRect(
            x: MusicChipLayout.leadingInset,
            y: (rect.height - thumbSide) / 2,
            width: thumbSide,
            height: thumbSide
        )
        context.saveGState()
        context.setAlpha(alpha)
        context.addEllipse(in: thumbRect)
        context.clip()
        if let thumbnail {
            context.interpolationQuality = .high
            context.draw(thumbnail, in: aspectFill(imageWidth: thumbnail.width, imageHeight: thumbnail.height, in: thumbRect))
        } else {
            context.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
            context.fill(thumbRect)
            drawNote(in: thumbRect)
        }
        context.restoreGState()

        // The title: 12 pt semibold white, one line, cut at 96 pt with a short fade instead of an ellipsis.
        let titleWidth = MusicChipLayout.titleWidth(naturalTitleWidth: naturalTitleWidth)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        let text = NSAttributedString(string: spec.title, attributes: attributes)
        let lineHeight = text.size().height
        let titleRect = CGRect(
            x: MusicChipLayout.titleOriginX,
            y: 0,
            width: titleWidth,
            height: rect.height
        )
        context.saveGState()
        context.clip(to: titleRect)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        text.draw(at: NSPoint(x: titleRect.minX, y: (rect.height - lineHeight) / 2))
        if let fadeStart = MusicChipLayout.fadeStart(naturalTitleWidth: naturalTitleWidth) {
            applyFade(in: context, titleRect: titleRect, fadeStart: titleRect.minX + fadeStart)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Multiplies what the transparency layer holds by a gradient that is 1 up to `fadeStart` and 0 at the title's end.
    private static func applyFade(in context: CGContext, titleRect: CGRect, fadeStart: CGFloat) {
        let colors = [
            CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 0),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) else {
            return
        }
        context.setBlendMode(.destinationIn)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: fadeStart, y: 0),
            end: CGPoint(x: titleRect.maxX, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.setBlendMode(.normal)
    }

    /// The music note of a chip whose cover is missing.
    private static func drawNote(in rect: CGRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height * 0.62, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        let target = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let tinted = NSImage(size: size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.white.setFill()
            bounds.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: target)
    }

    /// The rect a picture is drawn in so that it covers `target` with its centre in the middle (the part outside is
    /// clipped away).
    static func aspectFill(imageWidth: Int, imageHeight: Int, in target: CGRect) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return target }
        let scale = max(target.width / CGFloat(imageWidth), target.height / CGFloat(imageHeight))
        let width = CGFloat(imageWidth) * scale
        let height = CGFloat(imageHeight) * scale
        return CGRect(x: target.midX - width / 2, y: target.midY - height / 2, width: width, height: height)
    }
}
