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
        #expect(ChromeExtensionManager.multiOutputUIDs(tabs: [tab(1, names: pair, control: .page)], devices: allDevices).isEmpty)
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

    @Test("a stored list on a tab Chrome does not capture waits for a click, and an uncontrolled tab keeps its own caption")
    func captionNotCaptured() {
        #expect(ChromeTabRow.multiOutputNote(for: captionTab(control: .page), supportsMultiDevice: true) == .clickToUse)
        #expect(ChromeTabRow.multiOutputNote(for: captionTab(control: .armed), supportsMultiDevice: true) == .clickToUse)
        #expect(ChromeTabRow.multiOutputNote(for: captionTab(control: .none), supportsMultiDevice: true) == nil)
    }

    @Test("unreadable device names use the existing permission button, not a multi caption")
    func captionNoAccessIsLeftToTheButton() {
        #expect(ChromeTabRow.multiOutputNote(for: captionTab(status: .noAccess), supportsMultiDevice: true) == nil)
    }
}
