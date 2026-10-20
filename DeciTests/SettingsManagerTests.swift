// FineTuneTests/SettingsManagerTests.swift
// Tests for SettingsManager.Settings JSON round-trip, merge algorithm, and pruning.
// Uses temp directories — no real settings files affected.

import Testing
import Foundation
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

    @Test("Volume key steps default to 10% / 5% / 1%")
    func volumeStepDefaults() {
        let settings = AppSettings()
        #expect(settings.volumeStepPercent == 10)
        #expect(settings.volumeStepCommandPercent == 5)
        #expect(settings.volumeStepCommandShiftPercent == 1)
    }

    @Test("stepPercent(for:) and sliderDelta(for:) map each chord to its own field")
    func volumeStepHelpers() {
        var settings = AppSettings()
        #expect(settings.stepPercent(for: .plain) == 10)
        #expect(settings.stepPercent(for: .command) == 5)
        #expect(settings.stepPercent(for: .commandShift) == 1)
        #expect(abs(settings.sliderDelta(for: .plain) - 0.10) < 1e-12)
        #expect(abs(settings.sliderDelta(for: .command) - 0.05) < 1e-12)
        #expect(abs(settings.sliderDelta(for: .commandShift) - 0.01) < 1e-12)

        settings.volumeStepPercent = 20
        settings.volumeStepCommandPercent = 3
        settings.volumeStepCommandShiftPercent = 2
        #expect(settings.stepPercent(for: .plain) == 20)
        #expect(settings.stepPercent(for: .command) == 3)
        #expect(settings.stepPercent(for: .commandShift) == 2)
        #expect(abs(settings.sliderDelta(for: .plain) - 0.20) < 1e-12)
        #expect(abs(settings.sliderDelta(for: .command) - 0.03) < 1e-12)
        #expect(abs(settings.sliderDelta(for: .commandShift) - 0.02) < 1e-12)
    }

    @Test("Volume key steps round-trip through JSON")
    func volumeStepRoundTrip() throws {
        var settings = AppSettings()
        settings.volumeStepPercent = 25
        settings.volumeStepCommandPercent = 12
        settings.volumeStepCommandShiftPercent = 3
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.volumeStepPercent == 25)
        #expect(decoded.volumeStepCommandPercent == 12)
        #expect(decoded.volumeStepCommandShiftPercent == 3)
    }

    @Test("Missing volume step keys decode to the defaults")
    func volumeStepMissingKeysDefault() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded.volumeStepPercent == 10)
        #expect(decoded.volumeStepCommandPercent == 5)
        #expect(decoded.volumeStepCommandShiftPercent == 1)
    }

    @Test("A file with only some volume step keys keeps those and defaults the rest")
    func volumeStepPartialKeys() throws {
        let json = Data(#"{"volumeStepCommandPercent": 8}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.volumeStepPercent == 10)
        #expect(decoded.volumeStepCommandPercent == 8)
        #expect(decoded.volumeStepCommandShiftPercent == 1)
    }

    @Test("Out-of-range volume steps clamp into 1...50 on decode", arguments: [
        (raw: 0, clamped: 1),
        (raw: -7, clamped: 1),
        (raw: 1, clamped: 1),
        (raw: 50, clamped: 50),
        (raw: 51, clamped: 50),
        (raw: 99, clamped: 50),
    ])
    func volumeStepClampsOnDecode(_ c: (raw: Int, clamped: Int)) throws {
        let json = Data(
            #"{"volumeStepPercent": \#(c.raw), "volumeStepCommandPercent": \#(c.raw), "volumeStepCommandShiftPercent": \#(c.raw)}"#.utf8
        )
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.volumeStepPercent == c.clamped)
        #expect(decoded.volumeStepCommandPercent == c.clamped)
        #expect(decoded.volumeStepCommandShiftPercent == c.clamped)
    }

    @Test("stepPercent(for:) clamps programmatic out-of-range values into 1...50", arguments: [
        (raw: 0, clamped: 1),
        (raw: -5, clamped: 1),
        (raw: 51, clamped: 50),
        (raw: 1_000, clamped: 50),
    ])
    func stepPercentClampsAssignedValues(_ c: (raw: Int, clamped: Int)) {
        var settings = AppSettings()
        settings.volumeStepPercent = c.raw
        settings.volumeStepCommandPercent = c.raw
        settings.volumeStepCommandShiftPercent = c.raw
        for chord in VolumeStepChord.allCases {
            #expect(settings.stepPercent(for: chord) == c.clamped)
            #expect(abs(settings.sliderDelta(for: chord) - Double(c.clamped) / 100) < 1e-12)
        }
    }

    @Test("A malformed volume step falls back to its default and keeps every other setting", arguments: [
        "7.5", #""loud""#, "true", "null", "[10]", #"{"a": 1}"#,
    ])
    func malformedVolumeStepFallsBack(raw: String) throws {
        let json = Data(
            #"{"launchAtLogin": true, "volumeStepPercent": \#(raw), "volumeStepCommandPercent": 8, "volumeStepCommandShiftPercent": \#(raw)}"#.utf8
        )
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.launchAtLogin == true)
        #expect(decoded.volumeStepPercent == 10)
        #expect(decoded.volumeStepCommandPercent == 8)  // the well-formed neighbour survives
        #expect(decoded.volumeStepCommandShiftPercent == 1)
    }

    @Test("A hand-edited volume step does not reset the rest of the settings file")
    func malformedVolumeStepKeepsWholeFile() throws {
        let json = Data(
            #"{"appVolumes": {"com.test.app": 0.5}, "appSettings": {"volumeStepPercent": 7.5, "launchAtLogin": true}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: json)
        #expect(decoded.appVolumes == ["com.test.app": 0.5])
        #expect(decoded.appSettings.launchAtLogin == true)
        #expect(decoded.appSettings.volumeStepPercent == 10)
    }

    @Test("The legacy volumeHotkeyStep key is ignored, not migrated and not an error", arguments: [
        "coarse", "normal", "fine", "extraFine", "something-from-the-future",
    ])
    func legacyVolumeHotkeyStepIgnored(legacy: String) throws {
        let json = Data(#"{"volumeHotkeyStep": "\#(legacy)", "launchAtLogin": true}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.launchAtLogin == true)  // the rest of the file still loads
        #expect(decoded.volumeStepPercent == 10)
        #expect(decoded.volumeStepCommandPercent == 5)
        #expect(decoded.volumeStepCommandShiftPercent == 1)
    }

    @Test("Encoding writes the three step keys and no longer writes volumeHotkeyStep")
    func volumeStepEncodedKeys() throws {
        let data = try JSONEncoder().encode(AppSettings())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["volumeHotkeyStep"] == nil)
        #expect(object["volumeStepPercent"] as? Int == 10)
        #expect(object["volumeStepCommandPercent"] as? Int == 5)
        #expect(object["volumeStepCommandShiftPercent"] as? Int == 1)
    }

    @Test("resetAllSettings puts the volume steps back to the defaults")
    @MainActor
    func volumeStepResetAll() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manager = SettingsManager(directory: tempDir)
        var changed = manager.appSettings
        changed.volumeStepPercent = 30
        changed.volumeStepCommandPercent = 15
        changed.volumeStepCommandShiftPercent = 4
        manager.updateAppSettings(changed)
        #expect(manager.appSettings.volumeStepPercent == 30)

        manager.resetAllSettings()

        #expect(manager.appSettings.volumeStepPercent == 10)
        #expect(manager.appSettings.volumeStepCommandPercent == 5)
        #expect(manager.appSettings.volumeStepCommandShiftPercent == 1)
    }

}

// MARK: - Volume Step Chords

@Suite("VolumeStepChord: modifier mapping and metadata")
struct VolumeStepChordTests {

    @Test("from(command:shift:) maps every flag combination", arguments: [
        (command: false, shift: false, expected: VolumeStepChord.plain),
        (command: false, shift: true,  expected: VolumeStepChord.plain),  // Shift alone keeps the plain step
        (command: true,  shift: false, expected: VolumeStepChord.command),
        (command: true,  shift: true,  expected: VolumeStepChord.commandShift),
    ])
    func chordFromFlags(_ c: (command: Bool, shift: Bool, expected: VolumeStepChord)) {
        #expect(VolumeStepChord.from(command: c.command, shift: c.shift) == c.expected)
    }

    @Test("Default percents are 10 / 5 / 1")
    func defaultPercents() {
        #expect(VolumeStepChord.plain.defaultPercent == 10)
        #expect(VolumeStepChord.command.defaultPercent == 5)
        #expect(VolumeStepChord.commandShift.defaultPercent == 1)
    }

    @Test("The allowed percent range is 1...50")
    func percentRange() {
        #expect(VolumeStepChord.percentRange == 1...50)
        for chord in VolumeStepChord.allCases {
            #expect(VolumeStepChord.percentRange.contains(chord.defaultPercent))
        }
    }

    @Test("clampedPercent pulls values into the range", arguments: [
        (raw: Int.min, clamped: 1), (raw: -1, clamped: 1), (raw: 0, clamped: 1), (raw: 1, clamped: 1),
        (raw: 25, clamped: 25), (raw: 50, clamped: 50), (raw: 51, clamped: 50), (raw: Int.max, clamped: 50),
    ])
    func clampedPercent(_ c: (raw: Int, clamped: Int)) {
        #expect(VolumeStepChord.clampedPercent(c.raw) == c.clamped)
    }

    @Test("Labels name the key chord")
    func labels() {
        #expect(VolumeStepChord.plain.label == "F11 / F12")
        #expect(VolumeStepChord.command.label == "\u{2318} F11 / F12")
        #expect(VolumeStepChord.commandShift.label == "\u{2318}\u{21E7} F11 / F12")
    }

    @Test("Cases are ordered plain, command, commandShift with unique ids")
    func casesAndIDs() {
        #expect(VolumeStepChord.allCases == [.plain, .command, .commandShift])
        #expect(Set(VolumeStepChord.allCases.map(\.id)).count == 3)
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
