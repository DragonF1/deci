// DeciTests/ChromeExtensionTrackingTests.swift
// The Chrome tracking switches inside ChromeExtensionManager: SET_TRACKING messages,
// hiding tabs locally, and the handshake that keeps the extension's stored switches in
// line with Deci's. Throwaway instances only (no shared state, no host).

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("ChromeExtensionManager tracking")
struct ChromeExtensionTrackingTests {

    private final class SentLog {
        var messages: [[String: Any]] = []
        func trackingMessages() -> [[String: Any]] {
            messages.filter { $0["type"] as? String == "SET_TRACKING" }
        }
        func types() -> [String] { messages.compactMap { $0["type"] as? String } }
        func clear() { messages.removeAll() }
    }

    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func makeManager(
        clock: @escaping () -> Date = { Date() }
    ) -> (manager: ChromeExtensionManager, sent: SentLog) {
        let manager = ChromeExtensionManager(observeHost: false)
        let sent = SentLog()
        manager.messageSink = { sent.messages.append($0) }
        manager.connectionClock = clock
        return (manager, sent)
    }

    /// A TAB_LIST with one normal and one incognito tab, optionally echoing the extension's switches.
    private func tabList(echo: (tabs: Bool, incognito: Bool)? = nil, tabs: String? = nil) -> String {
        let tracking = echo.map { #","tracking":{"tabs":\#($0.tabs),"incognito":\#($0.incognito)}"# } ?? ""
        let list = tabs ?? #"[{"id":1,"title":"Open"},{"id":2,"title":"Private","incognito":true}]"#
        return #"{"type":"TAB_LIST","tabs":\#(list)\#(tracking)}"#
    }

    // MARK: - parsing

    @Test("parseTabList reads the tracking echo")
    func parseEcho() {
        let json: [String: Any] = ["tabs": [], "tracking": ["tabs": false, "incognito": true]]
        let result = ChromeExtensionManager.parseTabList(json)
        #expect(result.tracking == ChromeTracking(tabs: false, incognito: true))
    }

    @Test("parseTabList treats a missing or incomplete tracking echo as nil")
    func parseMissingEcho() {
        #expect(ChromeExtensionManager.parseTabList(["tabs": []]).tracking == nil)
        #expect(ChromeExtensionManager.parseTabList(["tabs": [], "tracking": ["tabs": true]]).tracking == nil)
        #expect(ChromeExtensionManager.parseTabList(["tabs": [], "tracking": "on"]).tracking == nil)
        #expect(ChromeExtensionManager.parseTabList(["tabs": [], "tracking": ["tabs": "yes", "incognito": 1]]).tracking == nil)
    }

    @Test("visibleTabs drops everything when tabs are off and only incognito when incognito is off")
    func visibleTabsFilter() {
        var normal = ChromeTab(id: 1, title: "Open", volume: 1)
        normal.isIncognito = false
        var priv = ChromeTab(id: 2, title: "Private", volume: 1)
        priv.isIncognito = true
        let all = [normal, priv]

        #expect(ChromeExtensionManager.visibleTabs(all, tracking: ChromeTracking(tabs: true, incognito: true)).map(\.id) == [1, 2])
        #expect(ChromeExtensionManager.visibleTabs(all, tracking: ChromeTracking(tabs: true, incognito: false)).map(\.id) == [1])
        #expect(ChromeExtensionManager.visibleTabs(all, tracking: ChromeTracking(tabs: false, incognito: true)).isEmpty)
        #expect(ChromeExtensionManager.visibleTabs(all, tracking: ChromeTracking(tabs: false, incognito: false)).isEmpty)
    }

    // MARK: - setTracking

    @Test("a new manager tracks normal tabs and hides incognito ones")
    func defaultsTrackNormalTabsOnly() {
        let (manager, _) = makeManager()
        #expect(manager.trackingTabs == true)
        #expect(manager.trackingIncognito == false)
    }

    @Test("setTracking stores the state and queues one SET_TRACKING with both switches")
    func setTrackingQueuesMessage() {
        let (manager, sent) = makeManager()

        manager.setTracking(tabs: true, incognito: false)
        manager.flushMessages()

        #expect(manager.trackingTabs == true)
        #expect(manager.trackingIncognito == false)
        let messages = sent.trackingMessages()
        #expect(messages.count == 1)
        #expect(messages[0]["tabs"] as? Bool == true)
        #expect(messages[0]["incognito"] as? Bool == false)
    }

    @Test("two setTracking calls inside the batch window send only the last one")
    func setTrackingBatches() {
        let (manager, sent) = makeManager()

        manager.setTracking(tabs: false, incognito: false)
        manager.setTracking(tabs: true, incognito: true)
        manager.flushMessages()

        let messages = sent.trackingMessages()
        #expect(messages.count == 1)
        #expect(messages[0]["tabs"] as? Bool == true)
        #expect(messages[0]["incognito"] as? Bool == true)
    }

    @Test("turning tabs off removes every tab at once")
    func setTrackingTabsOffPrunesAll() {
        let (manager, _) = makeManager()
        manager.setTracking(tabs: true, incognito: true)
        manager.handleChromeMessageString(tabList())
        #expect(manager.chromeTabs.map(\.id) == [1, 2])

        manager.setTracking(tabs: false, incognito: true)

        #expect(manager.chromeTabs.isEmpty)
    }

    @Test("turning incognito off removes only the incognito tabs")
    func setTrackingIncognitoOffPrunesIncognito() {
        let (manager, _) = makeManager()
        manager.setTracking(tabs: true, incognito: true)
        manager.handleChromeMessageString(tabList())
        #expect(manager.chromeTabs.map(\.id) == [1, 2])

        manager.setTracking(tabs: true, incognito: false)

        #expect(manager.chromeTabs.map(\.id) == [1])
        #expect(manager.chromeTabs.allSatisfy { !$0.isIncognito })
    }

    // MARK: - TAB_LIST filtering

    @Test("with tabs off a TAB_LIST never fills chromeTabs but still proves the extension is there")
    func tabListFilteredWhenTabsOff() {
        let (manager, _) = makeManager()
        manager.setTracking(tabs: false, incognito: true)

        manager.handleChromeMessageString(tabList(echo: (false, true)))

        #expect(manager.chromeTabs.isEmpty)
        #expect(manager.connectionState == .connected)
        #expect(manager.hasConnectedBefore == true)
    }

    @Test("with incognito off a TAB_LIST that still carries incognito tabs shows only the others")
    func tabListFilteredWhenIncognitoOff() {
        let (manager, _) = makeManager()
        manager.setTracking(tabs: true, incognito: false)

        manager.handleChromeMessageString(tabList(echo: (true, false)))

        #expect(manager.chromeTabs.map(\.id) == [1])
    }

    @Test("turning a switch back on shows the tabs again from the next TAB_LIST")
    func tabListRepopulatesAfterTurningOn() {
        let (manager, _) = makeManager()
        manager.setTracking(tabs: false, incognito: false)
        manager.handleChromeMessageString(tabList(echo: (false, false), tabs: "[]"))
        #expect(manager.chromeTabs.isEmpty)

        manager.setTracking(tabs: true, incognito: true)
        manager.handleChromeMessageString(tabList(echo: (true, true)))

        #expect(manager.chromeTabs.map(\.id) == [1, 2])
    }

    @Test("a hidden tab's media state is ignored")
    func hiddenTabMediaStateIgnored() {
        let (manager, _) = makeManager()
        manager.setTracking(tabs: false, incognito: true)
        manager.handleChromeMessageString(tabList(echo: (false, true)))

        manager.handleChromeMessageString(#"{"type":"MEDIA_STATE","tabId":1,"paused":false,"currentTime":1,"duration":2}"#)

        #expect(manager.chromeTabs.isEmpty)
    }

    // MARK: - handshake

    @Test("a TAB_LIST without a tracking echo asks once, then stays quiet")
    func handshakeMissingEchoSendsOnce() {
        let (manager, sent) = makeManager()
        manager.setTracking(tabs: true, incognito: false)
        manager.flushMessages()
        sent.clear()

        manager.handleChromeMessageString(tabList())
        manager.flushMessages()
        #expect(sent.trackingMessages().count == 1)
        #expect(sent.trackingMessages()[0]["incognito"] as? Bool == false)

        manager.handleChromeMessageString(tabList())
        manager.handleChromeMessageString(tabList())
        manager.flushMessages()
        #expect(sent.trackingMessages().count == 1)
    }

    @Test("a TAB_LIST that echoes the wanted state sends nothing")
    func handshakeMatchSendsNothing() {
        let (manager, sent) = makeManager()
        manager.setTracking(tabs: true, incognito: false)
        manager.flushMessages()
        sent.clear()

        manager.handleChromeMessageString(tabList(echo: (true, false)))
        manager.flushMessages()

        #expect(sent.messages.isEmpty)
    }

    @Test("a differing echo is answered once, a changed echo is answered again")
    func handshakeMismatchResend() {
        let (manager, sent) = makeManager()
        manager.setTracking(tabs: false, incognito: false)
        manager.flushMessages()
        sent.clear()

        // The extension still has everything on.
        manager.handleChromeMessageString(tabList(echo: (true, true)))
        manager.flushMessages()
        #expect(sent.trackingMessages().count == 1)

        // Same stale echo again: do not nag.
        manager.handleChromeMessageString(tabList(echo: (true, true)))
        manager.flushMessages()
        #expect(sent.trackingMessages().count == 1)

        // The extension moved to some other wrong state: that is a new mismatch.
        manager.handleChromeMessageString(tabList(echo: (true, false)))
        manager.flushMessages()
        #expect(sent.trackingMessages().count == 2)
    }

    @Test("after the echo matched, a later mismatch is answered again")
    func handshakeRearmsAfterMatch() {
        let (manager, sent) = makeManager()
        manager.setTracking(tabs: true, incognito: false)
        manager.flushMessages()
        sent.clear()

        manager.handleChromeMessageString(tabList(echo: (true, true)))
        manager.flushMessages()
        #expect(sent.trackingMessages().count == 1)

        manager.handleChromeMessageString(tabList(echo: (true, false)))
        manager.handleChromeMessageString(tabList(echo: (true, true)))
        manager.flushMessages()
        #expect(sent.trackingMessages().count == 2)
    }

    @Test("a fresh requestTabs lets a still-mismatching reply be answered again")
    func handshakeRearmsOnRequest() {
        let (manager, sent) = makeManager()
        manager.setTracking(tabs: true, incognito: false)
        manager.handleChromeMessageString(tabList())
        manager.flushMessages()
        sent.clear()

        manager.handleChromeMessageString(tabList())
        manager.flushMessages()
        #expect(sent.trackingMessages().isEmpty)

        manager.requestTabs()
        manager.flushMessages()
        let fromRequest = sent.trackingMessages().count
        #expect(fromRequest == 1)

        manager.handleChromeMessageString(tabList())
        manager.flushMessages()
        #expect(sent.trackingMessages().count == fromRequest + 1)
    }

    @Test("changing the wanted state re-arms the handshake")
    func setTrackingRearmsHandshake() {
        let (manager, sent) = makeManager()
        manager.handleChromeMessageString(tabList())
        manager.flushMessages()
        sent.clear()

        manager.setTracking(tabs: true, incognito: false)
        manager.flushMessages()
        #expect(sent.trackingMessages().count == 1)

        // The extension has not applied it yet (echo missing, as before): answered once more.
        manager.handleChromeMessageString(tabList())
        manager.flushMessages()
        #expect(sent.trackingMessages().count == 2)
    }

    // MARK: - requestTabs

    @Test("requestTabs carries the wanted state and puts it ahead of GET_TABS")
    func requestTabsSendsTrackingFirst() {
        let (manager, sent) = makeManager()
        manager.setTracking(tabs: true, incognito: false)
        manager.flushMessages()
        sent.clear()

        manager.requestTabs()
        manager.flushMessages()

        #expect(sent.types() == ["SET_TRACKING", "GET_TABS"])
        #expect(sent.trackingMessages()[0]["tabs"] as? Bool == true)
        #expect(sent.trackingMessages()[0]["incognito"] as? Bool == false)
    }

    @Test("with tabs off requestTabs still probes the connection and the list stays empty")
    func requestTabsWhenOffStillProbes() {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000_000))
        let (manager, sent) = makeManager(clock: { clock.now })
        manager.setTracking(tabs: false, incognito: true)
        manager.flushMessages()
        sent.clear()

        manager.requestTabs()
        manager.flushMessages()
        #expect(sent.types().contains("GET_TABS"))

        // The extension answers with an empty list: connected, nothing to show.
        clock.advance(0.2)
        manager.handleChromeMessageString(tabList(echo: (false, true), tabs: "[]"))
        clock.advance(5)
        manager.evaluateConnection()
        #expect(manager.connectionState == .connected)
        #expect(manager.chromeTabs.isEmpty)

        // No answer to the next request: the verdict is disconnected, as usual.
        clock.advance(10)
        manager.requestTabs()
        clock.advance(3)
        manager.evaluateConnection()
        #expect(manager.connectionState == .disconnected)
    }
}
