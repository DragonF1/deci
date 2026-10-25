// DeciTests/ChromeTabMultiDeviceTests.swift
// Multi-output for Chrome tabs: the manager side of SET_TAB_DEVICES. Every test builds a throwaway
// manager (no DeciHost) and reads what it would have sent through `messageSink`.

import Foundation
import Observation
import Testing
@testable import Deci

/// Counts observation callbacks. Outside the suite so it is not main-actor isolated: the callback is `@Sendable`.
private final class FireCounter: @unchecked Sendable {
    nonisolated(unsafe) var count = 0
}

@MainActor
@Suite("ChromeTabMultiDevice")
struct ChromeTabMultiDeviceTests {

    // MARK: - Fixtures

    private let speakers = AudioDevice(id: 1, uid: "uid-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
    private let headphones = AudioDevice(id: 2, uid: "uid-headphones", name: "Headphones", icon: nil, supportsAutoEQ: false)
    private let hdmi = AudioDevice(id: 3, uid: "uid-hdmi", name: "HDMI", icon: nil, supportsAutoEQ: false)
    private var allDevices: [AudioDevice] { [speakers, headphones, hdmi] }

    private final class SentLog {
        var messages: [[String: Any]] = []
        func messages(ofType type: String) -> [[String: Any]] {
            messages.filter { $0["type"] as? String == type }
        }
        var types: [String] { messages.compactMap { $0["type"] as? String } }
    }

    /// One tab as the extension sends it in TAB_LIST.
    private func tabJSON(
        id: Int = 1,
        title: String = "Tab",
        captured: Bool = true,
        deviceName: String = "",
        deviceNames: [String]? = nil,
        deviceMissing: [String]? = nil,
        deviceStatus: String? = nil
    ) -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "title": title,
            "captured": captured,
            "volume": 1.0,
            "deviceName": deviceName,
        ]
        if let deviceNames { json["deviceNames"] = deviceNames }
        if let deviceMissing { json["deviceMissing"] = deviceMissing }
        if let deviceStatus { json["deviceStatus"] = deviceStatus }
        return json
    }

    private func listString(_ tabs: [[String: Any]], multiDevice: Bool = true) -> String {
        var json: [String: Any] = ["type": "TAB_LIST", "tabs": tabs]
        if multiDevice { json["multiDevice"] = true }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return String(data: data, encoding: .utf8)!
    }

    /// A manager that has been told about `tabs` by a TAB_LIST, with the output devices known and the log cleared.
    private func makeManager(
        tabs: [[String: Any]]? = nil,
        multiDevice: Bool = true,
        devices: [AudioDevice]? = nil,
        defaultDeviceUID: String? = "uid-speakers"
    ) -> (manager: ChromeExtensionManager, sent: SentLog) {
        let manager = ChromeExtensionManager(observeHost: false)
        let sent = SentLog()
        manager.messageSink = { sent.messages.append($0) }
        manager.updateOutputDevices(devices ?? allDevices, defaultDeviceUID: defaultDeviceUID)
        manager.handleChromeMessageString(listString(tabs ?? [tabJSON()], multiDevice: multiDevice))
        manager.flushMessages()
        sent.messages.removeAll()
        return (manager, sent)
    }

    private func tab(_ manager: ChromeExtensionManager, id: Int = 1) -> ChromeTab {
        manager.chromeTabs.first { $0.id == id }!
    }

    // MARK: - Wire parsing

    @Test("parseTabList reads deviceNames and deviceMissing; absent means none")
    func parsesMultiFields() {
        let json: [String: Any] = [
            "tabs": [
                tabJSON(id: 1, deviceNames: ["Speakers", "HDMI"], deviceMissing: ["HDMI"]),
                tabJSON(id: 2),
            ],
        ]
        let tabs = ChromeExtensionManager.parseTabList(json).tabs
        #expect(tabs[0].deviceNames == ["Speakers", "HDMI"])
        #expect(tabs[0].missingDeviceNames == ["HDMI"])
        #expect(tabs[1].deviceNames.isEmpty)
        #expect(tabs[1].missingDeviceNames.isEmpty)
    }

    @Test("parseTabList drops non-string and empty names from the multi lists")
    func parsesMultiFieldsDefensively() {
        let json: [String: Any] = [
            "tabs": [tabJSON(id: 1, deviceNames: ["Speakers", "", "Speakers", "Headphones"])],
        ]
        let raw = ChromeExtensionManager.parseTabList(json).tabs[0]
        #expect(raw.deviceNames == ["Speakers", "Headphones"])

        var odd = tabJSON(id: 2)
        odd["deviceNames"] = [1, "HDMI", NSNull()]
        odd["deviceMissing"] = "HDMI"
        let tab = ChromeExtensionManager.parseTabList(["tabs": [odd]]).tabs[0]
        #expect(tab.deviceNames == ["HDMI"])
        #expect(tab.missingDeviceNames.isEmpty)
    }

    @Test("supportsMultiDevice follows the TAB_LIST capability marker")
    func capabilityMarker() {
        let (old, _) = makeManager(multiDevice: false)
        #expect(old.supportsMultiDevice == false)

        let (current, _) = makeManager(multiDevice: true)
        #expect(current.supportsMultiDevice == true)

        // A later list without the marker (an older extension took over) turns it off again.
        current.handleChromeMessageString(listString([tabJSON()], multiDevice: false))
        #expect(current.supportsMultiDevice == false)
    }

    @Test("a multi-output tab counts as a device choice for the device-access hint")
    func needsDeviceAccessCountsMultiNames() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"])])
        manager.handleChromeMessageString(
            "{\"type\":\"TAB_LIST\",\"deviceAccess\":false,\"multiDevice\":true,\"tabs\":[{\"id\":1,\"captured\":true,\"deviceName\":\"\",\"deviceNames\":[\"Speakers\",\"HDMI\"]}]}"
        )
        #expect(manager.needsDeviceAccess)
    }

    // MARK: - Seeding the first flip to Multi

    @Test("the first flip to Multi ticks the tab's current device and sends nothing")
    func seedsFromCurrentDevice() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceName: "Headphones")])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.flushMessages()

        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-headphones"])
        #expect(sent.messages.isEmpty)
    }

    @Test("a tab that follows the default is seeded with the default device")
    func seedsFromDefaultDevice() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceName: "")], defaultDeviceUID: "uid-hdmi")
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-hdmi"])
    }

    @Test("a tab on a device that is not plugged in is seeded with the default device")
    func seedsFromDefaultWhenDeviceMissing() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceName: "Unplugged Thing")], defaultDeviceUID: "uid-speakers")
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-speakers"])
    }

    @Test("with no default and no known device the seed stays empty")
    func seedsNothingWithoutAnyDevice() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceName: "")], devices: [], defaultDeviceUID: nil)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).selectedDeviceUIDs.isEmpty)
    }

    @Test("a selection already made is not reseeded by flipping modes back and forth")
    func existingSelectionIsNotReseeded() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceName: "Headphones")])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-speakers", "uid-hdmi"])
    }

    @Test("setting the mode it already has changes nothing")
    func sameModeIsANoOp() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceName: "Headphones")])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()
        #expect(tab(manager).deviceSelectionMode == .single)
        #expect(tab(manager).selectedDeviceUIDs.isEmpty)
        #expect(sent.messages.isEmpty)
    }

    @Test("an unknown tab id is ignored by every setter")
    func unknownTabIsIgnored() {
        let (manager, sent) = makeManager()
        manager.setTabDeviceSelectionMode(tabId: 99, to: .multi)
        manager.setTabDevices(tabId: 99, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        manager.flushMessages()
        #expect(sent.messages.isEmpty)
        #expect(manager.chromeTabs.count == 1)
    }

    // MARK: - SET_TAB_DEVICES payload

    @Test("ticking two devices sends one SET_TAB_DEVICES with their names in device-list order")
    func multiSendsNames() {
        let (manager, sent) = makeManager()
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-headphones", "uid-speakers"])
        manager.flushMessages()

        let multi = sent.messages(ofType: "SET_TAB_DEVICES")
        #expect(multi.count == 1)
        #expect(multi.first?["tabId"] as? Int == 1)
        #expect(multi.first?["deviceNames"] as? [String] == ["Speakers", "Headphones"])
        #expect(sent.messages(ofType: "SET_TAB_DEVICE").isEmpty)
        #expect(JSONSerialization.isValidJSONObject(multi.first ?? [:]))
    }

    @Test("a multi choice shows at once: names, pending status and the selection")
    func multiUpdatesTheTabLocally() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceName: "Headphones")])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])

        let tab = tab(manager)
        #expect(tab.deviceSelectionMode == .multi)
        #expect(tab.selectedDeviceUIDs == ["uid-speakers", "uid-hdmi"])
        #expect(tab.deviceNames == ["Speakers", "HDMI"])
        #expect(tab.deviceStatus == .pending)
        // The single choice is left alone, so flipping back can restore it.
        #expect(tab.deviceName == "Headphones")
    }

    @Test("UIDs map to the names the devices have, and unknown UIDs are skipped")
    func uidToNameMapping() {
        let (manager, sent) = makeManager()
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-hdmi", "uid-ghost", "uid-speakers"])
        manager.flushMessages()
        #expect(sent.messages(ofType: "SET_TAB_DEVICES").first?["deviceNames"] as? [String] == ["Speakers", "HDMI"])
    }

    @Test("a selection with no resolvable device sends nothing and leaves the tab where it is")
    func nothingResolvableSendsNothing() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"])])
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-ghost"])
        manager.flushMessages()
        #expect(sent.messages.isEmpty)
        #expect(tab(manager).deviceNames == ["Speakers", "HDMI"])
    }

    @Test("an empty selection is recorded but the tab keeps playing where it is")
    func emptySelectionKeepsTheTab() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"])])
        manager.setTabDevices(tabId: 1, deviceUIDs: [])
        manager.flushMessages()

        #expect(sent.messages.isEmpty)
        #expect(tab(manager).deviceNames == ["Speakers", "HDMI"])
        #expect(tab(manager).selectedDeviceUIDs.isEmpty)
        #expect(tab(manager).deviceSelectionMode == .multi)
    }

    @Test("the same selection twice sends once")
    func repeatedSelectionIsBatched() {
        let (manager, sent) = makeManager()
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers"])
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        manager.flushMessages()
        let multi = sent.messages(ofType: "SET_TAB_DEVICES")
        #expect(multi.count == 1)
        #expect(multi.first?["deviceNames"] as? [String] == ["Speakers", "HDMI"])
    }

    @Test("one multi tab does not touch another tab")
    func tabsAreIndependent() {
        let (manager, sent) = makeManager(tabs: [tabJSON(id: 1), tabJSON(id: 2)])
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        manager.flushMessages()
        #expect(tab(manager, id: 2).deviceSelectionMode == .single)
        #expect(tab(manager, id: 2).deviceNames.isEmpty)
        #expect(sent.messages(ofType: "SET_TAB_DEVICES").allSatisfy { $0["tabId"] as? Int == 1 })
    }

    @Test("a device that is unplugged keeps its place in the selection and its name for later")
    func unpluggedDeviceKeepsItsSeat() {
        let (manager, sent) = makeManager()
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-headphones"])
        manager.flushMessages()
        sent.messages.removeAll()

        // Headphones leave the device list; the picker still holds their UID and ticks HDMI.
        manager.updateOutputDevices([speakers, hdmi], defaultDeviceUID: "uid-speakers")
        #expect(tab(manager).selectedDeviceUIDs == ["uid-speakers", "uid-headphones"])
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-headphones", "uid-hdmi"])
        manager.flushMessages()

        let names = sent.messages(ofType: "SET_TAB_DEVICES").first?["deviceNames"] as? [String]
        #expect(names == ["Speakers", "HDMI", "Headphones"])
    }

    // MARK: - Old extension

    @Test("an extension without the capability marker is sent the single message only")
    func oldExtensionGetsSingleMessage() {
        let (manager, sent) = makeManager(multiDevice: false)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-hdmi", "uid-headphones"])
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICES").isEmpty)
        let single = sent.messages(ofType: "SET_TAB_DEVICE")
        #expect(single.count == 1)
        // First of the chosen devices in list order: the tab still reacts, on one output.
        #expect(single.first?["deviceName"] as? String == "Headphones")
        #expect(tab(manager).deviceName == "Headphones")
        #expect(tab(manager).deviceNames.isEmpty)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-hdmi", "uid-headphones"])
    }

    // MARK: - Single mode and flipping back

    @Test("single mode still sends SET_TAB_DEVICE and never SET_TAB_DEVICES")
    func singleKeepsTheOldMessage() {
        let (manager, sent) = makeManager()
        manager.setTabDevice(tabId: 1, deviceName: "HDMI")
        manager.flushMessages()
        #expect(sent.messages(ofType: "SET_TAB_DEVICES").isEmpty)
        let single = sent.messages(ofType: "SET_TAB_DEVICE")
        #expect(single.count == 1)
        #expect(single.first?["deviceName"] as? String == "HDMI")
    }

    @Test("a single choice right after a multi one wins the batch, so the order cannot flip")
    func singleAfterMultiDropsTheMultiMessage() {
        let (manager, sent) = makeManager()
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        manager.setTabDevice(tabId: 1, deviceName: "Headphones")
        manager.flushMessages()
        #expect(sent.types == ["SET_TAB_DEVICE"])
        #expect(tab(manager).deviceNames.isEmpty)
        #expect(tab(manager).deviceName == "Headphones")
    }

    @Test("a multi choice right after a single one wins the batch")
    func multiAfterSingleDropsTheSingleMessage() {
        let (manager, sent) = makeManager()
        manager.setTabDevice(tabId: 1, deviceName: "Headphones")
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        manager.flushMessages()
        #expect(sent.types == ["SET_TAB_DEVICES"])
    }

    @Test("flipping a multi-output tab back to single restores its single choice")
    func flipBackToSingle() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceName: "Headphones", deviceNames: ["Speakers", "HDMI"])])
        #expect(tab(manager).deviceSelectionMode == .multi)

        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()

        let single = sent.messages(ofType: "SET_TAB_DEVICE")
        #expect(single.count == 1)
        #expect(single.first?["deviceName"] as? String == "Headphones")
        #expect(sent.messages(ofType: "SET_TAB_DEVICES").isEmpty)
        #expect(tab(manager).deviceSelectionMode == .single)
        #expect(tab(manager).deviceNames.isEmpty)
        #expect(tab(manager).deviceStatus == .pending)
        // The multi selection is kept for the next flip, like the engine keeps it.
        #expect(tab(manager).selectedDeviceUIDs == ["uid-speakers", "uid-hdmi"])
    }

    @Test("flipping back for a tab that followed the default sends the follow-default form")
    func flipBackToFollowDefault() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceName: "", deviceNames: ["Speakers", "HDMI"])])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()
        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "")
        #expect(tab(manager).deviceStatus == .defaultOutput)
    }

    @Test("flipping to single when the extension is not routing a list sends nothing")
    func flipToSingleWithoutListSendsNothing() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceName: "Headphones")])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()
        #expect(sent.messages.isEmpty)
    }

    // MARK: - Persistence across TAB_LISTs

    @Test("mode and selection survive later TAB_LISTs that know nothing about them")
    func localStateSurvivesTabLists() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceName: "Headphones")])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)

        manager.handleChromeMessageString(listString([tabJSON(title: "Renamed", deviceName: "Headphones")]))

        #expect(tab(manager).title == "Renamed")
        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-headphones"])
    }

    @Test("a list the extension is playing on is adopted as multi, with UIDs from the known devices")
    func adoptsExtensionMultiState() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")])
        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).deviceNames == ["Speakers", "HDMI"])
        #expect(tab(manager).selectedDeviceUIDs == ["uid-speakers", "uid-hdmi"])
    }

    @Test("adopted names turn into UIDs once the device list arrives")
    func adoptedSelectionFillsInWhenDevicesArrive() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"])], devices: [])
        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).selectedDeviceUIDs.isEmpty)

        manager.updateOutputDevices(allDevices, defaultDeviceUID: "uid-speakers")
        #expect(tab(manager).selectedDeviceUIDs == ["uid-speakers", "uid-hdmi"])
    }

    @Test("merge keeps a local multi choice inside its pending window and adopts the echo after")
    func mergePendingWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var old = ChromeTab(id: 1, title: "Tab", volume: 1)
        old.deviceNames = ["Speakers", "HDMI"]
        old.missingDeviceNames = []
        old.deviceSelectionMode = .multi
        old.selectedDeviceUIDs = ["uid-speakers", "uid-hdmi"]

        var fresh = ChromeTab(id: 1, title: "Tab", volume: 1)
        fresh.deviceNames = ["Headphones", "HDMI"]
        fresh.missingDeviceNames = ["HDMI"]

        let pending = ChromeExtensionManager.merge(
            existing: [old], incoming: [fresh], pendingUntil: [1: now.addingTimeInterval(1)], now: now
        )
        #expect(pending[0].deviceNames == ["Speakers", "HDMI"])
        #expect(pending[0].missingDeviceNames.isEmpty)

        let settled = ChromeExtensionManager.merge(
            existing: [old], incoming: [fresh], pendingUntil: [:], now: now
        )
        #expect(settled[0].deviceNames == ["Headphones", "HDMI"])
        #expect(settled[0].missingDeviceNames == ["HDMI"])
        // The picker's own state is never taken from the extension.
        #expect(settled[0].deviceSelectionMode == .multi)
        #expect(settled[0].selectedDeviceUIDs == ["uid-speakers", "uid-hdmi"])
    }

    // MARK: - multiOutputDeviceUIDs

    @Test("multiOutputDeviceUIDs is empty with no tabs, and for tabs on one output")
    func multiOutputsEmptyByDefault() {
        let (manager, _) = makeManager(tabs: [tabJSON(id: 1, deviceName: "Headphones"), tabJSON(id: 2)])
        #expect(manager.multiOutputDeviceUIDs.isEmpty)
    }

    @Test("multiOutputDeviceUIDs is the union of the devices of every tab playing on two or more")
    func multiOutputsUnion() {
        let (manager, _) = makeManager(tabs: [
            tabJSON(id: 1, deviceNames: ["Speakers", "Headphones"], deviceStatus: "routed"),
            tabJSON(id: 2, deviceNames: ["Headphones", "HDMI"], deviceStatus: "routed"),
            tabJSON(id: 3, deviceNames: ["HDMI"], deviceStatus: "routed"),
        ])
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-headphones", "uid-hdmi"])
    }

    @Test("a local multi choice lights its devices at once")
    func multiOutputsFollowLocalChoice() {
        let (manager, _) = makeManager()
        #expect(manager.multiOutputDeviceUIDs.isEmpty)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-hdmi"])
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-hdmi"])
        #expect(manager.multiOutputDeviceUIDs.isEmpty)
    }

    @Test("flipping back to single clears it")
    func multiOutputsClearOnFlipBack() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")])
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-hdmi"])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        #expect(manager.multiOutputDeviceUIDs.isEmpty)
    }

    @Test("static rule: only captured tabs that really route count")
    func multiOutputRule() {
        func tab(
            _ id: Int,
            names: [String],
            missing: [String] = [],
            status: ChromeTabDeviceStatus = .routed,
            control: ChromeTabControl = .capture
        ) -> ChromeTab {
            var t = ChromeTab(id: id, title: "T", volume: 1)
            t.deviceNames = names
            t.missingDeviceNames = missing
            t.deviceStatus = status
            t.control = control
            return t
        }
        let pair = ["Speakers", "HDMI"]

        let counted = ChromeExtensionManager.multiOutputUIDs(tabs: [tab(1, names: pair)], devices: allDevices)
        #expect(counted == ["uid-speakers", "uid-hdmi"])

        // Not captured: Chrome plays it as it always did.
        #expect(ChromeExtensionManager.multiOutputUIDs(tabs: [tab(1, names: pair, control: .none)], devices: allDevices).isEmpty)
        // One of two names matched no output: one sink is left, which is not multi.
        #expect(ChromeExtensionManager.multiOutputUIDs(tabs: [tab(1, names: pair, missing: ["HDMI"])], devices: allDevices).isEmpty)
        // All matched: still multi.
        #expect(ChromeExtensionManager.multiOutputUIDs(tabs: [tab(1, names: ["Speakers", "HDMI", "Headphones"], missing: ["Headphones"])], devices: allDevices) == ["uid-speakers", "uid-hdmi"])
        // Nothing matched or names unreadable: the tab fell back to the default output.
        #expect(ChromeExtensionManager.multiOutputUIDs(tabs: [tab(1, names: pair, status: .notFound)], devices: allDevices).isEmpty)
        #expect(ChromeExtensionManager.multiOutputUIDs(tabs: [tab(1, names: pair, status: .noAccess)], devices: allDevices).isEmpty)
        #expect(ChromeExtensionManager.multiOutputUIDs(tabs: [tab(1, names: pair, status: .defaultOutput)], devices: allDevices).isEmpty)
        // A name no device has: the others still count.
        #expect(ChromeExtensionManager.multiOutputUIDs(tabs: [tab(1, names: ["Speakers", "HDMI", "Ghost"])], devices: allDevices) == ["uid-speakers", "uid-hdmi"])
        // Duplicates in the list are one device.
        #expect(ChromeExtensionManager.multiOutputUIDs(tabs: [tab(1, names: ["Speakers", "Speakers"])], devices: allDevices).isEmpty)
    }

    @Test("multiOutputDeviceUIDs is assigned only when it really changes")
    func multiOutputsChangeOnly() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")])
        let fired = FireCounter()
        func watch() {
            withObservationTracking {
                _ = manager.multiOutputDeviceUIDs
            } onChange: {
                fired.count += 1
            }
        }

        // A TAB_LIST that changes only the title leaves the set alone: no notification.
        watch()
        manager.handleChromeMessageString(listString([tabJSON(title: "Another song", deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")]))
        #expect(fired.count == 0)

        // The same devices in another order are the same set.
        manager.handleChromeMessageString(listString([tabJSON(title: "Another song", deviceNames: ["HDMI", "Speakers"], deviceStatus: "routed")]))
        #expect(fired.count == 0)

        // A real change notifies exactly once.
        manager.handleChromeMessageString(listString([tabJSON(title: "Another song", deviceNames: ["Speakers", "Headphones"], deviceStatus: "routed")]))
        #expect(fired.count == 1)
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-headphones"])

        // Volume and mute writes touch the tab array but not the set.
        watch()
        manager.setTabVolume(tabId: 1, volume: 0.4)
        manager.setTabMuted(tabId: 1, muted: true)
        #expect(fired.count == 1)
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-headphones"])
    }

    @Test("closing the tab clears the set")
    func closingTheTabClearsIt() {
        let (manager, _) = makeManager(tabs: [
            tabJSON(id: 1, deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed"),
            tabJSON(id: 2, deviceNames: ["Headphones", "HDMI"], deviceStatus: "routed"),
        ])
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-hdmi", "uid-headphones"])

        manager.handleChromeMessageString(listString([tabJSON(id: 2, deviceNames: ["Headphones", "HDMI"], deviceStatus: "routed")]))
        #expect(manager.multiOutputDeviceUIDs == ["uid-headphones", "uid-hdmi"])

        manager.handleChromeMessageString(listString([]))
        #expect(manager.multiOutputDeviceUIDs.isEmpty)
    }

    @Test("a tab that stops being captured, hidden tabs and a lost connection all clear it")
    func otherWaysToLoseTheTab() {
        let tabs = [tabJSON(deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")]

        let (uncaptured, _) = makeManager(tabs: tabs)
        uncaptured.handleChromeMessageString(listString([tabJSON(captured: false, deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")]))
        #expect(uncaptured.multiOutputDeviceUIDs.isEmpty)

        let (hidden, _) = makeManager(tabs: tabs)
        #expect(!hidden.multiOutputDeviceUIDs.isEmpty)
        hidden.setTracking(tabs: false, incognito: false)
        #expect(hidden.multiOutputDeviceUIDs.isEmpty)

        // The list above was stamped with the real clock, so the request must come after it.
        let clock = Date().addingTimeInterval(60)
        let (dropped, _) = makeManager(tabs: tabs)
        var now = clock
        dropped.connectionClock = { now }
        dropped.requestTabs()
        now = clock.addingTimeInterval(ChromeExtensionManager.connectionTimeout + 1)
        dropped.evaluateConnection()
        #expect(dropped.chromeTabs.isEmpty)
        #expect(dropped.multiOutputDeviceUIDs.isEmpty)
    }

    @Test("a device list change relights the set")
    func deviceListChangeRecomputes() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")], devices: [speakers])
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers"])
        manager.updateOutputDevices(allDevices, defaultDeviceUID: "uid-speakers")
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-hdmi"])
    }

    // MARK: - The engine already fans Chrome out

    // When the Chrome app row plays on two or more devices, the engine's tap mirrors everything Chrome
    // renders to each of them. A tab the extension also sinks to several devices would play twice on each, so
    // the tab is held to one device while that lasts. The ticks stay recorded, for when the row is single again.

    @Test("while the engine fans Chrome out, a multi tick plays on one device and keeps the selection")
    func fanOutCollapsesTheTick() {
        let (manager, sent) = makeManager()
        manager.setEngineFansOutChrome(true)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-headphones", "uid-speakers"])
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICES").isEmpty)
        let single = sent.messages(ofType: "SET_TAB_DEVICE")
        #expect(single.count == 1)
        // First of the ticked devices in list order, like the old-extension fallback.
        #expect(single.first?["deviceName"] as? String == "Speakers")
        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-headphones", "uid-speakers"])
        #expect(tab(manager).deviceNames.isEmpty)
        #expect(manager.multiOutputDeviceUIDs.isEmpty, "the tab plays on one output, so no multi route is lit")
    }

    @Test("while the engine fans Chrome out, a single tick still goes out as a list of one")
    func fanOutLeavesOneTickAlone() {
        let (manager, sent) = makeManager()
        manager.setEngineFansOutChrome(true)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-hdmi"])
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICES").first?["deviceNames"] as? [String] == ["HDMI"])
        #expect(sent.messages(ofType: "SET_TAB_DEVICE").isEmpty)
    }

    @Test("without the engine fanning Chrome out, a multi tick is still sent as a list")
    func noFanOutKeepsTheList() {
        let (manager, sent) = makeManager()
        manager.setEngineFansOutChrome(false)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-headphones", "uid-speakers"])
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICES").first?["deviceNames"] as? [String] == ["Speakers", "Headphones"])
    }

    @Test("the engine starting to fan Chrome out pulls a tab that plays on several devices back to one")
    func fanOutStartingCollapsesAPlayingList() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")])
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-hdmi"])

        manager.setEngineFansOutChrome(true)
        manager.flushMessages()

        let single = sent.messages(ofType: "SET_TAB_DEVICE")
        #expect(single.count == 1)
        #expect(single.first?["deviceName"] as? String == "Speakers")
        #expect(sent.messages(ofType: "SET_TAB_DEVICES").isEmpty)
        #expect(tab(manager).deviceNames.isEmpty)
        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-speakers", "uid-hdmi"])
        #expect(manager.multiOutputDeviceUIDs.isEmpty)
    }

    @Test("the engine stopping fanning Chrome out puts the ticked devices back on the tab")
    func fanOutEndingRestoresTheList() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")])
        manager.setEngineFansOutChrome(true)
        manager.flushMessages()
        sent.messages.removeAll()

        manager.setEngineFansOutChrome(false)
        manager.flushMessages()

        let multi = sent.messages(ofType: "SET_TAB_DEVICES")
        #expect(multi.count == 1)
        #expect(multi.first?["deviceNames"] as? [String] == ["Speakers", "HDMI"])
        #expect(tab(manager).deviceNames == ["Speakers", "HDMI"])
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-hdmi"])
    }

    @Test("a tab on one device is left alone when the engine starts or stops fanning Chrome out")
    func fanOutChangesLeaveSingleTabsAlone() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceName: "Headphones")])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)  // seeded with one device, nothing is playing on several
        sent.messages.removeAll()

        manager.setEngineFansOutChrome(true)
        manager.setEngineFansOutChrome(false)
        manager.flushMessages()

        #expect(sent.messages.isEmpty)
    }

    @Test("a tab that went back to single while the engine fanned Chrome out stays single when it stops")
    func fanOutEndingDoesNotReviveASingleTab() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")])
        manager.setEngineFansOutChrome(true)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()
        sent.messages.removeAll()

        manager.setEngineFansOutChrome(false)
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICES").isEmpty)
        #expect(tab(manager).deviceSelectionMode == .single)
    }

    @Test("telling the manager the same fan-out state twice sends nothing the second time")
    func fanOutIsIdempotent() {
        let (manager, sent) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")])
        manager.setEngineFansOutChrome(true)
        manager.flushMessages()
        sent.messages.removeAll()

        manager.setEngineFansOutChrome(true)
        manager.flushMessages()

        #expect(sent.messages.isEmpty)
    }

    @Test("a tab may use several outputs only when the extension can and the engine is not already doing it")
    func allowsTabMultiDeviceNeedsBoth() {
        let (current, _) = makeManager(multiDevice: true)
        #expect(current.allowsTabMultiDevice)
        current.setEngineFansOutChrome(true)
        #expect(!current.allowsTabMultiDevice)
        #expect(current.supportsMultiDevice, "the capability itself is untouched")
        current.setEngineFansOutChrome(false)
        #expect(current.allowsTabMultiDevice)

        let (old, _) = makeManager(multiDevice: false)
        #expect(!old.allowsTabMultiDevice)
    }

    // MARK: - Row captions

    private func captionTab(
        control: ChromeTabControl = .capture,
        mode: DeviceSelectionMode = .multi,
        selected: Set<String> = ["uid-speakers", "uid-hdmi"],
        names: [String] = ["Speakers", "HDMI"],
        missing: [String] = [],
        status: ChromeTabDeviceStatus = .routed
    ) -> ChromeTab {
        var t = ChromeTab(id: 1, title: "T", volume: 1)
        t.control = control
        t.deviceSelectionMode = mode
        t.selectedDeviceUIDs = selected
        t.deviceNames = names
        t.missingDeviceNames = missing
        t.deviceStatus = status
        return t
    }

    @Test("a healthy multi-output tab needs no caption")
    func captionQuietWhenRouted() {
        #expect(ChromeTabRow.multiOutputNote(for: captionTab(), supportsMultiDevice: true) == nil)
        #expect(ChromeTabRow.multiOutputNote(for: captionTab(status: .pending), supportsMultiDevice: true) == nil)
    }

    @Test("a tab on one output falls through to the single-output captions")
    func captionSingleTabIsNotCovered() {
        let single = captionTab(mode: .single, selected: [], names: [], status: .routed)
        #expect(ChromeTabRow.multiOutputNote(for: single, supportsMultiDevice: true) == nil)
        // One ticked device on an old extension is just a single choice.
        let oneTick = captionTab(selected: ["uid-speakers"], names: [])
        #expect(ChromeTabRow.multiOutputNote(for: oneTick, supportsMultiDevice: false) == nil)
    }

    @Test("several ticks on an extension without multi support ask for a reload")
    func captionReloadHint() {
        let tab = captionTab(names: [], status: .routed)
        #expect(ChromeTabRow.multiOutputNote(for: tab, supportsMultiDevice: false) == .reloadExtension)
        #expect(ChromeTabRow.multiOutputNote(for: tab, supportsMultiDevice: true) == nil)
    }

    @Test("missing outputs are counted, and all missing says it plays on the default")
    func captionMissingOutputs() {
        let some = captionTab(names: ["Speakers", "HDMI", "Headphones"], missing: ["HDMI"])
        #expect(ChromeTabRow.multiOutputNote(for: some, supportsMultiDevice: true) == .someNotFound(1))
        #expect(ChromeTabRow.multiOutputNote(for: some, supportsMultiDevice: true)?.text == "1 output not found")

        let two = captionTab(names: ["Speakers", "HDMI", "Headphones"], missing: ["HDMI", "Headphones"])
        #expect(ChromeTabRow.multiOutputNote(for: two, supportsMultiDevice: true)?.text == "2 outputs not found")

        let none = captionTab(missing: ["Speakers", "HDMI"], status: .notFound)
        #expect(ChromeTabRow.multiOutputNote(for: none, supportsMultiDevice: true) == .allNotFound)
    }

    @Test("a stored list on a tab that is not captured has no multi caption: its own caption covers it")
    func captionNotCaptured() {
        #expect(ChromeTabRow.multiOutputNote(for: captionTab(control: .none), supportsMultiDevice: true) == nil)
        #expect(ChromeTabRow.multiOutputNote(for: captionTab(control: .none, status: .notFound), supportsMultiDevice: true) == nil)
    }

    @Test("unreadable device names use the existing permission button, not a multi caption")
    func captionNoAccessIsLeftToTheButton() {
        #expect(ChromeTabRow.multiOutputNote(for: captionTab(status: .noAccess), supportsMultiDevice: true) == nil)
    }

    @Test("a multi tab says it follows the Chrome row while the engine fans Chrome out")
    func captionFanOut() {
        let tab = captionTab(names: [], status: .routed)
        #expect(ChromeTabRow.multiOutputNote(for: tab, supportsMultiDevice: true, engineFansOutChrome: true) == .chromeRowFansOut)
        #expect(ChromeTabRow.multiOutputNote(for: tab, supportsMultiDevice: true, engineFansOutChrome: false) == nil)
        // It outranks the reload hint: an extension that cannot do several outputs is not the problem now.
        #expect(ChromeTabRow.multiOutputNote(for: tab, supportsMultiDevice: false, engineFansOutChrome: true) == .chromeRowFansOut)
        #expect(ChromeTabRow.MultiOutputNote.chromeRowFansOut.text == "Plays on the outputs of the Chrome row")
    }

    @Test("the fan-out caption needs a captured multi tab with several ticks")
    func captionFanOutScope() {
        let oneTick = captionTab(selected: ["uid-speakers"], names: [])
        #expect(ChromeTabRow.multiOutputNote(for: oneTick, supportsMultiDevice: true, engineFansOutChrome: true) == nil)
        let single = captionTab(mode: .single, selected: [], names: [], status: .routed)
        #expect(ChromeTabRow.multiOutputNote(for: single, supportsMultiDevice: true, engineFansOutChrome: true) == nil)
        let uncaptured = captionTab(control: .none, names: [])
        #expect(ChromeTabRow.multiOutputNote(for: uncaptured, supportsMultiDevice: true, engineFansOutChrome: true) == nil)
    }

    // MARK: - A disconnect sends a Multi tab back to Single

    // When an output device in a tab's Multi selection disconnects, the tab goes back to Single right away: to
    // its pre-Multi single choice when it entered Multi under an hour ago, else to System Audio (the old choice is
    // cleared). A tab adopted from the extension has no recorded start. Nothing rejoins when the device returns.

    /// A manager whose clock the test moves. `advance(_:)` shifts it.
    private final class TestClock {
        var now = Date()
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func makeClockedManager(
        tabs: [[String: Any]]? = nil,
        multiDevice: Bool = true
    ) -> (manager: ChromeExtensionManager, sent: SentLog, clock: TestClock) {
        let (manager, sent) = makeManager(tabs: tabs, multiDevice: multiDevice)
        let clock = TestClock()
        manager.connectionClock = { clock.now }
        return (manager, sent, clock)
    }

    /// A tab on `deviceName` (its single choice) that is switched to Multi and then plays on a list of two outputs.
    private func tabPlayingAList(
        deviceName: String = "Headphones", uids: Set<String> = ["uid-speakers", "uid-hdmi"]
    ) -> (manager: ChromeExtensionManager, sent: SentLog, clock: TestClock) {
        let (manager, sent, clock) = makeClockedManager(tabs: [tabJSON(deviceName: deviceName)])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: uids)
        manager.flushMessages()
        sent.messages.removeAll()
        return (manager, sent, clock)
    }

    @Test("entering Multi records the time, leaving clears it, and re-entering starts a fresh clock")
    func multiSinceFollowsTheMode() {
        let (manager, _, clock) = makeClockedManager(tabs: [tabJSON(deviceName: "Headphones")])
        #expect(tab(manager).multiSince == nil)

        let entered = clock.now
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        #expect(tab(manager).multiSince == entered)

        clock.advance(100)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        #expect(tab(manager).multiSince == entered, "ticking more devices is the same session")

        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        #expect(tab(manager).multiSince == nil)

        clock.advance(100)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        #expect(tab(manager).multiSince == clock.now)
    }

    @Test("ticking devices on a single tab enters Multi and records the time")
    func tickingFromSingleRecordsTheTime() {
        let (manager, _, clock) = makeClockedManager()
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        #expect(tab(manager).multiSince == clock.now)
    }

    @Test("a later TAB_LIST keeps the recorded time")
    func tabListKeepsTheTime() {
        let (manager, _, clock) = makeClockedManager(tabs: [tabJSON(deviceName: "Headphones")])
        let entered = clock.now
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)

        manager.handleChromeMessageString(listString([tabJSON(title: "Renamed", deviceName: "Headphones")]))

        #expect(tab(manager).title == "Renamed")
        #expect(tab(manager).multiSince == entered)
    }

    @Test("merge carries the recorded time from the existing tab")
    func mergeCarriesTheTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var old = ChromeTab(id: 1, title: "Tab", volume: 1)
        old.deviceSelectionMode = .multi
        old.selectedDeviceUIDs = ["uid-speakers", "uid-hdmi"]
        old.multiSince = now.addingTimeInterval(-90)
        let fresh = ChromeTab(id: 1, title: "Tab", volume: 1)

        let merged = ChromeExtensionManager.merge(existing: [old], incoming: [fresh], pendingUntil: [:], now: now)

        #expect(merged[0].multiSince == now.addingTimeInterval(-90))
        #expect(merged[0].deviceSelectionMode == .multi)
    }

    @Test("a list the extension plays is adopted as Multi with no recorded time")
    func adoptedMultiHasNoRecordedTime() {
        let (manager, _) = makeManager(tabs: [tabJSON(deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")])
        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).multiSince == nil)
    }

    @Test("a short session returns a playing list to the pre-Multi single choice")
    func shortSessionReturnsToTheSingleChoice() {
        let (manager, sent, clock) = tabPlayingAList(deviceName: "Headphones")
        clock.advance(600)

        manager.outputDeviceDisconnected(uid: "uid-hdmi")
        manager.flushMessages()

        let single = sent.messages(ofType: "SET_TAB_DEVICE")
        #expect(single.count == 1)
        #expect(single.first?["deviceName"] as? String == "Headphones")
        #expect(sent.messages(ofType: "SET_TAB_DEVICES").isEmpty)
        #expect(tab(manager).deviceSelectionMode == .single)
        #expect(tab(manager).deviceName == "Headphones")
        #expect(tab(manager).deviceNames.isEmpty)
        #expect(tab(manager).multiSince == nil)
        // The ticks are kept, so flipping back by hand behaves as before.
        #expect(tab(manager).selectedDeviceUIDs == ["uid-speakers", "uid-hdmi"])
    }

    @Test("a short session for a tab that followed the default returns it to following the default")
    func shortSessionReturnsToTheDefault() {
        let (manager, sent, clock) = tabPlayingAList(deviceName: "")
        clock.advance(60)

        manager.outputDeviceDisconnected(uid: "uid-speakers")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "")
        #expect(tab(manager).deviceSelectionMode == .single)
        #expect((tab(manager).deviceName ?? "").isEmpty)
        #expect(tab(manager).deviceStatus == .defaultOutput)
    }

    @Test("a session just under an hour still restores the pre-Multi choice, an hour does not")
    func theWindowEdge() {
        let (under, underSent, underClock) = tabPlayingAList(deviceName: "Headphones")
        underClock.advance(MultiOutputRevert.rememberWindow - 1)
        under.outputDeviceDisconnected(uid: "uid-hdmi")
        under.flushMessages()
        #expect(underSent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "Headphones")

        let (over, overSent, overClock) = tabPlayingAList(deviceName: "Headphones")
        overClock.advance(MultiOutputRevert.rememberWindow)
        over.outputDeviceDisconnected(uid: "uid-hdmi")
        over.flushMessages()
        #expect(overSent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "")
    }

    @Test("a long session goes to System Audio and forgets the old single choice")
    func longSessionGoesToSystemAudio() {
        let (manager, sent, clock) = tabPlayingAList(deviceName: "Headphones")
        clock.advance(2 * MultiOutputRevert.rememberWindow)

        manager.outputDeviceDisconnected(uid: "uid-hdmi")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "")
        #expect(tab(manager).deviceSelectionMode == .single)
        #expect((tab(manager).deviceName ?? "").isEmpty, "the old choice must not come back later")
        #expect(tab(manager).deviceStatus == .defaultOutput)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-speakers", "uid-hdmi"])
    }

    @Test("a tab with no recorded start goes to System Audio")
    func noRecordedStartGoesToSystemAudio() {
        let (manager, sent) = makeManager(tabs: [
            tabJSON(deviceName: "Headphones", deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed"),
        ])

        manager.outputDeviceDisconnected(uid: "uid-hdmi")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "")
        #expect(tab(manager).deviceSelectionMode == .single)
        #expect((tab(manager).deviceName ?? "").isEmpty)
    }

    @Test("when the pre-Multi single choice is the device that dropped, it stays the choice")
    func theSingleChoiceThatDroppedStays() {
        let (manager, sent, clock) = tabPlayingAList(deviceName: "Headphones", uids: ["uid-headphones", "uid-hdmi"])
        clock.advance(60)

        manager.outputDeviceDisconnected(uid: "uid-headphones")
        manager.flushMessages()

        // The extension's own single-mode handling of a missing device takes it from here.
        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "Headphones")
        #expect(tab(manager).deviceName == "Headphones")
        #expect(tab(manager).deviceSelectionMode == .single)
    }

    @Test("a tab that was only seeded for Multi leaves it without sending anything in a short session")
    func seededTabShortSessionSendsNothing() {
        let (manager, sent, clock) = makeClockedManager(tabs: [tabJSON(deviceName: "Headphones")])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)  // seeded with the headphones, nothing plays on a list
        manager.flushMessages()
        sent.messages.removeAll()
        clock.advance(60)

        manager.outputDeviceDisconnected(uid: "uid-headphones")
        manager.flushMessages()

        #expect(sent.messages.isEmpty, "the tab never left its single device")
        #expect(tab(manager).deviceSelectionMode == .single)
        #expect(tab(manager).deviceName == "Headphones")
    }

    @Test("a seeded tab in a long session is moved to System Audio when it was on a specific device")
    func seededTabLongSessionClearsTheChoice() {
        let (manager, sent, clock) = makeClockedManager(tabs: [tabJSON(deviceName: "Headphones")])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.flushMessages()
        sent.messages.removeAll()
        clock.advance(MultiOutputRevert.rememberWindow + 1)

        manager.outputDeviceDisconnected(uid: "uid-headphones")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "")
        #expect((tab(manager).deviceName ?? "").isEmpty)
        #expect(tab(manager).deviceSelectionMode == .single)
    }

    @Test("a seeded tab that already followed the default needs no message in a long session")
    func seededDefaultTabLongSessionSendsNothing() {
        let (manager, sent, clock) = makeClockedManager(tabs: [tabJSON(deviceName: "")])
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)  // seeds the default, uid-speakers
        manager.flushMessages()
        sent.messages.removeAll()
        clock.advance(MultiOutputRevert.rememberWindow + 1)

        manager.outputDeviceDisconnected(uid: "uid-speakers")
        manager.flushMessages()

        #expect(sent.messages.isEmpty)
        #expect(tab(manager).deviceSelectionMode == .single)
    }

    @Test("nothing rejoins when the device returns, and flipping to Multi by hand uses the kept selection")
    func noRejoinAndManualFlipBack() {
        let (manager, sent, clock) = tabPlayingAList(deviceName: "Headphones")
        clock.advance(60)
        manager.outputDeviceDisconnected(uid: "uid-hdmi")
        manager.flushMessages()
        sent.messages.removeAll()

        manager.updateOutputDevices([speakers, headphones], defaultDeviceUID: "uid-speakers")  // the HDMI is gone
        manager.updateOutputDevices(allDevices, defaultDeviceUID: "uid-speakers")  // and back
        manager.flushMessages()
        #expect(sent.messages.isEmpty, "the returning device does not bring the list back")
        #expect(tab(manager).deviceSelectionMode == .single)

        clock.advance(30)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-speakers", "uid-hdmi"])
        #expect(tab(manager).multiSince == clock.now, "a fresh clock")
    }

    @Test("Multi to Single to Multi starts a fresh clock, so a long first session does not count")
    func freshClockAfterLeavingMulti() {
        let (manager, sent, clock) = tabPlayingAList(deviceName: "Headphones")
        clock.advance(2 * MultiOutputRevert.rememberWindow)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        manager.flushMessages()
        sent.messages.removeAll()
        clock.advance(60)

        manager.outputDeviceDisconnected(uid: "uid-hdmi")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "Headphones")
    }

    @Test("a device that is not in the tab's selection changes nothing")
    func unselectedDeviceChangesNothing() {
        let (manager, sent, clock) = tabPlayingAList(deviceName: "Headphones", uids: ["uid-speakers", "uid-hdmi"])
        clock.advance(60)

        manager.outputDeviceDisconnected(uid: "uid-headphones")
        manager.flushMessages()

        #expect(sent.messages.isEmpty)
        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).deviceNames == ["Speakers", "HDMI"])
        #expect(tab(manager).multiSince != nil)
    }

    @Test("a single-mode tab is not touched by the disconnect of a device left in its kept selection")
    func singleTabIsLeftAlone() {
        let (manager, sent, clock) = tabPlayingAList(deviceName: "Headphones")
        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()
        sent.messages.removeAll()
        clock.advance(60)

        manager.outputDeviceDisconnected(uid: "uid-hdmi")
        manager.flushMessages()

        #expect(sent.messages.isEmpty)
        #expect(tab(manager).deviceSelectionMode == .single)
    }

    @Test("only the tabs whose selection has the device go back to Single")
    func onlyAffectedTabsRevert() {
        let (manager, sent, clock) = makeClockedManager(tabs: [
            tabJSON(id: 1, deviceName: "Headphones"),
            tabJSON(id: 2, deviceName: "Headphones"),
        ])
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-hdmi"])
        manager.setTabDevices(tabId: 2, deviceUIDs: ["uid-speakers", "uid-headphones"])
        manager.flushMessages()
        sent.messages.removeAll()
        clock.advance(60)

        manager.outputDeviceDisconnected(uid: "uid-hdmi")
        manager.flushMessages()

        #expect(tab(manager, id: 1).deviceSelectionMode == .single)
        #expect(tab(manager, id: 2).deviceSelectionMode == .multi)
        let single = sent.messages(ofType: "SET_TAB_DEVICE")
        #expect(single.count == 1)
        #expect(single.first?["tabId"] as? Int == 1)
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-headphones"])
    }

    @Test("the multi-output devices are recomputed after the revert")
    func multiOutputsFollowTheRevert() {
        let (manager, _, clock) = tabPlayingAList(deviceName: "Headphones")
        #expect(manager.multiOutputDeviceUIDs == ["uid-speakers", "uid-hdmi"])
        clock.advance(60)

        manager.outputDeviceDisconnected(uid: "uid-hdmi")

        #expect(manager.multiOutputDeviceUIDs.isEmpty)
    }

    // MARK: - The pre-Multi single choice survives the one-output fallbacks

    // Without multi support in the extension, or while the engine plays the Chrome row on several outputs, a tab with
    // several ticks is pinned to its first tick, which overwrites `deviceName`. The revert must still go back to
    // what the tab was on before Multi, not to that first tick.

    @Test("without multi support, a short session restores the pre-Multi choice and not the first tick the fallback pinned")
    func fallbackPinDoesNotReplaceThePreMultiChoice() {
        let (manager, sent, clock) = makeClockedManager(tabs: [tabJSON(deviceName: "Speakers")], multiDevice: false)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-headphones", "uid-hdmi"])
        manager.flushMessages()
        #expect(tab(manager).deviceName == "Headphones", "the fallback pinned the first tick")
        sent.messages.removeAll()
        clock.advance(600)

        manager.outputDeviceDisconnected(uid: "uid-headphones")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "Speakers")
        #expect(tab(manager).deviceName == "Speakers")
        #expect(tab(manager).deviceSelectionMode == .single)
    }

    @Test("ticking straight from Single without multi support also keeps the pre-Multi choice")
    func tickingStraightFromSingleKeepsThePreMultiChoice() {
        let (manager, sent, clock) = makeClockedManager(tabs: [tabJSON(deviceName: "Speakers")], multiDevice: false)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-headphones", "uid-hdmi"])
        manager.flushMessages()
        sent.messages.removeAll()
        clock.advance(600)

        manager.outputDeviceDisconnected(uid: "uid-headphones")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "Speakers")
    }

    @Test("a tab that followed the default before Multi goes back to following it, not to the fallback's first tick")
    func fallbackPinDoesNotReplaceTheDefault() {
        let (manager, sent, clock) = makeClockedManager(tabs: [tabJSON(deviceName: "")], multiDevice: false)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-headphones", "uid-hdmi"])
        manager.flushMessages()
        sent.messages.removeAll()
        clock.advance(600)

        manager.outputDeviceDisconnected(uid: "uid-headphones")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "")
        #expect((tab(manager).deviceName ?? "").isEmpty)
    }

    @Test("while the engine fans Chrome out, a tab pulled to its first tick still goes back to its pre-Multi choice")
    func fanOutPinDoesNotReplaceThePreMultiChoice() {
        let (manager, sent, clock) = tabPlayingAList(deviceName: "Speakers", uids: ["uid-headphones", "uid-hdmi"])
        manager.setEngineFansOutChrome(true)
        manager.flushMessages()
        #expect(tab(manager).deviceName == "Headphones", "pulled to its first tick")
        sent.messages.removeAll()
        clock.advance(600)

        manager.outputDeviceDisconnected(uid: "uid-headphones")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "Speakers")
        #expect(tab(manager).deviceName == "Speakers")
    }

    // MARK: - Flipping back by hand uses the same choice as the revert

    @Test("a hand flip back to Single restores the pre-Multi choice the fallback pin had replaced")
    func handFlipRestoresThePreMultiChoice() {
        let (manager, sent, _) = makeClockedManager(tabs: [tabJSON(deviceName: "Speakers")], multiDevice: false)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-headphones", "uid-hdmi"])
        manager.flushMessages()
        #expect(tab(manager).deviceName == "Headphones", "the fallback pinned the first tick")
        #expect(tab(manager).deviceNames.isEmpty, "no list plays on this path")
        sent.messages.removeAll()

        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "Speakers")
        #expect(tab(manager).deviceName == "Speakers")
        #expect(tab(manager).deviceSelectionMode == .single)
        #expect(tab(manager).multiSince == nil)
        #expect(tab(manager).preMultiDeviceName == nil)
        #expect(tab(manager).selectedDeviceUIDs == ["uid-headphones", "uid-hdmi"], "the ticks are kept")
    }

    @Test("a hand flip back with a list playing restores the pre-Multi choice too")
    func handFlipWithAListRestoresThePreMultiChoice() {
        let (manager, sent, _) = tabPlayingAList(deviceName: "Speakers", uids: ["uid-headphones", "uid-hdmi"])
        #expect(!tab(manager).deviceNames.isEmpty)

        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "Speakers")
        #expect(sent.messages(ofType: "SET_TAB_DEVICES").isEmpty)
        #expect(tab(manager).deviceName == "Speakers")
        #expect(tab(manager).deviceNames.isEmpty)
    }

    @Test("a hand flip back for a tab that followed the default goes back to following it, not to the fallback's tick")
    func handFlipRestoresTheDefault() {
        let (manager, sent, _) = makeClockedManager(tabs: [tabJSON(deviceName: "")], multiDevice: false)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-headphones", "uid-hdmi"])
        manager.flushMessages()
        #expect(tab(manager).deviceName == "Headphones")
        sent.messages.removeAll()

        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "")
        #expect((tab(manager).deviceName ?? "").isEmpty)
        #expect(tab(manager).deviceStatus == .defaultOutput)
    }

    @Test("a hand flip back sends nothing when the tab is already on its pre-Multi choice and no list plays")
    func handFlipOnTheSameChoiceSendsNothing() {
        let (manager, sent, _) = makeClockedManager(tabs: [tabJSON(deviceName: "Speakers")], multiDevice: false)
        manager.setTabDeviceSelectionMode(tabId: 1, to: .multi)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers"])
        manager.flushMessages()
        #expect(tab(manager).deviceName == "Speakers")
        sent.messages.removeAll()

        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()

        #expect(sent.messages.isEmpty)
    }

    @Test("an adopted tab (start unknown) keeps its device name on a hand flip back")
    func handFlipOnAnAdoptedTabKeepsTheDeviceName() {
        let (manager, sent, _) = makeClockedManager(
            tabs: [tabJSON(deviceName: "Headphones", deviceNames: ["Speakers", "HDMI"])]
        )
        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).multiSince == nil, "adopted, not entered by hand")
        #expect(tab(manager).preMultiDeviceName == nil)

        manager.setTabDeviceSelectionMode(tabId: 1, to: .single)
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "Headphones")
        #expect(tab(manager).deviceName == "Headphones")
        #expect(tab(manager).deviceSelectionMode == .single)
    }

    @Test("each Multi session remembers the single choice it started from")
    func eachSessionRemembersItsOwnStart() {
        let (manager, sent, clock) = makeClockedManager(tabs: [tabJSON(deviceName: "Speakers")], multiDevice: false)
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-headphones", "uid-hdmi"])
        clock.advance(60)
        manager.outputDeviceDisconnected(uid: "uid-headphones")
        manager.flushMessages()
        #expect(tab(manager).deviceName == "Speakers")

        manager.setTabDevice(tabId: 1, deviceName: "HDMI")
        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-headphones"])
        manager.flushMessages()
        sent.messages.removeAll()
        clock.advance(60)

        manager.outputDeviceDisconnected(uid: "uid-headphones")
        manager.flushMessages()

        #expect(sent.messages(ofType: "SET_TAB_DEVICE").first?["deviceName"] as? String == "HDMI")
    }

    @Test("merge carries the pre-Multi choice from the existing tab")
    func mergeCarriesThePreMultiChoice() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var old = ChromeTab(id: 1, title: "Tab", volume: 1)
        old.deviceSelectionMode = .multi
        old.preMultiDeviceName = "Speakers"
        let fresh = ChromeTab(id: 1, title: "Tab", volume: 1)

        let merged = ChromeExtensionManager.merge(existing: [old], incoming: [fresh], pendingUntil: [:], now: now)

        #expect(merged[0].preMultiDeviceName == "Speakers")
    }

    // MARK: - A reverted tab is not pulled back into Multi by a stale list

    @Test("an extension that still reports the old list after the pending window does not pull a reverted tab back into Multi")
    func staleListIsNotReadopted() async {
        let (manager, _, clock) = tabPlayingAList(deviceName: "Headphones")
        clock.advance(60)
        manager.outputDeviceDisconnected(uid: "uid-hdmi")
        manager.flushMessages()
        #expect(tab(manager).deviceSelectionMode == .single)

        try? await Task.sleep(for: .milliseconds(1700))  // past the 1.5 s window in which local changes win
        let stale = tabJSON(deviceName: "Headphones", deviceNames: ["Speakers", "HDMI"], deviceStatus: "routed")
        manager.handleChromeMessageString(listString([stale]))
        #expect(tab(manager).deviceSelectionMode == .single, "the extension has not caught up yet")
        #expect(tab(manager).multiSince == nil)

        manager.handleChromeMessageString(listString([tabJSON(deviceName: "Headphones")]))
        #expect(tab(manager).deviceSelectionMode == .single, "the extension reports its single state")

        manager.handleChromeMessageString(listString([stale]))
        #expect(tab(manager).deviceSelectionMode == .multi, "once it has reported single, a list it plays is adopted again")
    }

    @Test("ticking devices again after a revert plays the new list even if the extension had not caught up")
    func tickingAgainEndsTheGuard() {
        let (manager, _, clock) = tabPlayingAList(deviceName: "Headphones")
        clock.advance(60)
        manager.outputDeviceDisconnected(uid: "uid-hdmi")
        manager.flushMessages()

        manager.setTabDevices(tabId: 1, deviceUIDs: ["uid-speakers", "uid-headphones"])

        #expect(tab(manager).deviceSelectionMode == .multi)
        #expect(tab(manager).deviceNames == ["Speakers", "Headphones"])
    }
}
