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

/// A colour taken from a cover (or stood in by the hash palette): its hue, saturation and brightness. The player column
/// and the accent scope derive what they draw from it.
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

    /// The tints that stand in for the colour of a cover that is not known yet.
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
