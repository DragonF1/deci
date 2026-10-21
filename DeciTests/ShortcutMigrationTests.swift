// DeciTests/ShortcutMigrationTests.swift
// The launch step that drops the three removed per-app volume hotkeys: their entries in settings.json and the chords
// KeyboardShortcuts kept for them. It must be safe to run on every launch.

import Testing
import Foundation
import KeyboardShortcuts
@testable import Deci

@Suite("ShortcutMigration")
@MainActor
struct ShortcutMigrationTests {
    private let oldKeys = ["frontmostAppVolumeUp", "frontmostAppVolumeDown", "frontmostAppMuteToggle"]
    private let oldNames = ["frontmost-app-volume-up", "frontmost-app-volume-down", "frontmost-app-mute-toggle"]

    @Test("It targets the three old persistence keys and the three old KeyboardShortcuts names")
    func targets() {
        #expect(ShortcutMigration.removedActionKeys == oldKeys)
        #expect(ShortcutMigration.removedNameIDs == oldNames)
    }

    @Test("The old entries leave settings.json and everything else stays")
    func dropsOldEntries() {
        let settings = makeSettings()
        var app = settings.appSettings
        for (i, key) in oldKeys.enumerated() {
            app.customShortcuts[key] = ShortcutCodable(keyCode: 20 + i, modifiers: 0x12_0000)
        }
        let toggle = ShortcutCodable(keyCode: 9, modifiers: 0x12_0000)
        let like = ShortcutCodable(keyCode: 4, modifiers: 0x12_0000)
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = toggle
        app.customShortcuts[ShortcutAction.likeSong.rawValue] = like
        settings.appSettings = app

        _ = ShortcutMigration.dropRemovedShortcuts(from: settings)

        #expect(settings.appSettings.customShortcuts == [
            ShortcutAction.togglePopup.rawValue: toggle,
            ShortcutAction.likeSong.rawValue: like
        ])
    }

    @Test("The chords KeyboardShortcuts kept for the old names are cleared")
    func resetsOldNames() {
        let names = oldNames.map { KeyboardShortcuts.Name($0) }
        defer { for name in names { KeyboardShortcuts.setShortcut(nil, for: name) } }
        for (i, name) in names.enumerated() {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(carbonKeyCode: 20 + i, carbonModifiers: 0x12_0000),
                for: name
            )
            #expect(KeyboardShortcuts.getShortcut(for: name) != nil)
        }

        _ = ShortcutMigration.dropRemovedShortcuts(from: makeSettings())

        for name in names {
            #expect(KeyboardShortcuts.getShortcut(for: name) == nil)
        }
    }

    @Test("A chord already bound to a new action is left alone")
    func leavesNewNamesAlone() {
        let like = KeyboardShortcuts.Name("music-like")
        let chord = KeyboardShortcuts.Shortcut(carbonKeyCode: 40, carbonModifiers: 0x12_0000)
        KeyboardShortcuts.setShortcut(chord, for: like)
        defer { KeyboardShortcuts.setShortcut(nil, for: like) }

        _ = ShortcutMigration.dropRemovedShortcuts(from: makeSettings())

        #expect(KeyboardShortcuts.getShortcut(for: like) == chord)
    }

    @Test("Running it again changes nothing")
    func idempotent() {
        let settings = makeSettings()
        let names = oldNames.map { KeyboardShortcuts.Name($0) }
        defer { for name in names { KeyboardShortcuts.setShortcut(nil, for: name) } }
        var app = settings.appSettings
        app.customShortcuts[oldKeys[0]] = ShortcutCodable(keyCode: 20, modifiers: 0x12_0000)
        app.customShortcuts[ShortcutAction.dislikeSong.rawValue] = ShortcutCodable(keyCode: 5, modifiers: 0x12_0000)
        settings.appSettings = app
        KeyboardShortcuts.setShortcut(KeyboardShortcuts.Shortcut(carbonKeyCode: 20, carbonModifiers: 0x12_0000), for: names[0])

        _ = ShortcutMigration.dropRemovedShortcuts(from: settings)
        let afterFirst = settings.appSettings.customShortcuts
        _ = ShortcutMigration.dropRemovedShortcuts(from: settings)

        #expect(settings.appSettings.customShortcuts == afterFirst)
        #expect(afterFirst.keys.sorted() == [ShortcutAction.dislikeSong.rawValue])
        for name in names {
            #expect(KeyboardShortcuts.getShortcut(for: name) == nil)
        }
    }

    @Test("It reports how many settings entries it dropped, and none the second time")
    func reportsCount() {
        let settings = makeSettings()
        var app = settings.appSettings
        app.customShortcuts[oldKeys[0]] = ShortcutCodable(keyCode: 20, modifiers: 0)
        app.customShortcuts[oldKeys[2]] = ShortcutCodable(keyCode: 22, modifiers: 0)
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = ShortcutCodable(keyCode: 9, modifiers: 0)
        settings.appSettings = app

        #expect(ShortcutMigration.dropRemovedShortcuts(from: settings) == 2)
        #expect(ShortcutMigration.dropRemovedShortcuts(from: settings) == 0)
        #expect(settings.appSettings.customShortcuts.count == 1)
    }

    @Test("With no old entries it returns 0 and leaves the settings as they were")
    func nothingToDrop() {
        let settings = makeSettings()
        var app = settings.appSettings
        let toggle = ShortcutCodable(keyCode: 9, modifiers: 0x12_0000)
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = toggle
        settings.appSettings = app

        #expect(ShortcutMigration.dropRemovedShortcuts(from: settings) == 0)
        #expect(settings.appSettings.customShortcuts == [ShortcutAction.togglePopup.rawValue: toggle])
    }

    // MARK: - Helpers

    private func makeSettings() -> SettingsManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DeciTests-\(UUID().uuidString)")
        return SettingsManager(directory: dir)
    }
}
