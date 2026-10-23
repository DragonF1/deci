// DeciTests/ChromeMediaStateTests.swift
// Chrome answers GET_MEDIA_STATE with the tab's paused flag, position and duration. A write into `chromeTabs` notifies
// every view that reads the array, equal value or not, so a reply that changes nothing (a paused tab asked every two
// seconds) must not be written. Throwaway manager, no host, no Chrome.

import Foundation
import Observation
import os
import Testing
@testable import Deci

/// Records that an observation fired, from the nonisolated closure `withObservationTracking` takes.
private nonisolated final class Fired: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

@MainActor
@Suite("Chrome MEDIA_STATE")
struct ChromeMediaStateTests {
    private let first = Date(timeIntervalSince1970: 1_000_000)
    private let later = Date(timeIntervalSince1970: 1_000_060)

    private func makeManager(tabs: [ChromeTab]) -> ChromeExtensionManager {
        let manager = ChromeExtensionManager(observeHost: false)
        manager.messageSink = { _ in }
        manager.chromeTabs = tabs
        return manager
    }

    private func reply(tab: Int = 1, paused: Bool, time: Double, duration: Double) -> String {
        #"{"type":"MEDIA_STATE","tabId":\#(tab),"paused":\#(paused),"currentTime":\#(time),"duration":\#(duration)}"#
    }

    /// Reads the tab list once, and says whether `change` afterwards would redraw whoever read it.
    private func redraws(_ manager: ChromeExtensionManager, after change: @MainActor () -> Void) -> Bool {
        let fired = Fired()
        withObservationTracking { _ = manager.chromeTabs } onChange: { fired.set() }
        change()
        return fired.value
    }

    // MARK: - The pure step

    @Test("The first reply takes the song baseline, the fields and the sync mark")
    func firstReply() throws {
        let tab = ChromeTab(id: 1, title: "T", volume: 1)
        let updated = try #require(ChromeExtensionManager.applyingMediaState(to: tab, paused: true, currentTime: 42, duration: 200, now: first))
        #expect(updated.paused)
        #expect(updated.currentTime == 42)
        #expect(updated.duration == 200)
        #expect(updated.songBaselineCurrentTime == 42)
        #expect(updated.lastSyncedAt == first)
    }

    @Test("A first reply that holds only the defaults still marks the tab as synced")
    func firstReplyOfDefaults() throws {
        let tab = ChromeTab(id: 1, title: "T", volume: 1)
        let updated = try #require(ChromeExtensionManager.applyingMediaState(to: tab, paused: false, currentTime: 0, duration: 0, now: first))
        #expect(updated.lastSyncedAt == first)
    }

    @Test("An identical reply changes nothing")
    func identicalReply() throws {
        let tab = ChromeTab(id: 1, title: "T", volume: 1)
        let synced = try #require(ChromeExtensionManager.applyingMediaState(to: tab, paused: true, currentTime: 42, duration: 200, now: first))
        #expect(ChromeExtensionManager.applyingMediaState(to: synced, paused: true, currentTime: 42, duration: 200, now: later) == nil)
    }

    @Test("A reply that moves one field is applied, keeps the baseline and refreshes the sync mark", arguments: [
        (false, 42.0, 200.0),
        (true, 43.0, 200.0),
        (true, 42.0, 210.0),
    ])
    func changedReply(paused: Bool, time: Double, duration: Double) throws {
        let tab = ChromeTab(id: 1, title: "T", volume: 1)
        let synced = try #require(ChromeExtensionManager.applyingMediaState(to: tab, paused: true, currentTime: 42, duration: 200, now: first))
        let updated = try #require(ChromeExtensionManager.applyingMediaState(to: synced, paused: paused, currentTime: time, duration: duration, now: later))
        #expect(updated.paused == paused)
        #expect(updated.currentTime == time)
        #expect(updated.duration == duration)
        #expect(updated.songBaselineCurrentTime == 42)
        #expect(updated.lastSyncedAt == later)
    }

    // MARK: - Through the manager

    @Test("A reply for a tab that is not listed changes nothing")
    func unknownTab() {
        let manager = makeManager(tabs: [ChromeTab(id: 1, title: "T", volume: 1)])
        let drawn = redraws(manager, after: { manager.handleChromeMessageString(reply(tab: 9, paused: true, time: 5, duration: 60)) })
        #expect(!drawn)
        #expect(manager.chromeTabs.first?.lastSyncedAt == nil)
    }

    @Test("The first reply redraws the readers of the tab list and fills the tab in")
    func firstReplyThroughTheManager() {
        let manager = makeManager(tabs: [ChromeTab(id: 1, title: "T", volume: 1)])
        let drawn = redraws(manager, after: { manager.handleChromeMessageString(reply(paused: true, time: 5, duration: 60)) })
        #expect(drawn)
        #expect(manager.chromeTabs.first?.paused == true)
        #expect(manager.chromeTabs.first?.currentTime == 5)
        #expect(manager.chromeTabs.first?.duration == 60)
        #expect(manager.chromeTabs.first?.lastSyncedAt != nil)
    }

    @Test("The same reply again redraws nobody and keeps the first sync mark")
    func sameReplyAgain() {
        let manager = makeManager(tabs: [ChromeTab(id: 1, title: "T", volume: 1)])
        manager.handleChromeMessageString(reply(paused: true, time: 5, duration: 60))
        let mark = manager.chromeTabs.first?.lastSyncedAt
        let drawn = redraws(manager, after: { manager.handleChromeMessageString(reply(paused: true, time: 5, duration: 60)) })
        #expect(!drawn)
        #expect(manager.chromeTabs.first?.lastSyncedAt == mark)
    }

    @Test("A reply with a new position redraws the readers of the tab list")
    func movedReply() {
        let manager = makeManager(tabs: [ChromeTab(id: 1, title: "T", volume: 1)])
        manager.handleChromeMessageString(reply(paused: false, time: 5, duration: 60))
        let drawn = redraws(manager, after: { manager.handleChromeMessageString(reply(paused: false, time: 7, duration: 60)) })
        #expect(drawn)
        #expect(manager.chromeTabs.first?.currentTime == 7)
    }
}
