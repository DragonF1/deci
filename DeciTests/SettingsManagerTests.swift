// FineTuneTests/SettingsManagerTests.swift
// Tests for SettingsManager.Settings JSON round-trip, merge algorithm, and pruning.
// Uses temp directories — no real settings files affected.

import Testing
import Foundation
import CoreGraphics
@testable import Deci

// MARK: - Settings JSON Round-Trip

@Suite("SettingsManager.Settings — JSON serialization")
@MainActor
struct SettingsJSONTests {

    @Test("Default Settings encodes and decodes to equal value")
    func defaultRoundTrip() throws {
        let original = SettingsManager.Settings()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == original.version)
        #expect(decoded.appVolumes == original.appVolumes)
        #expect(decoded.appMutes == original.appMutes)
        #expect(decoded.systemSoundsFollowsDefault == original.systemSoundsFollowsDefault)
    }

    @Test("Populated Settings round-trips all fields")
    func populatedRoundTrip() throws {
        var original = SettingsManager.Settings()
        original.appVolumes = ["com.test.app": 0.5]
        original.appMutes = ["com.test.app": true]
        original.appBoosts = ["com.test.app": 2.0]
        original.appDeviceRouting = ["com.test.app": "device-uid-123"]
        original.pinnedApps = Set(["com.test.app"])
        original.outputDevicePriority = ["uid-a", "uid-b", "uid-c"]
        original.ddcVolumes = ["monitor-1": 75]
        original.ddcMuteStates = ["monitor-1": false]
        original.autoEQPreampEnabled = false
        original.hiddenOutputDeviceUIDs = ["uid-hidden-out-1", "uid-hidden-out-2"]
        original.hiddenInputDeviceUIDs = ["uid-hidden-in-1"]
        original.deviceIconOverrides = ["uid-a": "airpodsmax", "uid-b": "gamecontroller.fill"]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.appVolumes == original.appVolumes)
        #expect(decoded.appMutes == original.appMutes)
        #expect(decoded.appBoosts == original.appBoosts)
        #expect(decoded.appDeviceRouting == original.appDeviceRouting)
        #expect(decoded.pinnedApps == original.pinnedApps)
        #expect(decoded.outputDevicePriority == original.outputDevicePriority)
        #expect(decoded.ddcVolumes == original.ddcVolumes)
        #expect(decoded.ddcMuteStates == original.ddcMuteStates)
        #expect(decoded.autoEQPreampEnabled == false)
        #expect(decoded.hiddenOutputDeviceUIDs == original.hiddenOutputDeviceUIDs)
        #expect(decoded.hiddenInputDeviceUIDs == original.hiddenInputDeviceUIDs)
        #expect(decoded.deviceIconOverrides == original.deviceIconOverrides)
    }

    @Test("Decoding empty JSON produces valid defaults")
    func emptyJSONDefaults() throws {
        let json = "{}"
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == 9)
        #expect(decoded.appVolumes.isEmpty)
        #expect(decoded.appMutes.isEmpty)
        #expect(decoded.systemSoundsFollowsDefault == true)
        #expect(decoded.autoEQPreampEnabled == true)
        #expect(decoded.hiddenOutputDeviceUIDs.isEmpty)
        #expect(decoded.hiddenInputDeviceUIDs.isEmpty)
        #expect(decoded.deviceIconOverrides.isEmpty)
    }

    @Test("Decoding with extra unknown keys is tolerated")
    func unknownKeysIgnored() throws {
        let json = """
        {"version": 9, "unknownField": "hello", "anotherNew": 42}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == 9)
    }

    @Test("Volume values above 1.0 are clamped to 1.0 on decode")
    func volumeClampedAboveOne() throws {
        let json = """
        {"appVolumes": {"com.test.app": 1.5, "com.other.app": 0.8}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appVolumes["com.test.app"] == 1.0)
        #expect(decoded.appVolumes["com.other.app"] == 0.8)
    }

    @Test("Negative volume values are filtered out on decode")
    func negativeVolumesFiltered() throws {
        let json = """
        {"appVolumes": {"com.test.app": -0.5, "com.good.app": 0.7}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appVolumes["com.test.app"] == nil, "Negative volume should be filtered out")
        #expect(decoded.appVolumes["com.good.app"] == 0.7)
    }

    @Test("Non-finite volume values cannot be encoded to JSON")
    func nonFiniteVolumesCannotEncode() throws {
        // JSON spec does not support NaN or Infinity.
        // JSONEncoder throws when encountering non-finite floats.
        // This verifies the boundary: production code's filter on decode handles
        // finite-but-invalid values (negative, >1.0); non-finite values are
        // prevented at the encoding layer.
        var settings = SettingsManager.Settings()
        settings.appVolumes["inf_app"] = Float.infinity

        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(settings)
        }
    }

    @Test("Invalid defaultNewAppVolume is reset to 1.0 on decode")
    func invalidDefaultVolumeReset() throws {
        // AppSettings uses auto-synthesized Codable — all keys required.
        // MenuBarIconStyle raw value is capitalized ("Default", not "default").
        let json = """
        {"appSettings": {"launchAtLogin": false, "menuBarIconStyle": "Default", "defaultNewAppVolume": -5.0, "lockInputDevice": true, "showDeviceDisconnectAlerts": true}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appSettings.defaultNewAppVolume == 1.0,
                "Negative defaultNewAppVolume should be reset to 1.0")
    }
}

// MARK: - mergePriorityOrder

@Suite("SettingsManager — mergePriorityOrder algorithm")
@MainActor
struct MergePriorityOrderTests {

    @Test("No disconnected devices: returns connectedOrder as-is")
    func noDisconnected() {
        let old = ["A", "B", "C"]
        let connected = ["C", "A", "B"] // user reordered
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        #expect(result == ["C", "A", "B"])
    }

    @Test("Disconnected device anchored between two connected devices")
    func disconnectedBetween() {
        let old = ["A", "D", "B"] // D is disconnected (not in connectedOrder)
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D was after A in old, so anchored to A. Result: A, D, B
        #expect(result == ["A", "D", "B"])
    }

    @Test("Disconnected device at the beginning (no preceding connected device)")
    func disconnectedAtStart() {
        let old = ["D", "A", "B"] // D is disconnected, before all connected
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D has nil anchor → inserted at front
        #expect(result == ["D", "A", "B"])
    }

    @Test("Multiple disconnected devices with same anchor")
    func multipleDisconnectedSameAnchor() {
        let old = ["A", "D1", "D2", "B"]
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        #expect(result == ["A", "D1", "D2", "B"])
    }

    @Test("All devices disconnected: returns disconnected in old order")
    func allDisconnected() {
        let old = ["A", "B", "C"]
        let connected: [String] = []
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // All disconnected, anchored to nil → inserted at front in order
        #expect(result == ["A", "B", "C"])
    }

    @Test("Empty old priority: returns connectedOrder")
    func emptyOldPriority() {
        let result = SettingsManager.mergePriorityOrder(oldPriority: [], connectedOrder: ["X", "Y"])
        #expect(result == ["X", "Y"])
    }

    @Test("Both empty: returns empty")
    func bothEmpty() {
        let result = SettingsManager.mergePriorityOrder(oldPriority: [], connectedOrder: [])
        #expect(result.isEmpty)
    }

    @Test("Reordering connected devices preserves disconnected anchors")
    func reorderPreservesAnchors() {
        let old = ["A", "D1", "B", "D2", "C"]
        let connected = ["C", "A", "B"] // user moved C to front
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D1 anchored to A, D2 anchored to B
        // Result: C, A, D1, B, D2
        #expect(result == ["C", "A", "D1", "B", "D2"])
    }

    @Test("Disconnected device at end (anchored to last connected)")
    func disconnectedAtEnd() {
        let old = ["A", "B", "D"]
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D anchored to B → after B
        #expect(result == ["A", "B", "D"])
    }
}

// MARK: - AppSettings Defaults

@Suite("AppSettings — Default values")
struct AppSettingsDefaultTests {

    @Test("Default AppSettings has expected values")
    func defaults() {
        let settings = AppSettings()
        #expect(settings.launchAtLogin == false)
        #expect(settings.menuBarIconStyle == .default)
        #expect(settings.defaultNewAppVolume == 1.0)
        #expect(settings.lockInputDevice == true)
        #expect(settings.showDeviceDisconnectAlerts == true)
    }

    @Test("loudnessEqualizationEnabled defaults to false")
    func loudnessEqualizationEnabledDefault() {
        let settings = AppSettings()
        #expect(settings.loudnessEqualizationEnabled == false)
    }

    @Test("loudnessEqualizationEnabled round-trips through JSON as true")
    func loudnessEqualizationEnabledRoundTrip() throws {
        var settings = AppSettings()
        settings.loudnessEqualizationEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.loudnessEqualizationEnabled == true)
    }

    @Test("Unified loudness toggle updates compensation and equalization together")
    func unifiedLoudnessToggleSetsBothFlags() {
        var settings = AppSettings()

        settings.setUnifiedLoudnessEnabled(true)
        #expect(settings.loudnessCompensationEnabled == true)
        #expect(settings.loudnessEqualizationEnabled == true)

        settings.setUnifiedLoudnessEnabled(false)
        #expect(settings.loudnessCompensationEnabled == false)
        #expect(settings.loudnessEqualizationEnabled == false)
    }

    @Test("loudnessEqualizationEnabled persists via SettingsManager")
    @MainActor
    func loudnessEqualizationEnabledPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let manager = SettingsManager(directory: tempDir)
        var newSettings = manager.appSettings
        newSettings.loudnessEqualizationEnabled = true
        manager.updateAppSettings(newSettings)
        #expect(manager.appSettings.loudnessEqualizationEnabled == true)
    }

    // MARK: Volume key bindings

    private func decodeAppSettings(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    /// One binding as a settings.json element: the modifier raw value is part of the file format.
    private func bindingJSON(combo: Int, percent: Int, id: UUID = UUID()) -> String {
        #"{"id": "\#(id.uuidString)", "combo": \#(combo), "percent": \#(percent)}"#
    }

    @Test("Volume key bindings default to plain 10%, Command 5% and Command+Shift 1%")
    func volumeKeyBindingDefaults() {
        let settings = AppSettings()
        #expect(settings.volumeKeyBindings.rows == defaultVolumeKeyRows)
        #expect(settings.volumeKeyBindings.rows == VolumeKeyBinding.defaults.rows)
    }

    @Test("Each AppSettings gets default rows with ids of its own, so no id outlives a reset")
    func volumeKeyBindingDefaultIDsAreFresh() {
        let first = AppSettings().volumeKeyBindings.map(\.id)
        let second = AppSettings().volumeKeyBindings.map(\.id)
        #expect(Set(first).count == 3)
        #expect(Set(first).isDisjoint(with: second))
    }

    @Test("A decode that falls back to the defaults hands out fresh ids each time")
    func fallbackDefaultsGetFreshIDs() throws {
        let first = try decodeAppSettings(#"{"volumeKeyBindings": []}"#).volumeKeyBindings.map(\.id)
        let second = try decodeAppSettings(#"{"volumeKeyBindings": []}"#).volumeKeyBindings.map(\.id)
        #expect(Set(first).isDisjoint(with: second))
    }

    @Test("sliderDelta(for:) turns the matched binding's percent into a slider fraction")
    func sliderDeltaFromBindings() throws {
        var settings = AppSettings()
        #expect(abs(try #require(settings.sliderDelta(for: [])) - 0.10) < 1e-12)
        #expect(abs(try #require(settings.sliderDelta(for: [.command])) - 0.05) < 1e-12)
        #expect(abs(try #require(settings.sliderDelta(for: [.command, .shift])) - 0.01) < 1e-12)

        settings.volumeKeyBindings[0].percent = 20
        settings.volumeKeyBindings[1].percent = 3
        settings.volumeKeyBindings[2].percent = 2
        #expect(abs(try #require(settings.sliderDelta(for: [])) - 0.20) < 1e-12)
        #expect(abs(try #require(settings.sliderDelta(for: [.command])) - 0.03) < 1e-12)
        #expect(abs(try #require(settings.sliderDelta(for: [.command, .shift])) - 0.02) < 1e-12)
    }

    @Test("sliderDelta(for:) is nil when no binding fits the held modifiers")
    func sliderDeltaNilWithoutMatch() {
        var settings = AppSettings()
        settings.volumeKeyBindings.removeFirst()  // the plain row
        #expect(settings.sliderDelta(for: []) == nil)
        #expect(settings.sliderDelta(for: [.shift]) == nil)
        #expect(settings.volumeKeyBinding(for: [.option]) == nil)
        #expect(settings.sliderDelta(for: [.command]) != nil)
    }

    @Test("sliderDelta(for:) clamps programmatic out-of-range values into 1...50", arguments: [
        (raw: 0, clamped: 1),
        (raw: -5, clamped: 1),
        (raw: 51, clamped: 50),
        (raw: 1_000, clamped: 50),
    ])
    func sliderDeltaClampsAssignedValues(_ c: (raw: Int, clamped: Int)) throws {
        var settings = AppSettings()
        for index in settings.volumeKeyBindings.indices { settings.volumeKeyBindings[index].percent = c.raw }
        for held in [VolumeKeyCombo([]), [.command], [.command, .shift]] {
            let delta = try #require(settings.sliderDelta(for: held))
            #expect(abs(delta - Double(c.clamped) / 100) < 1e-12)
        }
    }

    @Test("The arrow-key step is the empty-combo row's, and 10% when no row fits")
    func arrowKeySliderDelta() {
        var settings = AppSettings()
        #expect(abs(settings.arrowKeySliderDelta - 0.10) < 1e-12)

        settings.volumeKeyBindings[0].percent = 20
        #expect(abs(settings.arrowKeySliderDelta - 0.20) < 1e-12)

        settings.volumeKeyBindings = [VolumeKeyBinding(combo: [.command], percent: 5)]
        #expect(abs(settings.arrowKeySliderDelta - 0.10) < 1e-12)  // the plain row is gone, so the fallback
    }

    @Test("Volume key bindings round-trip through JSON, ids included")
    func volumeKeyBindingsRoundTrip() throws {
        var settings = AppSettings()
        settings.volumeKeyBindings = [
            VolumeKeyBinding(combo: [.option], percent: 25),
            VolumeKeyBinding(combo: [.control, .shift], percent: 3),
            VolumeKeyBinding(combo: [], percent: 12),
        ]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.volumeKeyBindings == settings.volumeKeyBindings)
    }

    @Test("Missing volume key bindings decode to the defaults")
    func volumeKeyBindingsMissingKeyDefaults() throws {
        let decoded = try decodeAppSettings("{}")
        #expect(decoded.volumeKeyBindings.rows == defaultVolumeKeyRows)
    }

    @Test("An empty bindings array decodes to the defaults, even beside legacy keys")
    func emptyBindingsArrayGivesDefaults() throws {
        #expect(try decodeAppSettings(#"{"volumeKeyBindings": []}"#).volumeKeyBindings.rows == defaultVolumeKeyRows)
        let withLegacy = try decodeAppSettings(#"{"volumeKeyBindings": [], "volumeStepPercent": 30}"#)
        #expect(withLegacy.volumeKeyBindings.rows == defaultVolumeKeyRows)
    }

    @Test("A bindings array in the file is used as written, in order")
    func volumeKeyBindingsDecodeNewKey() throws {
        let id = UUID()
        let json = "{\"volumeKeyBindings\": [\(bindingJSON(combo: 4, percent: 7, id: id)), \(bindingJSON(combo: 0, percent: 15))]}"
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.rows == [VolumeKeyRow([.option], 7), VolumeKeyRow([], 15)])
        #expect(decoded.volumeKeyBindings.first?.id == id)
    }

    @Test("When the bindings key is present the legacy step keys are ignored")
    func newKeyWinsOverLegacyKeys() throws {
        let json = "{\"volumeKeyBindings\": [\(bindingJSON(combo: 0, percent: 4))], \"volumeStepPercent\": 30, \"volumeStepCommandPercent\": 20}"
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.rows == [VolumeKeyRow([], 4)])
    }

    @Test("Out-of-range binding percents clamp into 1...50 on decode", arguments: [
        (raw: 0, clamped: 1),
        (raw: -7, clamped: 1),
        (raw: 1, clamped: 1),
        (raw: 50, clamped: 50),
        (raw: 51, clamped: 50),
        (raw: 99, clamped: 50),
    ])
    func bindingPercentClampsOnDecode(_ c: (raw: Int, clamped: Int)) throws {
        let json = "{\"volumeKeyBindings\": [\(bindingJSON(combo: 0, percent: c.raw)), \(bindingJSON(combo: 1, percent: c.raw))]}"
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.map(\.percent) == [c.clamped, c.clamped])
    }

    @Test("A later row with the same modifiers as an earlier one is dropped")
    func duplicateCombosDropLaterRows() throws {
        let json = "{\"volumeKeyBindings\": [\(bindingJSON(combo: 1, percent: 5)), \(bindingJSON(combo: 1, percent: 9)), "
            + "\(bindingJSON(combo: 0, percent: 3)), \(bindingJSON(combo: 1, percent: 7))]}"
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.rows == [VolumeKeyRow([.command], 5), VolumeKeyRow([], 3)])
    }

    @Test("A row that repeats an earlier row's id keeps its place and gets a fresh id")
    func repeatedIDsAreRenewed() throws {
        let id = UUID()
        let json = "{\"volumeKeyBindings\": [\(bindingJSON(combo: 0, percent: 5, id: id)), \(bindingJSON(combo: 1, percent: 9, id: id))]}"
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.rows == [VolumeKeyRow([], 5), VolumeKeyRow([.command], 9)])
        #expect(decoded.volumeKeyBindings[0].id == id)
        #expect(decoded.volumeKeyBindings[1].id != id)
    }

    @Test("More than eight rows are cut to the first eight, after duplicates are dropped")
    func bindingsCapAtEight() throws {
        // combo 0 appears twice; 10 distinct combos follow in total (0...9).
        let combos = [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        let json = "{\"volumeKeyBindings\": [" + combos.map { bindingJSON(combo: $0, percent: 5) }.joined(separator: ", ") + "]}"
        let decoded = try decodeAppSettings(json)
        #expect(VolumeKeyBinding.maxCount == 8)
        #expect(decoded.volumeKeyBindings.map(\.combo.rawValue) == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    @Test("Modifier bits this build does not know are dropped on decode")
    func unknownModifierBitsDropped() throws {
        let decoded = try decodeAppSettings("{\"volumeKeyBindings\": [\(bindingJSON(combo: 255, percent: 5))]}")
        #expect(decoded.volumeKeyBindings.first?.combo == [.command, .shift, .option, .control])
    }

    @Test("A malformed bindings value falls back to the defaults and keeps every other setting", arguments: [
        "7.5", #""loud""#, "true", "null", "[10]", #"{"a": 1}"#, #"[{"combo": 1}]"#, #"[{"id": "not-a-uuid", "combo": 1, "percent": 5}]"#,
    ])
    func malformedBindingsFallBack(raw: String) throws {
        let decoded = try decodeAppSettings(#"{"launchAtLogin": true, "volumeKeyBindings": \#(raw)}"#)
        #expect(decoded.launchAtLogin == true)
        #expect(decoded.volumeKeyBindings.rows == defaultVolumeKeyRows)
    }

    @Test("One bad element drops only that row; the rows around it load", arguments: [
        #"{"combo": 1}"#,
        #"{"id": "not-a-uuid", "combo": 1, "percent": 5}"#,
        #"{"id": "9F2C4E1A-0000-4000-8000-000000000001", "combo": "loud", "percent": 5}"#,
        #"{"id": "9F2C4E1A-0000-4000-8000-000000000001", "combo": 1, "percent": "ten"}"#,
        #"{"id": "9F2C4E1A-0000-4000-8000-000000000001", "combo": 1, "percent": 7.5}"#,
        "7", #""loud""#, "null", "[]", "{}",
    ])
    func badElementDropsOnlyThatRow(bad: String) throws {
        let id = UUID()
        let json = "{\"volumeKeyBindings\": [\(bindingJSON(combo: 4, percent: 7, id: id)), \(bad), \(bindingJSON(combo: 0, percent: 15))]}"
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.rows == [VolumeKeyRow([.option], 7), VolumeKeyRow([], 15)])
        #expect(decoded.volumeKeyBindings.first?.id == id)
    }

    @Test("A bad element beside a good one ignores the legacy keys, which only migrate when no row survives")
    func badElementKeepsSurvivorsOverLegacyKeys() throws {
        let json = "{\"volumeKeyBindings\": [{\"combo\": 1}, \(bindingJSON(combo: 0, percent: 4))], \"volumeStepPercent\": 30}"
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.rows == [VolumeKeyRow([], 4)])
    }

    @Test("When every element is bad the legacy keys migrate, as for any unreadable value")
    func allBadElementsFallToLegacyKeys() throws {
        let json = #"{"volumeKeyBindings": [{"combo": 1}, 7], "volumeStepPercent": 30}"#
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.rows == [
            VolumeKeyRow([], 30), VolumeKeyRow([.command], 5), VolumeKeyRow([.command, .shift], 1),
        ])
    }

    @Test("Surviving rows still lose duplicate combos and clamp their percent")
    func survivorsAreStillCleaned() throws {
        let json = "{\"volumeKeyBindings\": [\(bindingJSON(combo: 1, percent: 99)), {\"combo\": 2}, "
            + "\(bindingJSON(combo: 1, percent: 9)), \(bindingJSON(combo: 0, percent: 0))]}"
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.rows == [VolumeKeyRow([.command], 50), VolumeKeyRow([], 1)])
    }

    @Test("Bad elements among more than the cap still cut the survivors at the cap")
    func survivorsCutAtCap() throws {
        let good = (0..<10).map { bindingJSON(combo: $0, percent: 5) }
        let json = "{\"volumeKeyBindings\": [{\"combo\": 1}, " + good.joined(separator: ", ") + "]}"
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.count == VolumeKeyBinding.maxCount)
        #expect(decoded.volumeKeyBindings.map(\.combo.rawValue) == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    @Test("A hand-edited bindings value does not reset the rest of the settings file")
    func malformedBindingsKeepWholeFile() throws {
        let json = Data(
            #"{"appVolumes": {"com.test.app": 0.5}, "appSettings": {"volumeKeyBindings": 7.5, "launchAtLogin": true}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: json)
        #expect(decoded.appVolumes == ["com.test.app": 0.5])
        #expect(decoded.appSettings.launchAtLogin == true)
        #expect(decoded.appSettings.volumeKeyBindings.rows == defaultVolumeKeyRows)
    }

    // MARK: Legacy step keys

    @Test("A file with the three legacy step keys becomes plain, Command and Command+Shift rows")
    func legacyKeysMigrate() throws {
        let json = #"{"volumeStepPercent": 20, "volumeStepCommandPercent": 3, "volumeStepCommandShiftPercent": 2}"#
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.rows == [
            VolumeKeyRow([], 20), VolumeKeyRow([.command], 3), VolumeKeyRow([.command, .shift], 2),
        ])
    }

    @Test("A file with only some legacy keys keeps those and defaults the rest")
    func legacyPartialKeys() throws {
        let decoded = try decodeAppSettings(#"{"volumeStepCommandPercent": 8}"#)
        #expect(decoded.volumeKeyBindings.rows == [
            VolumeKeyRow([], 10), VolumeKeyRow([.command], 8), VolumeKeyRow([.command, .shift], 1),
        ])
    }

    @Test("Out-of-range legacy steps clamp into 1...50 while migrating", arguments: [
        (raw: 0, clamped: 1),
        (raw: -7, clamped: 1),
        (raw: 50, clamped: 50),
        (raw: 99, clamped: 50),
    ])
    func legacyClamps(_ c: (raw: Int, clamped: Int)) throws {
        let json = #"{"volumeStepPercent": \#(c.raw), "volumeStepCommandPercent": \#(c.raw), "volumeStepCommandShiftPercent": \#(c.raw)}"#
        let decoded = try decodeAppSettings(json)
        #expect(decoded.volumeKeyBindings.map(\.percent) == [c.clamped, c.clamped, c.clamped])
    }

    @Test("A malformed legacy step falls back to its own default and keeps its neighbours", arguments: [
        "7.5", #""loud""#, "true", "null", "[10]", #"{"a": 1}"#,
    ])
    func malformedLegacyStepFallsBack(raw: String) throws {
        let json = #"{"launchAtLogin": true, "volumeStepPercent": \#(raw), "volumeStepCommandPercent": 8, "volumeStepCommandShiftPercent": \#(raw)}"#
        let decoded = try decodeAppSettings(json)
        #expect(decoded.launchAtLogin == true)
        #expect(decoded.volumeKeyBindings.rows == [
            VolumeKeyRow([], 10), VolumeKeyRow([.command], 8), VolumeKeyRow([.command, .shift], 1),
        ])
    }

    @Test("A malformed bindings value beside legacy keys migrates the legacy keys")
    func malformedBindingsFallToLegacyKeys() throws {
        let decoded = try decodeAppSettings(#"{"volumeKeyBindings": "loud", "volumeStepPercent": 30}"#)
        #expect(decoded.volumeKeyBindings.rows == [
            VolumeKeyRow([], 30), VolumeKeyRow([.command], 5), VolumeKeyRow([.command, .shift], 1),
        ])
    }

    @Test("The legacy volumeHotkeyStep key is ignored, not migrated and not an error", arguments: [
        "coarse", "normal", "fine", "extraFine", "something-from-the-future",
    ])
    func legacyVolumeHotkeyStepIgnored(legacy: String) throws {
        let decoded = try decodeAppSettings(#"{"volumeHotkeyStep": "\#(legacy)", "launchAtLogin": true}"#)
        #expect(decoded.launchAtLogin == true)  // the rest of the file still loads
        #expect(decoded.volumeKeyBindings.rows == defaultVolumeKeyRows)
    }

    @Test("Encoding writes only the bindings key, as id, modifier raw value and percent")
    func volumeKeyBindingsEncodedKeys() throws {
        let data = try JSONEncoder().encode(AppSettings())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["volumeHotkeyStep"] == nil)
        #expect(object["volumeStepPercent"] == nil)
        #expect(object["volumeStepCommandPercent"] == nil)
        #expect(object["volumeStepCommandShiftPercent"] == nil)

        let rows = try #require(object["volumeKeyBindings"] as? [[String: Any]])
        #expect(rows.count == 3)
        #expect(rows.map { $0["combo"] as? Int } == [0, 1, 3])
        #expect(rows.map { $0["percent"] as? Int } == [10, 5, 1])
        #expect(rows.allSatisfy { UUID(uuidString: $0["id"] as? String ?? "") != nil })
    }

    @Test("resetAllSettings puts the volume key bindings back to the defaults")
    @MainActor
    func volumeKeyBindingsResetAll() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manager = SettingsManager(directory: tempDir)
        var changed = manager.appSettings
        changed.volumeKeyBindings = [
            VolumeKeyBinding(combo: [.option], percent: 30),
            VolumeKeyBinding(combo: [.control], percent: 4),
        ]
        manager.updateAppSettings(changed)
        #expect(manager.appSettings.volumeKeyBindings.count == 2)

        manager.resetAllSettings()

        #expect(manager.appSettings.volumeKeyBindings.rows == defaultVolumeKeyRows)
    }

    @Test("resetAllSettings hands out new row ids each time, so an old recording id matches nothing")
    @MainActor
    func volumeKeyBindingsResetAllFreshIDs() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manager = SettingsManager(directory: tempDir)
        manager.resetAllSettings()
        let first = manager.appSettings.volumeKeyBindings.map(\.id)

        manager.resetAllSettings()
        let second = manager.appSettings.volumeKeyBindings.map(\.id)

        #expect(first.count == 3)
        #expect(Set(first).isDisjoint(with: second))
    }

}

// MARK: - Volume Key Bindings

/// A binding without its id, so a test can compare the rows a decode produced with the rows it expects.
struct VolumeKeyRow: Equatable {
    let combo: VolumeKeyCombo
    let percent: Int

    init(_ combo: VolumeKeyCombo, _ percent: Int) {
        self.combo = combo
        self.percent = percent
    }
}

extension Array where Element == VolumeKeyBinding {
    var rows: [VolumeKeyRow] { map { VolumeKeyRow($0.combo, $0.percent) } }
}

let defaultVolumeKeyRows = [VolumeKeyRow([], 10), VolumeKeyRow([.command], 5), VolumeKeyRow([.command, .shift], 1)]

@Suite("VolumeKeyCombo: flags mapping and label")
struct VolumeKeyComboTests {

    @Test("init(flags:) maps each modifier flag and ignores the rest", arguments: [
        (flags: CGEventFlags([]),                               expected: VolumeKeyCombo([])),
        (flags: CGEventFlags([.maskCommand]),                   expected: VolumeKeyCombo([.command])),
        (flags: CGEventFlags([.maskShift]),                     expected: VolumeKeyCombo([.shift])),
        (flags: CGEventFlags([.maskAlternate]),                 expected: VolumeKeyCombo([.option])),
        (flags: CGEventFlags([.maskControl]),                   expected: VolumeKeyCombo([.control])),
        (flags: CGEventFlags([.maskCommand, .maskShift]),       expected: VolumeKeyCombo([.command, .shift])),
        (flags: CGEventFlags([.maskCommand, .maskShift, .maskAlternate, .maskControl]),
         expected: VolumeKeyCombo([.command, .shift, .option, .control])),
        (flags: CGEventFlags([.maskAlphaShift, .maskSecondaryFn, .maskNumericPad, .maskHelp]),
         expected: VolumeKeyCombo([])),  // Caps Lock, fn, arrow-pad and help are not modifiers a binding can name
        (flags: CGEventFlags([.maskShift, .maskSecondaryFn]),   expected: VolumeKeyCombo([.shift])),
    ])
    func flagsMapping(_ c: (flags: CGEventFlags, expected: VolumeKeyCombo)) {
        #expect(VolumeKeyCombo(flags: c.flags) == c.expected)
    }

    @Test("The four modifiers have distinct raw values")
    func rawValuesAreDistinct() {
        let all: [VolumeKeyCombo] = [.command, .shift, .option, .control]
        #expect(Set(all.map(\.rawValue)).count == 4)
        #expect(VolumeKeyCombo.all == [.command, .shift, .option, .control])
    }

    @Test("Labels list the modifier symbols in macOS order, control option shift command", arguments: [
        (combo: VolumeKeyCombo([]),                         label: "F11 / F12"),
        (combo: VolumeKeyCombo([.command]),                 label: "\u{2318} F11 / F12"),
        (combo: VolumeKeyCombo([.shift]),                   label: "\u{21E7} F11 / F12"),
        (combo: VolumeKeyCombo([.option]),                  label: "\u{2325} F11 / F12"),
        (combo: VolumeKeyCombo([.control]),                 label: "\u{2303} F11 / F12"),
        (combo: VolumeKeyCombo([.command, .shift]),         label: "\u{21E7}\u{2318} F11 / F12"),
        (combo: VolumeKeyCombo([.shift, .command]),         label: "\u{21E7}\u{2318} F11 / F12"),  // set order is irrelevant
        (combo: VolumeKeyCombo([.option, .control]),        label: "\u{2303}\u{2325} F11 / F12"),
        (combo: VolumeKeyCombo([.command, .shift, .option, .control]),
         label: "\u{2303}\u{2325}\u{21E7}\u{2318} F11 / F12"),
    ])
    func labels(_ c: (combo: VolumeKeyCombo, label: String)) {
        #expect(c.combo.label == c.label)
    }

    @Test("modifierCount counts the modifiers in the set", arguments: [
        (combo: VolumeKeyCombo([]), count: 0),
        (combo: VolumeKeyCombo([.option]), count: 1),
        (combo: VolumeKeyCombo([.command, .shift]), count: 2),
        (combo: VolumeKeyCombo([.command, .shift, .option, .control]), count: 4),
    ])
    func modifierCount(_ c: (combo: VolumeKeyCombo, count: Int)) {
        #expect(c.combo.modifierCount == c.count)
    }
}

@Suite("VolumeKeyBinding: range, defaults and matching")
struct VolumeKeyBindingTests {

    @Test("The allowed percent range is 1...50 and at most eight rows exist")
    func limits() {
        #expect(VolumeKeyBinding.percentRange == 1...50)
        #expect(VolumeKeyBinding.maxCount == 8)
    }

    @Test("clampedPercent pulls values into the range", arguments: [
        (raw: Int.min, clamped: 1), (raw: -1, clamped: 1), (raw: 0, clamped: 1), (raw: 1, clamped: 1),
        (raw: 25, clamped: 25), (raw: 50, clamped: 50), (raw: 51, clamped: 50), (raw: Int.max, clamped: 50),
    ])
    func clampedPercent(_ c: (raw: Int, clamped: Int)) {
        #expect(VolumeKeyBinding.clampedPercent(c.raw) == c.clamped)
    }

    @Test("The defaults are plain 10%, Command 5% and Command+Shift 1%, each with its own id")
    func defaults() {
        let defaults = VolumeKeyBinding.defaults
        #expect(defaults.rows == defaultVolumeKeyRows)
        #expect(Set(defaults.map(\.id)).count == 3)
        for binding in defaults {
            #expect(VolumeKeyBinding.percentRange.contains(binding.percent))
        }
    }

    @Test("Every call to defaults makes new ids, so a reset never reuses a row id")
    func defaultsAreFreshPerCall() {
        let first = VolumeKeyBinding.defaults
        let second = VolumeKeyBinding.defaults
        #expect(first.rows == second.rows)
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    }

    @Test("A new binding gets a fresh id")
    func freshIDs() {
        let a = VolumeKeyBinding(combo: [.option], percent: 5)
        let b = VolumeKeyBinding(combo: [.option], percent: 5)
        #expect(a.id != b.id)
        #expect(a != b)
    }

    // MARK: Matching

    private func percent(_ bindings: [VolumeKeyBinding], _ held: VolumeKeyCombo) -> Int? {
        bindings.binding(matching: held)?.percent
    }

    @Test("The default rows reproduce today's chords, and Shift, Option and Control alone fall to plain", arguments: [
        (held: VolumeKeyCombo([]),                                          percent: 10),
        (held: VolumeKeyCombo([.shift]),                                    percent: 10),
        (held: VolumeKeyCombo([.option]),                                   percent: 10),
        (held: VolumeKeyCombo([.control]),                                  percent: 10),
        (held: VolumeKeyCombo([.shift, .option]),                           percent: 10),
        (held: VolumeKeyCombo([.shift, .option, .control]),                 percent: 10),
        (held: VolumeKeyCombo([.command]),                                  percent: 5),
        (held: VolumeKeyCombo([.command, .option]),                         percent: 5),
        (held: VolumeKeyCombo([.command, .control]),                        percent: 5),
        (held: VolumeKeyCombo([.command, .shift]),                          percent: 1),
        (held: VolumeKeyCombo([.command, .shift, .option]),                 percent: 1),
        (held: VolumeKeyCombo([.command, .shift, .option, .control]),       percent: 1),
    ])
    func defaultsMatchToday(_ c: (held: VolumeKeyCombo, percent: Int)) {
        #expect(percent(VolumeKeyBinding.defaults, c.held) == c.percent)
    }

    @Test("The row with the most modifiers inside the held set wins")
    func mostModifiersWins() {
        let bindings = [
            VolumeKeyBinding(combo: [], percent: 10),
            VolumeKeyBinding(combo: [.command], percent: 5),
            VolumeKeyBinding(combo: [.command, .option], percent: 2),
        ]
        #expect(percent(bindings, [.command, .option]) == 2)
        #expect(percent(bindings, [.command, .option, .shift]) == 2)
        #expect(percent(bindings, [.command, .shift]) == 5)
        #expect(percent(bindings, [.option]) == 10)  // the Command+Option row needs Command too
    }

    @Test("Row order does not change which row has the most modifiers")
    func orderDoesNotBeatSpecificity() {
        let bindings = [
            VolumeKeyBinding(combo: [.command, .shift], percent: 1),
            VolumeKeyBinding(combo: [.command], percent: 5),
            VolumeKeyBinding(combo: [], percent: 10),
        ]
        #expect(percent(bindings, [.command, .shift]) == 1)
        #expect(percent(bindings, [.command]) == 5)
        #expect(percent(bindings, []) == 10)
    }

    @Test("A tie in modifier count goes to the earlier row")
    func tieGoesToEarlierRow() {
        let optionFirst = [VolumeKeyBinding(combo: [.option], percent: 2), VolumeKeyBinding(combo: [.control], percent: 3)]
        #expect(percent(optionFirst, [.option, .control]) == 2)
        let controlFirst = [VolumeKeyBinding(combo: [.control], percent: 3), VolumeKeyBinding(combo: [.option], percent: 2)]
        #expect(percent(controlFirst, [.option, .control]) == 3)
        // Only one of them fits when only one is held.
        #expect(percent(optionFirst, [.control]) == 3)
    }

    @Test("No row matches when none is a subset of the held modifiers")
    func noMatchWithoutSubset() {
        let withoutPlain = [
            VolumeKeyBinding(combo: [.command], percent: 5),
            VolumeKeyBinding(combo: [.option], percent: 2),
        ]
        #expect(withoutPlain.binding(matching: []) == nil)
        #expect(withoutPlain.binding(matching: [.shift]) == nil)
        #expect(withoutPlain.binding(matching: [.control, .shift]) == nil)
        #expect(percent(withoutPlain, [.command, .shift]) == 5)
        #expect([VolumeKeyBinding]().binding(matching: []) == nil)
    }

    @Test("A rebound plain row stops matching a bare key press")
    func reboundPlainRow() {
        var bindings = VolumeKeyBinding.defaults
        bindings[0].combo = [.option]
        #expect(percent(bindings, []) == nil)
        #expect(percent(bindings, [.shift]) == nil)
        #expect(percent(bindings, [.option]) == 10)
    }

    @Test("Matching returns the row itself, with its id")
    func matchReturnsTheRow() {
        let row = VolumeKeyBinding(combo: [.control], percent: 9)
        let bindings = [VolumeKeyBinding(combo: [.command], percent: 5), row]
        #expect(bindings.binding(matching: [.control, .shift]) == row)
    }

    // MARK: Adding a row

    @Test("The Add button's row takes the first unused combo, fewest modifiers first, at 5%")
    func unusedBindingPicksFirstFreeCombo() throws {
        let defaults = VolumeKeyBinding.defaults
        let fromDefaults = try #require(defaults.unusedBinding())
        #expect(fromDefaults.combo == [.shift])
        #expect(fromDefaults.percent == 5)
        #expect(!defaults.contains { $0.id == fromDefaults.id })

        let withoutPlain = Array(defaults.dropFirst())
        #expect(withoutPlain.unusedBinding()?.combo == [])  // a removed plain row comes back first

        #expect([VolumeKeyBinding]().unusedBinding()?.combo == [])
    }

    @Test("Adding rows one after another never repeats a combo, and stops at the cap")
    func unusedBindingFillsToTheCap() {
        var bindings = VolumeKeyBinding.defaults
        while let next = bindings.unusedBinding() {
            #expect(!bindings.contains { $0.combo == next.combo })
            bindings.append(next)
        }
        #expect(bindings.count == VolumeKeyBinding.maxCount)
        #expect(Set(bindings.map(\.combo)).count == VolumeKeyBinding.maxCount)
        #expect(bindings.unusedBinding() == nil)
    }
}

// MARK: - Hidden Devices

@Suite("SettingsManager — hidden device UIDs")
@MainActor
struct SettingsManagerHiddenDevicesTests {

    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("hideOutputDevice / unhideOutputDevice / isOutputDeviceHidden round-trip")
    func outputHideUnhideParity() {
        let m = makeManager()
        let uid = "uid-output-1"

        #expect(m.isOutputDeviceHidden(uid) == false)
        m.hideOutputDevice(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == true)
        #expect(m.hiddenOutputDeviceUIDs.contains(uid))
        m.unhideOutputDevice(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == false)
        #expect(m.hiddenOutputDeviceUIDs.contains(uid) == false)
    }

    @Test("hideInputDevice / unhideInputDevice / isInputDeviceHidden round-trip")
    func inputHideUnhideParity() {
        let m = makeManager()
        let uid = "uid-input-1"

        #expect(m.isInputDeviceHidden(uid) == false)
        m.hideInputDevice(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == true)
        m.unhideInputDevice(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == false)
    }

    @Test("toggleOutputDeviceHidden flips based on persisted state")
    func toggleOutputFlipsFromPersisted() {
        let m = makeManager()
        let uid = "uid-output-2"

        m.toggleOutputDeviceHidden(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == true)
        m.toggleOutputDeviceHidden(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == false)
    }

    @Test("toggleInputDeviceHidden flips based on persisted state")
    func toggleInputFlipsFromPersisted() {
        let m = makeManager()
        let uid = "uid-input-2"

        m.toggleInputDeviceHidden(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == true)
        m.toggleInputDeviceHidden(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == false)
    }

    @Test("Hidden output and input sets are independent")
    func outputAndInputSetsIndependent() {
        let m = makeManager()
        m.hideOutputDevice(uid: "shared-uid")
        #expect(m.isOutputDeviceHidden("shared-uid") == true)
        #expect(m.isInputDeviceHidden("shared-uid") == false)
    }
}

// MARK: - Device Icon Override API

@Suite("SettingsManager — deviceIconOverrides API")
@MainActor
struct DeviceIconOverrideTests {
    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("get/set round-trip for a single UID")
    func setAndGet() {
        let manager = makeManager()
        #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)

        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")

        manager.setDeviceIconOverride(for: "uid-a", to: "gamecontroller.fill")
        #expect(manager.getDeviceIconOverride(for: "uid-a") == "gamecontroller.fill")
    }

    @Test("Passing nil clears the override")
    func clearOverride() {
        let manager = makeManager()
        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")

        manager.setDeviceIconOverride(for: "uid-a", to: nil)
        #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)
    }

    @Test("Overrides for different UIDs are independent")
    func independentPerUID() {
        let manager = makeManager()
        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        manager.setDeviceIconOverride(for: "uid-b", to: "gamecontroller.fill")

        #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")
        #expect(manager.getDeviceIconOverride(for: "uid-b") == "gamecontroller.fill")
        #expect(manager.deviceIconOverrides == ["uid-a": "airpodsmax", "uid-b": "gamecontroller.fill"])
    }

    @Test("resetAllSettings clears all overrides")
    func resetClearsOverrides() {
        let manager = makeManager()
        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        manager.setDeviceIconOverride(for: "uid-b", to: "gamecontroller.fill")

        manager.resetAllSettings()

        #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)
        #expect(manager.getDeviceIconOverride(for: "uid-b") == nil)
        #expect(manager.deviceIconOverrides.isEmpty)
    }
}

// MARK: - MenuBarIconStyle

@Suite("MenuBarIconStyle — Enumeration")
struct MenuBarIconStyleTests {

    @Test("allCases has 5 styles")
    func allCasesCount() {
        #expect(MenuBarIconStyle.allCases.count == 5)
    }

    @Test("Only 'default' is not a system symbol")
    func defaultNotSystemSymbol() {
        #expect(!MenuBarIconStyle.default.isSystemSymbol)
        #expect(MenuBarIconStyle.speaker.isSystemSymbol)
        #expect(MenuBarIconStyle.device.isSystemSymbol)
        #expect(MenuBarIconStyle.waveform.isSystemSymbol)
        #expect(MenuBarIconStyle.equalizer.isSystemSymbol)
    }

    @Test("Every style has a non-empty icon name")
    func allHaveIconNames() {
        for style in MenuBarIconStyle.allCases {
            #expect(!style.iconName.isEmpty, "Style \(style.rawValue) has empty icon name")
        }
    }

    @Test("Round-trip through JSON Codable")
    func codableRoundTrip() throws {
        for style in MenuBarIconStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(MenuBarIconStyle.self, from: data)
            #expect(decoded == style)
        }
    }
}

// MARK: - Multi-output start times

@Suite("SettingsManager multi-output since")
@MainActor
struct SettingsManagerMultiOutputSinceTests {

    private let id = "com.deci.tests.App"
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test("The start-time map round-trips through JSON")
    func mapRoundTrips() throws {
        var original = SettingsManager.Settings()
        original.appMultiOutputSince = ["com.test.app": Date(timeIntervalSince1970: 1_700_000_000)]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.appMultiOutputSince == original.appMultiOutputSince)
    }

    @Test("A file written before the feature decodes to an empty map")
    func olderFilesDecodeEmpty() throws {
        let json = #"{"version": 12, "appDeviceSelectionMode": {"com.test.app": "multi"}}"#
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
        #expect(decoded.appMultiOutputSince.isEmpty)
        #expect(decoded.appDeviceSelectionMode["com.test.app"] == .multi)
    }

    @Test("Entering Multi records the time, and an unknown identifier has none")
    func enteringMultiRecordsTheTime() {
        let manager = SettingsManager(directory: makeDirectory())
        #expect(manager.getMultiOutputSince(for: id) == nil)

        manager.setDeviceSelectionMode(for: id, to: .multi, at: t0)

        #expect(manager.getMultiOutputSince(for: id) == t0)
        #expect(manager.getDeviceSelectionMode(for: id) == .multi)
    }

    @Test("Setting Multi again keeps the first start time")
    func repeatedMultiKeepsTheClock() {
        let manager = SettingsManager(directory: makeDirectory())
        manager.setDeviceSelectionMode(for: id, to: .multi, at: t0)

        manager.setDeviceSelectionMode(for: id, to: .multi, at: t0.addingTimeInterval(500))

        #expect(manager.getMultiOutputSince(for: id) == t0)
    }

    @Test("Leaving Multi clears the time, and Multi to Single to Multi starts a fresh clock")
    func leavingMultiClearsAndReentryRestarts() {
        let manager = SettingsManager(directory: makeDirectory())
        manager.setDeviceSelectionMode(for: id, to: .multi, at: t0)

        manager.setDeviceSelectionMode(for: id, to: .single, at: t0.addingTimeInterval(100))
        #expect(manager.getMultiOutputSince(for: id) == nil)

        manager.setDeviceSelectionMode(for: id, to: .multi, at: t0.addingTimeInterval(7200))
        #expect(manager.getMultiOutputSince(for: id) == t0.addingTimeInterval(7200))
    }

    @Test("Going to Single from no recorded mode records nothing")
    func singleFromNothingRecordsNothing() {
        let manager = SettingsManager(directory: makeDirectory())
        manager.setDeviceSelectionMode(for: id, to: .single, at: t0)
        #expect(manager.getMultiOutputSince(for: id) == nil)
    }

    @Test("The default time is now")
    func defaultTimeIsNow() {
        let manager = SettingsManager(directory: makeDirectory())
        let before = Date()
        manager.setDeviceSelectionMode(for: id, to: .multi)
        let since = manager.getMultiOutputSince(for: id)
        #expect(since != nil)
        #expect((since ?? .distantPast) >= before)
        #expect((since ?? .distantFuture) <= Date())
    }

    @Test("setMultiOutputSince writes and removes a time")
    func explicitSetter() {
        let manager = SettingsManager(directory: makeDirectory())
        manager.setMultiOutputSince(t0, for: id)
        #expect(manager.getMultiOutputSince(for: id) == t0)
        manager.setMultiOutputSince(nil, for: id)
        #expect(manager.getMultiOutputSince(for: id) == nil)
    }

    @Test("The start times survive a relaunch")
    func survivesRelaunch() {
        let dir = makeDirectory()
        let first = SettingsManager(directory: dir)
        first.setDeviceSelectionMode(for: id, to: .multi, at: t0)
        first.flushSync()

        let second = SettingsManager(directory: dir)

        #expect(second.getMultiOutputSince(for: id) == t0)
        #expect(second.getDeviceSelectionMode(for: id) == .multi)
    }

    @Test("Hiding an app drops its start time")
    func ignoreAppClearsTheTime() {
        let manager = SettingsManager(directory: makeDirectory())
        manager.setDeviceSelectionMode(for: id, to: .multi, at: t0)

        manager.ignoreApp(id, info: IgnoredAppInfo(persistenceIdentifier: id, displayName: "App", bundleID: id))

        #expect(manager.getMultiOutputSince(for: id) == nil)
    }

    @Test("Resetting all settings drops every start time")
    func resetClearsTheTimes() {
        let manager = SettingsManager(directory: makeDirectory())
        manager.setDeviceSelectionMode(for: id, to: .multi, at: t0)
        manager.setDeviceSelectionMode(for: "com.deci.tests.Other", to: .multi, at: t0)

        manager.resetAllSettings()

        #expect(manager.getMultiOutputSince(for: id) == nil)
        #expect(manager.getMultiOutputSince(for: "com.deci.tests.Other") == nil)
    }

    @Test("A time with no selection mode behind it is pruned with the stale app")
    func pruneDropsOrphanTimes() {
        let manager = SettingsManager(directory: makeDirectory())
        manager.setMultiOutputSince(t0, for: id)

        manager.pruneStaleSettings(keeping: [])

        #expect(manager.getMultiOutputSince(for: id) == nil)
    }

    @Test("A Multi app keeps its time through pruning")
    func pruneKeepsMultiApps() {
        let manager = SettingsManager(directory: makeDirectory())
        manager.setDeviceSelectionMode(for: id, to: .multi, at: t0)

        manager.pruneStaleSettings(keeping: [])

        #expect(manager.getMultiOutputSince(for: id) == t0)
    }

    @Test("multiOutputIdentifiers lists only Multi items that have the device selected")
    func identifiersContainingADevice() {
        let manager = SettingsManager(directory: makeDirectory())
        manager.setDeviceSelectionMode(for: "a", to: .multi, at: t0)
        manager.setSelectedDeviceUIDs(for: "a", to: ["uid-1", "uid-2"])
        manager.setDeviceSelectionMode(for: "b", to: .multi, at: t0)
        manager.setSelectedDeviceUIDs(for: "b", to: ["uid-2"])
        manager.setDeviceSelectionMode(for: "c", to: .single, at: t0)
        manager.setSelectedDeviceUIDs(for: "c", to: ["uid-1"])
        manager.setSelectedDeviceUIDs(for: "d", to: ["uid-1"])  // no mode recorded

        #expect(Set(manager.multiOutputIdentifiers(containing: "uid-1")) == ["a"])
        #expect(Set(manager.multiOutputIdentifiers(containing: "uid-2")) == ["a", "b"])
        #expect(manager.multiOutputIdentifiers(containing: "uid-9").isEmpty)
    }
}
