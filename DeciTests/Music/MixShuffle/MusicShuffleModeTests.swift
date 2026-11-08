// DeciTests/Music/MixShuffle/MusicShuffleModeTests.swift
// Tier 4 P3: the shuffle button's third state. The cycle, the names and glyphs, the settings that carry it and the
// guarantee that a build which does not know Mix still reads it as Shuffle.

import AppKit
import Foundation
import Testing
@testable import Deci

@Suite struct MusicShuffleModeTests {
    @Test("the button cycles Off, Shuffle, Mix, Off")
    func cycle() {
        #expect(MusicShuffleMode.off.next == .shuffle)
        #expect(MusicShuffleMode.shuffle.next == .mix)
        #expect(MusicShuffleMode.mix.next == .off)
    }

    @Test("Mix has its own glyph and name; Off and Shuffle keep the shuffle glyph")
    func lookOfEachMode() {
        #expect(MusicShuffleMode.off.symbol == "shuffle")
        #expect(MusicShuffleMode.shuffle.symbol == "shuffle")
        #expect(MusicShuffleMode.mix.symbol == "waveform.path")
        #expect(MusicShuffleMode.off.title == "Shuffle")
        #expect(MusicShuffleMode.shuffle.title == "Shuffle")
        #expect(MusicShuffleMode.mix.title == "Mix")
    }

    @Test("every glyph the Mix UI draws exists on this system")
    func glyphsExist() {
        let names = [
            MusicShuffleMode.mixSymbol, MusicShuffleMode.shuffleSymbol,
            MusicMixPairInfo(bpm: nil, camelot: nil, mode: .beat).symbol,
            MusicMixPairInfo(bpm: nil, camelot: nil, mode: .fade).symbol,
        ]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is not an SF Symbol")
        }
    }

    @Test("a glyph renders offscreen with ink in it")
    func mixGlyphRenders() throws {
        let image = try #require(NSImage(systemSymbolName: MusicShuffleMode.mixSymbol, accessibilityDescription: nil))
        let size = NSSize(width: 26, height: 22)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 52, pixelsHigh: 44, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var inked = false
        for x in 0..<rep.pixelsWide where !inked {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                inked = true
                break
            }
        }
        #expect(inked)
    }

    @Test("only Off is off")
    func isOn() {
        #expect(!MusicShuffleMode.off.isOn)
        #expect(MusicShuffleMode.shuffle.isOn)
        #expect(MusicShuffleMode.mix.isOn)
        #expect(MusicShuffleMode(shuffle: true) == .shuffle)
        #expect(MusicShuffleMode(shuffle: false) == .off)
    }

    @Test("the shuffle toggle takes its title and glyph from the mode")
    func toggleLook() {
        #expect(MusicPlaybackToggle.shuffle.symbol(loop: .off) == "shuffle")
        #expect(MusicPlaybackToggle.shuffle.symbol(loop: .off, shuffleMode: .mix) == "waveform.path")
        #expect(MusicPlaybackToggle.shuffle.title(loop: .off, shuffleMode: .mix) == "Mix")
        #expect(MusicPlaybackToggle.loop.symbol(loop: .song, shuffleMode: .mix) == MusicLoopMode.song.systemImage)
        #expect(MusicFavoriteControl.shuffle.symbol(loop: .off, isLiked: false, shuffleMode: .mix) == "waveform.path")
        #expect(MusicFavoriteControl.shuffle.title(shuffleMode: .mix) == "Mix")
        #expect(MusicFavoriteControl.shuffle.title() == "Shuffle")
    }

    @Test("the favorite snapshot reads Mix, and Mix counts as on")
    func snapshot() {
        let mix = MusicFavoriteSnapshot(shuffle: true, mix: true)
        #expect(mix.shuffleMode == .mix)
        #expect(mix.isOn(.shuffle))
        #expect(MusicFavoriteSnapshot(shuffle: true).shuffleMode == .shuffle)
        #expect(MusicFavoriteSnapshot().shuffleMode == .off)
    }

    @Test("the Shuffle menu entry names the mode and offers Off, Shuffle and Mix in cycle order")
    func menuEntry() {
        func model(shuffle: Bool, mix: Bool) -> MusicFavoriteMenuModel {
            MusicFavoriteMenuModel(
                shuffle: shuffle, mix: mix, loop: .off, autoplay: true, crossfade: false, fadeSeconds: 6, slotControl: .shuffle
            )
        }
        #expect(MusicFavoriteMenuModel.shuffleChoices.map(\.title) == ["Off", "Shuffle", "Mix"])
        #expect(MusicFavoriteMenuModel.shuffleChoices.map(\.mode) == [.off, .shuffle, .mix])
        #expect(model(shuffle: false, mix: false).entries[0] == .shuffle(selected: .off))
        #expect(model(shuffle: true, mix: false).entries[0] == .shuffle(selected: .shuffle))
        #expect(model(shuffle: true, mix: true).entries[0] == .shuffle(selected: .mix))
        #expect(model(shuffle: true, mix: true).entries[0].title == "Shuffle")
    }

    @Test("playback preferences keep shuffle on whenever Mix is on, so an older build still shuffles")
    func preferencesInvariant() {
        let mix = MusicPlaybackPreferences(mixShuffle: true)
        #expect(mix.shuffle)
        #expect(mix.shuffleMode == .mix)
        var prefs = MusicPlaybackPreferences()
        #expect(prefs.shuffleMode == .off)
        prefs.shuffleMode = .shuffle
        #expect(prefs.shuffle && !prefs.mixShuffle)
        prefs.shuffleMode = .mix
        #expect(prefs.shuffle && prefs.mixShuffle)
        prefs.shuffleMode = .off
        #expect(!prefs.shuffle && !prefs.mixShuffle)
    }
}

@Suite struct SettingsMixShuffleDecodeTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("settings written before Mix decode with Mix off")
    func missingKey() throws {
        let settings = try decode(#"{"musicShuffle": true}"#)
        #expect(settings.musicShuffle)
        #expect(!settings.musicMixShuffle)
        #expect(settings.musicPlayback.shuffleMode == .shuffle)
    }

    @Test("a value of the wrong type costs the listener nothing else")
    func wrongType() throws {
        let settings = try decode(#"{"musicShuffle": true, "musicMixShuffle": "yes", "musicAutoplay": false}"#)
        #expect(!settings.musicMixShuffle)
        #expect(settings.musicShuffle)
        #expect(!settings.musicAutoplay)
    }

    @Test("Mix survives a round trip and flows through the playback preferences")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.musicPlayback = MusicPlaybackPreferences(mixShuffle: true)
        #expect(settings.musicShuffle)
        #expect(settings.musicMixShuffle)
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.musicMixShuffle)
        #expect(again.musicPlayback.shuffleMode == .mix)
        settings.musicPlayback = MusicPlaybackPreferences(shuffle: true)
        #expect(!settings.musicMixShuffle)
    }
}
