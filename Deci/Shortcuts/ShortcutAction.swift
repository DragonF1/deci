// Deci/Shortcuts/ShortcutAction.swift
import Foundation

/// Actions that can be bound to a user-recordable global keyboard shortcut.
///
/// Adding a new action here is a single enum case + a corresponding arm
/// in `ShortcutsRegistry.dispatch(_:)`. The `rawValue` is the persistence key
/// in `AppSettings.customShortcuts` and must be stable across releases.
/// Removing an action leaves its key and its `KeyboardShortcuts` name behind in
/// the user's files: `ShortcutMigration` clears them at launch.
enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case togglePopup
    case saveSongToPlaylist = "musicSaveToPlaylist"
    case likeSong = "musicLike"
    case dislikeSong = "musicDislike"

    var displayName: String {
        switch self {
        case .togglePopup: "Toggle Deci Popup"
        case .saveSongToPlaylist: "Save Song to Playlist"
        case .likeSong: "Like Song"
        case .dislikeSong: "Dislike Song"
        }
    }
}
