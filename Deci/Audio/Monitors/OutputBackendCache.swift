// Deci/Audio/Monitors/OutputBackendCache.swift
import AudioToolbox
import Observation

/// The volume backend of each tracked output device, as of the last time it was read. The Mixer popup's device rows read
/// this instead of asking CoreAudio from a view body: `DeviceVolumeMonitor.outputVolumeBackend(for:)` makes several
/// property reads on every call, and the hidden popup's body runs on every state change.
///
/// Every write is skipped when it would change nothing. A dictionary write always notifies its readers, so a repeated
/// answer must not reach it, or the rows are redrawn for nothing. The monitor keeps the entries true: on every state
/// read, after a Bluetooth output's confirmation, and each time the Mixer popup opens (`refresh`).
@MainActor
@Observable
final class OutputBackendCache {
    private(set) var tiers: [AudioDeviceID: VolumeControlTier] = [:]

    func tier(for deviceID: AudioDeviceID) -> VolumeControlTier? {
        tiers[deviceID]
    }

    /// Records the backend of one device. True when that changed the entry.
    @discardableResult
    func store(_ tier: VolumeControlTier, for deviceID: AudioDeviceID) -> Bool {
        guard tiers[deviceID] != tier else { return false }
        tiers[deviceID] = tier
        return true
    }

    func remove(_ deviceID: AudioDeviceID) {
        guard tiers[deviceID] != nil else { return }
        tiers.removeValue(forKey: deviceID)
    }

    func removeAll() {
        guard !tiers.isEmpty else { return }
        tiers.removeAll()
    }

    /// Asks `read` for the backend of each listed device, once, and keeps the entries in step: a changed answer replaces
    /// the entry, an unchanged one writes nothing, and a device that is no longer listed is dropped.
    func refresh(_ deviceIDs: [AudioDeviceID], using read: (AudioDeviceID) -> VolumeControlTier) {
        for deviceID in deviceIDs {
            store(read(deviceID), for: deviceID)
        }
        let listed = Set(deviceIDs)
        for deviceID in tiers.keys.filter({ !listed.contains($0) }) {
            remove(deviceID)
        }
    }
}
