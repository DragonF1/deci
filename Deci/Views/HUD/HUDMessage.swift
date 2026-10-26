// Deci/Views/HUD/HUDMessage.swift
import Foundation

/// One short line for the HUD, with the SF Symbol that goes before it: what a hotkey came to.
nonisolated struct HUDMessage: Equatable, Sendable {
    let symbol: String
    let text: String

    /// A line longer than this many characters is the kind that wraps onto the tile's second row: the text column holds
    /// about 33 characters of the 13 pt title face, and the hotkeys' own lines (the longest has 28) all fit on one row.
    static let wrappingLength = 30

    /// How long a wrapping line stays up: a second row takes a moment more to read than a word or two.
    static let wrappingHideDelay = Duration.milliseconds(2500)

    /// How long the line stays on screen. A short line keeps `base`, the volume HUD's delay, and one that wraps stays
    /// `wrappingHideDelay` instead, though never less than a `base` that is longer still.
    func hideDelay(base: Duration) -> Duration {
        text.count > Self.wrappingLength ? max(base, Self.wrappingHideDelay) : base
    }
}

/// Whatever shows a `HUDMessage` on screen; `HUDWindowController` does, and tests stand in for it.
@MainActor
protocol MessageHUDPresenting: AnyObject {
    func showMessage(_ message: HUDMessage)
}
