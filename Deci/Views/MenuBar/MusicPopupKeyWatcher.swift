// Deci/Views/MenuBar/MusicPopupKeyWatcher.swift
// The one signal for the full Music popover opening and closing: it is the key window while it is open (a click opens
// it that way, FluidMenuBarExtra closes it when it resigns). The watcher only says "look again"; its owner reads
// `isPopupOpen`. Owners start it while they need the signal and stop it after, so nothing listens the rest of the time.

import AppKit

@MainActor
final class MusicPopupKeyWatcher {
    private var observers: [NSObjectProtocol] = []

    var isWatching: Bool { !observers.isEmpty }

    /// Whether the Music popover is open: on screen and key. Its fade-out after a close is not open, so a change made
    /// then does not wait for a notification that will not come.
    static var isPopupOpen: Bool {
        guard let window = MenuBarStatusItems.popupWindow(for: .music) else { return false }
        return window.isVisible && window.isKeyWindow
    }

    /// Calls `onChange` whenever any window gains or loses key status; a change in some other window is the owner's
    /// to ignore by comparing `isPopupOpen` with what it saw last. Idempotent.
    func start(onChange: @escaping @MainActor () -> Void) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
        }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}
