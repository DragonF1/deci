// Deci/Views/Music/MusicCoverColor.swift
import CoreGraphics
import Foundation
import ImageIO

/// The colour of a cover: the average of its pixels, held to a saturation and a brightness at which the page's roles
/// (a dark page, a light accent, an ink) keep white text readable. Pure, apart from the decoding of the picture,
/// which has no state either.
nonisolated enum MusicCoverColor {
    /// A cover is shrunk to a square this wide before it is averaged: 16 by 16 pixels is plenty for one colour.
    static let sampleSide = 16

    /// Bounds of the cover colour's saturation and brightness. A grey cover keeps a faint tint instead of a hue that
    /// is only noise, and a neon one is calmed; a black or a white cover still gives the page a body.
    static let saturationRange: ClosedRange<Double> = 0.12...0.78
    static let brightnessRange: ClosedRange<Double> = 0.25...0.90

    /// Pixels at or under this alpha (of 255) are left out of the average: a transparent corner is not a colour.
    static let minimumAlpha: UInt8 = 8

    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// The mean colour of RGBA8 pixels, weighted by their alpha so a half transparent pixel counts for half. The bytes
    /// are straight, not premultiplied. Nil for no pixels, for a length that is not a whole number of pixels and for
    /// pixels that are all transparent.
    static func average(rgba: [UInt8]) -> RGB? {
        guard !rgba.isEmpty, rgba.count % 4 == 0 else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        var index = 0
        while index < rgba.count {
            let alpha = rgba[index + 3]
            if alpha > minimumAlpha {
                let w = Double(alpha) / 255
                red += Double(rgba[index]) / 255 * w
                green += Double(rgba[index + 1]) / 255 * w
                blue += Double(rgba[index + 2]) / 255 * w
                weight += w
            }
            index += 4
        }
        guard weight > 0 else { return nil }
        return RGB(red: red / weight, green: green / weight, blue: blue / weight)
    }

    /// Hue, saturation and brightness of a colour, each 0...1.
    static func hsb(_ color: RGB) -> (hue: Double, saturation: Double, brightness: Double) {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let delta = high - low
        let saturation = high > 0 ? delta / high : 0
        guard delta > 0 else { return (0, saturation, high) }
        var hue: Double
        switch high {
        case color.red: hue = (color.green - color.blue) / delta
        case color.green: hue = 2 + (color.blue - color.red) / delta
        default: hue = 4 + (color.red - color.green) / delta
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, saturation, high)
    }

    /// The tint of a colour: its hue, with the saturation and brightness held to their ranges.
    static func tint(of color: RGB) -> MusicTint {
        let value = hsb(color)
        return MusicTint(
            hue: value.hue,
            saturation: min(max(value.saturation, saturationRange.lowerBound), saturationRange.upperBound),
            brightness: min(max(value.brightness, brightnessRange.lowerBound), brightnessRange.upperBound)
        )
    }

    /// The tint of RGBA8 pixels; nil when they hold no colour (see `average`).
    static func tint(rgba: [UInt8]) -> MusicTint? {
        average(rgba: rgba).map(tint(of:))
    }

    /// The tint of an encoded picture (JPEG, PNG, WebP and the rest ImageIO reads): it is decoded straight to a small
    /// thumbnail, drawn into RGBA8 and averaged. Nil for data that is not a picture.
    static func tint(imageData: Data) -> MusicTint? {
        guard let pixels = sampledPixels(imageData: imageData) else { return nil }
        return tint(rgba: pixels)
    }

    /// The most pixels wide or high a kept cover thumbnail is: enough for a 12 pt chip cover at 2x and a blurred card
    /// background.
    static let thumbnailSide = 64

    /// An encoded picture shrunk so its longer side is at most `maxPixelSize`, upright and decoded now, so drawing it
    /// later costs no decoding. Nil for data that is not a picture.
    static func thumbnail(imageData: Data, maxPixelSize: Int = thumbnailSide) -> CGImage? {
        guard maxPixelSize > 0, let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The picture as `sampleSide` squared straight RGBA8 pixels.
    private static func sampledPixels(imageData: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: sampleSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        return unpremultiplied(pixels)
    }

    /// Premultiplied RGBA8 back to straight, so `average` weights by alpha once and not twice.
    static func unpremultiplied(_ pixels: [UInt8]) -> [UInt8] {
        var out = pixels
        var index = 0
        while index + 3 < out.count {
            let alpha = Int(out[index + 3])
            if alpha > 0, alpha < 255 {
                for channel in 0..<3 {
                    out[index + channel] = UInt8(min(255, (Int(out[index + channel]) * 255 + alpha / 2) / alpha))
                }
            }
            index += 4
        }
        return out
    }
}
