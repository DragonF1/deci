// DeciTests/TapIOBufferFramesTests.swift
//
// Tests ProcessTapController.ioBufferFrames(anyBluetooth:allowed:), the IO buffer size a tap
// aggregate asks for. The HAL default of 512 frames left Chrome's tap no slack under load, so
// its IO proc missed deadlines and crackled.

import Testing
@testable import Deci

@Suite struct TapIOBufferFramesTests {
    @Test func bluetoothGetsTheLargestBuffer() {
        #expect(ProcessTapController.ioBufferFrames(anyBluetooth: true, allowed: 15...4096) == 2048)
    }

    @Test func wiredOutputsKeepAddedLatencyNearTwentyMilliseconds() {
        #expect(ProcessTapController.ioBufferFrames(anyBluetooth: false, allowed: 15...4096) == 1024)
    }

    @Test func clampedToTheAggregateRange() {
        #expect(ProcessTapController.ioBufferFrames(anyBluetooth: true, allowed: 15...1024) == 1024)
        #expect(ProcessTapController.ioBufferFrames(anyBluetooth: false, allowed: 1536...4096) == 1536)
    }

    @Test func unreadableRangeAsksForTheWantedSize() {
        #expect(ProcessTapController.ioBufferFrames(anyBluetooth: true, allowed: nil) == 2048)
        #expect(ProcessTapController.ioBufferFrames(anyBluetooth: false, allowed: nil) == 1024)
    }
}
