// DeciTests/Music/MusicAnalyzeSettingTests.swift
// "Analyse songs in the background" is remembered in settings.json. On by default, also for a file from before it existed.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music analyze setting")
struct MusicAnalyzeSettingTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("a fresh install analyses in the background")
    func defaultIsOn() {
        #expect(AppSettings().musicAnalyzeInBackground)
    }

    @Test("an old settings file without the key decodes to on and keeps the other settings")
    func oldFile() throws {
        let settings = try decode(#"{"launchAtLogin": true, "musicShuffle": true}"#)
        #expect(settings.musicAnalyzeInBackground)
        #expect(settings.launchAtLogin)
        #expect(settings.musicShuffle)
    }

    @Test("off survives an encode and decode, and so does on")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.musicAnalyzeInBackground = false
        let off = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(off.musicAnalyzeInBackground == false)
        #expect(off == settings)

        settings.musicAnalyzeInBackground = true
        let on = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(on.musicAnalyzeInBackground)
    }

    @Test("a value of the wrong type falls back to on without losing the rest")
    func wrongType() throws {
        let settings = try decode(#"{"musicAnalyzeInBackground": "nope", "launchAtLogin": true}"#)
        #expect(settings.musicAnalyzeInBackground)
        #expect(settings.launchAtLogin)
    }

    @Test("it is not part of the playback preferences")
    func notAPlaybackPreference() {
        var settings = AppSettings()
        settings.musicAnalyzeInBackground = false
        #expect(settings.musicPlayback == MusicPlaybackPreferences())
    }
}
