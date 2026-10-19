// Deci/Views/MenuBar/MenuBarStatusItems.swift
// AppKit lookups for Deci's two menu bar items. FluidMenuBarExtra hands out no reference to a
// scene's status item or popup window, so both are found through NSApp.windows. Every lookup
// filters by window title (see MenuBarItemID), because both popup windows are the same class.

import AppKit
import os

@MainActor
enum MenuBarStatusItems {
    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "MenuBarStatusItems")

    /// Which item a window is the popup of, or nil for any other window.
    static func itemID(of window: NSWindow) -> MenuBarItemID? {
        MenuBarItemID.match(windowTitle: window.title, className: window.className)
    }

    /// The popup window with this title. nil until the scene has built it.
    static func popupWindow(titled title: String) -> NSWindow? {
        NSApp.windows.first { MenuBarItemID.isPopupWindow(className: $0.className) && $0.title == title }
    }

    static func popupWindow(for id: MenuBarItemID) -> NSWindow? {
        popupWindow(titled: id.title)
    }

    /// The status item behind the popup window with this title, read through the private
    /// `statusItem` keys of the window and of FluidMenuBarExtra's status item wrapper.
    static func statusItem(titled title: String) -> NSStatusItem? {
        guard let window = popupWindow(titled: title),
              let fluidStatusItem = window.value(forKey: "statusItem") as? NSObject
        else { return nil }
        return fluidStatusItem.value(forKey: "statusItem") as? NSStatusItem
    }

    static func statusItem(for id: MenuBarItemID) -> NSStatusItem? {
        statusItem(titled: id.title)
    }

    /// Shows or hides a status item. FluidMenuBarExtra writes the change back to its `isInserted`
    /// binding, so this and the binding cannot disagree for long.
    static func setVisible(_ visible: Bool, for id: MenuBarItemID) {
        guard let item = statusItem(for: id), item.isVisible != visible else { return }
        item.isVisible = visible
    }

    /// True while the Music status item is being renamed. Setting the autosave name makes AppKit reload
    /// the item's saved visibility, and a change it makes then reaches the setting through FluidMenuBarExtra's
    /// `isInserted` binding. The binding ignores writes for the duration, and the item is put back after.
    private(set) static var isConfiguringMusicItem = false

    /// Writes the visibility keys AppKit keeps for the Music item so they match the setting. AppKit reads
    /// them when the autosave name is set, so a stale hidden value from an old cmd-drag would hide the item
    /// and the binding would turn the setting off with no user action. The Mixer has no name of its own, so
    /// nothing is written for it (its keys are kept visible at launch).
    static func writeVisibilityDefaults(_ visible: Bool, for id: MenuBarItemID, in defaults: UserDefaults = .standard) {
        for key in id.visibilityDefaultsKeys {
            defaults.set(visible ? 1 : 0, forKey: key)
        }
    }

    /// One attempt at giving the Music status item its fixed autosave name. False when its scene has not
    /// built the item yet. Safe to call again: an item that already has the name is left alone. The saved
    /// visibility is made to match the setting first, and the item is set to it again after the rename.
    @discardableResult
    static func nameMusicItem(shown: Bool) -> Bool {
        guard let item = statusItem(for: .music) else { return false }
        guard let name = MenuBarItemID.music.autosaveName, item.autosaveName != name else { return true }
        isConfiguringMusicItem = true
        defer { isConfiguringMusicItem = false }
        writeVisibilityDefaults(shown, for: .music)
        item.autosaveName = name
        setVisible(shown, for: .music)
        return true
    }

    /// Names the Music status item once its scene has built it. The scene is created after the app's init
    /// returns, so this retries for a second, the way the icon coordinator waits for the Mixer's button.
    /// `isShown` is read when the item is found, so it sees the setting as it is then. If the second runs
    /// out, the Music popup tries once more when it first opens.
    static func configureMusicItem(isShown: @escaping @MainActor () -> Bool, retriesLeft: Int = 20) {
        if nameMusicItem(shown: isShown()) { return }
        guard retriesLeft > 0 else {
            logger.error("Music menu bar item not found after 20 tries (1s); it keeps its default autosave name until its popup opens")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            configureMusicItem(isShown: isShown, retriesLeft: retriesLeft - 1)
        }
    }

    /// Applies the "Show Music in menu bar" setting to the menu bar: shows or hides the item, and when it
    /// is hidden closes the Music popup and resets what the popup reported. Playback is not touched, the
    /// player only loses its view. Safe to call repeatedly: every step does nothing when already done.
    static func applyMusicVisibility(_ shown: Bool, popupVisibility: PopupVisibilityService, musicHost: MusicServiceHost) {
        setVisible(shown, for: .music)
        guard !shown else { return }
        if let window = popupWindow(for: .music), window.isKeyWindow {
            window.resignKey()
        }
        popupVisibility.setOpen(.music, false)
        musicHost.isPopupVisible = false
        musicHost.isAccountCardOpen = false
    }
}
