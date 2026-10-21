// DeciTests/ShortcutsRegistryTests.swift
import Testing
import Foundation
import AppKit
import KeyboardShortcuts
@testable import Deci

@Suite("ShortcutsRegistry")
@MainActor
struct ShortcutsRegistryTests {
    // MARK: - dispatch

    @Test("dispatch(.togglePopup) calls popupController.toggle() exactly once")
    func dispatchTogglePopup() {
        let recorder = RecordingPopupController()
        let music = FakeMusicShortcuts()
        let registry = makeRegistry(popupController: recorder, music: music)

        registry.dispatch(.togglePopup)

        #expect(recorder.toggleCount == 1)
        #expect(music.calls.isEmpty)
    }

    @Test("Save song to playlist goes to the music side once, and the other two actions stay out of it")
    func dispatchSaveCalls() {
        let recorder = RecordingPopupController()
        let music = FakeMusicShortcuts()
        let registry = makeRegistry(popupController: recorder, music: music)

        registry.dispatch(.saveSongToPlaylist)

        #expect(music.calls == [.save])
        #expect(recorder.toggleCount == 0)
    }

    @Test("Save song to playlist reports what came back", arguments: MusicActionOutcome.allCases)
    func dispatchSaveReportsOutcome(outcome: MusicActionOutcome) {
        let music = FakeMusicShortcuts()
        music.outcome = outcome
        let reporter = RecordingOutcomeReporter()
        let registry = makeRegistry(music: music, outcomes: reporter)

        registry.dispatch(.saveSongToPlaylist)

        #expect(reporter.outcomes == [outcome])
    }

    @Test("Like song goes to the music side once and reports what came back", arguments: MusicActionOutcome.allCases)
    func dispatchLike(outcome: MusicActionOutcome) async {
        let music = FakeMusicShortcuts()
        music.outcome = outcome
        let reporter = RecordingOutcomeReporter()
        let registry = makeRegistry(music: music, outcomes: reporter)

        await registry.dispatch(.likeSong)?.value

        #expect(music.calls == [.like])
        #expect(reporter.outcomes == [outcome])
    }

    @Test("Dislike song goes to the music side once and reports what came back", arguments: MusicActionOutcome.allCases)
    func dispatchDislike(outcome: MusicActionOutcome) async {
        let music = FakeMusicShortcuts()
        music.outcome = outcome
        let reporter = RecordingOutcomeReporter()
        let registry = makeRegistry(music: music, outcomes: reporter)

        await registry.dispatch(.dislikeSong)?.value

        #expect(music.calls == [.dislike])
        #expect(reporter.outcomes == [outcome])
    }

    @Test("The report for Like waits for YouTube Music's answer, and the key press does not")
    func likeReportWaitsForTheAnswer() async {
        let music = FakeMusicShortcuts()
        music.outcome = .liked
        let gate = MusicTestGate()
        music.gate = gate
        let reporter = RecordingOutcomeReporter()
        let registry = makeRegistry(music: music, outcomes: reporter)

        let task = registry.dispatch(.likeSong)
        for _ in 0..<20 { await Task.yield() }

        #expect(music.calls == [.like])
        #expect(reporter.outcomes.isEmpty)

        await gate.open()
        await task?.value

        #expect(reporter.outcomes == [.liked])
    }

    @Test("A second press while the first is out is a second call to the music side, which answers it quietly")
    func repeatedPressesReachTheMusicSide() async {
        let music = FakeMusicShortcuts()
        music.outcome = .quiet
        let reporter = RecordingOutcomeReporter()
        let registry = makeRegistry(music: music, outcomes: reporter)

        await registry.dispatch(.dislikeSong)?.value
        await registry.dispatch(.dislikeSong)?.value

        #expect(music.calls == [.dislike, .dislike])
        #expect(reporter.outcomes == [.quiet, .quiet])
    }

    @Test("The popup toggle reports nothing")
    func toggleReportsNothing() {
        let reporter = RecordingOutcomeReporter()
        makeRegistry(outcomes: reporter).dispatch(.togglePopup)
        #expect(reporter.outcomes.isEmpty)
    }

    // MARK: - actions

    @Test("The actions are the popup toggle and the three music ones, in that order")
    func actionList() {
        #expect(ShortcutAction.allCases == [.togglePopup, .saveSongToPlaylist, .likeSong, .dislikeSong])
    }

    @Test("The raw values are the persistence keys in settings.json, and the removed ones are not actions any more")
    func rawValues() {
        #expect(ShortcutAction.togglePopup.rawValue == "togglePopup")
        #expect(ShortcutAction.saveSongToPlaylist.rawValue == "musicSaveToPlaylist")
        #expect(ShortcutAction.likeSong.rawValue == "musicLike")
        #expect(ShortcutAction.dislikeSong.rawValue == "musicDislike")
        for removed in ["frontmostAppVolumeUp", "frontmostAppVolumeDown", "frontmostAppMuteToggle"] {
            #expect(ShortcutAction(rawValue: removed) == nil)
        }
    }

    @Test("The names shown in Settings")
    func displayNames() {
        #expect(ShortcutAction.saveSongToPlaylist.displayName == "Save Song to Playlist")
        #expect(ShortcutAction.likeSong.displayName == "Like Song")
        #expect(ShortcutAction.dislikeSong.displayName == "Dislike Song")
    }

    @Test("name(for:) is the stable KeyboardShortcuts identifier of each action")
    func nameStable() {
        let registry = makeRegistry()
        #expect(registry.name(for: .togglePopup).rawValue == "toggle-popup")
        #expect(registry.name(for: .saveSongToPlaylist).rawValue == "music-save-to-playlist")
        #expect(registry.name(for: .likeSong).rawValue == "music-like")
        #expect(registry.name(for: .dislikeSong).rawValue == "music-dislike")
    }

    @Test("The new actions start with no chord bound")
    func noDefaultBindings() {
        let registry = makeRegistry()
        for action in ShortcutAction.allCases {
            #expect(registry.name(for: action).defaultShortcut == nil)
        }
    }

    // MARK: - start: load path

    @Test("start() loads stored shortcuts into KeyboardShortcuts")
    func startLoadsStoredShortcuts() {
        let settings = makeIsolatedSettings()
        let stored = ShortcutCodable(keyCode: 9, modifiers: 0x12_0000)
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = stored
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        registry.start()

        let resolved = KeyboardShortcuts.getShortcut(for: registry.name(for: .togglePopup))
        #expect(resolved?.carbonKeyCode == stored.keyCode)
        #expect(resolved?.carbonModifiers == stored.keyboardShortcut.carbonModifiers)

        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .togglePopup))
    }

    @Test("start() loads a stored chord for each of the music actions")
    func startLoadsMusicShortcuts() {
        let settings = makeIsolatedSettings()
        let chords: [ShortcutAction: ShortcutCodable] = [
            .saveSongToPlaylist: ShortcutCodable(keyCode: 3, modifiers: 0x12_0000),
            .likeSong: ShortcutCodable(keyCode: 4, modifiers: 0x12_0000),
            .dislikeSong: ShortcutCodable(keyCode: 5, modifiers: 0x12_0000)
        ]
        var app = settings.appSettings
        for (action, chord) in chords { app.customShortcuts[action.rawValue] = chord }
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        registry.start()
        defer {
            for action in chords.keys { KeyboardShortcuts.setShortcut(nil, for: registry.name(for: action)) }
        }

        for (action, chord) in chords {
            let resolved = KeyboardShortcuts.getShortcut(for: registry.name(for: action))
            #expect(resolved?.carbonKeyCode == chord.keyCode)
            #expect(resolved?.carbonModifiers == chord.keyboardShortcut.carbonModifiers)
        }
    }

    @Test("start() is idempotent")
    func startIsIdempotent() {
        let settings = makeIsolatedSettings()
        let registry = makeRegistry(settings: settings)

        registry.start()
        registry.start()

        let recorder = RecordingPopupController()
        let registryWithRecorder = makeRegistry(settings: settings, popupController: recorder)
        registryWithRecorder.start()
        registryWithRecorder.start()
        registryWithRecorder.dispatch(.togglePopup)
        #expect(recorder.toggleCount == 1)

        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .togglePopup))
    }

    // MARK: - recordCallback: write-back path

    @Test("recordCallback writes the new shortcut into AppSettings")
    func recordCallbackWritesBack() {
        let settings = makeIsolatedSettings()
        let registry = makeRegistry(settings: settings)

        let callback = registry.recordCallback(for: .togglePopup)
        let newShortcut = KeyboardShortcuts.Shortcut(carbonKeyCode: 11, carbonModifiers: 0x12_0000)
        callback(newShortcut)

        let stored = settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue]
        #expect(stored?.keyCode == 11)
        #expect(stored?.modifiers == UInt(newShortcut.carbonModifiers))
    }

    @Test("recordCallback stores a music action's chord under its own key")
    func recordCallbackWritesMusicAction() {
        let settings = makeIsolatedSettings()
        let registry = makeRegistry(settings: settings)

        registry.recordCallback(for: .likeSong)(KeyboardShortcuts.Shortcut(carbonKeyCode: 12, carbonModifiers: 0x12_0000))

        #expect(settings.appSettings.customShortcuts["musicLike"]?.keyCode == 12)
        #expect(settings.appSettings.customShortcuts.count == 1)
    }

    @Test("recordCallback clears the entry when given nil")
    func recordCallbackClearsOnNil() {
        let settings = makeIsolatedSettings()
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = ShortcutCodable(keyCode: 9, modifiers: 0)
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        let callback = registry.recordCallback(for: .togglePopup)
        callback(nil)

        #expect(settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] == nil)
    }

    // MARK: - Helpers

    private func makeRegistry(
        settings: SettingsManager? = nil,
        popupController: (any MenuBarPopupControlling)? = nil,
        music: (any MusicShortcutActing)? = nil,
        outcomes: (any MusicOutcomeReporting)? = nil
    ) -> ShortcutsRegistry {
        ShortcutsRegistry(
            settings: settings ?? makeIsolatedSettings(),
            popupController: popupController ?? RecordingPopupController(),
            music: music ?? FakeMusicShortcuts(),
            outcomes: outcomes ?? RecordingOutcomeReporter()
        )
    }

    private func makeIsolatedSettings() -> SettingsManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DeciTests-\(UUID().uuidString)")
        return SettingsManager(directory: dir)
    }
}

// MARK: - Music action HUD messages

@Suite("Music action HUD messages")
struct MusicActionHUDMessageTests {
    @Test("Each outcome has its own symbol and short line")
    func words() {
        #expect(MusicActionOutcome.liked.hudMessage == HUDMessage(symbol: "hand.thumbsup.fill", text: "Liked"))
        #expect(MusicActionOutcome.likeRemoved.hudMessage == HUDMessage(symbol: "hand.thumbsup", text: "Removed like"))
        #expect(MusicActionOutcome.disliked.hudMessage == HUDMessage(symbol: "hand.thumbsdown.fill", text: "Disliked"))
        #expect(
            MusicActionOutcome.dislikeRemoved.hudMessage == HUDMessage(symbol: "hand.thumbsdown", text: "Removed dislike")
        )
        #expect(MusicActionOutcome.nothingPlaying.hudMessage == HUDMessage(symbol: "music.note", text: "Nothing is playing"))
        #expect(
            MusicActionOutcome.signedOut.hudMessage
                == HUDMessage(symbol: "person.crop.circle.badge.exclamationmark", text: "Sign in to YouTube Music")
        )
        #expect(
            MusicActionOutcome.failed.hudMessage
                == HUDMessage(symbol: "exclamationmark.triangle", text: "Couldn't reach YouTube Music")
        )
        #expect(
            MusicActionOutcome.musicHidden.hudMessage
                == HUDMessage(symbol: "menubar.rectangle", text: "Show Music in the menu bar")
        )
    }

    @Test("A quiet outcome shows nothing, on the HUD or in the notice line")
    func quietIsSilent() {
        #expect(MusicActionOutcome.quiet.hudMessage == nil)
        #expect(MusicActionOutcome.quiet.noticeText == nil)
    }

    @Test("The notice line and the HUD say the same words for every outcome")
    func noticeAndHudShareWords() {
        for outcome in MusicActionOutcome.allCases {
            #expect(outcome.noticeText == outcome.hudMessage?.text)
        }
        #expect(MusicActionOutcome.likeRemoved.noticeText == "Removed like")
        #expect(MusicActionOutcome.dislikeRemoved.noticeText == "Removed dislike")
    }

    @Test("Only the four ratings are not failures; a refusal or a failed call is")
    func failures() {
        let successes: [MusicActionOutcome] = [.liked, .likeRemoved, .disliked, .dislikeRemoved, .quiet]
        for outcome in MusicActionOutcome.allCases {
            #expect(outcome.isFailure == !successes.contains(outcome))
        }
    }

    @Test("Every symbol exists, and every line fits the HUD's one row without an em-dash")
    func symbolsAndLength() {
        for outcome in MusicActionOutcome.allCases where outcome != .quiet {
            let message = outcome.hudMessage
            #expect(message != nil)
            #expect(NSImage(systemSymbolName: message?.symbol ?? "", accessibilityDescription: nil) != nil)
            #expect((message?.text.count ?? 99) <= 30)
            #expect(message?.text.contains("\u{2014}") == false)
        }
    }
}

// MARK: - The hover card's rating buttons

@MainActor
@Suite("Hover card rating failures")
struct MusicRateFailureHUDTests {
    @Test("A rating that failed or found the session gone is shown as the hotkey shows it")
    func failuresAreShown() {
        let hud = RecordingMessageHUD()

        hud.showIfFailed(.failed)
        hud.showIfFailed(.signedOut)

        #expect(hud.messages == [MusicActionOutcome.failed.hudMessage, MusicActionOutcome.signedOut.hudMessage].compactMap { $0 })
        #expect(hud.messages.count == 2)
    }

    @Test("A rating that went through stays silent, since the button already shows it", arguments: [
        MusicActionOutcome.liked, .likeRemoved, .disliked, .dislikeRemoved, .quiet,
    ])
    func successesAreSilent(outcome: MusicActionOutcome) {
        let hud = RecordingMessageHUD()
        hud.showIfFailed(outcome)
        #expect(hud.messages.isEmpty)
    }
}

// MARK: - Test doubles

@MainActor
final class RecordingPopupController: MenuBarPopupControlling {
    var toggleCount = 0
    func toggle() { toggleCount += 1 }
}

/// Stands in for the music side of the shortcuts: records which action reached it and answers with `outcome`.
@MainActor
final class FakeMusicShortcuts: MusicShortcutActing {
    enum Call: Equatable { case save, like, dislike }

    private(set) var calls: [Call] = []
    var outcome: MusicActionOutcome = .quiet
    /// When set, Like and Dislike wait here before they answer.
    var gate: MusicTestGate?

    func saveToPlaylist() -> MusicActionOutcome {
        calls.append(.save)
        return outcome
    }

    func toggleLike() async -> MusicActionOutcome {
        calls.append(.like)
        await gate?.wait()
        return outcome
    }

    func dislike() async -> MusicActionOutcome {
        calls.append(.dislike)
        await gate?.wait()
        return outcome
    }
}

/// Stands in for where a hotkey's outcome is shown: records every outcome it was given.
@MainActor
final class RecordingOutcomeReporter: MusicOutcomeReporting {
    private(set) var outcomes: [MusicActionOutcome] = []
    func report(_ outcome: MusicActionOutcome) { outcomes.append(outcome) }
}

@MainActor
final class RecordingMessageHUD: MessageHUDPresenting {
    private(set) var messages: [HUDMessage] = []
    func showMessage(_ message: HUDMessage) { messages.append(message) }
}
