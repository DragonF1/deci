// Deci/Shortcuts/ShortcutsRegistry.swift
import AppKit
import Foundation
import KeyboardShortcuts
import os

/// Bridges `KeyboardShortcuts` (Carbon-backed global hotkey library, MIT) to
/// Deci's settings layer.
///
/// Responsibilities:
///   1. Load: on `start()`, push every persisted shortcut from `AppSettings`
///      into `KeyboardShortcuts` and register a `onKeyDown` handler that
///      dispatches the matching `ShortcutAction`.
///   2. Save: vend `recordCallback(for:)` closures that the UI's `Recorder`
///      passes as its `onChange` parameter. When the user records a new
///      chord, the callback writes the change back to `SettingsManager`,
///      keeping `settings.json` the source of truth.
///
/// Why no async-stream observer for write-back: `KeyboardShortcuts.events(...)`
/// only emits `.keyDown` / `.keyUp`, not "shortcut changed". The library's only
/// shortcut-mutation hook is the `Recorder.onChange` per-instance callback,
/// which we wire from the UI. This keeps re-entrancy impossible by construction:
/// programmatic `setShortcut(_:for:)` from `start()` never fires `Recorder.onChange`.
@MainActor
@Observable
final class ShortcutsRegistry {
    private static let logger = Logger(
        subsystem: "com.abraham.Deci",
        category: "ShortcutsRegistry"
    )

    private let settings: SettingsManager
    private let popupController: any MenuBarPopupControlling
    private let music: any MusicShortcutActing
    private let outcomes: any MusicOutcomeReporting
    private var didStart = false

    init(
        settings: SettingsManager,
        popupController: any MenuBarPopupControlling,
        music: any MusicShortcutActing,
        outcomes: any MusicOutcomeReporting
    ) {
        self.settings = settings
        self.popupController = popupController
        self.music = music
        self.outcomes = outcomes
    }

    /// Stable `KeyboardShortcuts.Name` per action. The raw string is part of
    /// the persistence contract — don't change it without a migration.
    func name(for action: ShortcutAction) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name(stableID(for: action))
    }

    /// Routes a fired action to its handler. Exposed `internal` so tests can
    /// drive it directly without faking a global key event.
    ///
    /// Like and Dislike wait on YouTube Music, so they run in a task that reports
    /// the outcome once the answer is in; that task is returned for tests to wait
    /// on. The other actions finish before this returns.
    ///
    /// Each press is logged by action, and each music outcome by case name, so a
    /// hotkey that seemed to do nothing can be told from one that never fired.
    /// Nothing about the song is logged.
    @discardableResult
    func dispatch(_ action: ShortcutAction) -> Task<Void, Never>? {
        Self.logger.info("shortcut pressed: \(action.rawValue, privacy: .public)")
        switch action {
        case .togglePopup:
            popupController.toggle()
        case .saveSongToPlaylist:
            show(music.saveToPlaylist(), for: action)
        case .likeSong:
            return Task { @MainActor [weak self] in
                guard let self else { return }
                self.show(await self.music.toggleLike(), for: action)
            }
        case .dislikeSong:
            return Task { @MainActor [weak self] in
                guard let self else { return }
                self.show(await self.music.dislike(), for: action)
            }
        }
        return nil
    }

    // MARK: - Music dispatch

    /// Hands the outcome to where it is shown: the Music popup's notice line while that popup is open, else the HUD.
    private func show(_ outcome: MusicActionOutcome, for action: ShortcutAction) {
        Self.logger.info("shortcut \(action.rawValue, privacy: .public) came to: \(String(describing: outcome), privacy: .public)")
        outcomes.report(outcome)
    }

    /// Idempotent. Subsequent calls are no-ops. Safe to call from a SwiftUI
    /// `.task` modifier on the popup content, and from the app's launch: the
    /// registry is main-actor bound, so the two cannot interleave.
    func start() {
        guard !didStart else { return }
        didStart = true

        for action in ShortcutAction.allCases {
            let actionName = name(for: action)

            if let codable = settings.appSettings.customShortcuts[action.rawValue] {
                KeyboardShortcuts.setShortcut(codable.keyboardShortcut, for: actionName)
            }

            KeyboardShortcuts.onKeyDown(for: actionName) { [weak self] in
                self?.dispatch(action)
            }
        }

        Self.logger.info("ShortcutsRegistry started; \(ShortcutAction.allCases.count) action(s) registered")
    }

    /// Returns a closure suitable for `KeyboardShortcuts.Recorder(for:onChange:)`.
    /// When the user records or clears a chord, the closure mirrors the change
    /// into `SettingsManager.appSettings.customShortcuts`.
    ///
    /// The return type carries `@MainActor` even though the library's parameter
    /// type does not — this works today because `KeyboardShortcuts.Recorder` is
    /// SwiftUI-presented and its `Coordinator.handleChange(_:)` runs on the
    /// MainActor, so passing a more-isolated function value satisfies the
    /// less-isolated parameter via implicit conversion. If a future library
    /// version dispatches `onChange` from a non-MainActor context, that becomes
    /// a runtime crash; the annotation is the contract that makes it surface
    /// loudly rather than silently corrupt MainActor-isolated state.
    func recordCallback(for action: ShortcutAction) -> @MainActor (KeyboardShortcuts.Shortcut?) -> Void {
        return { [weak self] shortcut in
            self?.handleRecorderChange(shortcut: shortcut, for: action)
        }
    }

    private func handleRecorderChange(shortcut: KeyboardShortcuts.Shortcut?, for action: ShortcutAction) {
        var app = settings.appSettings
        if let shortcut {
            app.customShortcuts[action.rawValue] = ShortcutCodable.from(shortcut)
        } else {
            app.customShortcuts[action.rawValue] = nil
        }
        settings.appSettings = app
    }

    private func stableID(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: "toggle-popup"
        case .saveSongToPlaylist: "music-save-to-playlist"
        case .likeSong: "music-like"
        case .dislikeSong: "music-dislike"
        }
    }
}

extension HUDWindowController: MessageHUDPresenting {}
