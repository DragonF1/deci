// FineTune/Audio/Keys/PopupVisibilityService.swift
import Foundation

/// `true` while a menu-bar popup is visible. Read by the HUD to skip overlay display.
///
/// Each popup reports itself with `setOpen`. Swapping from one popup to the other resigns one
/// window and makes the other key in either order, so the flag follows the set of open popups
/// and never the last report.
@Observable
@MainActor
final class PopupVisibilityService {
    var isVisible: Bool = false

    @ObservationIgnored private var openItems: Set<MenuBarItemID> = []

    /// Records that a popup opened or closed, then updates `isVisible` to "any popup is open".
    func setOpen(_ id: MenuBarItemID, _ open: Bool) {
        if open {
            openItems.insert(id)
        } else {
            openItems.remove(id)
        }
        isVisible = !openItems.isEmpty
    }
}
