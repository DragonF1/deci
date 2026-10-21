// Deci/Views/HUD/HUDMessage.swift
import Foundation

/// One short line for the HUD, with the SF Symbol that goes before it: what a hotkey came to.
nonisolated struct HUDMessage: Equatable, Sendable {
    let symbol: String
    let text: String
}

/// Whatever shows a `HUDMessage` on screen; `HUDWindowController` does, and tests stand in for it.
@MainActor
protocol MessageHUDPresenting: AnyObject {
    func showMessage(_ message: HUDMessage)
}
