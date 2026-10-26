// DeciTests/PlaybackKeyCoordinatorTests.swift
// The coordinator carries out what the router decides: a fresh press goes to a Chrome tab or to Deci's player, a repeat
// or a key-up does nothing, and a switch away from Chrome makes it forget the tab a key paused. Fake Chrome, fake player,
// a private notification center and a front app the test sets: no Chrome, no music, no event tap.

import AppKit
import Foundation
import Testing
@testable import Deci

@MainActor
private final class FakeChrome: PlaybackKeyChromeControlling {
    var chromeTabs: [ChromeTab] = []
    private(set) var sent: [(tabId: Int, key: PlaybackKey)] = []
    func sendMediaKey(tabId: Int, key: PlaybackKey) { sent.append((tabId, key)) }
}

@MainActor
private final class FakeDeci: PlaybackKeyDeciControlling {
    var playbackState: DeciPlaybackState = .idle
    private(set) var performed: [DeciPlaybackAction] = []
    func perform(_ action: DeciPlaybackAction) { performed.append(action) }
}

@MainActor
@Suite("PlaybackKeyCoordinator")
struct PlaybackKeyCoordinatorTests {
    private final class Front {
        var bundleID: String? = "com.google.Chrome"
    }

    private struct Rig {
        let coordinator: PlaybackKeyCoordinator
        let chrome = FakeChrome()
        let deci = FakeDeci()
        let front = Front()
        let center = NotificationCenter()

        init() {
            let front = front
            coordinator = PlaybackKeyCoordinator(
                chrome: chrome,
                deci: deci,
                frontmostBundleID: { front.bundleID },
                notificationCenter: center
            )
        }
    }

    private func tab(_ id: Int, audible: Bool = false) -> ChromeTab {
        ChromeTab(id: id, title: "Tab \(id)", volume: 1, isAudible: audible)
    }

    // MARK: - Acting on a press

    @Test("A fresh press with Chrome in front and a tab audible goes to the tab and not to Deci")
    func pressGoesToChrome() {
        let rig = Rig()
        rig.chrome.chromeTabs = [tab(5, audible: true)]
        rig.deci.playbackState = .playing
        rig.coordinator.handle(.next, phase: .down)
        #expect(rig.chrome.sent.map(\.tabId) == [5])
        #expect(rig.chrome.sent.map(\.key) == [.next])
        #expect(rig.deci.performed.isEmpty)
    }

    @Test("A fresh press goes to Deci's player when Chrome is not in front", arguments: [
        (PlaybackKey.playPause, DeciPlaybackAction.pause), (.next, .next), (.previous, .previous),
    ])
    func pressGoesToDeci(key: PlaybackKey, action: DeciPlaybackAction) {
        let rig = Rig()
        rig.front.bundleID = "com.apple.Safari"
        rig.chrome.chromeTabs = [tab(5, audible: true)]
        rig.deci.playbackState = .playing
        rig.coordinator.handle(key, phase: .down)
        #expect(rig.deci.performed == [action])
        #expect(rig.chrome.sent.isEmpty)
    }

    @Test("Play/pause resumes a paused Deci song")
    func pressResumesDeci() {
        let rig = Rig()
        rig.front.bundleID = nil
        rig.deci.playbackState = .pausedWithSong
        rig.coordinator.handle(.playPause, phase: .down)
        #expect(rig.deci.performed == [.resume])
    }

    @Test("A press that nothing can take does nothing")
    func pressWithNothingToDo() {
        let rig = Rig()
        for key in [PlaybackKey.playPause, .next, .previous] {
            rig.coordinator.handle(key, phase: .down)
        }
        #expect(rig.chrome.sent.isEmpty)
        #expect(rig.deci.performed.isEmpty)
    }

    @Test("A repeat or a key-up does nothing, whoever would have taken the press", arguments: [PlaybackKeyPhase.autoRepeat, .up])
    func repeatAndUpDoNothing(phase: PlaybackKeyPhase) {
        for chromeInFront in [true, false] {
            let rig = Rig()
            rig.front.bundleID = chromeInFront ? "com.google.Chrome" : "com.apple.Safari"
            rig.chrome.chromeTabs = [tab(5, audible: true)]
            rig.deci.playbackState = .playing
            for key in [PlaybackKey.playPause, .next, .previous] {
                rig.coordinator.handle(key, phase: phase)
            }
            #expect(rig.chrome.sent.isEmpty)
            #expect(rig.deci.performed.isEmpty)
            // And they leave no memory behind either.
            #expect(rig.coordinator.keyPausedTabID == nil)
        }
    }

    @Test("The front app and the tab list are read when the key is pressed")
    func readAtPressTime() {
        let rig = Rig()
        rig.deci.playbackState = .playing
        rig.chrome.chromeTabs = [tab(5, audible: true)]
        rig.coordinator.handle(.next, phase: .down)

        rig.front.bundleID = "com.apple.Safari"
        rig.coordinator.handle(.next, phase: .down)

        rig.front.bundleID = "com.google.Chrome"
        rig.chrome.chromeTabs = []
        rig.coordinator.handle(.next, phase: .down)

        #expect(rig.chrome.sent.map(\.tabId) == [5])
        #expect(rig.deci.performed == [.next, .next])
    }

    // MARK: - The tab a key paused

    @Test("Play/pause pauses the audible tab, then resumes it once it is quiet")
    func pauseThenResume() {
        let rig = Rig()
        rig.chrome.chromeTabs = [tab(5, audible: true)]
        rig.coordinator.handle(.playPause, phase: .down)
        #expect(rig.coordinator.keyPausedTabID == 5)

        rig.chrome.chromeTabs = [tab(5)]
        rig.coordinator.handle(.playPause, phase: .down)
        #expect(rig.coordinator.keyPausedTabID == nil)

        #expect(rig.chrome.sent.map(\.tabId) == [5, 5])
        #expect(rig.chrome.sent.map(\.key) == [.playPause, .playPause])
        #expect(rig.deci.performed.isEmpty)
    }

    @Test("While Deci plays, play/pause pauses Deci and keeps the remembered tab for the press after it")
    func memoryWaitsWhileDeciPlays() {
        let rig = Rig()
        rig.chrome.chromeTabs = [tab(5, audible: true)]
        rig.coordinator.handle(.playPause, phase: .down)
        #expect(rig.coordinator.keyPausedTabID == 5)

        // The tab is quiet and Deci is playing: the press is Deci's, and the tab stays remembered.
        rig.chrome.chromeTabs = [tab(5)]
        rig.deci.playbackState = .playing
        rig.coordinator.handle(.playPause, phase: .down)
        #expect(rig.deci.performed == [.pause])
        #expect(rig.chrome.sent.map(\.tabId) == [5])
        #expect(rig.coordinator.keyPausedTabID == 5)

        // Deci is paused now, so the next press resumes the tab.
        rig.deci.playbackState = .pausedWithSong
        rig.coordinator.handle(.playPause, phase: .down)
        #expect(rig.chrome.sent.map(\.tabId) == [5, 5])
        #expect(rig.deci.performed == [.pause])
        #expect(rig.coordinator.keyPausedTabID == nil)
    }

    @Test("Switching to another app makes the next play/pause leave the tab alone")
    func switchingAwayForgetsTheTab() {
        let rig = Rig()
        rig.chrome.chromeTabs = [tab(5, audible: true)]
        rig.deci.playbackState = .pausedWithSong
        rig.coordinator.handle(.playPause, phase: .down)

        rig.coordinator.frontmostApplicationChanged(to: "com.apple.Safari")
        #expect(rig.coordinator.keyPausedTabID == nil)

        rig.front.bundleID = "com.google.Chrome"
        rig.chrome.chromeTabs = [tab(5)]
        rig.coordinator.handle(.playPause, phase: .down)
        #expect(rig.chrome.sent.map(\.tabId) == [5])
        #expect(rig.deci.performed == [.resume])
    }

    @Test("Chrome coming to the front keeps the tab a key paused")
    func chromeActivationKeepsTheTab() {
        let rig = Rig()
        rig.chrome.chromeTabs = [tab(5, audible: true)]
        rig.coordinator.handle(.playPause, phase: .down)
        rig.coordinator.frontmostApplicationChanged(to: "com.google.Chrome")
        #expect(rig.coordinator.keyPausedTabID == 5)
    }

    // MARK: - The workspace notification

    /// Waits for the main queue to deliver a notification, which the coordinator asks to be delivered there.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("An app other than Chrome being activated clears the remembered tab")
    func activationNotificationClears() async {
        let rig = Rig()
        rig.chrome.chromeTabs = [tab(5, audible: true)]
        rig.coordinator.handle(.playPause, phase: .down)
        #expect(rig.coordinator.keyPausedTabID == 5)

        // The test host is not Chrome, whatever its bundle id.
        rig.center.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )
        await settle { rig.coordinator.keyPausedTabID == nil }
        #expect(rig.coordinator.keyPausedTabID == nil)
    }

    @Test("An activation that names no app clears the remembered tab")
    func activationWithoutAppClears() async {
        let rig = Rig()
        rig.chrome.chromeTabs = [tab(5, audible: true)]
        rig.coordinator.handle(.playPause, phase: .down)

        rig.center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await settle { rig.coordinator.keyPausedTabID == nil }
        #expect(rig.coordinator.keyPausedTabID == nil)
    }
}
