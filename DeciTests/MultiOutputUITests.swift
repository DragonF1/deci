// DeciTests/MultiOutputUITests.swift
// View-level piece of multi-output routing: when a device row's badge is lit.

import Testing
import Foundation
import AudioToolbox
@testable import Deci

@MainActor
@Suite("Multi-output device rows")
struct MultiOutputUITests {

    private let device = AudioDevice(id: AudioDeviceID(7), uid: "uid-row", name: "Row Device", icon: nil, supportsAutoEQ: false)

    private func deviceRow(isDefault: Bool, isInUse: Bool? = nil) -> DeviceRow {
        if let isInUse {
            return DeviceRow(
                device: device, isDefault: isDefault, isInUse: isInUse, volume: 1, isMuted: false,
                onSetDefault: {}, onVolumeChange: { _ in }, onMuteToggle: {}
            )
        }
        return DeviceRow(
            device: device, isDefault: isDefault, volume: 1, isMuted: false,
            onSetDefault: {}, onVolumeChange: { _ in }, onMuteToggle: {}
        )
    }

    @Test("The default device's badge is lit whether or not a multi route uses it")
    func defaultBadgeIsLit() {
        #expect(deviceRow(isDefault: true).isBadgeSelected)
        #expect(deviceRow(isDefault: true, isInUse: false).isBadgeSelected)
        #expect(deviceRow(isDefault: true, isInUse: true).isBadgeSelected)
    }

    @Test("A non-default device in use by a multi route has its badge lit")
    func inUseBadgeIsLit() {
        #expect(deviceRow(isDefault: false, isInUse: true).isBadgeSelected)
    }

    @Test("A device that is neither the default nor in use has its badge off")
    func idleBadgeIsOff() {
        #expect(!deviceRow(isDefault: false).isBadgeSelected)
        #expect(!deviceRow(isDefault: false, isInUse: false).isBadgeSelected)
    }

    @Test("Being in use does not make a device the default")
    func inUseIsNotDefault() {
        let row = deviceRow(isDefault: false, isInUse: true)
        #expect(!row.isDefault)
        #expect(row.isInUse)
    }
}
