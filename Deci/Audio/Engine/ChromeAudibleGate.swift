// Deci/Audio/Engine/ChromeAudibleGate.swift
import Foundation

/// What the Chrome extension says about whether any tab makes sound.
enum ChromeAudibleReport: Equatable {
    /// The extension is not connected, or tab tracking is off (it then reports no tabs at all): nothing is known.
    case unknown
    /// Connected and tracking, and no tab is audible and unmuted.
    case silent
    /// At least one tab is audible and not muted.
    case audible
}

/// Decides whether Chrome counts as "playing" for the stuck-tap watchdog, using the extension's word on its tabs.
///
/// Chrome keeps its output IO running while it makes no sound (paused tabs, page and offscreen AudioContexts), so the
/// watchdog's test "tap input silent while the app runs output" is true for a quiet Chrome all the time. Every probe
/// builds and tears down a second aggregate on the tapped output, which glitches all audio on a Bluetooth device: the
/// user hears static over Deci's own music. The extension knows which tabs are audible, so a Chrome with none is not
/// probed. Pure, so it can be tested without Core Audio or Chrome.
enum ChromeAudibleGate {
    /// Chrome's tab `audible` flag lingers about 2 s after the sound stops, and the extension adds its push debounce
    /// (150 ms), a `tabs.query` and the native messaging hop before Deci hears the flag clear. Until the tap's input has
    /// been silent this long, an audible tab proves nothing about a silent tap.
    static let audibleHold: Double = 3.5

    /// The watchdog's `appIsPlaying` for one tap: `running` (HAL IsRunningOutput, nil when unread) corrected by what the
    /// extension reports. `inputSilence` is how long the tap's input has been silent, in seconds. Rules, in order:
    static func appIsPlaying(running: Bool?, isChrome: Bool, report: ChromeAudibleReport, inputSilence: Double) -> Bool? {
        // Not running output, or not read: nothing to correct.
        guard running == true else { return running }
        // Not Chrome, or the extension says nothing: today's behaviour.
        guard isChrome, report != .unknown else { return running }
        // Signal is flowing: the tap hears Chrome (this keeps the output-silent rebuild rule working).
        if inputSilence < TapWatchdog.rescueThreshold(rung: 0) { return true }
        // Chrome makes no sound, so the tap's silence is expected. Not playing resets the watchdog to stopped.
        if report == .silent { return false }
        // Audible: the flag may be a leftover of sound that just ended, so before the hold there is no decision. Past it
        // a tab is still audible while the tap hears nothing: the tap may really be dead, so the ladder may probe.
        return inputSilence < audibleHold ? nil : true
    }

    /// The report for the extension's state. Only a connected extension that is tracking tabs can say anything: a
    /// disconnected one, or one with tab tracking off, has no tabs on record that mean "silent". A tab flagged audible
    /// but muted outputs nothing, so it does not count; neither does one turned down to volume 0 (a captured tab zeroed
    /// locally can stay flagged audible).
    static func report(connection: ChromeConnectionState, trackingTabs: Bool, tabs: [ChromeTab]) -> ChromeAudibleReport {
        guard connection == .connected, trackingTabs else { return .unknown }
        return tabs.contains { $0.isAudible && !$0.isMuted && $0.volume > 0 } ? .audible : .silent
    }
}
