// Deci/Views/Music/MusicTint.swift
import SwiftUI

/// FNV-1a, 64 bit. Swift's `hashValue` changes on every launch, so a colour picked from it would flicker between
/// runs; this one is the same every time.
nonisolated enum MusicHash {
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// The colours an item takes from its cover: a page colour for a card or a hero, a darker one for the bottom of the
/// page, a light one for the Play pill and accent text, and an ink for what sits on the light one. They follow the
/// derivation of the design: keep the cover's hue, then fix the brightness of each role.
nonisolated struct MusicTint: Equatable, Sendable {
    /// Hue, saturation and brightness of the dominant colour, each 0...1.
    let hue: Double
    let saturation: Double
    let brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        // The hue wraps around the colour wheel; a value that is not a number reads as red.
        let wrapped = hue - hue.rounded(.down)
        self.hue = wrapped.isFinite ? wrapped : 0
        self.saturation = saturation.isFinite ? min(max(saturation, 0), 1) : 0
        self.brightness = brightness.isFinite ? min(max(brightness, 0), 1) : 0
    }

    /// Page top, hero fade and card fill: brightness 23 to 46 percent.
    var pageBrightness: Double { min(max(brightness, 0.23), 0.46) }

    /// About half the brightness of the page top.
    var pageBottomBrightness: Double { pageBrightness / 2 }

    /// Play pill fill and accent text: brightness 84 to 100 percent, saturation 20 to 30 percent.
    var lightBrightness: Double { 0.84 + 0.16 * brightness }
    var lightSaturation: Double { min(max(saturation, 0.2), 0.3) }

    /// Play pill content: dark, and more saturated than the light colour.
    var inkBrightness: Double { 0.12 + 0.11 * brightness }
    var inkSaturation: Double { min(1, saturation * 0.5 + 0.5) }

    var page: Color { Color(hue: hue, saturation: saturation, brightness: pageBrightness) }
    var pageBottom: Color { Color(hue: hue, saturation: saturation, brightness: pageBottomBrightness) }
    var light: Color { Color(hue: hue, saturation: lightSaturation, brightness: lightBrightness) }
    var ink: Color { Color(hue: hue, saturation: inkSaturation, brightness: inkBrightness) }

    /// The tints Top Picks cards take, which stand in for the colour of the cover.
    static let palette: [MusicTint] = [
        MusicTint(hue: 0.43, saturation: 0.22, brightness: 0.26),
        MusicTint(hue: 0.58, saturation: 0.70, brightness: 0.31),
        MusicTint(hue: 0.00, saturation: 0.74, brightness: 0.29),
        MusicTint(hue: 0.89, saturation: 0.35, brightness: 0.25),
        MusicTint(hue: 0.50, saturation: 0.45, brightness: 0.28),
        MusicTint(hue: 0.07, saturation: 0.55, brightness: 0.32),
        MusicTint(hue: 0.68, saturation: 0.45, brightness: 0.34),
        MusicTint(hue: 0.78, saturation: 0.40, brightness: 0.30),
    ]

    /// A tint that is the same for the same key on every run, so a card keeps its colour.
    static func forKey(_ key: String) -> MusicTint {
        palette[Int(MusicHash.fnv1a(key) % UInt64(palette.count))]
    }
}
