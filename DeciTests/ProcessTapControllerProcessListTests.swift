// DeciTests/ProcessTapControllerProcessListTests.swift
//
// The parts of ProcessTapController that need no CoreAudio: the process list a tap is
// built around, and the volume accessor that now reads the engine's target.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import Deci

@Suite("ProcessTapController: process list and volume target (inactive controller)")
@MainActor
struct ProcessTapControllerProcessListTests {

    private func makeApp(ids: [AudioObjectID], name: String = "Chrome") -> AudioApp {
        AudioApp(
            id: 4242,
            processObjectIDs: ids,
            name: name,
            icon: NSImage(),
            bundleID: "com.google.Chrome",
            isHelperBacked: true
        )
    }

    private func makeController(ids: [AudioObjectID] = [10, 20]) -> ProcessTapController {
        ProcessTapController(app: makeApp(ids: ids), targetDeviceUID: "uid-test")
    }

    // MARK: updateProcesses before activation

    @Test("Before activation updateProcesses only stores the new app")
    func inactiveUpdateStoresApp() async throws {
        let tap = makeController(ids: [10, 20])

        try await tap.updateProcesses(makeApp(ids: [10, 20, 30]))

        #expect(tap.app.processObjectIDs == [10, 20, 30])
        #expect(tap.currentDeviceUIDs.isEmpty, "no device switch happens without an activated tap")
    }

    @Test("Before activation a shrunken list is stored too (nothing to rebuild)")
    func inactiveUpdateStoresShrunkList() async throws {
        let tap = makeController(ids: [10, 20, 30])

        try await tap.updateProcesses(makeApp(ids: [10]))

        #expect(tap.app.processObjectIDs == [10])
    }

    @Test("Before activation the last call wins")
    func inactiveUpdateLastWins() async throws {
        let tap = makeController(ids: [10])

        try await tap.updateProcesses(makeApp(ids: [10, 20]))
        try await tap.updateProcesses(makeApp(ids: [10, 20, 30], name: "Chrome Beta"))

        #expect(tap.app.processObjectIDs == [10, 20, 30])
        #expect(tap.app.name == "Chrome Beta")
    }

    @Test("Before activation an empty list is stored without crashing")
    func inactiveUpdateEmptyList() async throws {
        let tap = makeController(ids: [10])

        try await tap.updateProcesses(makeApp(ids: []))

        #expect(tap.app.processObjectIDs.isEmpty)
    }

    // MARK: volume accessor

    @Test("An idle controller reports the volume it was given")
    func idleVolumeRoundTrips() {
        let tap = makeController()

        #expect(tap.volume == 1.0)
        tap.volume = 0.25
        #expect(tap.volume == 0.25)
        tap.volume = 0
        #expect(tap.volume == 0)
        tap.volume = 4.0
        #expect(tap.volume == 4.0)
    }

    @Test("Invalidating a controller that was never activated leaves the volume alone")
    func invalidateInactiveKeepsVolume() {
        let tap = makeController()
        tap.volume = 0.6

        tap.invalidate()

        #expect(tap.volume == 0.6)
    }
}
