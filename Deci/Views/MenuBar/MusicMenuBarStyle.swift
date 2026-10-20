// Deci/Views/MenuBar/MusicMenuBarStyle.swift
// How the Music menu bar item looks. Pure, so the setting's rules are unit tested.

import Foundation

/// The Music menu bar item as the plain music note icon (the default), or as a Now playing chip: a small pill with the
/// song's cover and title, which appears while a song is loaded and hands the item back to the icon otherwise.
nonisolated enum MusicMenuBarStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case icon
    case chip

    /// What a settings file without the key, or with a value this build does not know, decodes to.
    static let `default`: MusicMenuBarStyle = .icon

    /// What the picker in Settings calls it.
    var title: String {
        switch self {
        case .icon: "Icon"
        case .chip: "Now playing chip"
        }
    }
}
