// DeciTests/Music/MixShuffle/MusicShuffleModeTests.swift
// The shuffle button's three states (Off, Shuffle, Flow Shuffle) and the Transitions button's three (Off, Crossfade, Mixing):
// the cycles, the names and glyphs, and the settings that carry them, with the migration from the older keys.

import AppKit
import Foundation
import Testing
@testable import Deci

@Suite struct MusicShuffleModeTests {
    @Test("the button cycles Off, Shuffle, Flow Shuffle, Off")
    func cycle() {
        #expect(MusicShuffleMode.off.next == .shuffle)
        #expect(MusicShuffleMode.shuffle.next == .flow)
        #expect(MusicShuffleMode.flow.next == .off)
        #expect(MusicShuffleMode.allCases == [.off, .shuffle, .flow])
        #expect(MusicShuffleMode.allCases.map(\.rawValue) == ["off", "shuffle", "flow"])
    }

    @Test("Off and Shuffle share the shuffle glyph and title; Flow Shuffle has its own")
    func lookOfEachMode() {
        #expect(MusicShuffleMode.off.symbol == "shuffle")
        #expect(MusicShuffleMode.shuffle.symbol == "shuffle")
        #expect(MusicShuffleMode.flow.symbol == MusicShuffleMode.flowSymbol)
        #expect(MusicShuffleMode.off.title == "Shuffle")
        #expect(MusicShuffleMode.shuffle.title == "Shuffle")
        #expect(MusicShuffleMode.flow.title == "Flow Shuffle")
    }

    @Test("Flow Shuffle's glyph is the curved path and exists on this system")
    func flowGlyph() {
        #expect(MusicShuffleMode.flowSymbol == "point.topleft.down.to.point.bottomright.curvepath")
        #expect(NSImage(systemSymbolName: MusicShuffleMode.flowSymbol, accessibilityDescription: nil) != nil)
    }

    /// The plain shuffle glyph has always been wider than its 13 pt box (about 17 pt at the slot's 12 pt medium) and
    /// spills a little into the gaps on either side, so the bound is that room: no mode's glyph is wider than the plain
    /// one, and its spill stays well short of the button next to it.
    @Test("every shuffle glyph fits the room the shuffle slot has at the row's size")
    func shuffleGlyphsFitTheSlot() throws {
        let box = MusicTransportMetrics.box(.shuffle)
        let gap = MusicTransportMetrics.gap()
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        func size(_ symbol: String) throws -> NSSize {
            let base = try #require(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
            return try #require(base.withSymbolConfiguration(config)).size
        }
        let plain = try size(MusicShuffleMode.symbol)
        for mode in MusicShuffleMode.allCases {
            let glyph = try size(mode.symbol)
            #expect(glyph.width <= plain.width + 1, "\(mode) is \(glyph.width) pt wide, the shuffle glyph \(plain.width) pt")
            #expect((glyph.width - box) / 2 <= gap / 2, "\(mode) spills past half the \(gap) pt gap")
            #expect(glyph.height <= MusicTransportMetrics.height)
        }
    }

    @Test("the Transitions button cycles Off, Crossfade, Mixing, Off")
    func transitionCycle() {
        #expect(MusicTransitionMode.off.next == .crossfade)
        #expect(MusicTransitionMode.crossfade.next == .mixing)
        #expect(MusicTransitionMode.mixing.next == .off)
        #expect(MusicTransitionMode.allCases == [.off, .crossfade, .mixing])
        #expect(MusicTransitionMode.allCases.map(\.rawValue) == ["off", "crossfade", "mixing"])
    }

    @Test("Transitions names and glyphs: Mixing has its own, Off and Crossfade keep the crossfade glyph")
    func transitionLook() {
        #expect(MusicTransitionMode.off.title == "Transitions")
        #expect(MusicTransitionMode.crossfade.title == "Crossfade")
        #expect(MusicTransitionMode.mixing.title == "Mixing")
        #expect(MusicTransitionMode.off.symbol == "arrow.triangle.merge")
        #expect(MusicTransitionMode.crossfade.symbol == "arrow.triangle.merge")
        #expect(MusicTransitionMode.mixing.symbol == "waveform.path")
        #expect(!MusicTransitionMode.off.isOn)
        #expect(MusicTransitionMode.crossfade.isOn)
        #expect(MusicTransitionMode.mixing.isOn)
    }

    @Test("every glyph the shuffle and Transitions UI draws exists on this system")
    func glyphsExist() {
        let names = [MusicShuffleMode.symbol, MusicShuffleMode.flowSymbol, MusicTransitionMode.crossfadeSymbol, MusicTransitionMode.mixingSymbol]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is not an SF Symbol")
        }
    }

    @Test("a glyph renders offscreen with ink in it")
    func mixGlyphRenders() throws {
        let image = try #require(NSImage(systemSymbolName: MusicTransitionMode.mixingSymbol, accessibilityDescription: nil))
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
        #expect(MusicShuffleMode.flow.isOn)
    }

    @Test("the toggles take their title and glyph from the modes")
    func toggleLook() {
        #expect(MusicPlaybackToggle.shuffle.symbol(loop: .off) == "shuffle")
        #expect(MusicPlaybackToggle.shuffle.title(loop: .off, shuffleMode: .flow) == "Flow Shuffle")
        #expect(MusicPlaybackToggle.shuffle.title(loop: .off, shuffleMode: .shuffle) == "Shuffle")
        #expect(MusicPlaybackToggle.shuffle.symbol(loop: .off, shuffleMode: .flow) == MusicShuffleMode.flowSymbol)
        #expect(MusicPlaybackToggle.transitions.title(loop: .off, transitionMode: .mixing) == "Mixing")
        #expect(MusicPlaybackToggle.transitions.symbol(loop: .off, transitionMode: .mixing) == "waveform.path")
        #expect(MusicPlaybackToggle.transitions.symbol(loop: .off, transitionMode: .crossfade) == "arrow.triangle.merge")
        #expect(MusicPlaybackToggle.loop.symbol(loop: .song, transitionMode: .mixing) == MusicLoopMode.song.systemImage)
        #expect(MusicFavoriteControl.transitions.symbol(loop: .off, transitionMode: .mixing) == "waveform.path")
        #expect(MusicFavoriteControl.transitions.title(transitionMode: .crossfade) == "Crossfade")
        #expect(MusicFavoriteControl.transitions.menuTitle == "Transitions")
        #expect(MusicFavoriteControl.shuffle.title() == "Shuffle")
    }

    @Test("the favorite snapshot reads the shuffle mode and Transitions, and any mode but Off counts as on")
    func snapshot() {
        let snapshot = MusicFavoriteSnapshot(shuffle: .flow, transitions: .mixing)
        #expect(snapshot.shuffleMode == .flow)
        #expect(MusicFavoriteSnapshot(shuffle: .shuffle).isOn(.shuffle))
        #expect(snapshot.isOn(.shuffle))
        #expect(snapshot.isOn(.transitions))
        #expect(MusicFavoriteSnapshot().shuffleMode == .off)
        #expect(!MusicFavoriteSnapshot().isOn(.transitions))
    }

    @Test("the Shuffle and Transitions menu entries name the mode and offer their choices in cycle order")
    func menuEntries() {
        func model(shuffle: MusicShuffleMode, transitions: MusicTransitionMode) -> MusicFavoriteMenuModel {
            MusicFavoriteMenuModel(
                shuffle: shuffle, loop: .off, autoplay: true, transitions: transitions, fadeSeconds: 6, slotControl: .shuffle
            )
        }
        #expect(MusicFavoriteMenuModel.shuffleChoices.map(\.title) == ["Off", "Shuffle", "Flow Shuffle"])
        #expect(MusicFavoriteMenuModel.shuffleChoices.map(\.mode) == [.off, .shuffle, .flow])
        #expect(MusicFavoriteMenuModel.transitionChoices.map(\.title) == ["Off", "Crossfade", "Mixing"])
        #expect(MusicFavoriteMenuModel.transitionChoices.map(\.mode) == [.off, .crossfade, .mixing])
        #expect(model(shuffle: .off, transitions: .off).entries[0] == .shuffle(selected: .off))
        #expect(model(shuffle: .shuffle, transitions: .off).entries[0] == .shuffle(selected: .shuffle))
        #expect(model(shuffle: .flow, transitions: .off).entries[0] == .shuffle(selected: .flow))
        #expect(model(shuffle: .flow, transitions: .off).entries[0].title == "Shuffle")
        let entries = model(shuffle: .off, transitions: .mixing).entries
        #expect(entries.contains(.transitions(selected: .mixing)))
        #expect(entries.contains { $0.title == "Transitions" })
    }

    @Test("the playback preferences carry a shuffle mode and a transition mode")
    func preferencesModes() {
        var prefs = MusicPlaybackPreferences()
        #expect(prefs.shuffleMode == .off)
        #expect(prefs.transitionMode == .off)
        prefs.shuffleMode = .flow
        prefs.transitionMode = .mixing
        #expect(prefs == MusicPlaybackPreferences(shuffleMode: .flow, transitionMode: .mixing))
    }
}

@Suite struct SettingsTransitionsMigrationTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("a file with only the old keys migrates: Mix with beat matching is Mixing")
    func oldMixWithBeat() throws {
        let s = try decode(#"{"musicShuffle": true, "musicMixShuffle": true, "musicBeatMix": true, "musicCrossfadeEnabled": false}"#)
        #expect(s.musicTransitions == .mixing)
        #expect(s.musicPlayback.shuffleMode == .flow)
    }

    @Test("Mix without beat matching always faded: it is Crossfade")
    func oldMixWithoutBeat() throws {
        let s = try decode(#"{"musicShuffle": true, "musicMixShuffle": true, "musicBeatMix": false, "musicCrossfadeEnabled": false}"#)
        #expect(s.musicTransitions == .crossfade)
    }

    @Test("without Mix the old Crossfade switch decides, whatever beat matching said")
    func oldCrossfadeSwitch() throws {
        let on = try decode(#"{"musicShuffle": true, "musicBeatMix": true, "musicCrossfadeEnabled": true}"#)
        #expect(on.musicTransitions == .crossfade)
        let off = try decode(#"{"musicShuffle": false, "musicBeatMix": true, "musicCrossfadeEnabled": false}"#)
        #expect(off.musicTransitions == .off)
        #expect(try decode("{}").musicTransitions == .off)
    }

    @Test("an old Mix flag without the shuffle flag is not Mixing: Crossfade when it was on, else Off")
    func mixFlagWithoutShuffle() throws {
        let fade = try decode(#"{"musicShuffle": false, "musicMixShuffle": true, "musicBeatMix": true, "musicCrossfadeEnabled": true}"#)
        #expect(fade.musicTransitions == .crossfade)
        let off = try decode(#"{"musicShuffle": false, "musicMixShuffle": true, "musicBeatMix": true, "musicCrossfadeEnabled": false}"#)
        #expect(off.musicTransitions == .off)
    }

    @Test("a beat-matching value of the wrong type reads as on, so old Mix gives Mixing")
    func wrongTypedBeatMix() throws {
        let s = try decode(#"{"musicShuffle": true, "musicMixShuffle": true, "musicBeatMix": "x"}"#)
        #expect(s.musicTransitions == .mixing)
    }

    @Test("the two shuffle keys read as Off, Shuffle and Flow Shuffle, and write back the same")
    func threeShuffleStates() throws {
        #expect(try decode(#"{"musicShuffle": false}"#).musicPlayback.shuffleMode == .off)
        #expect(try decode(#"{"musicShuffle": false, "musicMixShuffle": true}"#).musicPlayback.shuffleMode == .off)
        #expect(try decode(#"{"musicShuffle": true, "musicMixShuffle": false}"#).musicPlayback.shuffleMode == .shuffle)
        #expect(try decode(#"{"musicShuffle": true, "musicMixShuffle": true}"#).musicPlayback.shuffleMode == .flow)
        #expect(try decode(#"{}"#).musicPlayback.shuffleMode == .off)
        for mode in MusicShuffleMode.allCases {
            var settings = AppSettings()
            settings.musicPlayback = MusicPlaybackPreferences(shuffleMode: mode)
            #expect(settings.musicShuffle == mode.isOn)
            #expect(settings.musicMixShuffle == (mode == .flow))
            let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(again.musicPlayback.shuffleMode == mode)
        }
    }

    @Test("data from before Transitions: plain shuffle stays Shuffle, Mix shuffle stays Flow Shuffle with its transitions")
    func oldKeysKeepTheirShuffle() throws {
        let plain = try decode(#"{"musicShuffle": true}"#)
        #expect(plain.musicPlayback.shuffleMode == .shuffle)
        #expect(plain.musicTransitions == .off)
        let mix = try decode(#"{"musicShuffle": true, "musicMixShuffle": true, "musicBeatMix": true}"#)
        #expect(mix.musicPlayback.shuffleMode == .flow)
        #expect(mix.musicTransitions == .mixing)
        let mixOnly = try decode(#"{"musicShuffle": true, "musicMixShuffle": true, "musicBeatMix": false}"#)
        #expect(mixOnly.musicPlayback.shuffleMode == .flow)
        #expect(mixOnly.musicTransitions == .crossfade)
    }

    @Test("data the Systematic build wrote (Mix shuffle mirrors shuffle) reads as Flow Shuffle, and only with shuffle on")
    func systematicBuildData() throws {
        let on = try decode(#"{"musicShuffle": true, "musicMixShuffle": true, "musicTransitions": "crossfade"}"#)
        #expect(on.musicPlayback.shuffleMode == .flow)
        #expect(on.musicTransitions == .crossfade)
        let off = try decode(#"{"musicShuffle": false, "musicMixShuffle": false, "musicTransitions": "mixing"}"#)
        #expect(off.musicPlayback.shuffleMode == .off)
        #expect(off.musicTransitions == .mixing)
        #expect(MusicShuffleMode(rawValue: "systematic") == nil, "the old name was never a stored value")
    }

    @Test("the new key wins over the old ones")
    func newKeyWins() throws {
        let s = try decode(#"{"musicTransitions": "off", "musicMixShuffle": true, "musicShuffle": true, "musicBeatMix": true, "musicCrossfadeEnabled": true}"#)
        #expect(s.musicTransitions == .off)
        #expect(!s.musicCrossfadeEnabled)
        #expect(!s.musicBeatMix)
        #expect(try decode(#"{"musicTransitions": "mixing"}"#).musicTransitions == .mixing)
        #expect(try decode(#"{"musicTransitions": "crossfade", "musicBeatMix": true}"#).musicTransitions == .crossfade)
    }

    @Test("a value of the wrong type or an unknown mode falls back to the old keys and costs nothing else")
    func badNewKey() throws {
        let s = try decode(#"{"musicTransitions": "warp", "musicCrossfadeEnabled": true, "musicAutoplay": false}"#)
        #expect(s.musicTransitions == .crossfade)
        #expect(!s.musicAutoplay)
        #expect(try decode(#"{"musicTransitions": 7}"#).musicTransitions == .off)
    }

    @Test("the old keys are written for older builds, from the shuffle and Transitions modes")
    func oldKeysWritten() throws {
        func written(_ shuffle: MusicShuffleMode, _ transitions: MusicTransitionMode) throws -> [String: Any] {
            var settings = AppSettings()
            settings.musicPlayback = MusicPlaybackPreferences(shuffleMode: shuffle, transitionMode: transitions)
            let data = try JSONEncoder().encode(settings)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let mixed = try written(.flow, .mixing)
        #expect(mixed["musicTransitions"] as? String == "mixing")
        #expect(mixed["musicShuffle"] as? Bool == true)
        #expect(mixed["musicMixShuffle"] as? Bool == true)
        #expect(mixed["musicCrossfadeEnabled"] as? Bool == true)
        #expect(mixed["musicBeatMix"] as? Bool == true)
        let faded = try written(.off, .crossfade)
        #expect(faded["musicShuffle"] as? Bool == false)
        #expect(faded["musicMixShuffle"] as? Bool == false)
        #expect(faded["musicCrossfadeEnabled"] as? Bool == true)
        #expect(faded["musicBeatMix"] as? Bool == false)
        let plain = try written(.shuffle, .off)
        #expect(plain["musicShuffle"] as? Bool == true)
        #expect(plain["musicMixShuffle"] as? Bool == false)
        let off = try written(.flow, .off)
        #expect(off["musicShuffle"] as? Bool == true)
        #expect(off["musicCrossfadeEnabled"] as? Bool == false)
        #expect(off["musicBeatMix"] as? Bool == false)
    }

    @Test("the modes survive a round trip and flow through the playback preferences")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.musicPlayback = MusicPlaybackPreferences(shuffleMode: .flow, transitionMode: .mixing)
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(again == settings)
        #expect(again.musicPlayback.shuffleMode == .flow)
        #expect(again.musicPlayback.transitionMode == .mixing)
        settings.musicTransitions = .off
        #expect(!settings.musicBeatMix && !settings.musicCrossfadeEnabled)
    }

    @Test("the migration table is the one the settings use")
    func migrationTable() {
        typealias P = MusicPlaybackPreferences
        #expect(P.migratedTransitionMode(mixShuffle: true, beatMix: true, crossfade: false) == .mixing)
        #expect(P.migratedTransitionMode(mixShuffle: true, beatMix: true, crossfade: true) == .mixing)
        #expect(P.migratedTransitionMode(mixShuffle: true, beatMix: false, crossfade: false) == .crossfade)
        #expect(P.migratedTransitionMode(mixShuffle: false, beatMix: true, crossfade: true) == .crossfade)
        #expect(P.migratedTransitionMode(mixShuffle: false, beatMix: false, crossfade: true) == .crossfade)
        #expect(P.migratedTransitionMode(mixShuffle: false, beatMix: true, crossfade: false) == .off)
    }
}
