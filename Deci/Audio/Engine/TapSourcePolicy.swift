// Deci/Audio/Engine/TapSourcePolicy.swift
import Foundation

/// Picks the kind of process tap for an app that follows a source device (the output it plays on by itself).
///
/// A device-stream tap (`CATapDescription(processes:deviceUID:stream:)`) can capture holes: runs of exact-zero frames
/// (340 frames, 7.7 ms at 44.1 kHz) cut into the app's audio, heard as static. The holes are in the capture itself:
/// a stereo mixdown tap of the same processes, open in the same window, stays clean. The bad state comes and goes per
/// stream (a page refresh in Chrome clears it), so it cannot be caught and repaired before it is heard.
///
/// A mixdown tap captures and mutes the app on every device, though (the HAL ignores a device scope on a mixdown), so
/// it is used only where it captures the same audio as the stream tap would: the app plays on no device other than
/// the source, and the source has at most two output channels (a mixdown is stereo). Otherwise the stream tap stays,
/// which keeps per-tab routing, Chrome Multi and multichannel interfaces working.
nonisolated enum TapSourcePolicy {
    enum Kind: Equatable, Sendable {
        /// A device-stream tap of the source device.
        case stream
        /// A stereo mixdown of the app's processes.
        case mixdown
    }

    /// - Parameters:
    ///   - sourceDeviceUID: The device the app follows; nil for an app Deci routes (always a mixdown).
    ///   - sourceOutputChannels: Output channels of the source device; nil when unread (counts as stereo).
    ///   - appOutputDeviceUIDs: The devices the app's processes output to now; nil when unread (keeps the stream tap).
    static func kind(sourceDeviceUID: String?, sourceOutputChannels: UInt32?, appOutputDeviceUIDs: Set<String>?) -> Kind {
        guard let source = sourceDeviceUID else { return .mixdown }
        if let channels = sourceOutputChannels, channels > 2 { return .stream }
        guard let outputs = appOutputDeviceUIDs else { return .stream }
        return outputs.isSubset(of: [source]) ? .mixdown : .stream
    }

    /// What a change in the app's output devices calls for, given the running tap.
    enum Rebuild: Equatable, Sendable {
        case none
        /// The app started playing on another device. A mixdown carries that audio to the source and mutes it where
        /// it belongs, so the stream tap is due at once.
        case now
        /// The app plays only on its source again. The mixdown is due once that has held for a while, so pausing and
        /// resuming a tab routed elsewhere does not rebuild the tap each time.
        case afterHold
    }

    /// - Parameters:
    ///   - running: The kind the running tap was built as (what `kind` picked then, even if a stream tap fell back to
    ///     a mixdown, so a fallback is not rebuilt over and over); nil when there is no tap.
    ///   - wanted: What `kind` picks now.
    ///   - appOutputDeviceUIDs: The devices the app's processes output to now, as passed to `kind`.
    static func rebuild(running: Kind?, wanted: Kind, appOutputDeviceUIDs: Set<String>?) -> Rebuild {
        guard let running, wanted != running else { return .none }
        // An app playing nowhere right now (paused, between tracks) gives no reason to change: keep the tap.
        if appOutputDeviceUIDs?.isEmpty == true { return .none }
        return wanted == .stream ? .now : .afterHold
    }
}
