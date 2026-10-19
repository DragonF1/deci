// DeciTests/Music/MusicMenuBarSettingTests.swift
// "Show Music in menu bar": whether the second menu bar icon exists. On by default, remembered in
// settings.json, and an old file from before the setting decodes to on.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Show Music in menu bar setting")
struct MusicMenuBarSettingTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("deci-music-menubar-\(UUID().uuidString)")
    }

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("a fresh install shows the Music icon")
    func defaultIsOn() {
        #expect(AppSettings().showMusicInMenuBar)
    }

    @Test("a settings file from before the setting existed decodes to on")
    func oldFile() throws {
        let settings = try decode(#"{"launchAtLogin": true, "chromeTabsEnabled": false}"#)
        #expect(settings.showMusicInMenuBar)
        #expect(settings.launchAtLogin)
    }

    @Test("an empty settings file decodes to on")
    func emptyFile() throws {
        #expect(try decode("{}").showMusicInMenuBar)
    }

    @Test("an explicit off in the file stays off and leaves the other settings alone")
    func explicitOff() throws {
        let settings = try decode(#"{"showMusicInMenuBar": false, "launchAtLogin": true}"#)
        #expect(settings.showMusicInMenuBar == false)
        #expect(settings.launchAtLogin)
    }

    @Test("off survives an encode and decode", arguments: [true, false])
    func roundTrip(value: Bool) throws {
        var settings = AppSettings()
        settings.showMusicInMenuBar = value
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.showMusicInMenuBar == value)
        #expect(decoded == settings)
    }

    @Test("the setting is written to disk and read back by the next launch")
    func persists() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SettingsManager(directory: directory)
        var settings = first.appSettings
        settings.showMusicInMenuBar = false
        first.updateAppSettings(settings)
        first.flushSync()

        let second = SettingsManager(directory: directory)
        #expect(second.appSettings.showMusicInMenuBar == false)
    }

    @Test("Reset all settings brings the Music icon back")
    func resetAll() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = SettingsManager(directory: directory)
        var settings = manager.appSettings
        settings.showMusicInMenuBar = false
        manager.updateAppSettings(settings)
        #expect(manager.appSettings.showMusicInMenuBar == false)

        manager.resetAllSettings()

        #expect(manager.appSettings.showMusicInMenuBar)
    }

    @Test("turning it off does not touch the playback options")
    func playbackOptionsUntouched() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = SettingsManager(directory: directory)
        var settings = manager.appSettings
        settings.musicPlayback = MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false)
        manager.updateAppSettings(settings)

        var hidden = manager.appSettings
        hidden.showMusicInMenuBar = false
        manager.updateAppSettings(hidden)

        #expect(manager.appSettings.musicPlayback == MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false))
    }

    // MARK: - Change hook

    private final class Calls {
        var values: [Bool] = []
    }

    @Test("a real change reports the new value once, each time it changes")
    func hookFiresOncePerChange() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        let calls = Calls()
        manager.onShowMusicInMenuBarChange = { calls.values.append($0) }

        manager.appSettings.showMusicInMenuBar = false
        #expect(calls.values == [false])

        manager.appSettings.showMusicInMenuBar = true
        #expect(calls.values == [false, true])
    }

    @Test("writing the value it already has does not report")
    func hookIgnoresSameValue() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        let calls = Calls()
        manager.onShowMusicInMenuBarChange = { calls.values.append($0) }

        manager.appSettings.showMusicInMenuBar = true
        manager.appSettings.showMusicInMenuBar = true

        manager.appSettings.showMusicInMenuBar = false
        calls.values.removeAll()
        manager.appSettings.showMusicInMenuBar = false

        #expect(calls.values.isEmpty)
    }

    @Test("changing another setting does not report")
    func hookIgnoresOtherSettings() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        let calls = Calls()
        manager.onShowMusicInMenuBarChange = { calls.values.append($0) }

        manager.appSettings.showDeviceDisconnectAlerts = false
        manager.appSettings.chromeTabsEnabled = true
        manager.appSettings.launchAtLogin = false

        #expect(calls.values.isEmpty)
    }

    @Test("Reset all settings reports when the icon was hidden, and not when it was already on")
    func hookOnReset() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        let calls = Calls()
        manager.onShowMusicInMenuBarChange = { calls.values.append($0) }

        manager.resetAllSettings()
        #expect(calls.values.isEmpty)

        manager.appSettings.showMusicInMenuBar = false
        calls.values.removeAll()
        manager.resetAllSettings()

        #expect(calls.values == [true])
    }

    @Test("loading a file with the icon off does not report")
    func hookSilentOnLoad() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SettingsManager(directory: directory)
        first.appSettings.showMusicInMenuBar = false
        first.flushSync()

        let second = SettingsManager(directory: directory)
        let calls = Calls()
        second.onShowMusicInMenuBarChange = { calls.values.append($0) }

        #expect(second.appSettings.showMusicInMenuBar == false)
        #expect(calls.values.isEmpty)
    }
}
