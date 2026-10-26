// FineTuneTests/HUDWindowControllerTests.swift
// Tests for HUDWindowController: position math, hide-timer reset semantics,
// style-specific hide delay, and popup-guard behavior.
//
// NSPanel/NSScreen creation is avoided — position math is tested via the pure
// static method, and timer behavior is tested via the hideDelayOverride hook.

import Testing
import Foundation
import AppKit
@testable import Deci

@Suite("HUDWindowController — computePosition()")
@MainActor
struct HUDWindowControllerPositionTests {

    private let screen = NSRect(x: 0, y: 23, width: 1440, height: 877)  // typical macOS visible frame

    // MARK: - Tahoe style

    @Test("Tahoe style places HUD at top-right, inset 8pt from edges (AC #16)")
    func tahoeTopRight() {
        let size = NSSize(width: 300, height: 72)
        let pt = HUDWindowController.computePosition(
            style: .tahoe,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: false
        )
        let expectedX = screen.maxX - size.width - 8
        let expectedY = screen.maxY - size.height - 8
        #expect(pt.x == expectedX)
        #expect(pt.y == expectedY)
    }

    @Test("Tahoe style shifts to upper-left quarter when suppressionDegraded (AC #15 formula)")
    func tahoeSuppressionDegraded() {
        let size = NSSize(width: 300, height: 72)
        let pt = HUDWindowController.computePosition(
            style: .tahoe,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: true
        )
        let expectedX = screen.minX + screen.width * 0.25 - size.width / 2
        let expectedY = screen.maxY - size.height - 8
        #expect(pt.x == expectedX)
        #expect(pt.y == expectedY)
    }

    @Test("B12 position formula holds across varying visibleFrame widths")
    func tahoeSuppressionDegradedFormulaHolds() {
        // AC #15 worked example: vf.width = 1440 → x = 360 − 150 = 210.
        let size = NSSize(width: 300, height: 72)
        let frames: [NSRect] = [
            NSRect(x: 0, y: 23, width: 1440, height: 877),
            NSRect(x: 0, y: 23, width: 1920, height: 1057),
            NSRect(x: 0, y: 23, width: 2560, height: 1417)
        ]
        for vf in frames {
            let pt = HUDWindowController.computePosition(
                style: .tahoe,
                size: size,
                visibleFrame: vf,
                suppressionDegraded: true
            )
            #expect(pt.x == vf.minX + vf.width * 0.25 - size.width / 2)
            #expect(pt.y == vf.maxY - size.height - 8)
        }
    }

    // MARK: - Classic style

    @Test("Classic style centers horizontally, 140pt above screen bottom")
    func classicCenterBottom() {
        let size = NSSize(width: 200, height: 200)
        let pt = HUDWindowController.computePosition(
            style: .classic,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: false
        )
        let expectedX = screen.midX - size.width / 2
        let expectedY = screen.minY + 140
        #expect(pt.x == expectedX)
        #expect(pt.y == expectedY)
    }

    @Test("Classic style position is unchanged when suppressionDegraded")
    func classicSuppressionDegradedUnchanged() {
        let size = NSSize(width: 200, height: 200)
        let normal = HUDWindowController.computePosition(
            style: .classic,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: false
        )
        let degraded = HUDWindowController.computePosition(
            style: .classic,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: true
        )
        #expect(normal == degraded)
    }

    // MARK: - Edge cases

    @Test("Tahoe with zero-size HUD lands at top-right corner minus 8pt")
    func tahoeZeroSize() {
        let size = NSSize.zero
        let pt = HUDWindowController.computePosition(
            style: .tahoe,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: false
        )
        #expect(pt.x == screen.maxX - 8)
        #expect(pt.y == screen.maxY - 8)
    }
}

// MARK: - Hide timer + style-specific delay

@Suite("HUDWindowController — hide timer + per-style delay")
@MainActor
struct HUDWindowControllerTimerTests {

    private func makeController(popupVisible: Bool = false) -> HUDWindowController {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let status = MediaKeyStatus()
        let popup = PopupVisibilityService()
        popup.isVisible = popupVisible
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: status, popupVisibility: popup)
        // Stub out frame to avoid real NSScreen in tests.
        hud.frameProvider = { NSRect(x: 0, y: 23, width: 1440, height: 877) }
        // Stub the fullscreen probe so a fullscreen frontmost app does not skip show().
        hud.fullscreenOverride = false
        return hud
    }

    @Test("showCallCount increments on each show()")
    func showCallCountIncrements() {
        let hud = makeController()
        #expect(hud.showCallCount == 0)
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "")
        #expect(hud.showCallCount == 1)
        hud.show(sliderFraction: 0.6, mute: false, deviceName: "")
        #expect(hud.showCallCount == 2)
    }

    @Test("showCallCount increments even when the show is guard-skipped (counter tracks attempts)")
    func showCallCountTracksAttempts() {
        // showCallCount is incremented before the fullscreen + popup guards, so
        // it records every attempt regardless of whether the panel is actually shown.
        let hud = makeController()
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "")
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "")
        #expect(hud.showCallCount == 2)
    }

    @Test("Two rapid show() calls result in exactly two increments")
    func twoRapidShowsIncrementTwice() {
        let hud = makeController()
        hud.show(sliderFraction: 0.3, mute: false, deviceName: "")
        hud.show(sliderFraction: 0.4, mute: true, deviceName: "")
        #expect(hud.showCallCount == 2)
    }

    // MARK: - Per-style hide delay (AC #17)

    @Test("hideDelay is 1100 ms for both styles")
    func hideDelayIs1100msForBothStyles() {
        let hud = makeController()
        #expect(hud.hideDelay(for: .tahoe) == .milliseconds(1100))
        #expect(hud.hideDelay(for: .classic) == .milliseconds(1100))
    }

    @Test("hideDelayOverride applies uniformly to both styles")
    func hideDelayOverrideApplies() {
        let hud = makeController()
        hud.hideDelayOverride = .milliseconds(250)
        #expect(hud.hideDelay(for: .tahoe) == .milliseconds(250))
        #expect(hud.hideDelay(for: .classic) == .milliseconds(250))
    }

    // MARK: - Popup-visibility guard (AC #23)

    @Test("popupGuardSuppressesShow: popup visible ⇒ show() does not update panel")
    func popupGuardSuppressesShow() {
        let hud = makeController(popupVisible: true)
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Test Device")
        // Attempt is counted, but panel was not updated.
        #expect(hud.showCallCount == 1)
        #expect(hud.showDidUpdatePanel == false)
    }

    @Test("Popup hidden ⇒ show() updates panel")
    func popupHiddenShowUpdatesPanel() {
        let hud = makeController(popupVisible: false)
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Test Device")
        #expect(hud.showCallCount == 1)
        #expect(hud.showDidUpdatePanel == true)
    }
}

// MARK: - Message HUD

@Suite("HUDWindowController: message HUD")
@MainActor
struct HUDWindowControllerMessageTests {
    private let message = HUDMessage(symbol: "hand.thumbsup.fill", text: "Liked")

    private func makeController(popupVisible: Bool = false, fullscreen: Bool = false) -> HUDWindowController {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let popup = PopupVisibilityService()
        popup.isVisible = popupVisible
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: popup)
        // Far off every screen, so the panel these tests order front is never seen.
        hud.frameProvider = { NSRect(x: -40_000, y: -40_000, width: 1440, height: 877) }
        hud.fullscreenOverride = fullscreen
        hud.hideDelayOverride = .milliseconds(20)
        return hud
    }

    @Test("A message updates the panel and counts as an attempt")
    func showsAMessage() {
        let hud = makeController()
        defer { hud.shutdown() }

        hud.showMessage(message)

        #expect(hud.showCallCount == 1)
        #expect(hud.showDidUpdatePanel == true)
    }

    @Test("A message shows while a popup is visible: the user asked for it with a hotkey")
    func popupDoesNotSkipTheMessage() {
        let hud = makeController(popupVisible: true)
        defer { hud.shutdown() }

        hud.showMessage(message)

        #expect(hud.showCallCount == 1)
        #expect(hud.showDidUpdatePanel == true)
    }

    @Test("The volume HUD is still skipped while a popup is visible")
    func popupStillSkipsTheVolumeHud() {
        let hud = makeController(popupVisible: true)
        defer { hud.shutdown() }

        hud.show(sliderFraction: 0.5, mute: false, deviceName: "")

        #expect(hud.showCallCount == 1)
        #expect(hud.showDidUpdatePanel == false)
        #expect(hud.panelLevel == nil)
    }

    @Test("A message sits above the menu bar popups' level, so it shows over an open popup")
    func messageIsAbovePopups() {
        let hud = makeController(popupVisible: true)
        defer { hud.shutdown() }
        #expect(hud.panelLevel == nil)

        hud.showMessage(message)

        let level = hud.panelLevel
        #expect(level != nil)
        #expect((level ?? .normal) > .statusBar)
        #expect((level ?? .normal) < .popUpMenu)
        #expect(level == HUDWindowController.messageLevel)
    }

    @Test("The volume HUD stays at the floating level, below the hover card and the revealed menu bar")
    func volumeHudStaysFloating() {
        let hud = makeController()
        defer { hud.shutdown() }

        hud.show(sliderFraction: 0.5, mute: false, deviceName: "")

        #expect(hud.panelLevel == .floating)
        #expect(hud.panelLevel == HUDWindowController.volumeLevel)
        #expect((hud.panelLevel ?? .normal) < .statusBar)
    }

    @Test("The panel is shared, so each show sets its own level: a message raises it and the next volume HUD lowers it")
    func eachShowSetsItsLevel() {
        let hud = makeController()
        defer { hud.shutdown() }

        hud.show(sliderFraction: 0.5, mute: false, deviceName: "")
        #expect(hud.panelLevel == HUDWindowController.volumeLevel)

        hud.showMessage(message)
        #expect(hud.panelLevel == HUDWindowController.messageLevel)

        hud.show(sliderFraction: 0.6, mute: false, deviceName: "")
        #expect(hud.panelLevel == HUDWindowController.volumeLevel)

        hud.showMessage(HUDMessage(symbol: "hand.thumbsdown.fill", text: "Disliked"))
        #expect(hud.panelLevel == HUDWindowController.messageLevel)
    }

    @Test("A volume HUD the guards skip leaves the level a message set alone")
    func skippedVolumeHudKeepsTheLevel() {
        let hud = makeController(popupVisible: false, fullscreen: false)
        defer { hud.shutdown() }
        hud.showMessage(message)

        hud.fullscreenOverride = true
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "")

        #expect(hud.showDidUpdatePanel == false)
        #expect(hud.panelLevel == HUDWindowController.messageLevel)
    }

    @Test("A fullscreen app does not hide a message the user asked for with a hotkey")
    func fullscreenDoesNotSkipTheMessage() {
        let hud = makeController(fullscreen: true)
        defer { hud.shutdown() }

        hud.showMessage(message)

        #expect(hud.showDidUpdatePanel == true)
    }

    @Test("A fullscreen app still skips the volume HUD")
    func fullscreenStillSkipsTheVolumeHud() {
        let hud = makeController(fullscreen: true)
        defer { hud.shutdown() }

        hud.show(sliderFraction: 0.5, mute: false, deviceName: "")

        #expect(hud.showDidUpdatePanel == false)
    }

    @Test("Two messages in a row are both shown, the second replacing the first")
    func twoMessages() {
        let hud = makeController()
        defer { hud.shutdown() }

        hud.showMessage(message)
        hud.showMessage(HUDMessage(symbol: "hand.thumbsdown.fill", text: "Disliked"))

        #expect(hud.showCallCount == 2)
        #expect(hud.showDidUpdatePanel == true)
    }

    @Test("A short message uses the same hide delay as the volume HUD")
    func sameTiming() {
        let hud = makeController()
        defer { hud.shutdown() }
        hud.hideDelayOverride = nil
        #expect(hud.hideDelay(for: .tahoe) == .milliseconds(1100))

        hud.showMessage(message)
        #expect(hud.scheduledHideDelay == .milliseconds(1100))
    }

    @Test("A long message that wraps stays up longer, and the volume HUD after it is back to its own delay")
    func longMessageStaysLonger() {
        let hud = makeController()
        defer { hud.shutdown() }
        hud.hideDelayOverride = nil

        hud.showMessage(HUDMessage(symbol: "exclamationmark.triangle", text: Self.longText))
        #expect(hud.scheduledHideDelay == .milliseconds(2500))

        hud.show(sliderFraction: 0.5, mute: false, deviceName: "")
        #expect(hud.scheduledHideDelay == .milliseconds(1100))

        hud.showMessage(message)
        #expect(hud.scheduledHideDelay == .milliseconds(1100))
    }

    @Test("The override of a test wins over the longer delay of a long message")
    func overrideWinsOverLongMessage() {
        let hud = makeController()
        defer { hud.shutdown() }
        hud.hideDelayOverride = .milliseconds(20)

        hud.showMessage(HUDMessage(symbol: "exclamationmark.triangle", text: Self.longText))

        #expect(hud.scheduledHideDelay == .milliseconds(20))
    }

    private static let longText = "Couldn't add the account. Still signed in as before."
}

// MARK: - Message hide delay

@Suite("HUDMessage: hide delay")
struct HUDMessageHideDelayTests {
    private let base = Duration.milliseconds(1100)

    @Test("every line a hotkey outcome words keeps the base delay", arguments: MusicActionOutcome.allCases)
    func outcomeLinesKeepTheBase(outcome: MusicActionOutcome) {
        guard let message = outcome.hudMessage else { return }
        #expect(message.hideDelay(base: base) == base)
    }

    @Test("a rating that was made still has no line to time")
    func someOutcomesHaveNoLine() {
        #expect(MusicActionOutcome.allCases.compactMap(\.hudMessage).count == 4)
    }

    @Test("a line that wraps on the tile's second row stays 2.5 s", arguments: [
        "Couldn't add the account. Still signed in as before.",
        "Couldn't switch the channel. Still playing as before."
    ])
    func wrappingLinesStayLonger(text: String) {
        let message = HUDMessage(symbol: "exclamationmark.triangle", text: text)
        #expect(message.hideDelay(base: base) == .milliseconds(2500))
    }

    @Test("the line is long from 31 characters: 30 keep the base")
    func boundary() {
        let thirty = HUDMessage(symbol: "star", text: String(repeating: "a", count: 30))
        let thirtyOne = HUDMessage(symbol: "star", text: String(repeating: "a", count: 31))
        #expect(thirty.hideDelay(base: base) == base)
        #expect(thirtyOne.hideDelay(base: base) == .milliseconds(2500))
    }

    @Test("characters are counted, not bytes: emoji and accents do not make a short line long")
    func charactersNotBytes() {
        let emoji = HUDMessage(symbol: "star", text: String(repeating: "\u{1F3B5}", count: 10))
        let accents = HUDMessage(symbol: "star", text: String(repeating: "\u{E9}", count: 30))
        #expect(emoji.hideDelay(base: base) == base)
        #expect(accents.hideDelay(base: base) == base)
    }

    @Test("an empty line keeps the base")
    func emptyLine() {
        #expect(HUDMessage(symbol: "star", text: "").hideDelay(base: base) == base)
    }

    @Test("the base is passed through, so a longer line never gets less than a slow base")
    func slowBaseIsKept() {
        let slow = Duration.seconds(4)
        let message = HUDMessage(symbol: "star", text: String(repeating: "a", count: 60))
        #expect(message.hideDelay(base: slow) == slow)
    }
}

// MARK: - Suppression-degraded detection

@Suite("HUDWindowController: suppression-degraded detection")
@MainActor
struct HUDSuppressionDegradedTests {

    private func makeController() -> (hud: HUDWindowController, status: MediaKeyStatus) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let status = MediaKeyStatus()
        let hud = HUDWindowController(
            settingsManager: SettingsManager(directory: tempDir),
            mediaKeyStatus: status,
            popupVisibility: PopupVisibilityService()
        )
        return (hud, status)
    }

    @Test("The system's own volume notification right after a swallowed key marks suppression degraded")
    func nativeHudAfterSwallowIsDegraded() {
        let (hud, status) = makeController()
        hud.swallowObserved()
        hud.handleSettingsChangedNotification()
        #expect(status.suppressionDegraded)
    }

    @Test("A volume notification with no swallowed key before it is not a leak")
    func notificationWithoutSwallowIsIgnored() {
        let (hud, status) = makeController()
        hud.handleSettingsChangedNotification()
        #expect(status.suppressionDegraded == false)
    }

    @Test("A key left to macOS clears the stamp of an earlier swallow")
    func passThroughClearsTheStamp() {
        let (hud, status) = makeController()
        hud.swallowObserved()
        hud.passThroughObserved()
        hud.handleSettingsChangedNotification()
        #expect(status.suppressionDegraded == false)
    }

    @Test("A swallow after a pass-through arms the stamp again")
    func swallowAfterPassThroughRearms() {
        let (hud, status) = makeController()
        hud.passThroughObserved()
        hud.swallowObserved()
        hud.handleSettingsChangedNotification()
        #expect(status.suppressionDegraded)
    }

    @Test("A pass-through with nothing swallowed before it is harmless")
    func passThroughWithoutSwallow() {
        let (hud, status) = makeController()
        hud.passThroughObserved()
        hud.handleSettingsChangedNotification()
        #expect(status.suppressionDegraded == false)
    }
}
