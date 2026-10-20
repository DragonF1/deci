// Deci/Views/MenuBar/MusicChipTint.swift
// The chip's fill: the cover's colour, darkened only as far as white text needs to be readable on it. Pure colour
// math, so the contrast rule is unit tested.

import Foundation

nonisolated enum MusicChipTint {
    /// The contrast white text needs against the fill (WCAG AA for normal text).
    static let minimumContrast = 4.5

    /// A tint as sRGB, each 0...1 (HSB to RGB).
    static func rgb(of tint: MusicTint) -> (red: Double, green: Double, blue: Double) {
        let value = tint.brightness
        let sector = tint.hue * 6
        let index = sector.rounded(.down)
        let fraction = sector - index
        let p = value * (1 - tint.saturation)
        let q = value * (1 - tint.saturation * fraction)
        let t = value * (1 - tint.saturation * (1 - fraction))
        switch Int(index) % 6 {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }

    /// The WCAG contrast ratio of white text on `tint`: 21 on black, 1 on white.
    static func contrastWithWhite(_ tint: MusicTint) -> Double {
        let color = rgb(of: tint)
        let luminance = 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        return 1.05 / (luminance + 0.05)
    }

    /// The fill the chip is drawn with: the tint itself when white text already reads on it, else the same hue and
    /// saturation at the greatest brightness that does.
    static func readableFill(_ tint: MusicTint) -> MusicTint {
        guard contrastWithWhite(tint) < minimumContrast else { return tint }
        // Brightness only ever darkens the colour, so contrast only grows as it falls: the greatest brightness that
        // passes sits between black (always passes) and the tint (fails), and bisection finds it.
        var passes = 0.0
        var fails = tint.brightness
        for _ in 0..<40 {
            let middle = (passes + fails) / 2
            let candidate = MusicTint(hue: tint.hue, saturation: tint.saturation, brightness: middle)
            if contrastWithWhite(candidate) >= minimumContrast {
                passes = middle
            } else {
                fails = middle
            }
        }
        return MusicTint(hue: tint.hue, saturation: tint.saturation, brightness: passes)
    }

    /// One sRGB channel to linear light.
    private static func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}
