// DeciTests/VolumeStateSelectionTests.swift
// The selected-devices half of VolumeState: a selection is saved by default, and an in-memory
// update (a device going away) changes what the app sees without touching what is saved.

import Testing
import Foundation
@testable import Deci

@MainActor
@Suite("VolumeState selected devices")
struct VolumeStateSelectionTests {

    private func makeSettings() -> SettingsManager {
        SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test("A selection is kept in memory and saved by default")
    func savesByDefault() {
        let settings = makeSettings()
        let state = VolumeState(settingsManager: settings)

        state.setSelectedDeviceUIDs(for: 1, to: ["a", "b"], identifier: "com.deci.tests.App")

        #expect(state.getSelectedDeviceUIDs(for: 1) == ["a", "b"])
        #expect(settings.getSelectedDeviceUIDs(for: "com.deci.tests.App") == ["a", "b"])
    }

    @Test("An in-memory update leaves the saved selection alone")
    func inMemoryUpdateDoesNotSave() {
        let settings = makeSettings()
        let state = VolumeState(settingsManager: settings)
        state.setSelectedDeviceUIDs(for: 1, to: ["a", "b"], identifier: "com.deci.tests.App")

        state.setSelectedDeviceUIDs(for: 1, to: ["b"], identifier: nil, persist: false)

        #expect(state.getSelectedDeviceUIDs(for: 1) == ["b"])
        #expect(settings.getSelectedDeviceUIDs(for: "com.deci.tests.App") == ["a", "b"])
    }

    @Test("An in-memory update for an app with no state creates it without saving")
    func inMemoryUpdateWithoutStateDoesNotSave() {
        let settings = makeSettings()
        let state = VolumeState(settingsManager: settings)

        state.setSelectedDeviceUIDs(for: 1, to: ["a"], identifier: "com.deci.tests.App", persist: false)

        #expect(state.getSelectedDeviceUIDs(for: 1) == ["a"])
        #expect(settings.getSelectedDeviceUIDs(for: "com.deci.tests.App") == nil)
    }

    @Test("A later normal update saves again")
    func normalUpdateAfterInMemoryUpdateSaves() {
        let settings = makeSettings()
        let state = VolumeState(settingsManager: settings)
        state.setSelectedDeviceUIDs(for: 1, to: ["a", "b"], identifier: "com.deci.tests.App")
        state.setSelectedDeviceUIDs(for: 1, to: ["b"], identifier: nil, persist: false)

        state.setSelectedDeviceUIDs(for: 1, to: ["b", "c"], identifier: nil)

        #expect(settings.getSelectedDeviceUIDs(for: "com.deci.tests.App") == ["b", "c"])
    }
}
