// DeciTests/Music/MusicBeatMixSettingTests.swift
// The Beat-matched transitions switch is gone from Settings: Mixing is beat matching. The old musicBeatMix key is still
// written for older builds, from Transitions, and read only as a fallback when a file has no musicTransitions.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music beat mix setting")
struct MusicBeatMixSettingTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    @Test("a fresh install has Transitions off, so the old beat mix key reads false")
    func defaults() {
        #expect(AppSettings().musicTransitions == .off)
        #expect(!AppSettings().musicBeatMix)
        #expect(MusicPlaybackPreferences().transitionMode == .off)
    }

    @Test("an empty file and a file with other music keys leave Transitions off")
    func absentKey() throws {
        #expect(try decode("{}").musicTransitions == .off)
        #expect(try decode(#"{"musicCrossfadeEnabled": true, "musicCrossfadeSeconds": 8}"#).musicTransitions == .crossfade)
    }

    @Test("the v10 and v11 settings fixtures decode and keep the old keys in line with Transitions")
    func fixturesDecode() throws {
        for name in ["settings-v10.json", "settings-v11.json"] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: try fixture(name))
            #expect(settings.musicBeatMix == (settings.musicTransitions == .mixing), "\(name)")
            #expect(settings.musicCrossfadeEnabled == settings.musicTransitions.isOn, "\(name)")
        }
    }

    @Test("a stored old key is a fallback only: a wrong type reads as the default, and the key follows Transitions")
    func storedValues() throws {
        #expect(try decode(#"{"musicBeatMix": false, "musicCrossfadeEnabled": true}"#).musicTransitions == .crossfade)
        #expect(try decode(#"{"musicBeatMix": "no"}"#).musicTransitions == .off)
        var settings = AppSettings()
        settings.musicTransitions = .mixing
        #expect(settings.musicBeatMix)
        let data = try JSONEncoder().encode(settings)
        let again = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(again.musicBeatMix)
        #expect(again.musicTransitions == .mixing)
    }
}
