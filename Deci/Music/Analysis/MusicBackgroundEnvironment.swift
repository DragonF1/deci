// Deci/Music/Analysis/MusicBackgroundEnvironment.swift
import Foundation
import IOKit.ps

/// The real machine and app behind `MusicBackgroundEnvironment`. The app's own state is read on the main actor through
/// closures the host supplies; the power state comes from ProcessInfo and IOKit's power sources.
struct MusicLiveBackgroundEnvironment: MusicBackgroundEnvironment {
    let enabled: @MainActor () -> Bool
    let playing: @MainActor () -> Bool
    let online: @MainActor () -> Bool
    let signedIn: @MainActor () -> Bool
    let downloadsBusy: @MainActor () -> Bool

    func isEnabled() async -> Bool { await enabled() }
    func isPlaying() async -> Bool { await playing() }
    func isOnline() async -> Bool { await online() }
    func isSignedIn() async -> Bool { await signedIn() }
    func isDownloadsBusy() async -> Bool { await downloadsBusy() }
    func isLowPowerMode() async -> Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    func isThermallyConstrained() async -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    func battery() async -> MusicBatteryState { Self.readBattery() }

    /// The internal battery from IOKit's power sources. A Mac with none (a desktop) is never on battery.
    static func readBattery() -> MusicBatteryState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return MusicBatteryState(onBattery: false, fraction: nil)
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            var fraction: Double?
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                fraction = Double(current) / Double(maximum)
            }
            return MusicBatteryState(onBattery: onBattery, fraction: fraction)
        }
        return MusicBatteryState(onBattery: false, fraction: nil)
    }
}
