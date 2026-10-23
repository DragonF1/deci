// FineTune/Audio/Keys/PopupVisibilityService.swift
import Foundation

/// `true` while a menu-bar popup is visible. Read by the HUD to skip overlay display.
///
/// Each popup reports itself with `setOpen`. Swapping from one popup to the other resigns one
/// window and makes the other key in either order, so the flag follows the set of open popups
/// and never the last report.
///
/// `isOpen` answers for one popup. A popup's hidden window keeps its SwiftUI tree mounted and still
/// redraws on every state change, so the polling inside a popup gates on its own `isOpen`: reading
/// it registers only that popup, and the other one opening does not redraw the reader.
@Observable
@MainActor
final class PopupVisibilityService {
    var isVisible: Bool = false

    private var isMixerOpen = false
    private var isMusicOpen = false

    /// Whether this popup is open (its window is key).
    func isOpen(_ id: MenuBarItemID) -> Bool {
        switch id {
        case .mixer: isMixerOpen
        case .music: isMusicOpen
        }
    }

    /// Records that a popup opened or closed, then updates `isVisible` to "any popup is open".
    /// Every write is skipped when it would change nothing, so a repeated report redraws nobody.
    func setOpen(_ id: MenuBarItemID, _ open: Bool) {
        switch id {
        case .mixer:
            if isMixerOpen != open { isMixerOpen = open }
        case .music:
            if isMusicOpen != open { isMusicOpen = open }
        }
        let anyOpen = isMixerOpen || isMusicOpen
        if isVisible != anyOpen { isVisible = anyOpen }
    }
}
