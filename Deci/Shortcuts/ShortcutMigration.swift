// Deci/Shortcuts/ShortcutMigration.swift
import Foundation
import KeyboardShortcuts
import os

/// Clears what the removed App Volume Up, App Volume Down and App Mute hotkeys left behind: their entries in
/// `AppSettings.customShortcuts` and the chords `KeyboardShortcuts` keeps for them in UserDefaults. Without it a
/// chord the user once bound would sit in both files for good, shown nowhere. Run once per launch, before the
/// registry starts. Running it again finds nothing and changes nothing.
enum ShortcutMigration {
    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "ShortcutMigration")

    /// The removed actions' `ShortcutAction` raw values: their keys in `customShortcuts`.
    nonisolated static let removedActionKeys = ["frontmostAppVolumeUp", "frontmostAppVolumeDown", "frontmostAppMuteToggle"]

    /// The removed actions' `KeyboardShortcuts.Name` ids.
    nonisolated static let removedNameIDs = ["frontmost-app-volume-up", "frontmost-app-volume-down", "frontmost-app-mute-toggle"]

    /// Returns how many entries it dropped from the settings, for the log and the tests.
    @MainActor
    @discardableResult
    static func dropRemovedShortcuts(from settings: SettingsManager) -> Int {
        var app = settings.appSettings
        let present = removedActionKeys.filter { app.customShortcuts[$0] != nil }
        if !present.isEmpty {
            for key in present { app.customShortcuts[key] = nil }
            settings.appSettings = app
        }
        // Resetting a name with no stored chord is a no-op, so this is safe on every launch.
        KeyboardShortcuts.reset(removedNameIDs.map { KeyboardShortcuts.Name($0) })
        if !present.isEmpty {
            logger.info("dropped \(present.count) removed hotkey entries from settings")
        }
        return present.count
    }
}
