// DeciTests/ChromeSetTapLatencyTests.swift
//
// The manager side of SET_TAP_LATENCY: the tab-less message that tells the Chrome extension how much delay Deci's own
// tap adds to each output it taps. Every test builds a throwaway manager (no DeciHost) and reads what it would have
// sent through `messageSink`.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("ChromeSetTapLatency")
struct ChromeSetTapLatencyTests {

    // MARK: - Fixtures

    private let xm5 = AudioDevice(id: 1, uid: "uid-xm5", name: "WH-1000XM5", icon: nil, supportsAutoEQ: false)
    private let buds = AudioDevice(id: 2, uid: "uid-buds", name: "Buds", icon: nil, supportsAutoEQ: false)
    private let speakers = AudioDevice(id: 3, uid: "uid-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
    private var allDevices: [AudioDevice] { [xm5, buds, speakers] }

    private final class SentLog {
        var messages: [[String: Any]] = []
        func messages(ofType type: String) -> [[String: Any]] {
            messages.filter { $0["type"] as? String == type }
        }
        var types: [String] { messages.compactMap { $0["type"] as? String } }
    }

    private func makeManager(devices: [AudioDevice]? = nil) -> (manager: ChromeExtensionManager, sent: SentLog) {
        let manager = ChromeExtensionManager(observeHost: false)
        let sent = SentLog()
        manager.messageSink = { sent.messages.append($0) }
        manager.updateOutputDevices(devices ?? allDevices, defaultDeviceUID: "uid-xm5")
        manager.flushMessages()
        sent.messages.removeAll()
        return (manager, sent)
    }

    private func tapLatencyMessages(_ sent: SentLog) -> [[String: Any]] {
        sent.messages(ofType: "SET_TAP_LATENCY")
    }

    /// The devices of a message as (name, milliseconds) pairs, in the order sent.
    private func entries(_ message: [String: Any]) -> [(name: String, ms: Int)] {
        let devices = message["devices"] as? [[String: Any]] ?? []
        return devices.map { device in
            let seconds = device["seconds"] as? Double ?? -1
            return (device["deviceName"] as? String ?? "?", Int((seconds * 1000).rounded()))
        }
    }

    /// The `seconds` values of a message, in the order sent.
    private func secondsList(_ message: [String: Any]) -> [Double] {
        ((message["devices"] as? [[String: Any]]) ?? []).compactMap { $0["seconds"] as? Double }
    }

    private func names(_ message: [String: Any]) -> Set<String> {
        Set(entries(message).map(\.name))
    }

    // MARK: - Message shape

    @Test("one tapped output goes out as a tab-less SET_TAP_LATENCY with the device name and the seconds")
    func messageShape() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()

        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 1)
        let message = messages[0]
        #expect(message["tabId"] == nil)
        #expect(Set(message.keys) == ["type", "devices"])
        let devices = message["devices"] as? [[String: Any]]
        #expect(devices?.count == 1)
        #expect(Set(devices?.first?.keys.map { $0 } ?? []) == ["deviceName", "seconds"])
        #expect(devices?.first?["deviceName"] as? String == "WH-1000XM5")
        #expect(devices?.first?["seconds"] as? Double == 0.046)
        #expect(JSONSerialization.isValidJSONObject(message))
    }

    @Test("it is the only message queued: nothing else rides along")
    func onlyMessage() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        #expect(sent.types == ["SET_TAP_LATENCY"])
    }

    @Test("seconds are rounded to a millisecond")
    func roundsToMilliseconds() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.0464])
        manager.flushMessages()
        #expect(secondsList(tapLatencyMessages(sent)[0]) == [0.046])

        sent.messages.removeAll()
        manager.setTapLatency(["uid-xm5": 0.0466])
        manager.flushMessages()
        #expect(secondsList(tapLatencyMessages(sent)[0]) == [0.047])
    }

    // MARK: - Name mapping

    @Test("each UID is mapped to the name the routing messages use")
    func nameMapping() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046, "uid-buds": 0.012])
        manager.flushMessages()

        let message = tapLatencyMessages(sent)[0]
        let byName = Dictionary(uniqueKeysWithValues: entries(message).map { ($0.name, $0.ms) })
        #expect(byName == ["WH-1000XM5": 46, "Buds": 12])
    }

    @Test("the entries come out in a stable order, by name")
    func stableOrder() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046, "uid-buds": 0.012, "uid-speakers": 0.020])
        manager.flushMessages()
        #expect(entries(tapLatencyMessages(sent)[0]).map(\.name) == ["Buds", "Speakers", "WH-1000XM5"])
    }

    @Test("the name is the one in the output the tab routing uses (SET_TAB_DEVICES) for the same device")
    func sameNameAsRouting() {
        let (manager, sent) = makeManager()
        manager.handleChromeMessageString(#"{"type":"TAB_LIST","multiDevice":true,"tabs":[{"id":1,"title":"T","captured":true,"volume":1,"deviceName":""}]}"#)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-xm5", "uid-buds"])
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()

        let routed = Set((sent.messages(ofType: "SET_TAB_DEVICES").first?["deviceNames"] as? [String]) ?? [])
        let latency = names(tapLatencyMessages(sent)[0])
        #expect(latency.isSubset(of: routed))
        #expect(latency == ["WH-1000XM5"])
    }

    @Test("a UID with no known name is dropped, and the rest is still sent")
    func unknownUIDDropped() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046, "uid-never-seen": 0.030])
        manager.flushMessages()

        let message = tapLatencyMessages(sent)[0]
        #expect(entries(message).map(\.name) == ["WH-1000XM5"])
    }

    @Test("only unknown UIDs: nothing is sent")
    func onlyUnknownUIDs() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-never-seen": 0.030])
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).isEmpty)
    }

    @Test("a device that left the list keeps the name it had")
    func unpluggedDeviceKeepsItsName() {
        let (manager, sent) = makeManager()
        manager.updateOutputDevices([buds, speakers], defaultDeviceUID: "uid-speakers")
        manager.flushMessages()
        sent.messages.removeAll()

        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        #expect(entries(tapLatencyMessages(sent)[0]).map(\.name) == ["WH-1000XM5"])
    }

    @Test("two UIDs with one name become one entry with the larger value")
    func sameNameTwice() {
        let twin = AudioDevice(id: 9, uid: "uid-xm5-b", name: "WH-1000XM5", icon: nil, supportsAutoEQ: false)
        let (manager, sent) = makeManager(devices: [xm5, twin, buds])
        manager.setTapLatency(["uid-xm5": 0.040, "uid-xm5-b": 0.052])
        manager.flushMessages()

        let message = tapLatencyMessages(sent)[0]
        #expect(entries(message).count == 1)
        #expect(entries(message).first?.ms == 52)
    }

    @Test("a UID seen before its device list arrived is sent as soon as the list names it")
    func nameArrivesLater() {
        let manager = ChromeExtensionManager(observeHost: false)
        let sent = SentLog()
        manager.messageSink = { sent.messages.append($0) }

        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).isEmpty)

        manager.updateOutputDevices(allDevices, defaultDeviceUID: "uid-xm5")
        manager.flushMessages()
        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 1)
        #expect(entries(messages[0]).map(\.name) == ["WH-1000XM5"])
    }

    @Test("a renamed device is restated under its new name")
    func renamedDevice() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        sent.messages.removeAll()

        let renamed = AudioDevice(id: 1, uid: "uid-xm5", name: "Sony", icon: nil, supportsAutoEQ: false)
        manager.updateOutputDevices([renamed, buds, speakers], defaultDeviceUID: "uid-xm5")
        manager.flushMessages()

        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 1)
        #expect(entries(messages[0]).map(\.name) == ["Sony"])
    }

    @Test("repeating the same device list does not resend")
    func sameListDoesNotResend() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        sent.messages.removeAll()

        manager.updateOutputDevices(allDevices, defaultDeviceUID: "uid-xm5")
        manager.updateOutputDevices(allDevices, defaultDeviceUID: "uid-speakers")
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).isEmpty)
    }

    // MARK: - Values that are not sent

    @Test("zero, negative, non-finite and over-half-second values are dropped")
    func badValuesDropped() {
        let (manager, sent) = makeManager()
        manager.setTapLatency([
            "uid-xm5": 0.046,
            "uid-buds": 0,
            "uid-speakers": -0.01,
        ])
        manager.flushMessages()
        #expect(entries(tapLatencyMessages(sent)[0]).map(\.name) == ["WH-1000XM5"])

        sent.messages.removeAll()
        manager.setTapLatency(["uid-xm5": .nan, "uid-buds": .infinity, "uid-speakers": 0.7])
        manager.flushMessages()
        // Everything was dropped, which is a clear.
        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 1)
        #expect((messages[0]["devices"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("a value under half a millisecond rounds to nothing and is dropped")
    func subMillisecond() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.0004])
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).isEmpty)
    }

    // MARK: - Dedup

    @Test("the same value twice sends once")
    func dedupSameValue() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).count == 1)
    }

    @Test("values in the same millisecond count as the same value")
    func dedupAfterRounding() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.0461])
        manager.flushMessages()
        manager.setTapLatency(["uid-xm5": 0.0464])
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).count == 1)
    }

    @Test("a value in another millisecond is sent")
    func changeIsSent() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        manager.setTapLatency(["uid-xm5": 0.052])
        manager.flushMessages()

        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 2)
        #expect(entries(messages[1]).map(\.ms) == [52])
    }

    @Test("a different set of devices is sent even at the same value")
    func deviceSetChangeIsSent() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        manager.setTapLatency(["uid-xm5": 0.046, "uid-buds": 0.046])
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).count == 2)
    }

    @Test("two changes inside one batch window send only the last")
    func changesCoalesce() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.setTapLatency(["uid-xm5": 0.060])
        manager.flushMessages()

        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 1)
        #expect(entries(messages[0]).map(\.ms) == [60])
    }

    // MARK: - Clearing

    @Test("an empty map after a value sends devices: [] once")
    func emptyClears() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        sent.messages.removeAll()

        manager.setTapLatency([:])
        manager.flushMessages()
        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 1)
        let devices = messages[0]["devices"] as? [[String: Any]]
        #expect(devices != nil)
        #expect(devices?.isEmpty == true)
        #expect(messages[0]["tabId"] == nil)

        sent.messages.removeAll()
        manager.setTapLatency([:])
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).isEmpty)
    }

    @Test("an empty map before anything was sent sends nothing")
    func emptyFromTheStart() {
        let (manager, sent) = makeManager()
        manager.setTapLatency([:])
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).isEmpty)
    }

    @Test("a value after a clear is sent again, even at the old value")
    func valueAfterClear() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        manager.setTapLatency([:])
        manager.flushMessages()
        sent.messages.removeAll()

        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).count == 1)
        #expect(entries(tapLatencyMessages(sent)[0]).map(\.ms) == [46])
    }

    @Test("a clear inside the batch window of a value replaces it")
    func clearReplacesQueuedValue() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.setTapLatency([:])
        manager.flushMessages()

        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 1)
        #expect((messages[0]["devices"] as? [[String: Any]])?.isEmpty == true)
    }

    // MARK: - requestTabs

    @Test("requestTabs restates the last value so a reconnecting extension gets it")
    func requestTabsRestates() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        sent.messages.removeAll()

        manager.requestTabs()
        manager.flushMessages()

        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 1)
        #expect(entries(messages[0]).map(\.name) == ["WH-1000XM5"])
        #expect(entries(messages[0]).map(\.ms) == [46])
        #expect(messages[0]["tabId"] == nil)
        #expect(Set(sent.types) == ["SET_TRACKING", "SET_OPTIONS", "GET_TABS", "SET_TAP_LATENCY"])
    }

    @Test("requestTabs sends an empty tap latency when none is set, clearing what a previous run left")
    func requestTabsWithNothingSet() {
        let (manager, sent) = makeManager()
        manager.requestTabs()
        manager.flushMessages()
        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 1)
        #expect(entries(messages[0]).isEmpty)
        #expect(Set(sent.types) == ["SET_TRACKING", "SET_OPTIONS", "GET_TABS", "SET_TAP_LATENCY"])
    }

    @Test("requestTabs restates the clear once it was cleared")
    func requestTabsAfterClear() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        manager.setTapLatency([:])
        manager.flushMessages()
        sent.messages.removeAll()

        manager.requestTabs()
        manager.flushMessages()
        let messages = tapLatencyMessages(sent)
        #expect(messages.count == 1)
        #expect(entries(messages[0]).isEmpty)
    }

    @Test("a restated value does not break the dedup: the same value after requestTabs is still quiet")
    func dedupSurvivesRequestTabs() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        manager.requestTabs()
        manager.flushMessages()
        sent.messages.removeAll()

        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).isEmpty)
    }

    @Test("requestTabs restates the value under a device's current name")
    func requestTabsUsesCurrentName() {
        let (manager, sent) = makeManager()
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.flushMessages()
        let renamed = AudioDevice(id: 1, uid: "uid-xm5", name: "Sony", icon: nil, supportsAutoEQ: false)
        manager.updateOutputDevices([renamed, buds, speakers], defaultDeviceUID: "uid-xm5")
        manager.flushMessages()
        sent.messages.removeAll()

        manager.requestTabs()
        manager.flushMessages()
        #expect(entries(tapLatencyMessages(sent)[0]).map(\.name) == ["Sony"])
    }

    // MARK: - Independence from tabs

    @Test("tabs coming and going do not change what is sent")
    func independentOfTabs() {
        let (manager, sent) = makeManager()
        manager.handleChromeMessageString(#"{"type":"TAB_LIST","multiDevice":true,"tabs":[{"id":4,"title":"A","captured":true,"volume":1,"deviceName":""}]}"#)
        manager.setTapLatency(["uid-xm5": 0.046])
        manager.handleChromeMessageString(#"{"type":"TAB_LIST","tabs":[]}"#)
        manager.flushMessages()
        #expect(tapLatencyMessages(sent).count == 1)
        #expect(tapLatencyMessages(sent)[0]["tabId"] == nil)
    }
}
