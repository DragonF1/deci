// DeciTests/AudioProcessMonitorOwnProcessTests.swift
//
// The process monitor must never list a Deci process, whatever its PID: test hosts and dev builds play silence,
// which the watchdog reads as a stuck tap, and each rescue probe glitches shared Bluetooth output.

import Foundation
import Testing
@testable import Deci

@Suite("AudioProcessMonitor own-process filter")
struct AudioProcessMonitorOwnProcessTests {
    private let bundle = "com.abraham.Deci"

    @Test func ownPIDIsExcluded() {
        #expect(AudioProcessMonitor.isOwnProcess(pid: 10, bundleID: nil, ownPID: 10, ownBundleID: bundle))
    }

    @Test func otherPIDWithDeciBundleIsExcluded() {
        #expect(AudioProcessMonitor.isOwnProcess(pid: 71393, bundleID: bundle, ownPID: 10, ownBundleID: bundle))
    }

    @Test func otherAppIsKept() {
        #expect(!AudioProcessMonitor.isOwnProcess(pid: 5, bundleID: "com.hnc.Discord", ownPID: 10, ownBundleID: bundle))
    }

    @Test func nilBundleOnOtherPIDIsKept() {
        #expect(!AudioProcessMonitor.isOwnProcess(pid: 5, bundleID: nil, ownPID: 10, ownBundleID: bundle))
    }

    @Test func missingOwnBundleDoesNotMatchEverything() {
        #expect(!AudioProcessMonitor.isOwnProcess(pid: 5, bundleID: "x.y", ownPID: 10, ownBundleID: nil))
        #expect(!AudioProcessMonitor.isOwnProcess(pid: 5, bundleID: "", ownPID: 10, ownBundleID: ""))
    }

    @Test func similarBundleIDIsKept() {
        #expect(!AudioProcessMonitor.isOwnProcess(pid: 5, bundleID: "com.abraham.Deci.Helper", ownPID: 10, ownBundleID: bundle))
    }
}
