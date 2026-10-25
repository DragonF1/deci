// DeciTests/ChromeExtensionManagerTests.swift
// Tests for the pure TAB_LIST parsing and merge logic behind ChromeExtensionManager,
// one end-to-end check of setTabMuted through the shared instance, and the connection,
// device-permission and batching behaviour on throwaway instances (no shared state).

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("ChromeExtensionManager")
struct ChromeExtensionManagerTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeTab(
        id: Int = 1,
        title: String = "Tab",
        volume: Float = 1.0,
        boost: BoostLevel = .x1,
        isMuted: Bool = false,
        deviceName: String? = nil,
        captured: Bool = false
    ) -> ChromeTab {
        var tab = ChromeTab(id: id, title: title, volume: volume)
        tab.boost = boost
        tab.isMuted = isMuted
        tab.deviceName = deviceName
        tab.isCaptured = captured
        return tab
    }

    /// Collects what a manager would have sent to the host.
    private final class SentLog {
        var messages: [[String: Any]] = []

        func types() -> [String] { messages.compactMap { $0["type"] as? String } }
        func messages(ofType type: String) -> [[String: Any]] {
            messages.filter { $0["type"] as? String == type }
        }
    }

    /// A manager that ignores the host and records outgoing messages, with a controllable clock.
    private func makeManager(
        tabs: [ChromeTab] = [],
        clock: @escaping () -> Date = { Date() }
    ) -> (manager: ChromeExtensionManager, sent: SentLog) {
        let manager = ChromeExtensionManager(observeHost: false)
        let sent = SentLog()
        manager.messageSink = { sent.messages.append($0) }
        manager.connectionClock = clock
        manager.chromeTabs = tabs
        return (manager, sent)
    }

    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    // MARK: - parseTabList

    @Test("parseTabList maps the new TAB_LIST fields")
    func parseNewFields() {
        let json: [String: Any] = [
            "type": "TAB_LIST",
            "incognitoAllowed": false,
            "tabs": [[
                "id": 42,
                "title": "Lofi",
                "favIconUrl": NSNull(),
                "incognito": true,
                "isAudible": true,
                "captured": true,
                "volume": 0.5,
                "boost": 3,
                "muted": true,
                "eqBands": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
                "deviceName": "MacBook Speakers",
            ]],
        ]

        let result = ChromeExtensionManager.parseTabList(json)

        #expect(result.incognitoAllowed == false)
        #expect(result.tabs.count == 1)
        let tab = result.tabs[0]
        #expect(tab.id == 42)
        #expect(tab.title == "Lofi")
        #expect(tab.favIconUrl == nil)
        #expect(tab.isIncognito)
        #expect(tab.isAudible)
        #expect(tab.isCaptured)
        #expect(tab.volume == 0.5)
        #expect(tab.boost == .x3)
        #expect(tab.isMuted)
        #expect(tab.eqSettings.bandGains == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(tab.deviceName == "MacBook Speakers")
    }

    @Test("parseTabList treats empty deviceName as nil and defaults missing fields")
    func parseDefaults() {
        let json: [String: Any] = [
            "tabs": [
                ["id": 1, "deviceName": "", "boost": 9],
                ["id": 2],
            ],
        ]

        let result = ChromeExtensionManager.parseTabList(json)

        #expect(result.incognitoAllowed == true)
        #expect(result.tabs.map(\.id) == [1, 2])
        #expect(result.tabs[0].deviceName == nil)
        #expect(result.tabs[0].boost == .x1)
        #expect(result.tabs[1].isIncognito == false)
        #expect(result.tabs[1].isCaptured == false)
        #expect(result.tabs[1].isMuted == false)
        #expect(result.tabs[1].volume == 1.0)
    }

    @Test("parseTabList skips tabs without an id and clamps volume")
    func parseSkipsAndClamps() {
        let json: [String: Any] = [
            "tabs": [
                ["title": "no id"],
                ["id": 7, "volume": 5.0],
                ["id": 8, "volume": -1.0],
            ],
        ]

        let result = ChromeExtensionManager.parseTabList(json)

        #expect(result.tabs.map(\.id) == [7, 8])
        #expect(result.tabs[0].volume == 1.0)
        #expect(result.tabs[1].volume == 0.0)
    }

    // MARK: - merge

    @Test("merge adopts extension values when no local change is pending")
    func mergeAdoptsExtensionValues() {
        let existing = [makeTab(volume: 0.2, boost: .x1, isMuted: false, deviceName: nil)]
        var incoming = makeTab(volume: 0.8, boost: .x4, isMuted: true, deviceName: "AirPods")
        incoming.eqSettings = EQSettings(bandGains: Array(repeating: 3, count: 10))

        let merged = ChromeExtensionManager.merge(
            existing: existing, incoming: [incoming], pendingUntil: [:], now: now
        )

        #expect(merged.count == 1)
        #expect(merged[0].volume == 0.8)
        #expect(merged[0].boost == .x4)
        #expect(merged[0].isMuted)
        #expect(merged[0].deviceName == "AirPods")
        #expect(merged[0].eqSettings.bandGains == Array(repeating: 3, count: 10))
    }

    @Test("merge keeps local values while a change is pending and adopts after it expires")
    func mergeKeepsLocalWhilePending() {
        var local = makeTab(volume: 0.2, boost: .x2, isMuted: true, deviceName: "Local")
        local.eqSettings = EQSettings(bandGains: Array(repeating: -4, count: 10))
        let incoming = makeTab(volume: 0.9, boost: .x1, isMuted: false, deviceName: "Remote")

        let kept = ChromeExtensionManager.merge(
            existing: [local], incoming: [incoming],
            pendingUntil: [1: now.addingTimeInterval(1.0)], now: now
        )
        #expect(kept[0].volume == 0.2)
        #expect(kept[0].boost == .x2)
        #expect(kept[0].isMuted)
        #expect(kept[0].deviceName == "Local")
        #expect(kept[0].eqSettings.bandGains == Array(repeating: -4, count: 10))

        let adopted = ChromeExtensionManager.merge(
            existing: [local], incoming: [incoming],
            pendingUntil: [1: now.addingTimeInterval(-0.1)], now: now
        )
        #expect(adopted[0].volume == 0.9)
        #expect(adopted[0].boost == .x1)
        #expect(adopted[0].isMuted == false)
        #expect(adopted[0].deviceName == "Remote")
    }

    @Test("merge pending state is per tab")
    func mergePendingIsPerTab() {
        let existing = [makeTab(id: 1, volume: 0.2), makeTab(id: 2, volume: 0.2)]
        let incoming = [makeTab(id: 1, volume: 0.9), makeTab(id: 2, volume: 0.9)]

        let merged = ChromeExtensionManager.merge(
            existing: existing, incoming: incoming,
            pendingUntil: [1: now.addingTimeInterval(1.0)], now: now
        )

        #expect(merged[0].volume == 0.2)
        #expect(merged[1].volume == 0.9)
    }

    @Test("merge preserves media-state fields and falls back to the old title and favicon")
    func mergePreservesMediaState() {
        let synced = now.addingTimeInterval(-3)
        var existing = makeTab(title: "Old Song")
        existing.favIconUrl = "https://example.com/icon.png"
        existing.paused = true
        existing.currentTime = 42
        existing.duration = 200
        existing.lastSyncedAt = synced
        existing.songBaselineCurrentTime = 10

        var incoming = makeTab(title: "")
        incoming.isAudible = true
        incoming.isCaptured = true
        incoming.isIncognito = true

        let merged = ChromeExtensionManager.merge(
            existing: [existing], incoming: [incoming], pendingUntil: [:], now: now
        )[0]

        #expect(merged.paused)
        #expect(merged.currentTime == 42)
        #expect(merged.duration == 200)
        #expect(merged.lastSyncedAt == synced)
        #expect(merged.songBaselineCurrentTime == 10)
        #expect(merged.title == "Old Song")
        #expect(merged.favIconUrl == "https://example.com/icon.png")
        // State owned by the extension is always adopted.
        #expect(merged.isAudible)
        #expect(merged.isCaptured)
        #expect(merged.isIncognito)
    }

    @Test("merge resets the song baseline when the title changes")
    func mergeResetsBaselineOnTitleChange() {
        var existing = makeTab(title: "Song A")
        existing.currentTime = 99
        existing.songBaselineCurrentTime = 5
        let incoming = makeTab(title: "Song B")

        let merged = ChromeExtensionManager.merge(
            existing: [existing], incoming: [incoming], pendingUntil: [:], now: now
        )[0]

        #expect(merged.title == "Song B")
        #expect(merged.songBaselineCurrentTime == 99)
    }

    @Test("merge keeps a locally bypassed EQ when the extension reports a flat curve")
    func mergeKeepsBypassedEQ() {
        var existing = makeTab()
        existing.eqSettings = EQSettings(bandGains: Array(repeating: 6, count: 10), isEnabled: false)
        let incoming = makeTab()

        let merged = ChromeExtensionManager.merge(
            existing: [existing], incoming: [incoming], pendingUntil: [:], now: now
        )[0]

        #expect(merged.eqSettings == existing.eqSettings)
    }

    @Test("merge passes through tabs that were not known before")
    func mergeNewTab() {
        let incoming = makeTab(id: 5, volume: 0.4, boost: .x2)

        let merged = ChromeExtensionManager.merge(
            existing: [makeTab(id: 1)], incoming: [incoming], pendingUntil: [:], now: now
        )

        #expect(merged == [incoming])
    }

    // MARK: - parseTabList: device access and status

    @Test("parseTabList reads deviceAccess and treats a missing value as granted")
    func parseDeviceAccess() {
        #expect(ChromeExtensionManager.parseTabList(["deviceAccess": true, "tabs": []]).deviceAccess == true)
        #expect(ChromeExtensionManager.parseTabList(["deviceAccess": false, "tabs": []]).deviceAccess == false)
        // An older extension does not send the field at all.
        #expect(ChromeExtensionManager.parseTabList(["tabs": []]).deviceAccess == true)
    }

    @Test("parseTabList maps every deviceStatus value", arguments: [
        ("default", ChromeTabDeviceStatus.defaultOutput),
        ("pending", .pending),
        ("routed", .routed),
        ("notFound", .notFound),
        ("noAccess", .noAccess),
    ])
    func parseDeviceStatus(raw: String, expected: ChromeTabDeviceStatus) {
        let json: [String: Any] = ["tabs": [["id": 1, "deviceName": "Speakers", "deviceStatus": raw]]]

        #expect(ChromeExtensionManager.parseTabList(json).tabs[0].deviceStatus == expected)
    }

    @Test("parseTabList falls back to the default status for unknown, wrongly typed or missing values")
    func parseDeviceStatusFallback() {
        let json: [String: Any] = ["tabs": [
            ["id": 1, "deviceStatus": "somethingNew"],
            ["id": 2, "deviceStatus": 5],
            ["id": 3, "deviceStatus": NSNull()],
            ["id": 4],
        ]]

        let tabs = ChromeExtensionManager.parseTabList(json).tabs

        #expect(tabs.map(\.deviceStatus) == Array(repeating: .defaultOutput, count: 4))
    }

    @Test("parseTabList reads control, with captured winning and old extensions falling back")
    func parseControl() {
        let json: [String: Any] = ["tabs": [
            ["id": 1, "control": "capture", "captured": true],
            ["id": 2, "control": "none", "captured": false],
            ["id": 3, "control": "none"],
            ["id": 4, "control": "none", "captured": true],
            ["id": 5, "captured": true],
            ["id": 6],
            ["id": 7, "control": "somethingNew"],
            ["id": 8, "control": "capture"],
        ]]

        let tabs = ChromeExtensionManager.parseTabList(json).tabs

        #expect(tabs.map(\.control) == [.capture, .none, .none, .capture, .capture, .none, .none, .capture])
        #expect(tabs.map(\.isCaptured) == [true, false, false, true, true, false, false, true])
    }

    @Test("control values from the removed auto mode read as not captured, and a capture still wins")
    func parseLegacyControl() {
        // An older extension build may still send "page" or "armed". They must not crash and must not count as a capture.
        let json: [String: Any] = ["tabs": [
            ["id": 1, "control": "page", "captured": false],
            ["id": 2, "control": "armed", "captured": false],
            ["id": 3, "control": "page"],
            ["id": 4, "control": "armed"],
            ["id": 5, "control": "page", "captured": true],
            ["id": 6, "control": "armed", "captured": true],
            ["id": 7, "control": 5],
            ["id": 8, "control": ""],
        ]]

        let tabs = ChromeExtensionManager.parseTabList(json).tabs

        #expect(tabs.map(\.control) == [.none, .none, .none, .none, .capture, .capture, .none, .none])
        #expect(tabs.map(\.isCaptured) == [false, false, false, false, true, true, false, false])
    }

    @Test("isCaptured sets a capture and clears it")
    func isCapturedSetter() {
        var tab = ChromeTab(id: 1, title: "T", volume: 1, favIconUrl: nil)
        #expect(tab.control == .none)
        tab.isCaptured = true
        #expect(tab.control == .capture)
        #expect(tab.isCaptured)
        tab.isCaptured = false
        #expect(tab.control == .none)
        #expect(!tab.isCaptured)
    }

    @Test("a TAB_LIST message updates deviceAccess and each tab's deviceStatus")
    func tabListMessageCarriesDeviceState() {
        let (manager, _) = makeManager()
        #expect(manager.deviceAccess == true)

        manager.handleChromeMessageString(#"{"type":"TAB_LIST","deviceAccess":false,"tabs":[{"id":3,"title":"T","deviceName":"AirPods","deviceStatus":"noAccess","captured":true}]}"#)
        #expect(manager.deviceAccess == false)
        #expect(manager.chromeTabs.first?.deviceStatus == .noAccess)
        #expect(manager.chromeTabs.first?.deviceName == "AirPods")

        // An older extension omits the field: that means access is not a problem.
        manager.handleChromeMessageString(#"{"type":"TAB_LIST","tabs":[{"id":3,"title":"T"}]}"#)
        #expect(manager.deviceAccess == true)
        #expect(manager.chromeTabs.first?.deviceStatus == .defaultOutput)
    }

    // MARK: - merge: device status

    @Test("merge adopts deviceStatus while pending only when it is about the same device")
    func mergeAdoptsDeviceStatusWhilePending() {
        var local = makeTab(deviceName: "Local")
        local.deviceStatus = .routed
        var incoming = makeTab(deviceName: "Remote")
        incoming.deviceStatus = .notFound

        let pending = ChromeExtensionManager.merge(
            existing: [local], incoming: [incoming],
            pendingUntil: [1: now.addingTimeInterval(1.0)], now: now
        )[0]
        // deviceName keeps the pending rule; a status for another device is stale.
        #expect(pending.deviceName == "Local")
        #expect(pending.deviceStatus == .routed)

        var sameDevice = incoming
        sameDevice.deviceName = "Local"
        let pendingSame = ChromeExtensionManager.merge(
            existing: [local], incoming: [sameDevice],
            pendingUntil: [1: now.addingTimeInterval(1.0)], now: now
        )[0]
        #expect(pendingSame.deviceStatus == .notFound)

        let settled = ChromeExtensionManager.merge(
            existing: [local], incoming: [incoming], pendingUntil: [:], now: now
        )[0]
        #expect(settled.deviceName == "Remote")
        #expect(settled.deviceStatus == .notFound)
    }

    // MARK: - connection state

    private let timeout: TimeInterval = 2.5

    @Test("connection decision: nothing is judged before the first request")
    func connectionNoRequest() {
        let state = ChromeExtensionManager.connectionState(
            current: .unknown, lastRequestAt: nil, lastMessageAt: nil, now: now, timeout: timeout
        )
        #expect(state == .unknown)

        // A push with no request in flight still means the extension is there.
        let pushed = ChromeExtensionManager.connectionState(
            current: .unknown, lastRequestAt: nil, lastMessageAt: now, now: now, timeout: timeout
        )
        #expect(pushed == .connected)
    }

    @Test("connection decision: a reply after the request means connected")
    func connectionReplied() {
        let state = ChromeExtensionManager.connectionState(
            current: .unknown,
            lastRequestAt: now,
            lastMessageAt: now.addingTimeInterval(0.2),
            now: now.addingTimeInterval(60),
            timeout: timeout
        )
        #expect(state == .connected)
    }

    @Test("connection decision: an unanswered request keeps the old state until the timeout")
    func connectionWaiting() {
        for current in [ChromeConnectionState.unknown, .connected, .disconnected] {
            let state = ChromeExtensionManager.connectionState(
                current: current,
                lastRequestAt: now,
                lastMessageAt: now.addingTimeInterval(-30),
                now: now.addingTimeInterval(timeout - 0.1),
                timeout: timeout
            )
            #expect(state == current)
        }
    }

    @Test("connection decision: an unanswered request disconnects at the timeout")
    func connectionTimedOut() {
        for lastMessageAt in [nil, now.addingTimeInterval(-30)] {
            let atTimeout = ChromeExtensionManager.connectionState(
                current: .connected, lastRequestAt: now, lastMessageAt: lastMessageAt,
                now: now.addingTimeInterval(timeout), timeout: timeout
            )
            #expect(atTimeout == .disconnected)

            let fromUnknown = ChromeExtensionManager.connectionState(
                current: .unknown, lastRequestAt: now, lastMessageAt: lastMessageAt,
                now: now.addingTimeInterval(10), timeout: timeout
            )
            #expect(fromUnknown == .disconnected)
        }
    }

    @Test("connection decision: messages that keep arriving never read as disconnected")
    func connectionStaysWhileMessagesArrive() {
        // Request at t=0, a push at t=2.4, nothing since; judged long after the timeout.
        let state = ChromeExtensionManager.connectionState(
            current: .connected,
            lastRequestAt: now,
            lastMessageAt: now.addingTimeInterval(2.4),
            now: now.addingTimeInterval(5),
            timeout: timeout
        )
        #expect(state == .connected)
    }

    @Test("a manager starts unknown, disconnects after an unanswered request and reconnects on any message")
    func connectionLifecycle() {
        let clock = FakeClock(now)
        let (manager, _) = makeManager(clock: { clock.now })
        #expect(manager.connectionState == .unknown)

        manager.requestTabs()
        clock.advance(1.0)
        manager.evaluateConnection()
        #expect(manager.connectionState == .unknown)

        clock.advance(2.0)
        manager.evaluateConnection()
        #expect(manager.connectionState == .disconnected)

        // Any message counts, not only TAB_LIST.
        #expect(manager.hasConnectedBefore == false)
        manager.handleChromeMessageString(#"{"type":"MEDIA_STATE","tabId":9,"paused":false,"currentTime":1,"duration":2}"#)
        #expect(manager.connectionState == .connected)
        #expect(manager.hasConnectedBefore == true)

        // The next request is answered in time: stays connected.
        clock.advance(10)
        manager.requestTabs()
        clock.advance(0.3)
        manager.handleChromeMessageString(#"{"type":"TAB_LIST","tabs":[]}"#)
        clock.advance(5)
        manager.evaluateConnection()
        #expect(manager.connectionState == .connected)

        // Chrome goes away: the following request is never answered, stale tabs are dropped.
        manager.handleChromeMessageString(#"{"type":"TAB_LIST","tabs":[{"id":4,"title":"A"}]}"#)
        #expect(manager.chromeTabs.count == 1)
        clock.advance(10)
        manager.requestTabs()
        clock.advance(3)
        manager.evaluateConnection()
        #expect(manager.connectionState == .disconnected)
        #expect(manager.chromeTabs.isEmpty)
    }

    @Test("repeated requests cannot postpone the disconnected verdict")
    func repeatedRequestsDoNotResetTheClock() {
        let clock = FakeClock(now)
        let (manager, _) = makeManager(clock: { clock.now })

        manager.requestTabs()
        clock.advance(2.0)
        manager.requestTabs()
        clock.advance(0.6)
        manager.evaluateConnection()

        #expect(manager.connectionState == .disconnected)
    }

    @Test("an unparseable or type-less message does not count as the extension talking")
    func garbageIsNotAMessage() {
        let (manager, _) = makeManager()

        manager.handleChromeMessageString("not json")
        manager.handleChromeMessageString(#"{"tabs":[]}"#)
        manager.handleChromeMessageString(nil)

        #expect(manager.connectionState == .unknown)
    }

    // MARK: - device permission

    @Test("choosing a device without device access also asks the extension to open the permission page")
    func setTabDeviceOpensPermissionOnce() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 1), makeTab(id: 2)])
        manager.deviceAccess = false

        manager.setTabDevice(tabId: 1, deviceName: "AirPods")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").count == 1)
        #expect(sent.messages(ofType: "SET_TAB_DEVICE")[0]["tabId"] as? Int == 1)
        #expect(sent.messages(ofType: "SET_TAB_DEVICE")[0]["deviceName"] as? String == "AirPods")
        #expect(sent.messages(ofType: "OPEN_DEVICE_PERMISSION").count == 1)
        // The previous device's status no longer applies.
        #expect(manager.chromeTabs.first { $0.id == 1 }?.deviceStatus == .pending)

        // A second pick (same or another tab) must not open the page again.
        manager.setTabDevice(tabId: 2, deviceName: "Speakers")
        manager.setTabDevice(tabId: 1, deviceName: "Speakers")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").count == 3)
        #expect(sent.messages(ofType: "OPEN_DEVICE_PERMISSION").count == 1)
    }

    @Test("the permission page is offered again after access was granted and lost")
    func permissionPromptRearms() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 1)])
        manager.handleChromeMessageString(#"{"type":"TAB_LIST","deviceAccess":false,"tabs":[{"id":1,"title":"T"}]}"#)
        manager.setTabDevice(tabId: 1, deviceName: "AirPods")
        manager.flushMessages()
        #expect(sent.messages(ofType: "OPEN_DEVICE_PERMISSION").count == 1)

        manager.handleChromeMessageString(#"{"type":"TAB_LIST","deviceAccess":true,"tabs":[{"id":1,"title":"T"}]}"#)
        manager.handleChromeMessageString(#"{"type":"TAB_LIST","deviceAccess":false,"tabs":[{"id":1,"title":"T"}]}"#)
        manager.setTabDevice(tabId: 1, deviceName: "Speakers")
        manager.flushMessages()

        #expect(sent.messages(ofType: "OPEN_DEVICE_PERMISSION").count == 2)
    }

    @Test("no permission request when access is granted or the choice is the system default")
    func setTabDeviceWithoutNeedForPermission() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 1)])

        manager.setTabDevice(tabId: 1, deviceName: "AirPods")
        manager.flushMessages()
        #expect(sent.types() == ["SET_TAB_DEVICE"])

        manager.deviceAccess = false
        manager.setTabDevice(tabId: 1, deviceName: nil)
        manager.setTabDevice(tabId: 1, deviceName: "")
        manager.flushMessages()
        #expect(sent.messages(ofType: "OPEN_DEVICE_PERMISSION").isEmpty)
    }

    @Test("openDevicePermission always sends, and an explicit open satisfies the automatic one")
    func openDevicePermissionExplicit() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 1)])
        manager.deviceAccess = false

        manager.openDevicePermission()
        manager.flushMessages()
        manager.openDevicePermission()
        manager.flushMessages()
        #expect(sent.messages(ofType: "OPEN_DEVICE_PERMISSION").count == 2)

        manager.setTabDevice(tabId: 1, deviceName: "AirPods")
        manager.flushMessages()
        #expect(sent.messages(ofType: "OPEN_DEVICE_PERMISSION").count == 2)
    }

    @Test("needsDeviceAccess needs both missing access and a tab with a chosen device")
    func needsDeviceAccess() {
        let (manager, _) = makeManager(tabs: [makeTab(id: 1), makeTab(id: 2, deviceName: "AirPods")])
        #expect(manager.needsDeviceAccess == false)

        manager.deviceAccess = false
        #expect(manager.needsDeviceAccess == true)

        manager.chromeTabs = [makeTab(id: 1)]
        #expect(manager.needsDeviceAccess == false)
    }

    // MARK: - batching

    @Test("two volume changes for one tab inside the batch window send one message with the latest value")
    func batchingCollapsesVolume() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 1), makeTab(id: 2)])

        manager.setTabVolume(tabId: 1, volume: 0.3)
        manager.setTabVolume(tabId: 1, volume: 0.7)
        manager.setTabVolume(tabId: 2, volume: 0.5)
        manager.setTabBoost(tabId: 1, boost: .x3)
        manager.flushMessages()

        let volumes = sent.messages(ofType: "SET_TAB_VOLUME")
        #expect(volumes.count == 2)
        let forTab1 = volumes.first { $0["tabId"] as? Int == 1 }
        #expect((forTab1?["volume"] as? Float) == 0.7)
        // Boost travels with volume, so the collapsed message carries both.
        #expect((forTab1?["boost"] as? Float) == BoostLevel.x3.rawValue)
        let forTab2 = volumes.first { $0["tabId"] as? Int == 2 }
        #expect((forTab2?["volume"] as? Float) == 0.5)
    }

    @Test("muting twice sends a single mute message and leaves volume alone")
    func muteSendsOneMessage() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 1, volume: 0.6)])

        manager.setTabMuted(tabId: 1, muted: true)
        manager.setTabMuted(tabId: 1, muted: true)
        manager.flushMessages()

        let mutes = sent.messages(ofType: "SET_TAB_MUTE")
        #expect(mutes.count == 1)
        #expect(mutes[0]["muted"] as? Bool == true)
        #expect(sent.messages(ofType: "SET_TAB_VOLUME").isEmpty)
        #expect(manager.chromeTabs[0].volume == 0.6)
    }

    @Test("flushing leaves nothing queued, so a second flush sends nothing")
    func flushDrainsTheQueue() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 1)])

        manager.setTabMuted(tabId: 1, muted: true)
        manager.flushMessages()
        manager.flushMessages()

        #expect(sent.messages.count == 1)
    }

    // MARK: - plain control of an uncaptured tab

    @Test("a volume change on an uncaptured tab sends SET_TAB_VOLUME with the stored boost")
    func uncapturedVolumeIsSent() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 4, volume: 1.0, boost: .x3)])

        manager.setTabVolume(tabId: 4, volume: 0.4)
        manager.flushMessages()

        let volumes = sent.messages(ofType: "SET_TAB_VOLUME")
        #expect(volumes.count == 1)
        #expect(volumes[0]["tabId"] as? Int == 4)
        #expect((volumes[0]["volume"] as? Float) == 0.4)
        // The extension keeps the boost for a later capture, so it travels along and is not rewritten here.
        #expect((volumes[0]["boost"] as? Float) == BoostLevel.x3.rawValue)
        #expect(manager.chromeTabs[0].volume == 0.4)
        #expect(manager.chromeTabs[0].boost == .x3)
    }

    @Test("muting and unmuting an uncaptured tab sends SET_TAB_MUTE and leaves volume and boost alone")
    func uncapturedMuteIsSent() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 4, volume: 0.6, boost: .x2)])

        manager.setTabMuted(tabId: 4, muted: true)
        manager.flushMessages()
        #expect(sent.messages(ofType: "SET_TAB_MUTE").count == 1)
        #expect(sent.messages(ofType: "SET_TAB_MUTE")[0]["tabId"] as? Int == 4)
        #expect(sent.messages(ofType: "SET_TAB_MUTE")[0]["muted"] as? Bool == true)
        #expect(manager.chromeTabs[0].isMuted)

        sent.messages.removeAll()
        manager.setTabMuted(tabId: 4, muted: false)
        manager.flushMessages()
        #expect(sent.messages(ofType: "SET_TAB_MUTE")[0]["muted"] as? Bool == false)
        #expect(!manager.chromeTabs[0].isMuted)
        #expect(manager.chromeTabs[0].volume == 0.6)
        #expect(manager.chromeTabs[0].boost == .x2)
        #expect(sent.messages(ofType: "SET_TAB_VOLUME").isEmpty)
    }

    @Test("an uncaptured tab's volume is capped to 0...1, both stored and sent, and its boost is untouched")
    func uncapturedVolumeIsCapped() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 4, volume: 0.5, boost: .x4)])

        manager.setTabVolume(tabId: 4, volume: 1.7)
        manager.flushMessages()
        #expect((sent.messages(ofType: "SET_TAB_VOLUME").last?["volume"] as? Float) == 1.0)
        #expect(manager.chromeTabs[0].volume == 1.0)

        sent.messages.removeAll()
        manager.setTabVolume(tabId: 4, volume: -0.3)
        manager.flushMessages()
        #expect((sent.messages(ofType: "SET_TAB_VOLUME").last?["volume"] as? Float) == 0.0)
        #expect(manager.chromeTabs[0].volume == 0.0)

        #expect(manager.chromeTabs[0].boost == .x4)
        #expect((sent.messages(ofType: "SET_TAB_VOLUME").last?["boost"] as? Float) == BoostLevel.x4.rawValue)
    }

    @Test("a captured tab sends volume, boost and mute exactly as before")
    func capturedControlIsUnchanged() {
        let (manager, sent) = makeManager(tabs: [makeTab(id: 9, volume: 1.0, boost: .x2, captured: true)])

        manager.setTabVolume(tabId: 9, volume: 0.25)
        manager.setTabBoost(tabId: 9, boost: .x3)
        manager.setTabMuted(tabId: 9, muted: true)
        manager.flushMessages()

        let volumes = sent.messages(ofType: "SET_TAB_VOLUME")
        #expect(volumes.count == 1)
        #expect((volumes[0]["volume"] as? Float) == 0.25)
        #expect((volumes[0]["boost"] as? Float) == BoostLevel.x3.rawValue)
        #expect(sent.messages(ofType: "SET_TAB_MUTE")[0]["muted"] as? Bool == true)
        #expect(manager.chromeTabs[0].volume == 0.25)
        #expect(manager.chromeTabs[0].boost == .x3)
        #expect(manager.chromeTabs[0].isMuted)
    }

    @Test("a stale TAB_LIST inside the pending window does not undo an uncaptured tab's volume or mute")
    func uncapturedChangeIsShieldedFromStaleList() {
        let (manager, _) = makeManager()
        let list = #"{"type":"TAB_LIST","tabs":[{"id":6,"title":"T","volume":1,"boost":1,"muted":false,"captured":false}]}"#
        manager.handleChromeMessageString(list)
        #expect(manager.chromeTabs.first?.isCaptured == false)

        manager.setTabVolume(tabId: 6, volume: 0.3)
        manager.setTabMuted(tabId: 6, muted: true)
        manager.handleChromeMessageString(list)

        #expect(manager.chromeTabs.first?.volume == 0.3)
        #expect(manager.chromeTabs.first?.isMuted == true)
    }

    // MARK: - setTabMuted (shared instance)

    @Test("setTabMuted is idempotent, never touches volume, and shields the tab from a stale TAB_LIST")
    func setTabMutedEndToEnd() {
        let manager = ChromeExtensionManager.shared
        // Keep the queued SET_TAB_MUTE from reaching a running DeciHost (and a real tab).
        manager.messageSink = { _ in }
        defer { manager.handleChromeMessageString(#"{"type":"TAB_LIST","tabs":[]}"#) }

        let list = #"{"type":"TAB_LIST","incognitoAllowed":true,"tabs":[{"id":77,"title":"T","volume":0.6,"boost":1,"muted":false,"captured":true}]}"#
        manager.handleChromeMessageString(list)
        #expect(manager.chromeTabs.first?.isMuted == false)

        manager.setTabMuted(tabId: 77, muted: true)
        manager.setTabMuted(tabId: 77, muted: true)
        #expect(manager.chromeTabs.first?.isMuted == true)
        #expect(manager.chromeTabs.first?.volume == 0.6)

        // A TAB_LIST that still says unmuted arrives inside the pending window.
        manager.handleChromeMessageString(list)
        #expect(manager.chromeTabs.first?.isMuted == true)
        #expect(manager.chromeTabs.first?.volume == 0.6)

        manager.setTabMuted(tabId: 77, muted: false)
        #expect(manager.chromeTabs.first?.isMuted == false)
        #expect(manager.chromeTabs.first?.volume == 0.6)
    }
}
