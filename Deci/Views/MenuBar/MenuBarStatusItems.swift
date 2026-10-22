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

    /// The status item behind the popup window with this title, read through FluidMenuBarExtra's
    /// status item wrapper.
    static func statusItem(titled title: String) -> NSStatusItem? {
        guard let window = popupWindow(titled: title) else { return nil }
        return statusItemValue(of: window) as? NSStatusItem
    }

    /// The private `statusItem` of FluidMenuBarExtra's wrapper, which makes itself the popup window's
    /// delegate. The window's own `statusItem` is a Swift property of a generic class, invisible to KVC,
    /// so reading the window always gave nil. Nil when the delegate is anything else.
    static func statusItemValue(of window: NSWindow) -> Any? {
        let key = "statusItem"
        guard let wrapper = window.delegate as? NSObject,
              wrapper.responds(to: NSSelectorFromString(key))
        else { return nil }
        return wrapper.value(forKey: key)
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

    /// Copies the menu bar position saved under the item's current autosave name to the name it is about to get,
    /// so the rename does not move the icon. A position already saved under the new name wins.
    static func carryPosition(from oldName: String, to newName: String, in defaults: UserDefaults = .standard) {
        let oldKey = "NSStatusItem Preferred Position \(oldName)"
        let newKey = "NSStatusItem Preferred Position \(newName)"
        guard oldName != newName, defaults.object(forKey: newKey) == nil,
              let position = defaults.object(forKey: oldKey)
        else { return }
        defaults.set(position, forKey: newKey)
    }

    /// The autosave name AppKit gives the Music item when its scene builds it, after the Mixer's "Item-0". The item
    /// keeps it until `nameMusicItem` renames it.
    static let musicLaunchName = "Item-1"

    /// Copies the Music item's saved position to the name AppKit builds it under, before its scene builds it. AppKit
    /// places a new item by the position saved under its name, and macOS rewrites that number only on a Cmd-drag, so
    /// the launch name's number goes stale once the item is renamed. Without this the item first appears in an old
    /// spot, and stays there when the rename comes late (a busy login after a restart).
    static func seedMusicLaunchPosition(in defaults: UserDefaults = .standard) {
        guard let name = MenuBarItemID.music.autosaveName else { return }
        seedPosition(from: name, to: musicLaunchName, in: defaults)
    }

    /// Copies the position saved under one autosave name to another, over whatever the other holds. Nothing is
    /// written when the first has none.
    static func seedPosition(from source: String, to target: String, in defaults: UserDefaults = .standard) {
        guard let position = defaults.object(forKey: "NSStatusItem Preferred Position \(source)") else { return }
        defaults.set(position, forKey: "NSStatusItem Preferred Position \(target)")
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
        if let oldName = item.autosaveName as String? {
            if oldName != musicLaunchName {
                logger.warning("Music menu bar item was built as \(oldName, privacy: .public), not \(Self.musicLaunchName, privacy: .public); its launch spot was not seeded")
            }
            carryPosition(from: oldName, to: name)
        }
        item.autosaveName = name
        setVisible(shown, for: .music)
        return true
    }

    /// Names the Music status item once its scene has built it. The scene is created after the app's init
    /// returns, so this retries for up to 10 seconds, long enough for a busy login after a restart. `isShown`
    /// is read when the item is found, so it sees the setting as it is then. If the time runs out, the Music
    /// popup tries once more when it first opens.
    static func configureMusicItem(isShown: @escaping @MainActor () -> Bool, retriesLeft: Int = 200) {
        if nameMusicItem(shown: isShown()) { return }
        guard retriesLeft > 0 else {
            logger.error("Music menu bar item not found after 200 tries (10s); it keeps its default autosave name until its popup opens")
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
