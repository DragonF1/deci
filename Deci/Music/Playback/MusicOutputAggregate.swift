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
    func description(name: String, uid: String) -> [String: Any] {
        let subDevices: [[String: Any]] = subDeviceUIDs.enumerated().map { index, deviceUID in
            [
                kAudioSubDeviceUIDKey: deviceUID,
                // The clock device needs none; every other device is kept in step with it.
                kAudioSubDeviceDriftCompensationKey: index > 0
            ]
        }
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

/// The real aggregates, made through Core Audio. Each one is tracked by `CrashGuard`, so a crash does not leave it
/// behind in the system's device list.
@MainActor
final class CoreAudioMusicOutputAggregates: MusicOutputAggregating {
    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicOutputAggregates")

    func isBluetooth(deviceUID: String) -> Bool {
        Self.deviceID(forUID: deviceUID)?.isBluetoothDevice() ?? false
    }

    func makeAggregate(for stack: MusicOutputStack) -> MusicOutputAggregate? {
        let flat = stack.flattened { Self.deviceID(forUID: $0)?.aggregateSubDeviceUIDs() }
        let uid = "\(MusicOutputStack.aggregateName)-\(UUID().uuidString)"
        let description = flat.description(name: MusicOutputStack.aggregateName, uid: uid)

        var aggregateID: AudioObjectID = .unknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else {
            Self.logger.error("AudioHardwareCreateAggregateDevice failed: OSStatus \(status)")
            return nil
        }
        CrashGuard.trackDevice(aggregateID)

        guard aggregateID.waitUntilReady(timeout: 2.0) else {
            Self.logger.error("Aggregate device \(aggregateID) was not ready within the timeout")
            destroyDevice(aggregateID)
            return nil
        }
        return MusicOutputAggregate(uid: uid, objectID: aggregateID)
    }

    func destroy(_ aggregate: MusicOutputAggregate) {
        destroyDevice(aggregate.objectID)
    }

    private func destroyDevice(_ deviceID: AudioObjectID) {
        CrashGuard.untrackDevice(deviceID)
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        if status != noErr {
            Self.logger.error("AudioHardwareDestroyAggregateDevice failed for \(deviceID): OSStatus \(status)")
        }
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard let ids = try? AudioObjectID.readDeviceList() else { return nil }
        return ids.first { (try? $0.readDeviceUID()) == uid }
    }
}
