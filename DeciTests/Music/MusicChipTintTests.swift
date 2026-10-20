// DeciTests/Music/MusicChipTintTests.swift
// The chip's fill: the cover's colour, darkened only as far as white text needs (4.5 to 1 against it). Pure colour math.

import Foundation
import Testing
@testable import Deci

@Suite("Music chip tint")
struct MusicChipTintTests {
    private func rgb(_ tint: MusicTint) -> (red: Double, green: Double, blue: Double) {
        MusicChipTint.rgb(of: tint)
    }

    @Test("HSB converts to the RGB of the primaries")
    func hsbToRGB() {
        let red = rgb(MusicTint(hue: 0, saturation: 1, brightness: 1))
        #expect(red.red == 1 && red.green == 0 && red.blue == 0)
        let green = rgb(MusicTint(hue: 1.0 / 3.0, saturation: 1, brightness: 1))
        #expect(abs(green.red) < 1e-9 && abs(green.green - 1) < 1e-9 && abs(green.blue) < 1e-9)
        let blue = rgb(MusicTint(hue: 2.0 / 3.0, saturation: 1, brightness: 1))
        #expect(abs(blue.red) < 1e-9 && abs(blue.green) < 1e-9 && abs(blue.blue - 1) < 1e-9)
        let grey = rgb(MusicTint(hue: 0.3, saturation: 0, brightness: 0.5))
        #expect(grey.red == 0.5 && grey.green == 0.5 && grey.blue == 0.5)
    }

    @Test("white on black reads 21 to 1 and white on white 1 to 1")
    func contrastExtremes() {
        #expect(abs(MusicChipTint.contrastWithWhite(MusicTint(hue: 0, saturation: 0, brightness: 0)) - 21) < 1e-9)
        #expect(abs(MusicChipTint.contrastWithWhite(MusicTint(hue: 0, saturation: 0, brightness: 1)) - 1) < 1e-9)
    }

    @Test("a dark cover colour is used as it is")
    func darkTintUntouched() {
        let tint = MusicTint(hue: 0.6, saturation: 0.7, brightness: 0.30)
        #expect(MusicChipTint.contrastWithWhite(tint) >= MusicChipTint.minimumContrast)
        #expect(MusicChipTint.readableFill(tint) == tint)
    }

    @Test("a bright cover colour is darkened, keeping its hue and saturation")
    func brightTintDarkened() {
        let tint = MusicTint(hue: 0.15, saturation: 0.7, brightness: 0.9)
        #expect(MusicChipTint.contrastWithWhite(tint) < MusicChipTint.minimumContrast)
        let fill = MusicChipTint.readableFill(tint)
        #expect(fill.hue == tint.hue)
        #expect(fill.saturation == tint.saturation)
        #expect(fill.brightness < tint.brightness)
        #expect(MusicChipTint.contrastWithWhite(fill) >= MusicChipTint.minimumContrast)
    }

    @Test("it darkens no further than it has to")
    func notDarkerThanNeeded() {
        let fill = MusicChipTint.readableFill(MusicTint(hue: 0.15, saturation: 0.7, brightness: 0.9))
        #expect(MusicChipTint.contrastWithWhite(fill) < MusicChipTint.minimumContrast + 0.05)
    }

    @Test("white goes to a grey that white text can be read on")
    func whiteBecomesGrey() {
        let fill = MusicChipTint.readableFill(MusicTint(hue: 0, saturation: 0, brightness: 1))
        #expect(fill.saturation == 0)
        #expect(MusicChipTint.contrastWithWhite(fill) >= MusicChipTint.minimumContrast)
        #expect(fill.brightness > 0.3)
    }

    @Test("every tint of the grid, and the stand-in palette, ends up readable")
    func gridIsReadable() {
        var tints = MusicTint.palette
        for hue in stride(from: 0.0, to: 1.0, by: 0.05) {
            for saturation in stride(from: 0.0, through: 1.0, by: 0.25) {
                for brightness in stride(from: 0.0, through: 1.0, by: 0.125) {
                    tints.append(MusicTint(hue: hue, saturation: saturation, brightness: brightness))
                }
            }
        }
        for tint in tints {
            let fill = MusicChipTint.readableFill(tint)
            #expect(MusicChipTint.contrastWithWhite(fill) >= MusicChipTint.minimumContrast)
            #expect(fill.brightness <= tint.brightness)
        }
    }

    @Test("a pure black tint stays black")
    func blackStays() {
        let black = MusicTint(hue: 0.2, saturation: 0.5, brightness: 0)
        #expect(MusicChipTint.readableFill(black) == black)
    }
}
