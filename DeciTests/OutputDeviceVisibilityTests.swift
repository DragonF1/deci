// DeciTests/OutputDeviceVisibilityTests.swift
// Which output devices the Mixer popup lists: hidden devices drop out, but the default stays and the list is never empty.

import AudioToolbox
import Foundation
import Testing
@testable import Deci

struct OutputDeviceVisibilityTests {
    private static func device(_ uid: String, id: UInt32) -> AudioDevice {
        AudioDevice(id: AudioDeviceID(id), uid: uid, name: "Device \(uid)", icon: nil, supportsAutoEQ: true)
    }

    private let sorted = [device("uid-a", id: 1), device("uid-b", id: 2), device("uid-c", id: 3)]

    @Test("hidden devices are left out, in priority order, but the default stays even when hidden")
    func hiddenDevicesAreLeftOut() {
        let hidden: Set<String> = ["uid-a", "uid-b"]
        let visible = OutputDeviceVisibility.visible(sorted: sorted, defaultUID: "uid-a") { hidden.contains($0) }
        #expect(visible.map(\.uid) == ["uid-a", "uid-c"])
    }

    @Test("nothing hidden lists every device")
    func nothingHidden() {
        let visible = OutputDeviceVisibility.visible(sorted: sorted, defaultUID: "uid-b") { _ in false }
        #expect(visible.map(\.uid) == ["uid-a", "uid-b", "uid-c"])
    }

    @Test("a filter that leaves nothing falls back to the whole list (default UID briefly nil during a switchover)")
    func neverEmpty() {
        let visible = OutputDeviceVisibility.visible(sorted: sorted, defaultUID: nil) { _ in true }
        #expect(visible.map(\.uid) == ["uid-a", "uid-b", "uid-c"])
    }
}
