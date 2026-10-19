// Deci/Views/MenuBar/MenuBarItemID.swift
// The two menu bar items and how a window is traced back to one of them. Pure, so the
// matching rule is unit tested; the AppKit lookups built on it live in MenuBarStatusItems.

import Foundation

/// The two status items Deci puts in the menu bar, each with its own popup window.
///
/// Both popup windows are the same class, so a window is told apart by its title, which
/// FluidMenuBarExtra sets from the scene title. A class name alone must never decide which item
/// a window belongs to: every filter in the app goes through `match` or `isPopupWindow`.
nonisolated enum MenuBarItemID: String, CaseIterable, Hashable {
    case mixer
    case music

    /// The scene title: FluidMenuBarExtra uses it as the popup window's title and as the status
    /// button's accessibility title. Matched exactly, so "Deci" never matches "Deci Music".
    var title: String {
        switch self {
        case .mixer: "Deci"
        case .music: "Deci Music"
        }
    }

    /// The name the status item's position and visibility are saved under, or nil to keep the one
    /// AppKit gave it at creation. The Mixer is the first scene, so it keeps "Item-0" and the icon
    /// stays where it was put. The Music item gets a fixed name so its place does not depend on
    /// the order the scenes are created in.
    var autosaveName: String? {
        switch self {
        case .mixer: nil
        case .music: "DeciMusic"
        }
    }

    /// The user defaults keys AppKit reads and writes for the visibility of a status item with this
    /// autosave name. AppKit reads them when the name is set, so a stale hidden value left by an old
    /// cmd-drag would hide the item at once.
    static func visibilityDefaultsKeys(autosaveName: String) -> [String] {
        ["NSStatusItem Visible \(autosaveName)", "NSStatusItem VisibleCC \(autosaveName)"]
    }

    /// The visibility keys of this item's fixed autosave name. Empty for the Mixer, whose keys are the
    /// ones AppKit made for it and which the app keeps set to visible at launch.
    var visibilityDefaultsKeys: [String] {
        autosaveName.map { Self.visibilityDefaultsKeys(autosaveName: $0) } ?? []
    }

    /// Whether a window of this class is a FluidMenuBarExtra popup. Accepts the plain, the
    /// module-qualified and the mangled name of the generic window class.
    static func isPopupWindow(className: String) -> Bool {
        className.contains("FluidMenuBarExtraWindow")
    }

    /// The item a window is the popup of, or nil for any other window (Settings, alerts, the
    /// sign-in window, a status bar button window), whatever its title.
    static func match(windowTitle: String, className: String) -> MenuBarItemID? {
        guard isPopupWindow(className: className) else { return nil }
        return allCases.first { $0.title == windowTitle }
    }
}
