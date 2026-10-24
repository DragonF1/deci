// Deci/Music/Playback/MusicOutputAggregate.swift
import AudioToolbox
import Foundation
import os

/// A private aggregate device the player is pointed at, made by `MusicOutputAggregating`.
struct MusicOutputAggregate: Equatable {
    let uid: String
    let objectID: AudioObjectID
}

/// The sub-devices of the stacked aggregate that mirrors the music to several outputs.
nonisolated struct MusicOutputStack: Equatable {
    /// The aggregate's name. The "Deci-" start is what keeps `AudioDeviceMonitor` from listing it as an output, so
    /// making and destroying it never reads as a device coming or going.
    static let aggregateName = "Deci-Music"

    /// Every sub-device, the clock device first, the others in sorted UID order.
    let subDeviceUIDs: [String]

    var clockDeviceUID: String { subDeviceUIDs[0] }

    /// The stack for these devices. The clock is the first one that is not Bluetooth (a built-in or HDMI output keeps
    /// steadier time), else the first in sorted UID order; the others follow in sorted order and are drift compensated
    /// to it. nil: a stack needs two devices.
    static func plan(for deviceUIDs: Set<String>, isBluetooth: (String) -> Bool) -> MusicOutputStack? {
        guard deviceUIDs.count >= 2 else { return nil }
        let sorted = deviceUIDs.sorted()
        let clock = sorted.first { !isBluetooth($0) } ?? sorted[0]
        return MusicOutputStack(subDeviceUIDs: [clock] + sorted.filter { $0 != clock })
    }

    /// The same stack with every aggregate in it swapped for its own devices: an aggregate cannot hold another one (the
    /// outer one would report no output channels). `expand` gives an aggregate's devices and nil for any other device.
    /// A device that would appear twice stays where it first was.
    func flattened(expand: (String) -> [String]?) -> MusicOutputStack {
        var seen = Set<String>()
        var flat: [String] = []
        for uid in subDeviceUIDs {
            let members = expand(uid).flatMap { $0.isEmpty ? nil : $0 } ?? [uid]
            for member in members where seen.insert(member).inserted {
                flat.append(member)
            }
        }
        return MusicOutputStack(subDeviceUIDs: flat)
    }

    /// The Core Audio description of a private stacked aggregate. Stacked mirrors the one stream to every sub-device.
    /// `extraOutputLatencyFrames` is how many frames of output latency each device is given (0 when it is not in the
    /// table), so that the devices sound together.
    func description(name: String, uid: String, extraOutputLatencyFrames: [String: UInt32] = [:]) -> [String: Any] {
        // The clock device needs no drift compensation; every other device is kept in step with it.
        let subDevices = AggregateSubDeviceList.entries(uids: subDeviceUIDs, extraOutputLatencyFrames: extraOutputLatencyFrames)
        return [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices
        ]
    }
}

/// Makes and destroys the aggregate the music player outputs into when it plays on several devices. A protocol so the
/// mixer can be tested without touching Core Audio.
@MainActor
protocol MusicOutputAggregating: AnyObject {
    /// Whether the device is on a Bluetooth link, which makes a poor clock for the other devices to follow.
    func isBluetooth(deviceUID: String) -> Bool
    /// Builds the aggregate for `stack`. nil when Core Audio refused it or it did not come up.
    func makeAggregate(for stack: MusicOutputStack) -> MusicOutputAggregate?
    func destroy(_ aggregate: MusicOutputAggregate)
}

/// The Core Audio calls behind the real aggregates. A protocol so the building of an aggregate can be tested without
/// creating one.
@MainActor
protocol MusicAggregateHardware: AnyObject {
    func isBluetooth(deviceUID: String) -> Bool
    /// The devices inside a user aggregate, nil for any other device.
    func memberUIDs(ofAggregate deviceUID: String) -> [String]?
    /// Makes the aggregate and tracks it for crash cleanup when it was made.
    func createAggregate(description: [String: Any]) -> (status: OSStatus, id: AudioObjectID)
    func waitUntilReady(_ id: AudioObjectID) -> Bool
    /// Sets the IO buffer size for the aggregate, and says what was asked for and what the HAL answered.
    func setIOBufferFrames(_ id: AudioObjectID, anyBluetooth: Bool) -> (frames: UInt32, status: OSStatus)
    func destroyAggregate(_ id: AudioObjectID) -> OSStatus
}

/// The real aggregates, made through Core Audio. Each one is tracked by `CrashGuard`, so a crash does not leave it
/// behind in the system's device list.
@MainActor
final class CoreAudioMusicOutputAggregates: MusicOutputAggregating {
    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicOutputAggregates")

    private let hardware: any MusicAggregateHardware
    private let latency: any OutputLatencyReading

    init(
        hardware: any MusicAggregateHardware = CoreAudioMusicAggregateHardware(),
        latency: any OutputLatencyReading = CoreAudioOutputLatencyReader()
    ) {
        self.hardware = hardware
        self.latency = latency
    }

    func isBluetooth(deviceUID: String) -> Bool {
        hardware.isBluetooth(deviceUID: deviceUID)
    }

    func makeAggregate(for stack: MusicOutputStack) -> MusicOutputAggregate? {
        let flat = stack.flattened { hardware.memberUIDs(ofAggregate: $0) }
        let uid = "\(MusicOutputStack.aggregateName)-\(UUID().uuidString)"
        // Bluetooth headsets differ in link delay and the HAL adds no compensation between sub-devices, so the
        // faster one is delayed by the difference to sound together with the slowest.
        let aligned = OutputLatencyAlignment.align(flat.subDeviceUIDs, using: latency)
        Self.logger.notice("[LATENCY] \(aligned.summary, privacy: .public)")
        let description = flat.description(
            name: MusicOutputStack.aggregateName,
            uid: uid,
            extraOutputLatencyFrames: aligned.extraFrames
        )

        let (status, aggregateID) = hardware.createAggregate(description: description)
        guard status == noErr else {
            Self.logger.error("AudioHardwareCreateAggregateDevice failed: OSStatus \(status)")
            return nil
        }

        guard hardware.waitUntilReady(aggregateID) else {
            Self.logger.error("Aggregate device \(aggregateID) was not ready within the timeout")
            destroyDevice(aggregateID)
            return nil
        }

        // The HAL default of 512 frames leaves a Bluetooth sub-device no slack: it starves now and then and only that
        // one cuts out. Sized before the player starts its IO, the same way as for the app taps.
        let anyBluetooth = flat.subDeviceUIDs.contains { hardware.isBluetooth(deviceUID: $0) }
        let buffer = hardware.setIOBufferFrames(aggregateID, anyBluetooth: anyBluetooth)
        if buffer.status == noErr {
            Self.logger.notice("IO buffer \(buffer.frames) frames (bluetooth=\(anyBluetooth))")
        } else {
            Self.logger.warning("IO buffer \(buffer.frames) frames refused: \(buffer.status)")
        }
        return MusicOutputAggregate(uid: uid, objectID: aggregateID)
    }

    func destroy(_ aggregate: MusicOutputAggregate) {
        destroyDevice(aggregate.objectID)
    }

    private func destroyDevice(_ deviceID: AudioObjectID) {
        let status = hardware.destroyAggregate(deviceID)
        if status != noErr {
            Self.logger.error("AudioHardwareDestroyAggregateDevice failed for \(deviceID): OSStatus \(status)")
        }
    }
}

/// The real Core Audio calls.
@MainActor
final class CoreAudioMusicAggregateHardware: MusicAggregateHardware {
    func isBluetooth(deviceUID: String) -> Bool {
        Self.deviceID(forUID: deviceUID)?.isBluetoothDevice() ?? false
    }

    func memberUIDs(ofAggregate deviceUID: String) -> [String]? {
        Self.deviceID(forUID: deviceUID)?.aggregateSubDeviceUIDs()
    }

    func createAggregate(description: [String: Any]) -> (status: OSStatus, id: AudioObjectID) {
        var aggregateID: AudioObjectID = .unknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        if status == noErr { CrashGuard.trackDevice(aggregateID) }
        return (status, aggregateID)
    }

    func waitUntilReady(_ id: AudioObjectID) -> Bool {
        id.waitUntilReady(timeout: 2.0)
    }

    func setIOBufferFrames(_ id: AudioObjectID, anyBluetooth: Bool) -> (frames: UInt32, status: OSStatus) {
        ProcessTapController.setIOBufferFrameSize(aggregateID: id, anyBluetooth: anyBluetooth)
    }

    func destroyAggregate(_ id: AudioObjectID) -> OSStatus {
        CrashGuard.untrackDevice(id)
        return AudioHardwareDestroyAggregateDevice(id)
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard let ids = try? AudioObjectID.readDeviceList() else { return nil }
        return ids.first { (try? $0.readDeviceUID()) == uid }
    }
}
