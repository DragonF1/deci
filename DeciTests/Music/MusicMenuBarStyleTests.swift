// DeciTests/Music/MusicMenuBarStyleTests.swift
// "Menu bar style" of the Music item: the plain icon (the default) or the Now playing chip. Remembered in settings.json,
// and a file from before the setting decodes to the icon.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music menu bar style setting")
struct MusicMenuBarStyleTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("deci-music-style-\(UUID().uuidString)")
    }

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("a fresh install keeps the icon")
    func defaultIsIcon() {
        #expect(AppSettings().musicMenuBarStyle == .icon)
        #expect(MusicMenuBarStyle.default == .icon)
    }

    @Test("a settings file from before the setting existed decodes to the icon")
    func oldFile() throws {
        let settings = try decode(#"{"launchAtLogin": true, "showMusicInMenuBar": false}"#)
        #expect(settings.musicMenuBarStyle == .icon)
        #expect(settings.launchAtLogin)
        #expect(settings.showMusicInMenuBar == false)
    }

    @Test("an empty settings file decodes to the icon")
    func emptyFile() throws {
        #expect(try decode("{}").musicMenuBarStyle == .icon)
    }

    @Test("a chip in the file stays a chip")
    func explicitChip() throws {
        let settings = try decode(#"{"musicMenuBarStyle": "chip", "launchAtLogin": true}"#)
        #expect(settings.musicMenuBarStyle == .chip)
        #expect(settings.launchAtLogin)
    }

    @Test("a style this build does not know falls back to the icon and keeps the other settings")
    func unknownValue() throws {
        let settings = try decode(#"{"musicMenuBarStyle": "marquee", "launchAtLogin": true}"#)
        #expect(settings.musicMenuBarStyle == .icon)
        #expect(settings.launchAtLogin)
    }

    @Test("a value of the wrong type falls back to the icon")
    func wrongType() throws {
        #expect(try decode(#"{"musicMenuBarStyle": 7}"#).musicMenuBarStyle == .icon)
    }

    @Test("each style survives an encode and decode", arguments: MusicMenuBarStyle.allCases)
    func roundTrip(style: MusicMenuBarStyle) throws {
        var settings = AppSettings()
        settings.musicMenuBarStyle = style
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.musicMenuBarStyle == style)
        #expect(decoded == settings)
    }

    @Test("the picker lists the icon first, then the chip, with their own words")
    func pickerWords() {
        #expect(MusicMenuBarStyle.allCases == [.icon, .chip])
        #expect(MusicMenuBarStyle.icon.title == "Icon")
        #expect(MusicMenuBarStyle.chip.title == "Now playing chip")
    }

    @Test("the style is written to disk and read back by the next launch")
    func persists() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SettingsManager(directory: directory)
        first.appSettings.musicMenuBarStyle = .chip
        first.flushSync()

        let second = SettingsManager(directory: directory)
        #expect(second.appSettings.musicMenuBarStyle == .chip)
    }

    @Test("Reset all settings brings the icon back")
    func resetAll() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = SettingsManager(directory: directory)
        manager.appSettings.musicMenuBarStyle = .chip
        manager.resetAllSettings()

        #expect(manager.appSettings.musicMenuBarStyle == .icon)
    }
}
