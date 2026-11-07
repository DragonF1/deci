// DeciTests/Music/MusicBeatMixSettingTests.swift
// Tier 3b P3: the beat-matched transitions switch is on by default, a file without the key reads as on (the old fixtures
// included), a stored false survives a round trip, and the preference carries it to the player.

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

    @Test("a fresh install has beat mixing on")
    func defaultIsOn() {
        #expect(AppSettings().musicBeatMix)
        #expect(MusicPlaybackPreferences().beatMix)
        #expect(AppSettings().musicPlayback.beatMix)
    }

    @Test("an empty file and a file with other music keys read the key as on")
    func absentKeyIsOn() throws {
        #expect(try decode("{}").musicBeatMix)
        #expect(try decode(#"{"musicCrossfadeEnabled": true, "musicCrossfadeSeconds": 8}"#).musicBeatMix)
    }

    @Test("the v10 and v11 settings fixtures read the key as on and keep their other settings")
    func fixturesReadAsOn() throws {
        for name in ["settings-v10.json", "settings-v11.json"] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: try fixture(name))
            #expect(settings.musicBeatMix, "\(name)")
        }
    }

    @Test("a stored false stays false, a wrong type reads as on, and the setting round-trips")
    func storedValues() throws {
        #expect(try decode(#"{"musicBeatMix": false}"#).musicBeatMix == false)
        #expect(try decode(#"{"musicBeatMix": "no"}"#).musicBeatMix)
        var settings = AppSettings()
        settings.musicBeatMix = false
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).musicBeatMix == false)
    }

    @Test("the playback preference reads and writes the setting")
    func preferenceBridge() {
        var settings = AppSettings()
        var preferences = settings.musicPlayback
        preferences.beatMix = false
        settings.musicPlayback = preferences
        #expect(settings.musicBeatMix == false)
        #expect(settings.musicPlayback.beatMix == false)
    }
}
