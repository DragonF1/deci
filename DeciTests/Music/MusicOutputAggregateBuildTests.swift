// DeciTests/Music/MusicOutputAggregateBuildTests.swift
// How CoreAudioMusicOutputAggregates builds the aggregate the music plays into: the extra output latency that lines
// the sub-devices up, and the IO buffer size that keeps a Bluetooth sub-device from cutting out. The Core Audio calls
// are a fake, so nothing is created, nothing plays and the real device list is never read.

import AudioToolbox
import Foundation
import Testing
@testable import Deci

/// The Core Audio calls the builder makes, recorded in order.
@MainActor
final class FakeAggregateHardware: MusicAggregateHardware {
    enum Call: Equatable {
        case create
        case ready(AudioObjectID)
        case ioBuffer(AudioObjectID, anyBluetooth: Bool)
        case destroy(AudioObjectID)
    }

    static let aggregateID = AudioObjectID(777)

    var bluetoothUIDs: Set<String> = []
    /// What a user aggregate holds, by UID. Any other device is not an aggregate.
    var members: [String: [String]] = [:]
    var createStatus: OSStatus = noErr
    var becomesReady = true
    var ioBufferStatus: OSStatus = noErr
    private(set) var calls: [Call] = []
    private(set) var descriptions: [[String: Any]] = []

    func isBluetooth(deviceUID: String) -> Bool { bluetoothUIDs.contains(deviceUID) }

    func memberUIDs(ofAggregate deviceUID: String) -> [String]? { members[deviceUID] }

    func createAggregate(description: [String: Any]) -> (status: OSStatus, id: AudioObjectID) {
        calls.append(.create)
        descriptions.append(description)
        return createStatus == noErr ? (noErr, Self.aggregateID) : (createStatus, AudioObjectID(kAudioObjectUnknown))
    }

    func waitUntilReady(_ id: AudioObjectID) -> Bool {
        calls.append(.ready(id))
        return becomesReady
    }

    func setIOBufferFrames(_ id: AudioObjectID, anyBluetooth: Bool) -> (frames: UInt32, status: OSStatus) {
        calls.append(.ioBuffer(id, anyBluetooth: anyBluetooth))
        return (anyBluetooth ? 2048 : 1024, ioBufferStatus)
    }

    func destroyAggregate(_ id: AudioObjectID) -> OSStatus {
        calls.append(.destroy(id))
        return noErr
    }
}

@MainActor
@Suite("Music output aggregate build")
struct MusicOutputAggregateBuildTests {
    private let xm5 = OutputLatency(frames: 8961, sampleRate: 44_100)
    private let buds = OutputLatency(frames: 10_373, sampleRate: 44_100)

    private func builder(
        _ hardware: FakeAggregateHardware,
        latencies: [String: OutputLatency] = [:]
    ) -> CoreAudioMusicOutputAggregates {
        CoreAudioMusicOutputAggregates(hardware: hardware, latency: FakeOutputLatencyReader(table: latencies))
    }

    private func subDevices(_ hardware: FakeAggregateHardware) throws -> [[String: Any]] {
        let description = try #require(hardware.descriptions.last)
        return try #require(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
    }

    // MARK: Latency alignment

    @Test("the description the aggregate is made from delays the faster headset to the slower one")
    func descriptionCarriesTheAlignment() throws {
        let hardware = FakeAggregateHardware()
        hardware.bluetoothUIDs = ["xm5", "buds"]
        let made = builder(hardware, latencies: ["xm5": xm5, "buds": buds])
            .makeAggregate(for: MusicOutputStack(subDeviceUIDs: ["xm5", "buds"]))

        let entries = try subDevices(hardware)
        #expect(entries.map { $0[kAudioSubDeviceUIDKey] as? String } == ["xm5", "buds"])
        #expect(entries.map { $0[kAudioSubDeviceExtraOutputLatencyKey] as? UInt32 } == [1412, 0])
        #expect(entries.map { $0[kAudioSubDeviceDriftCompensationKey] as? Bool } == [false, true])
        let uid = try #require(hardware.descriptions.last?[kAudioAggregateDeviceUIDKey] as? String)
        #expect(made == MusicOutputAggregate(uid: uid, objectID: FakeAggregateHardware.aggregateID))
        #expect(uid.hasPrefix("\(MusicOutputStack.aggregateName)-"))
    }

    @Test("a device whose latency cannot be read leaves every sub-device undelayed")
    func unreadableLatencyDelaysNothing() throws {
        let hardware = FakeAggregateHardware()
        _ = builder(hardware, latencies: ["xm5": xm5])
            .makeAggregate(for: MusicOutputStack(subDeviceUIDs: ["xm5", "buds"]))

        let entries = try subDevices(hardware)
        #expect(entries.map { $0[kAudioSubDeviceExtraOutputLatencyKey] as? UInt32 } == [0, 0])
    }

    @Test("the alignment is worked out across the flattened devices, because a user aggregate is replaced by its own")
    func alignmentUsesTheFlattenedDevices() throws {
        let hardware = FakeAggregateHardware()
        hardware.members = ["agg": ["xm5", "buds"]]
        let wired = OutputLatency(frames: 512, sampleRate: 44_100)
        _ = builder(hardware, latencies: ["xm5": xm5, "buds": buds, "wired": wired])
            .makeAggregate(for: MusicOutputStack(subDeviceUIDs: ["agg", "wired"]))

        let entries = try subDevices(hardware)
        #expect(entries.map { $0[kAudioSubDeviceUIDKey] as? String } == ["xm5", "buds", "wired"])
        #expect(entries.map { $0[kAudioSubDeviceExtraOutputLatencyKey] as? UInt32 } == [1412, 0, 9861])
    }

    // MARK: IO buffer

    @Test("the IO buffer is sized once the aggregate is up, and before it is handed back")
    func ioBufferAfterReady() {
        let hardware = FakeAggregateHardware()
        hardware.bluetoothUIDs = ["buds"]
        let made = builder(hardware).makeAggregate(for: MusicOutputStack(subDeviceUIDs: ["wired", "buds"]))

        let id = FakeAggregateHardware.aggregateID
        #expect(hardware.calls == [.create, .ready(id), .ioBuffer(id, anyBluetooth: true)])
        #expect(made?.objectID == id)
    }

    @Test("with no Bluetooth device the IO buffer is sized for wired outputs")
    func ioBufferForWiredOutputs() {
        let hardware = FakeAggregateHardware()
        _ = builder(hardware).makeAggregate(for: MusicOutputStack(subDeviceUIDs: ["a", "b"]))
        #expect(hardware.calls.last == .ioBuffer(FakeAggregateHardware.aggregateID, anyBluetooth: false))
    }

    @Test("a Bluetooth device inside a user aggregate counts, so the buffer is sized for Bluetooth")
    func bluetoothInsideAUserAggregate() {
        let hardware = FakeAggregateHardware()
        hardware.members = ["agg": ["x", "y"]]
        hardware.bluetoothUIDs = ["y"]
        _ = builder(hardware).makeAggregate(for: MusicOutputStack(subDeviceUIDs: ["agg", "b"]))
        #expect(hardware.calls.last == .ioBuffer(FakeAggregateHardware.aggregateID, anyBluetooth: true))
    }

    @Test("a buffer size the HAL refuses leaves the aggregate in use")
    func refusedBufferSizeIsNotFatal() {
        let hardware = FakeAggregateHardware()
        hardware.ioBufferStatus = OSStatus(kAudioHardwareIllegalOperationError)
        let made = builder(hardware).makeAggregate(for: MusicOutputStack(subDeviceUIDs: ["a", "b"]))
        #expect(made?.objectID == FakeAggregateHardware.aggregateID)
        #expect(!hardware.calls.contains(.destroy(FakeAggregateHardware.aggregateID)))
    }

    // MARK: Failure

    @Test("an aggregate Core Audio refuses to make is not waited for or resized")
    func createFails() {
        let hardware = FakeAggregateHardware()
        hardware.createStatus = OSStatus(kAudioHardwareIllegalOperationError)
        let made = builder(hardware).makeAggregate(for: MusicOutputStack(subDeviceUIDs: ["a", "b"]))
        #expect(made == nil)
        #expect(hardware.calls == [.create])
    }

    @Test("an aggregate that does not come up is destroyed and never resized")
    func notReady() {
        let hardware = FakeAggregateHardware()
        hardware.becomesReady = false
        let made = builder(hardware).makeAggregate(for: MusicOutputStack(subDeviceUIDs: ["a", "b"]))
        let id = FakeAggregateHardware.aggregateID
        #expect(made == nil)
        #expect(hardware.calls == [.create, .ready(id), .destroy(id)])
    }

    @Test("destroying an aggregate hands its device to Core Audio")
    func destroy() {
        let hardware = FakeAggregateHardware()
        let aggregates = builder(hardware)
        let made = aggregates.makeAggregate(for: MusicOutputStack(subDeviceUIDs: ["a", "b"]))
        aggregates.destroy(made!)
        #expect(hardware.calls.last == .destroy(FakeAggregateHardware.aggregateID))
    }

    @Test("whether a device is Bluetooth is asked of the hardware")
    func bluetoothQuestion() {
        let hardware = FakeAggregateHardware()
        hardware.bluetoothUIDs = ["buds"]
        let aggregates = builder(hardware)
        #expect(aggregates.isBluetooth(deviceUID: "buds"))
        #expect(!aggregates.isBluetooth(deviceUID: "wired"))
    }
}
